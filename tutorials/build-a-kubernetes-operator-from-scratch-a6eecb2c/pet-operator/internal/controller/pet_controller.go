package controller

import (
	"context"
	"fmt"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/utils/ptr"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/recorder"

	zoov1alpha1 "example.com/pet-operator/api/v1alpha1"
)

const (
	Happy   = "Happy"
	Hungry  = "Hungry"
	RanAway = "RanAway"
)

type PetReconciler struct {
	client.Client
	Scheme   *runtime.Scheme
	Recorder recorder.EventRecorder
}

// Reconcile makes the world match one Pet. It is called with just a namespace/name,
// never with "what changed", so it always starts by reading the current state.
func (r *PetReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	// 1. Observe: fetch the desired state.
	var pet zoov1alpha1.Pet
	if err := r.Get(ctx, req.NamespacedName, &pet); err != nil {
		// Deleted? Nothing to do: owner references let the garbage collector remove the Pod and ConfigMap.
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	// How hungry is it? Nothing in the cluster changes when time passes,
	// so the controller has to work this out itself on every run.
	feedEvery, err := time.ParseDuration(pet.Spec.Diet.FeedEvery)
	if err != nil {
		return ctrl.Result{}, err
	}
	lastFed := pet.CreationTimestamp.Time
	if pet.Spec.LastFedAt != nil {
		lastFed = pet.Spec.LastFedAt.Time
	}
	now := time.Now()
	mood, moodChangesAt := moodAt(now, lastFed, feedEvery)

	// 2. Act: the ConfigMap holds the pet's "card", the Pod shows it.
	card := &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{Name: pet.Name + "-card", Namespace: pet.Namespace}}
	op, err := controllerutil.CreateOrUpdate(ctx, r.Client, card, func() error {
		// An existing ConfigMap has a ResourceVersion. Never take over one that isn't ours.
		if card.ResourceVersion != "" && !metav1.IsControlledBy(card, &pet) {
			return fmt.Errorf("ConfigMap %s already exists and doesn't belong to %s", card.Name, pet.Name)
		}
		card.Data = map[string]string{"card": renderCard(&pet, mood)}
		return controllerutil.SetControllerReference(&pet, card, r.Scheme)
	})
	if err != nil {
		return ctrl.Result{}, err
	}
	if op != controllerutil.OperationResultNone {
		logger.Info("card updated", "mood", mood, "operation", op)
	}

	podName, nameTaken, err := r.reconcilePod(ctx, &pet, card, mood)
	if err != nil {
		return ctrl.Result{}, err
	}

	// 3. Report: write what we observed to status.
	pet.Status.Mood = mood
	pet.Status.Face = faces[pet.Spec.Species][mood]
	pet.Status.PodName = podName
	pet.Status.ObservedGeneration = pet.Generation
	home := metav1.Condition{
		Type:               "AtHome",
		Status:             metav1.ConditionTrue,
		Reason:             mood,
		Message:            fmt.Sprintf("%s lives in Pod %s", pet.Name, podName),
		ObservedGeneration: pet.Generation,
	}
	if mood == RanAway {
		home.Status, home.Message = metav1.ConditionFalse, fmt.Sprintf("%s ran away. Feed it to bring it back.", pet.Name)
	}
	if nameTaken {
		home.Status, home.Reason = metav1.ConditionFalse, "PodNameTaken"
		home.Message = fmt.Sprintf("a Pod named %s already exists and doesn't belong to this Pet. Delete it and %s moves in.", pet.Name, pet.Name)
	}
	meta.SetStatusCondition(&pet.Status.Conditions, home)
	if err := r.Status().Update(ctx, &pet); err != nil {
		return ctrl.Result{}, err
	}

	// 4. Come back when the mood is due to change, even if nothing else happens.
	var wake time.Duration
	if !moodChangesAt.IsZero() {
		wake = moodChangesAt.Sub(now) + time.Second
	}
	// The cache sees every Pod, but only events on Pods we own queue a reconcile,
	// so nothing tells us when someone else's Pod goes away. Check back soon.
	if nameTaken && wake > 10*time.Second {
		wake = 10 * time.Second
	}
	return ctrl.Result{RequeueAfter: wake}, nil
}

// moodAt: fed less than feedEvery ago is Happy, less than 3x feedEvery is Hungry,
// anything longer and the pet runs away. It also says when the mood changes next.
func moodAt(now, lastFed time.Time, feedEvery time.Duration) (mood string, changesAt time.Time) {
	hungryAt := lastFed.Add(feedEvery)
	runAwayAt := lastFed.Add(3 * feedEvery)
	switch {
	case now.Before(hungryAt):
		return Happy, hungryAt
	case now.Before(runAwayAt):
		return Hungry, runAwayAt
	default:
		return RanAway, time.Time{} // it stays gone until someone feeds it
	}
}

// reconcilePod makes sure the pet's Pod exists, unless the pet ran away.
// Most of a Pod's spec can't be changed after creation, so the Pod never gets
// updated: anything that changes (the card) lives in the ConfigMap it mounts.
// It reports nameTaken if a Pod with the pet's name exists but isn't the pet's.
func (r *PetReconciler) reconcilePod(ctx context.Context, pet *zoov1alpha1.Pet, card *corev1.ConfigMap, mood string) (podName string, nameTaken bool, err error) {
	var pod corev1.Pod
	err = r.Get(ctx, client.ObjectKey{Namespace: pet.Namespace, Name: pet.Name}, &pod)
	exists := err == nil
	if err != nil && !apierrors.IsNotFound(err) {
		return "", false, err
	}

	// Never use, or delete, what you don't own.
	if exists && !metav1.IsControlledBy(&pod, pet) {
		if mood == RanAway {
			return "", false, nil
		}
		r.Recorder.Eventf(pet, &pod, corev1.EventTypeWarning, "PodNameTaken", "CreatePod", "Pod %s already exists and doesn't belong to %s", pod.Name, pet.Name)
		return "", true, nil
	}

	if mood == RanAway {
		if exists && pod.DeletionTimestamp == nil {
			if err := r.Delete(ctx, &pod); client.IgnoreNotFound(err) != nil {
				return "", false, err
			}
			r.Recorder.Eventf(pet, &pod, corev1.EventTypeWarning, "RanAway", "Starve", "%s got too hungry and ran away", pet.Name)
		}
		return "", false, nil
	}
	if exists {
		return pod.Name, false, nil
	}

	pod = corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      pet.Name,
			Namespace: pet.Namespace,
		},
		Spec: corev1.PodSpec{
			TerminationGracePeriodSeconds: ptr.To[int64](1),
			Containers: []corev1.Container{{
				Name:         "pet",
				Image:        "busybox:1.37",
				Command:      []string{"sh", "-c", `while true; do echo "--- $(date +%T)"; cat /pet/card; sleep 10; done`},
				VolumeMounts: []corev1.VolumeMount{{Name: "card", MountPath: "/pet"}},
			}},
			Volumes: []corev1.Volume{{
				Name: "card",
				VolumeSource: corev1.VolumeSource{ConfigMap: &corev1.ConfigMapVolumeSource{
					LocalObjectReference: corev1.LocalObjectReference{Name: card.Name},
				}},
			}},
		},
	}
	if err := controllerutil.SetControllerReference(pet, &pod, r.Scheme); err != nil {
		return "", false, err
	}
	if err := r.Create(ctx, &pod); apierrors.IsAlreadyExists(err) {
		// The cache hasn't seen the Pod we created a moment ago yet. The next reconcile will.
		return pod.Name, false, nil
	} else if err != nil {
		return "", false, err
	}
	r.Recorder.Eventf(pet, &pod, corev1.EventTypeNormal, "MovedIn", "CreatePod", "%s moved into Pod %s", pet.Name, pod.Name)
	return pod.Name, false, nil
}

var faces = map[string]map[string]string{
	"cat":    {Happy: "😺", Hungry: "😾", RanAway: "💨"},
	"dog":    {Happy: "🐶", Hungry: "🥺", RanAway: "💨"},
	"dragon": {Happy: "🐲", Hungry: "🔥", RanAway: "💨"},
	"cactus": {Happy: "🌵", Hungry: "🥀", RanAway: "💨"},
}

var art = map[string]string{
	"cat": `
  /\_/\
 ( %s )
  > ^ <`,
	"dog": `
  /^ ^\
 / %s \
 V\ Y /V
  / - \
 |    \
 || (__V`,
	"dragon": `
   __/\__
  (  %s  )~~<
   \_vv_/  ~~`,
	"cactus": `
      _
   _ | | _
  | || || |
   \_%s_/
     | |
   __|_|__`,
}

var eyes = map[string]string{Happy: "^.^", Hungry: "o.o", RanAway: "   "}

func renderCard(pet *zoov1alpha1.Pet, mood string) string {
	var b strings.Builder
	switch mood {
	case RanAway:
		fmt.Fprintf(&b, "%s ran away. Feed it to bring it back!\n", pet.Name)
		return b.String()
	case Hungry:
		fmt.Fprintf(&b, "%s is HUNGRY. %s, please!\n", pet.Name, pet.Spec.Diet.Food)
	default:
		fmt.Fprintf(&b, "%s is happy.\n", pet.Name)
	}
	fmt.Fprintf(&b, art[pet.Spec.Species]+"\n", eyes[mood])
	if pet.Spec.Toy != "" {
		fmt.Fprintf(&b, "playing with: %s\n", pet.Spec.Toy)
	}
	return b.String()
}

// SetupWithManager wires up the watches: every Pet event, and every event on a
// Pod or ConfigMap a Pet owns, ends up as a Reconcile call for that Pet.
func (r *PetReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&zoov1alpha1.Pet{}).
		Owns(&corev1.Pod{}).
		Owns(&corev1.ConfigMap{}).
		Complete(r)
}

package controller

import (
	"context"
	"fmt"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/tools/record"
	"k8s.io/utils/ptr"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"

	platformv1alpha1 "example.com/backup-operator/api/v1alpha1"
)

// The "backup agent" is a stand-in: it tars the PVC's contents to prove it could read them.
const backupScript = `echo "backing up pvc ${PVC} with ${METHOD} to ${REPOSITORY:-<local>}"
tar czf /tmp/backup.tgz -C /data .
echo "done: $(wc -c < /tmp/backup.tgz) bytes"`

type BackupScheduleReconciler struct {
	client.Client
	Scheme   *runtime.Scheme
	Recorder record.EventRecorder
}

// Reconcile makes the world match one BackupSchedule. It is called with just a
// namespace/name, never with "what changed", so it always starts by reading the
// current state from scratch.
func (r *BackupScheduleReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	// 1. Observe: fetch the desired state.
	var bs platformv1alpha1.BackupSchedule
	if err := r.Get(ctx, req.NamespacedName, &bs); err != nil {
		// Deleted? Nothing to do: the owner reference lets the garbage collector remove the CronJob.
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	// 2. Act: make the CronJob look the way the BackupSchedule says it should.
	cj := &batchv1.CronJob{ObjectMeta: metav1.ObjectMeta{
		Name:      bs.Name + "-backup",
		Namespace: bs.Namespace,
	}}
	op, err := controllerutil.CreateOrUpdate(ctx, r.Client, cj, func() error {
		mutateCronJob(cj, &bs)
		return controllerutil.SetControllerReference(&bs, cj, r.Scheme)
	})
	if err != nil {
		return ctrl.Result{}, err
	}
	if op != controllerutil.OperationResultNone {
		logger.Info("CronJob reconciled", "cronjob", cj.Name, "operation", op)
		r.Recorder.Eventf(&bs, corev1.EventTypeNormal, "CronJobReconciled", "CronJob %s %s", cj.Name, op)
	}

	// 3. Report: write what we observed to status.
	bs.Status.ObservedGeneration = bs.Generation
	bs.Status.CronJobName = cj.Name
	bs.Status.LastBackupTime = cj.Status.LastSuccessfulTime
	ready := metav1.Condition{
		Type:               "Ready",
		Status:             metav1.ConditionTrue,
		Reason:             "Scheduled",
		Message:            fmt.Sprintf("CronJob %s runs %q", cj.Name, cj.Spec.Schedule),
		ObservedGeneration: bs.Generation,
	}
	if bs.Spec.Suspend {
		ready.Status, ready.Reason, ready.Message = metav1.ConditionFalse, "Suspended", "backups are suspended"
	}
	meta.SetStatusCondition(&bs.Status.Conditions, ready)

	if err := r.Status().Update(ctx, &bs); err != nil {
		return ctrl.Result{}, err
	}
	return ctrl.Result{}, nil
}

// mutateCronJob sets only the fields this controller owns and leaves everything
// else (including the defaults the API server filled in) alone. Replacing whole
// structs here would wipe those defaults, so every reconcile would look like a
// change and send a pointless update to the API server.
func mutateCronJob(cj *batchv1.CronJob, bs *platformv1alpha1.BackupSchedule) {
	cj.Spec.Schedule = bs.Spec.Schedule
	cj.Spec.Suspend = ptr.To(bs.Spec.Suspend)
	cj.Spec.ConcurrencyPolicy = batchv1.ForbidConcurrent
	cj.Spec.SuccessfulJobsHistoryLimit = ptr.To(bs.Spec.Retention.KeepLast)

	pod := &cj.Spec.JobTemplate.Spec.Template.Spec
	pod.RestartPolicy = corev1.RestartPolicyOnFailure
	pod.Volumes = []corev1.Volume{{
		Name: "data",
		VolumeSource: corev1.VolumeSource{PersistentVolumeClaim: &corev1.PersistentVolumeClaimVolumeSource{
			ClaimName: bs.Spec.Source.PVCName,
			ReadOnly:  true,
		}},
	}}

	if len(pod.Containers) == 0 {
		pod.Containers = []corev1.Container{{}}
	}
	c := &pod.Containers[0]
	c.Name = "backup"
	c.Image = "busybox:1.36"
	c.Command = []string{"sh", "-c", backupScript}
	c.Env = []corev1.EnvVar{
		{Name: "PVC", Value: bs.Spec.Source.PVCName},
		{Name: "METHOD", Value: bs.Spec.Method},
		{Name: "REPOSITORY", Value: bs.Spec.Repository},
	}
	c.VolumeMounts = []corev1.VolumeMount{{Name: "data", MountPath: "/data", ReadOnly: true}}
}

// SetupWithManager wires up the watches: every BackupSchedule event, and every event
// on a CronJob it owns, ends up as a Reconcile call for that BackupSchedule.
func (r *BackupScheduleReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&platformv1alpha1.BackupSchedule{}).
		Owns(&batchv1.CronJob{}).
		Complete(r)
}

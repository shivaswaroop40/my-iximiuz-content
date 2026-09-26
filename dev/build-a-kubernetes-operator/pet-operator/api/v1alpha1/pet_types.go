package v1alpha1

import metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

// +kubebuilder:validation:XValidation:rule="self.species != 'cactus' || !has(self.toy)",message="cacti don't play with toys"
// +kubebuilder:validation:XValidation:rule="self.species != 'dragon' || duration(self.diet.feedEvery) >= duration('1h')",message="dragons eat at most once an hour: diet.feedEvery must be at least 1h"
type PetSpec struct {
	// +kubebuilder:validation:Enum=cat;dog;dragon;cactus
	Species string `json:"species"`

	// +kubebuilder:validation:MaxLength=20
	// +optional
	Toy string `json:"toy,omitempty"`

	// +kubebuilder:default={}
	// +optional
	Diet Diet `json:"diet,omitempty"`

	// When the pet was last fed. Feed it by setting this to the current time.
	// +optional
	LastFedAt *metav1.Time `json:"lastFedAt,omitempty"`
}

type Diet struct {
	// +kubebuilder:validation:MaxLength=20
	// +kubebuilder:default=snacks
	// +optional
	Food string `json:"food,omitempty"`

	// How often the pet needs food, e.g. "10m" or "6h".
	// +kubebuilder:validation:MaxLength=10
	// +kubebuilder:validation:Pattern=`^[0-9]+(s|m|h)$`
	// +kubebuilder:validation:XValidation:rule="duration(self) >= duration('1s') && duration(self) <= duration('8760h')",message="feedEvery must be between 1s and 8760h (a year)"
	// +kubebuilder:default="10m"
	// +optional
	FeedEvery string `json:"feedEvery,omitempty"`
}

type PetStatus struct {
	// Happy, Hungry or RanAway.
	// +optional
	Mood string `json:"mood,omitempty"`

	// +optional
	Face string `json:"face,omitempty"`

	// The Pod the pet lives in. Empty if it ran away.
	// +optional
	PodName string `json:"podName,omitempty"`

	// The .metadata.generation the controller last acted on.
	// +optional
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`

	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:shortName=pt,categories=zoo
// +kubebuilder:printcolumn:name="Species",type=string,JSONPath=`.spec.species`
// +kubebuilder:printcolumn:name="Face",type=string,JSONPath=`.status.face`
// +kubebuilder:printcolumn:name="Mood",type=string,JSONPath=`.status.mood`
// +kubebuilder:printcolumn:name="Toy",type=string,JSONPath=`.spec.toy`
// +kubebuilder:printcolumn:name="Last Fed",type=date,JSONPath=`.spec.lastFedAt`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`
type Pet struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   PetSpec   `json:"spec"`
	Status PetStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true
type PetList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []Pet `json:"items"`
}

func init() {
	SchemeBuilder.Register(&Pet{}, &PetList{})
}

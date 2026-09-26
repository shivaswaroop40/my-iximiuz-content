package v1alpha1

import metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

// +kubebuilder:validation:XValidation:rule="self.method != 'restic' || has(self.repository)",message="repository is required when method is restic"
type BackupScheduleSpec struct {
	// A 5-field cron expression, e.g. "0 2 * * *".
	// +kubebuilder:validation:Pattern=`^(\S+\s+){4}\S+$`
	Schedule string `json:"schedule"`

	Source BackupSource `json:"source"`

	// +kubebuilder:validation:Enum=snapshot;restic
	// +kubebuilder:default=snapshot
	// +optional
	Method string `json:"method,omitempty"`

	// +optional
	Repository string `json:"repository,omitempty"`

	// +kubebuilder:default={}
	// +optional
	Retention Retention `json:"retention,omitempty"`

	// +kubebuilder:default=false
	// +optional
	Suspend bool `json:"suspend,omitempty"`
}

type BackupSource struct {
	// +kubebuilder:validation:MinLength=1
	PVCName string `json:"pvcName"`
}

type Retention struct {
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=30
	// +kubebuilder:default=7
	// +optional
	KeepLast int32 `json:"keepLast,omitempty"`
}

type BackupScheduleStatus struct {
	// The .metadata.generation the controller last acted on.
	// +optional
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`

	// +optional
	CronJobName string `json:"cronJobName,omitempty"`

	// +optional
	LastBackupTime *metav1.Time `json:"lastBackupTime,omitempty"`

	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:shortName=bks,categories=platform
// +kubebuilder:printcolumn:name="Schedule",type=string,JSONPath=`.spec.schedule`
// +kubebuilder:printcolumn:name="Method",type=string,JSONPath=`.spec.method`
// +kubebuilder:printcolumn:name="Keep",type=integer,JSONPath=`.spec.retention.keepLast`
// +kubebuilder:printcolumn:name="Suspended",type=boolean,JSONPath=`.spec.suspend`
// +kubebuilder:printcolumn:name="Ready",type=string,JSONPath=`.status.conditions[?(@.type=="Ready")].status`
// +kubebuilder:printcolumn:name="Last Backup",type=date,JSONPath=`.status.lastBackupTime`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`
type BackupSchedule struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   BackupScheduleSpec   `json:"spec"`
	Status BackupScheduleStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true
type BackupScheduleList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []BackupSchedule `json:"items"`
}

func init() {
	SchemeBuilder.Register(&BackupSchedule{}, &BackupScheduleList{})
}

package resources

import (
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
)

const (
	DefaultCPURequest    = "50m"
	DefaultMemoryRequest = "50Mi"
	DefaultCPULimit      = "100m"
	DefaultMemoryLimit   = "100Mi"
)

func NewResourceRequirements(cpuRequest, memoryRequest, cpuLimit, memoryLimit string) corev1.ResourceRequirements {
	return corev1.ResourceRequirements{
		Requests: corev1.ResourceList{
			corev1.ResourceCPU:    resource.MustParse(cpuRequest),
			corev1.ResourceMemory: resource.MustParse(memoryRequest),
		},
		Limits: corev1.ResourceList{
			corev1.ResourceCPU:    resource.MustParse(cpuLimit),
			corev1.ResourceMemory: resource.MustParse(memoryLimit),
		},
	}
}

func DefaultResourceRequirement() corev1.ResourceRequirements {
	return NewResourceRequirements(DefaultCPURequest, DefaultMemoryRequest, DefaultCPULimit, DefaultMemoryLimit)
}

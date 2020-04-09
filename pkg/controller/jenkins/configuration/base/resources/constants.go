package resources

import corev1 "k8s.io/api/core/v1"

const (
	// NamespaceDefault means the object is in the default namespace which is applied when not specified by clients
	JenkinsAppLabelName    = "app"
	JenkinsWebPortName     = "web"
	JenkinsWebPortProtocol = corev1.ProtocolTCP
	JenkinsWebPort         = 80
	JenkinsWebPortAsInt    = 8080
	JenkinsWebPortAsStr    = "8080"

	JenkinsAgentPortName     = "agent"
	JenkinsAgentPortProtocol = corev1.ProtocolTCP
	JenkinsAgentPort         = 50000
	JenkinsAgentPortAsInt    = 50000
	JenkinsAgentPortAsStr    = "50000"

	JenkinsServiceName       = "jenkins"
	JenkinsJNLPServiceName   = "jenkins-jnlp"
	JenkinsJnlpServiceSuffix = "-jnlp"
	JenkinsContainerName     = "jenkins"
	JenkinsContainerMemory   = "1Gi"
	JenkinsAppLabel          = "app"
	JenkinsNameLabel         = "name"

	JenkinsPvcName         = "jenkins"
	JenkinsPvcDefaultSize  = "1Gi"
	JenkinsVolumeName      = "jenkins-data"
	JenkinsVolumeMountPath = "/var/lib/jenkins"
	DefaultTerminationMessagePath = "/dev/termination-log"
	DefaultResourceMemory = "1Gi"
	DefaultJenkinsImage             = "image-registry.openshift-image-registry.svc:5000/openshift/jenkins"
)

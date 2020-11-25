package kubetest

import (
	osapps_v1 "github.com/openshift/api/apps/v1"
	"github.com/stretchr/testify/mock"
	apps_v1 "k8s.io/api/apps/v1"
	batch_v1 "k8s.io/api/batch/v1"
	batch_apps_v1 "k8s.io/api/batch/v1beta1"
	core_v1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	meta_v1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/version"

	"github.com/kiali/kiali/kubernetes"
)

//// Mock for the K8SClientFactory

type K8SClientFactoryMock struct {
	mock.Mock
	k8s kubernetes.ClientInterface
}

// Constructor
func NewK8SClientFactoryMock(k8s kubernetes.ClientInterface) *K8SClientFactoryMock {
	k8sClientFactory := new(K8SClientFactoryMock)
	k8sClientFactory.k8s = k8s
	return k8sClientFactory
}

// Business Methods
func (o *K8SClientFactoryMock) GetClient(token string) (kubernetes.ClientInterface, error) {
	return o.k8s, nil
}

/////

type K8SClientMock struct {
	mock.Mock
}

// Constructor

func NewK8SClientMock() *K8SClientMock {
	k8s := new(K8SClientMock)
	k8s.On("IsOpenShift").Return(true)
	return k8s
}

// Business methods

// MockEmptyWorkloads setup the current mock to return empty workloads for every type of workloads (deployment, dc, rs, jobs, etc.)
func (o *K8SClientMock) MockEmptyWorkloads(namespace interface{}) {
	o.On("GetDeployments", namespace).Return([]apps_v1.Deployment{}, nil)
	o.On("GetReplicaSets", namespace).Return([]apps_v1.ReplicaSet{}, nil)
	o.On("GetReplicationControllers", namespace).Return([]core_v1.ReplicationController{}, nil)
	o.On("GetDeploymentConfigs", namespace).Return([]osapps_v1.DeploymentConfig{}, nil)
	o.On("GetStatefulSets", namespace).Return([]apps_v1.StatefulSet{}, nil)
	o.On("GetJobs", namespace).Return([]batch_v1.Job{}, nil)
	o.On("GetCronJobs", namespace).Return([]batch_apps_v1.CronJob{}, nil)
}

// MockEmptyWorkload setup the current mock to return an empty workload for every type of workloads (deployment, dc, rs, jobs, etc.)
func (o *K8SClientMock) MockEmptyWorkload(namespace interface{}, workload interface{}) {
	gr := schema.GroupResource{
		Group:    "test-group",
		Resource: "test-resource",
	}
	notfound := errors.NewNotFound(gr, "not found")
	o.On("GetDeployment", namespace, workload).Return(&apps_v1.Deployment{}, notfound)
	o.On("GetStatefulSet", namespace, workload).Return(&apps_v1.StatefulSet{}, notfound)
	o.On("GetDeploymentConfig", namespace, workload).Return(&osapps_v1.DeploymentConfig{}, notfound)
	o.On("GetReplicaSets", namespace).Return([]apps_v1.ReplicaSet{}, nil)
	o.On("GetReplicationControllers", namespace).Return([]core_v1.ReplicationController{}, nil)
	o.On("GetJobs", namespace).Return([]batch_v1.Job{}, nil)
	o.On("GetCronJobs", namespace).Return([]batch_apps_v1.CronJob{}, nil)
}

func (o *K8SClientMock) IsOpenShift() bool {
	args := o.Called()
	return args.Get(0).(bool)
}

func (o *K8SClientMock) IsMaistraApi() bool {
	args := o.Called()
	return args.Get(0).(bool)
}

func (o *K8SClientMock) GetServerVersion() (*version.Info, error) {
	args := o.Called()
	return args.Get(0).(*version.Info), args.Error(1)
}

func (o *K8SClientMock) GetToken() string {
	args := o.Called()
	return args.Get(0).(string)
}

func (o *K8SClientMock) MockService(namespace, name string) {
	s := fakeService(namespace, name)
	o.On("GetService", namespace, name).Return(&s, nil)
}

func (o *K8SClientMock) MockServices(namespace string, names []string) {
	services := []core_v1.Service{}
	for _, name := range names {
		services = append(services, fakeService(namespace, name))
	}
	o.On("GetServices", namespace, mock.AnythingOfType("map[string]string")).Return(services, nil)
	o.On("GetDeployments", mock.AnythingOfType("string"), mock.AnythingOfType("string")).Return([]apps_v1.Deployment{}, nil)
}

func fakeService(namespace, name string) core_v1.Service {
	return core_v1.Service{
		ObjectMeta: meta_v1.ObjectMeta{
			Name:      name,
			Namespace: namespace,
			Labels: map[string]string{
				"app": name,
			},
		},
		Spec: core_v1.ServiceSpec{
			ClusterIP: "fromservice",
			Type:      "ClusterIP",
			Selector:  map[string]string{"app": name},
			Ports: []core_v1.ServicePort{
				{
					Name:     "http",
					Protocol: "TCP",
					Port:     3001,
				},
				{
					Name:     "http",
					Protocol: "TCP",
					Port:     3000,
				},
			},
		},
	}
}

func FakePodList() []core_v1.Pod {
	return []core_v1.Pod{
		{
			ObjectMeta: meta_v1.ObjectMeta{
				Name:        "reviews-v1",
				Labels:      map[string]string{"app": "reviews", "version": "v1"},
				Annotations: FakeIstioAnnotations(),
			},
		},
		{
			ObjectMeta: meta_v1.ObjectMeta{
				Name:        "reviews-v2",
				Labels:      map[string]string{"app": "reviews", "version": "v2"},
				Annotations: FakeIstioAnnotations(),
			},
		},
		{
			ObjectMeta: meta_v1.ObjectMeta{
				Name:        "httpbin-v1",
				Labels:      map[string]string{"app": "httpbin", "version": "v1"},
				Annotations: FakeIstioAnnotations(),
			},
		},
	}
}

func FakeIstioAnnotations() map[string]string {
	return map[string]string{"sidecar.istio.io/status": "{\"version\":\"\",\"initContainers\":[\"istio-init\",\"enable-core-dump\"],\"containers\":[\"istio-proxy\"],\"volumes\":[\"istio-envoy\",\"istio-certs\"]}"}
}

func FakeNamespace(name string) *core_v1.Namespace {
	return &core_v1.Namespace{
		ObjectMeta: meta_v1.ObjectMeta{
			Name: name,
		},
	}
}

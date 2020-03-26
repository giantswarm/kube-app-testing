#!/bin/bash -e

# TODO:
# - add CLI options
#   - `--cleanup` whether to delete the cluster after test or not
#   - CHART_NAME ($1) arg - validate if the dir exists
# - create App's ConfigMap/Secrets before creating App CR
# - validate necessary tools are installed:
#   - kind
#   - helm (2!)
#   - awk
# - add option to create worker nodes as well (and how many)
# - add option to use diffrent k8s version
# - add option to use custom kind config (docs necessary, as we need some options there)
# - switch CNI to calico to be compatible(-ish, screw AWS CNI)
# - add logging with timestamps
# - add support for pre-test hooks: installtion of dependencies, like cert-manager
# - add version information 


if [[ $# < 1 ]]; then
  echo "Usage:"
  echo ""
  echo "  $0 [chart_dir_name] - the name of the chart and also the dir in 'helm/' dir"
  exit 1
fi
CHART_NAME=$1

CONFIG_DIR=/tmp/kind_test
export KUBECONFIG=${CONFIG_DIR}/kubei.config
CLUSTER_NAME=kt
TOOLS_NAMESPACE=giantswarm

ARCHITECT_VERSION_TAG=latest
CHART_MUSEUM_VERSION_TAG=latest

####################
# Files & templates
####################

chart_museum_deploy () {
  name="chart-museum"
  image=chartmuseum/chartmuseum:${CHART_MUSEUM_VERSION_TAG}

  kubectl create -f - << EOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}
  labels:
    app: ${name}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${name}
  template:
    metadata:
      labels:
        app: ${name}
    spec:
      containers:
      - name: ${name}
        image: ${image}
        ports:
          - containerPort: 8080
        env:
        - name: DEBUG
          value: "true"
        - name: STORAGE
          value: "local"
        - name: STORAGE_LOCAL_ROOTDIR
          value: "/charts"
        volumeMounts:
        - mountPath: /charts
          name: chart-volume
      volumes:
      - name: chart-volume
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: ${name}
  labels:
    app: ${name}
spec:
  type: NodePort
  ports:
  - port: 8080
    protocol: TCP
    targetPort: 8080
    nodePort: 30100
  selector:
    app: ${name}
EOF
  kubectl rollout status deployment ${name}
}

create_kind_config () {
  cat > $1 << EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
# switch to calico later
#networking:
  # the default CNI will not be installed
  #disableDefaultCNI: true
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 30100
    hostPort: 8080
    listenAddress: "127.0.0.1"
    protocol: TCP
  #  extraMounts:
  #  - hostPath: /tmp/kind_test
  #    containerPath: /tmp/kind_test
EOF
}

create_app_catalog_cr () {
  kubectl create -f - << EOF
apiVersion: application.giantswarm.io/v1alpha1
kind: AppCatalog
metadata:
  labels:
    app-operator.giantswarm.io/version: 1.0.0
    application.giantswarm.io/catalog-type: ""
  name: testing
spec:
  description: 'Catalog to hold charts for testing.'
  storage:
    URL: http://chart-museum.default.svc.cluster.local:8080/charts/
    type: helm
  title: Testing Catalog
EOF
}

create_app_cr () {
  name=$1
  version=$2

  kubectl create -f - << EOF
apiVersion: application.giantswarm.io/v1alpha1
kind: App
metadata:
  name: ${name}
  namespace: default

  labels:
    app: ${name}
    app-operator.giantswarm.io/version: "1.0.0"

spec:
  catalog: testing
  version: ${version}
  kubeConfig:
    inCluster: true
  name: ${name}
  namespace: default
EOF
}

##################
# functions
##################

wait_for_resource () {
  resource=$1

  while true; do 
    kubectl get --no-headers $resource 1>/dev/null 2>&1 && break
    echo "Waiting for resource ${resource} to be present in cluster..."
    sleep 1
  done
  echo "Resource ${resource} present."
}

create_cluster () {
  if [[ ! -d ${CONFIG_DIR} ]]; then
    mkdir ${CONFIG_DIR}
  fi
  create_kind_config ${CONFIG_DIR}/kind.yaml
  kind create cluster --name ${CLUSTER_NAME} --config ${CONFIG_DIR}/kind.yaml
  kind get kubeconfig --name ${CLUSTER_NAME} --internal > ${KUBECONFIG}
  kubectl -n kube-system rollout status deployment coredns
}

delete_cluster () {
  kind delete cluster --name ${CLUSTER_NAME}
}

start () {
  kubeconfig=$(cat ${KUBECONFIG})
  # start chart-museum
  chart_museum_deploy
  # create giantswarm namespace
  kubectl create ns $TOOLS_NAMESPACE
  # start app+chart-operators
  kubectl create serviceaccount appcatalog
  kubectl create clusterrolebinding appcatalog_cluster-admin --clusterrole=cluster-admin --serviceaccount=default:appcatalog
  kubectl run app-operator --serviceaccount=appcatalog --generator=run-pod/v1 --image=quay.io/giantswarm/app-operator -- daemon --service.kubernetes.kubeconfig="${kubeconfig}" --service.kubernetes.incluster="false"
  kubectl run chart-operator --serviceaccount=appcatalog --generator=run-pod/v1 --image=quay.io/giantswarm/chart-operator -- daemon --service.kubernetes.kubeconfig="${kubeconfig}" --server.listen.address="http://127.0.0.1:7000" --service.kubernetes.incluster="false"
  kubectl wait --for=condition=Ready pod/app-operator
  kubectl wait --for=condition=Ready pod/chart-operator
  wait_for_resource crd/appcatalogs.application.giantswarm.io
  wait_for_resource crd/apps.application.giantswarm.io
  wait_for_resource crd/charts.application.giantswarm.io
  create_app_catalog_cr
}

build_chart () {
  docker run -it --rm -v $(pwd):/workdir -w /workdir quay.io/giantswarm/architect:${ARCHITECT_VERSION_TAG} helm template --validate --dir helm/$1
  chart_log=$(helm package helm/$1)
  echo $chart_log
  chart_name=$(echo $chart_log | awk -F "/" '{print $NF}')
  echo "Uploading chart ${chart_name} to chart-museum..."
  curl --data-binary "@${chart_name}" http://localhost:8080/api/charts
}

create_app () {
  name=$1
  version=$(docker run -it --rm -v $(pwd):/workdir -w /workdir quay.io/giantswarm/architect:${ARCHITECT_VERSION_TAG} project version | tr -d '\r')

  echo "Creating 'app CR' with version=${version} and name=${name}"
  create_app_cr $name $version
}

delete_cluster
create_cluster
start
build_chart ${CHART_NAME}
create_app ${CHART_NAME}
#delete_cluster

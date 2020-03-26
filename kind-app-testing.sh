#!/bin/bash -ex

if [[ $# < 1 ]]; then
  echo "Usage:"
  echo ""
  echo "  $0 [chart_dir_name]"
  exit 1
fi
CHART_NAME=$1

CONFIG_DIR=/tmp/kind_test
export KUBECONFIG=${CONFIG_DIR}/kubei.config
CLUSTER_NAME=kt
CR_NAMESPACE=giantswarm
#KUBECONFIG_INTERNAL_DIR=/tmp/kind_test
#KUBECONFIG_INTERNAL=${KUBECONFIG_INTERNAL_DIR}/kubei.config

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

##################
# functions
##################

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
  kubectl create ns $CR_NAMESPACE
  # start app+chart-operators
  kubectl run app-operator --generator=run-pod/v1 --image=quay.io/giantswarm/app-operator -- daemon --service.kubernetes.kubeconfig="${kubeconfig}" --service.kubernetes.incluster="false"
  kubectl run chart-operator --generator=run-pod/v1 --image=quay.io/giantswarm/chart-operator -- daemon --service.kubernetes.kubeconfig="${kubeconfig}" --server.listen.address="http://127.0.0.1:7000" --service.kubernetes.incluster="false"
}

build_chart () {
  docker run -it --rm -v $(pwd):/workdir -w /workdir quay.io/giantswarm/architect:${ARCHITECT_VERSION_TAG} helm template --validate --dir helm/$1
  chart_log=$(helm package helm/$1)
  echo $chart_log
  chart_name=$(echo $chart_log | awk -F "/" '{print $NF}')
#  kubectl port-forward svc/chart-museum  8080:8080 &
#  port_forward_pid=$!
  echo "Uploading chart ${chart_name} to chart-museum..."
  curl --data-binary "@${chart_name}" http://localhost:8080/api/charts
#  kill $port_forward_pid
}

delete_cluster
create_cluster
start
build_chart ${CHART_NAME}
#delete_cluster


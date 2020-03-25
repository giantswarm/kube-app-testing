#!/bin/bash

KUBECONFIG_DIR=/tmp/kind_test
export KUBECONFIG=${KUBECONFIG_DIR}/kubei.config
KUBECONFIG_INTERNAL_DIR=/tmp/kind_test
KUBECONFIG_INTERNAL=${KUBECONFIG_INTERNAL_DIR}/kubei.config
CLUSTER_NAME=kt
KIND_CONFIG=kind.yaml
CR_NAMESPACE=giantswarm

create_cluster () {
  if [[ ! -d ${KUBECONFIG_DIR} ]]; then
    mkdir ${KUBECONFIG_DIR}
  fi
  kind create cluster --name ${CLUSTER_NAME} --config ${KIND_CONFIG}
  kind get kubeconfig --name ${CLUSTER_NAME} --internal > ${KUBECONFIG}
  kubectl -n kube-system rollout status deployment coredns
}

delete_cluster () {
  kind delete cluster --name ${CLUSTER_NAME}
}

start () {
  kubeconfig=$(cat ${KUBECONFIG_INTERNAL})
  # start chart-museum
  kubectl run chart-museum --restart Always --expose --port 8080 --hostport=8080 -l "app=chrt-museum" --env DEBUG=true --env STORAGE=local --env STORAGE_LOCAL_ROOTDIR=/charts --generator run-pod/v1 --image chartmuseum/chartmuseum:latest
  # create giantswarm namespace
  kubectl create ns $CR_NAMESPACE
  # start app+chart-operators
#kubectl run app-operator --generator=run-pod/v1 --image=quay.io/giantswarm/app-operator -- daemon --service.kubernetes.kubeconfig="${kubeconfig}" --service.kubernetes.incluster="false"
#kubectl run chart-operator --generator=run-pod/v1 --image=quay.io/giantswarm/chart-operator -- daemon --service.kubernetes.kubeconfig="${kubeconfig}" --server.listen.address="http://127.0.0.1:7000" --service.kubernetes.incluster="false"
}

build_chart () {
docker run -it --rm -v $(pwd):/workdir -w /workdir quay.io/giantswarm/architect:latest helm template --validate --dir helm/$1
}

chart_name=$1
#delete_cluster
#create_cluster
#start
build_chart $chart_name
#delete_cluster

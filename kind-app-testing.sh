#!/bin/bash -e

# TODO:
# - add CLI options
#   - `--cleanup` whether to delete the cluster after test or not
#   - CHART_NAME ($1) arg - validate if the dir exists
# - validate necessary tools are installed:
#   - kind
#   - helm (2!)
#   - pipenv
# - add option to create worker nodes as well (and how many)
# - add option to use diffrent k8s version
# - add option to use custom kind config (docs necessary, as we need some options there)
# - switch CNI to calico to be compatible(-ish, screw AWS CNI)
# - add logging with timestamps
# - add support for pre-test hooks: installtion of dependencies, like cert-manager
# - add version information 


if [[ $# -lt 1 ]]; then
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
CHART_DEPLOY_NAMESPACE=default
MAX_WAIT_FOR_HELM_STATUS_DEPLOY_SEC=60

ARCHITECT_VERSION_TAG=latest
CHART_MUSEUM_VERSION_TAG=latest
APP_OPERATOR_VERSION_TAG=latest
CHART_OPERATOR_VERSION_TAG=latest

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
  namespace: ${TOOLS_NAMESPACE}
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
  namespace: ${TOOLS_NAMESPACE}
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
  kubectl -n ${TOOLS_NAMESPACE} rollout status deployment ${name}
}

create_kind_config () {
  cat > $1 << EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
#networking:
  #disableDefaultCNI: true
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 30100
    hostPort: 8080
    listenAddress: "127.0.0.1"
    protocol: TCP
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
    URL: http://chart-museum.${TOOLS_NAMESPACE}.svc.cluster.local:8080/charts/
    type: helm
  title: Testing Catalog
EOF
}

create_app_cr () {
  name=$1
  version=$2
  config_file=$3

  config=""

  if [[ $config_file != "" ]]; then
    cm_name=${name}-testing-user-config
    kubectl -n ${TOOLS_NAMESPACE} create configmap ${cm_name} --from-file=${config_file}
    config="userConfig:
    configMap:
      name: \"${cm_name}\"
      namespace: \"${TOOLS_NAMESPACE}\""
  fi

  kubectl create -f - << EOF
apiVersion: application.giantswarm.io/v1alpha1
kind: App
metadata:
  name: ${name}
  namespace: ${TOOLS_NAMESPACE}
  labels:
    app: ${name}
    app-operator.giantswarm.io/version: "1.0.0"
spec:
  catalog: testing
  version: ${version}
  kubeConfig:
    inCluster: true
  name: ${name}
  namespace: ${CHART_DEPLOY_NAMESPACE}
  ${config}
EOF
}

##################
# functions
##################

wait_for_resource () {
  namespace=$1
  resource=$2

  while true; do 
    kubectl -n $namespace get --no-headers $resource 1>/dev/null 2>&1 && break
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
  # create tools namespace
  kubectl create ns $TOOLS_NAMESPACE
  # start chart-museum
  chart_museum_deploy
  # start app+chart-operators
  kubectl -n ${TOOLS_NAMESPACE} create serviceaccount appcatalog
  kubectl create clusterrolebinding appcatalog_cluster-admin --clusterrole=cluster-admin --serviceaccount=${TOOLS_NAMESPACE}:appcatalog
  kubectl -n ${TOOLS_NAMESPACE} run app-operator --serviceaccount=appcatalog --generator=run-pod/v1 --image=quay.io/giantswarm/app-operator:${APP_OPERATOR_VERSION_TAG} -- daemon --service.kubernetes.kubeconfig="${kubeconfig}" --service.kubernetes.incluster="false"
  kubectl -n ${TOOLS_NAMESPACE} run chart-operator --serviceaccount=appcatalog --generator=run-pod/v1 --image=quay.io/giantswarm/chart-operator:${CHART_OPERATOR_VERSION_TAG} -- daemon --service.kubernetes.kubeconfig="${kubeconfig}" --server.listen.address="http://127.0.0.1:7000" --service.kubernetes.incluster="false"
  kubectl -n ${TOOLS_NAMESPACE} wait --for=condition=Ready pod/app-operator
  kubectl -n ${TOOLS_NAMESPACE} wait --for=condition=Ready pod/chart-operator
  wait_for_resource ${TOOLS_NAMESPACE} crd/appcatalogs.application.giantswarm.io
  wait_for_resource ${TOOLS_NAMESPACE} crd/apps.application.giantswarm.io
  wait_for_resource ${TOOLS_NAMESPACE} crd/charts.application.giantswarm.io
  create_app_catalog_cr
}

build_chart () {
  docker run -it --rm -v $(pwd):/workdir -w /workdir quay.io/giantswarm/architect:${ARCHITECT_VERSION_TAG} helm template --validate --dir helm/$1
  chart_log=$(helm package helm/$1)
  echo $chart_log
  chart_name=${chart_log##*/}
  echo "Uploading chart ${chart_name} to chart-museum..."
  curl --data-binary "@${chart_name}" http://localhost:8080/api/charts
}

create_app () {
  name=$1
  config_file=$2
  version=$(docker run -it --rm -v $(pwd):/workdir -w /workdir quay.io/giantswarm/architect:${ARCHITECT_VERSION_TAG} project version | tr -d '\r')

  echo "Creating 'app CR' with version=${version} and name=${name}"
  create_app_cr $name $version $config_file
}

verify_helm () {
  chart_name=$1

  timer=0
  expected="DEPLOYED"
  while true; do
    set +e
    status_out=$(helm --tiller-namespace giantswarm status ${chart_name} | head -n 3 | grep "STATUS:")
    out_code=$?
    set -e
    status=${status_out##* }
    if [[ $out_code != 0 ]]; then
      echo "Helm is not ready, exit code: $out_code"
    elif [[ $status != $expected ]]; then
      echo "Deployment ${chart_name} is not ${expected}, current status is $status"
    else
      echo "Deployment ${chart_name} is ${expected}!"
      echo "Test successful."
      break
    fi
    echo "Waiting for status update..."
    sleep 1
    timer=$((timer+1))
    if [[ $timer -gt $MAX_WAIT_FOR_HELM_STATUS_DEPLOY_SEC ]]; then
      echo "Deployment ${chart_name} failed to become ${expected} in ${MAX_WAIT_FOR_HELM_STATUS_DEPLOY_SEC} seconds."
      echo "Test failed."
      exit 3
    fi
  done
}

run_pytest () {
  chart_name=$1
  config_file=$2

  if [[ ! -d "test/kind" ]]; then
    echo "No pytest tests found in 'test/kind', skipping"
    return
  fi

  test_res_file="junit-${chart_name}"
  if [[ $config_file != "" ]]; then
    test_res_file="${test_res_file}-${config_file##*/}"
  fi
  test_res_file="${test_res_file}.xml"

  # This can be run within docker container as well, removing the need of 'pipenv'.
  # Still, fetching dependencies inside the container with pip and pipenv takes way too long.
  cd test/kind
  echo "Starting tests with pipenv+pytest, saving results to \"${test_res_file}\""
  pipenv sync
  pipenv run pytest \
    --kube-config /tmp/kind_test/kubei.config \
    --chart-name ${chart_name} \
    --values-file ../../${config_file} \
    --junitxml=../../test-results/${test_res_file}
  cd ../..
}

run_tests_for_single_config () {
  config_file=$1

  create_cluster
  start
  build_chart ${CHART_NAME}
  create_app ${CHART_NAME} $config_file
  verify_helm ${CHART_NAME}
  run_pytest ${CHART_NAME} $config_file
  delete_cluster
}

main () {
  delete_cluster

  if [[ ! -d "helm" ]]; then
    echo "This doesn't look like top level app directory. 'helm' directory not found. Exiting."
    exit 4
  fi

  set +e
  ls helm/${CHART_NAME}/ci/*.yaml 1>/dev/null 2>&1
  out=$?
  set -e
  if [[ $out > 0 ]]; then
    echo "No sample configuration files found for the tested chart. Running single test without any ConfigMap."
    run_tests_for_single_config ""
  else
    for file in $(ls helm/${CHART_NAME}/ci/*.yaml); do
      echo "Starting test run for configuration file $file"
      run_tests_for_single_config "$file"
    done
  fi
}

main

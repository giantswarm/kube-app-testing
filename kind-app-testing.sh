#!/bin/bash -e

# TODO:
# - do we need tools versions (helm, kind, python) validation?
# - add option to create worker nodes as well (and how many)
# - add option to use diffrent k8s version
# - already available option to use custom kind config: docs necessary, as we need some options there
# - switch CNI to calico to be compatible(-ish, screw AWS CNI)
# - use external kubeconfig - to run on already existing cluster

# const
KAT_VERSION=0.1.14

# config
CONFIG_DIR=/tmp/kind_test
export KUBECONFIG=${CONFIG_DIR}/kubei.config
CLUSTER_NAME=kt
TOOLS_NAMESPACE=giantswarm
CHART_DEPLOY_NAMESPACE=default
MAX_WAIT_FOR_HELM_STATUS_DEPLOY_SEC=60
PIPENV_PYTHON_VERSION=3.7
TEST_CONFIG_FILES_SUBPATH="ci/*.yaml"
PRE_TEST_SCRIPT_PATH="ci/pre-test-hook.sh"

# docker image tags
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
# logging
##################

log () {
  level=$1
  shift 1
  date --rfc-3339=seconds -u | tr -d '\n'
  echo " [${level}] $@"
}

info () {
  log "INFO" "$@"
}

warn () {
  log "WARN" "$@"
}

err () {
  log "ERROR" "$@"
}

print_help () {
  echo "KAT v${KAT_VERSION} - KinD Application Testing"
  echo ""
  echo "Usage:"
  echo ""
  echo "  ${0##*/} [OPTION...] -c [chart name in helm/ dir]"
  echo ""
  echo "Options:"
  echo "  -h, --help                      display this help screen"
  echo "  -k, --keep-after-test           after first test is successful, abort and keep"
  echo "                                  the test cluster running"
  echo "  -i, --kind-config-file [path]   don't use the default kind.yaml config file,"
  echo "                                  but provide your own"
  echo "  -p, --pre-script-file [path]    override the default path to look for the"
  echo "                                  pre-test hook script file"
  echo ""
  echo "Requirements: kind, helm, pipenv."
  echo ""
  echo "This script builds and tests a helm chart using a kind cluster. The only required"
  echo "parameter is [chart name], which needs to be a name of the chart and also a directory"
  echo "name in the \"helm/\" directory. If there are YAML files present in the directory"
  echo "helm/[chart name]/ci\", a full test starting with creation of a new clean cluster"
  echo "will be executed for each one of them". 
  echo "If there's a file \"helm/[chart name]/si/pre-test-hook.sh\", it will be executed after"
  echo "the cluster is ready to deploy the tested application, but before the application"
  echo "is deployed. KUBECONFIG variable is set to the test cluster for the script execution."
  echo "In the next step the chart is built, pushed to the chart repository in the cluster"
  echo "and the App CR is created to deploy the application."
  echo "The last (and optional) step is to execute functional test. If the directory"
  echo "\"test/kind\" is present in the top level directory, the command \"pipenv run pytest\""
  echo "is executed as the last step."
}

##################
# functions
##################

wait_for_resource () {
  namespace=$1
  resource=$2

  while true; do 
    kubectl -n $namespace get --no-headers $resource 1>/dev/null 2>&1 && break
    info "Waiting for resource ${resource} to be present in cluster..."
    sleep 1
  done
  info "Resource ${resource} present."
}

create_cluster () {
  if [[ ! -d ${CONFIG_DIR} ]]; then
    mkdir ${CONFIG_DIR}
  fi

  if [[ -z $KIND_CONFIG_FILE ]]; then
    KIND_CONFIG_FILE="${CONFIG_DIR}/kind.yaml"
    info "Creating default KinD config file ${KIND_CONFIG_FILE}"
    create_kind_config ${KIND_CONFIG_FILE}
  else
    info "Using provided KinD config file ${KIND_CONFIG_FILE}"
  fi

  kind create cluster --name ${CLUSTER_NAME} --config ${CONFIG_DIR}/kind.yaml
  kind get kubeconfig --name ${CLUSTER_NAME} --internal > ${KUBECONFIG}
  info "Cluster created, waiting for basic services to come up"
  kubectl -n kube-system rollout status deployment coredns
}

delete_cluster () {
  info "Deleting cluster ${CLUSTER_NAME}"
  kind delete cluster --name ${CLUSTER_NAME}
}

start () {
  kubeconfig=$(cat ${KUBECONFIG})
  # create tools namespace
  kubectl create ns $TOOLS_NAMESPACE
  # start chart-museum
  info "Deploying \"chart-museum\""
  chart_museum_deploy
  # start app+chart-operators
  info "Deploying \"app-operator\""
  kubectl -n ${TOOLS_NAMESPACE} create serviceaccount appcatalog
  kubectl create clusterrolebinding appcatalog_cluster-admin --clusterrole=cluster-admin --serviceaccount=${TOOLS_NAMESPACE}:appcatalog
  kubectl -n ${TOOLS_NAMESPACE} run app-operator --serviceaccount=appcatalog --generator=run-pod/v1 --image=quay.io/giantswarm/app-operator:${APP_OPERATOR_VERSION_TAG} -- daemon --service.kubernetes.kubeconfig="${kubeconfig}" --service.kubernetes.incluster="false"
  info "Deploying \"chart-operator\""
  kubectl -n ${TOOLS_NAMESPACE} run chart-operator --serviceaccount=appcatalog --generator=run-pod/v1 --image=quay.io/giantswarm/chart-operator:${CHART_OPERATOR_VERSION_TAG} -- daemon --service.kubernetes.kubeconfig="${kubeconfig}" --server.listen.address="http://127.0.0.1:7000" --service.kubernetes.incluster="false"
  info "Waiting for services to come up"
  kubectl -n ${TOOLS_NAMESPACE} wait --for=condition=Ready pod/app-operator
  kubectl -n ${TOOLS_NAMESPACE} wait --for=condition=Ready pod/chart-operator
  info "Waiting for AppCatalog/App/Chart CRDs to be registered with API server"
  wait_for_resource ${TOOLS_NAMESPACE} crd/appcatalogs.application.giantswarm.io
  wait_for_resource ${TOOLS_NAMESPACE} crd/apps.application.giantswarm.io
  wait_for_resource ${TOOLS_NAMESPACE} crd/charts.application.giantswarm.io
  info "Creating AppCatalog CR for \"chart-museum\""
  create_app_catalog_cr
}

build_chart () {
  chart_name=$1

  info "Validating chart \"${chart_name}\" with architect"
  docker run -it --rm -v $(pwd):/workdir -w /workdir quay.io/giantswarm/architect:${ARCHITECT_VERSION_TAG} helm template --validate --dir helm/${chart_name}
  info "Packaging chart \"${chart_name}\" with helm"
  chart_log=$(helm package helm/$chart_name)
  echo $chart_log
  chart_file_name=${chart_log##*/}
  info "Uploading chart ${chart_file_name} to chart-museum..."
  curl --data-binary "@${chart_file_name}" http://localhost:8080/api/charts
}

create_app () {
  name=$1
  config_file=$2
  version=$(docker run -it --rm -v $(pwd):/workdir -w /workdir quay.io/giantswarm/architect:${ARCHITECT_VERSION_TAG} project version | tr -d '\r')

  info "Creating 'app CR' with version=${version} and name=${name}"
  create_app_cr $name $version $config_file
}

verify_helm () {
  chart_name=$1

  timer=0
  expected="DEPLOYED"
  while true; do
    set +e
    status_out=$(helm --tiller-namespace giantswarm status ${chart_name} 2>&1 | head -n 3 | grep "STATUS:")
    out_code=$?
    set -e
    status=${status_out##* }
    if [[ $out_code != 0 ]]; then
      info "Helm is not ready, exit code: $out_code"
    elif [[ $status != $expected ]]; then
      info "Deployment ${chart_name} is not ${expected}, current status is $status"
    else
      info "Deployment ${chart_name} is ${expected}!"
      break
    fi
    sleep 1
    timer=$((timer+1))
    if [[ $timer -gt $MAX_WAIT_FOR_HELM_STATUS_DEPLOY_SEC ]]; then
      err "Deployment ${chart_name} failed to become ${expected} in ${MAX_WAIT_FOR_HELM_STATUS_DEPLOY_SEC} seconds."
      err "Test failed."
      exit 1
    fi
  done
}

run_pytest () {
  chart_name=$1
  config_file=$2

  if [[ ! -d "test/kind" ]]; then
    info "No pytest tests found in 'test/kind', skipping"
    return
  fi

  test_res_file="junit-${chart_name}"
  if [[ $config_file != "" ]]; then
    test_res_file="${test_res_file}-${config_file##*/}"
  fi
  test_res_file="test-results/${test_res_file}.xml"

  # This can be run within docker container as well, removing the need of 'pipenv'.
  # Still, fetching dependencies inside the container with pip and pipenv takes way too long.
  cd test/kind
  info "Starting tests with pipenv+pytest, saving results to \"${test_res_file}\""
  pipenv --python ${PIPENV_PYTHON_VERSION} sync
  pipenv run pytest \
    --kube-config /tmp/kind_test/kubei.config \
    --chart-name ${chart_name} \
    --values-file ../../${config_file} \
    --junitxml=../../${test_res_file}
  cd ../..
}

run_pre_test_hook () {
  chart_name=$1

  if [[ -z ${OVERRIDEN_PRE_SCRIPT_PATH} ]]; then
    script_path="helm/${chart_name}/${PRE_TEST_SCRIPT_PATH}"
  else
    script_path="${OVERRIDEN_PRE_SCRIPT_PATH}"
  fi

  if [[ ! -f ${script_path} ]]; then
    info "No pre-test init script found in ${script_path}."
    return
  fi

  info "Executing pre-test script from ${script_path}."
  ${script_path}
}

run_tests_for_single_config () {
  chart_name=$1
  config_file=$2

  create_cluster
  start
  build_chart ${chart_name}
  run_pre_test_hook ${chart_name}
  create_app ${chart_name} $config_file
  verify_helm ${chart_name}
  run_pytest ${chart_name} $config_file
  if [ $KEEP_AFTER_TEST ]; then
    warn "--keep-after-test was used, I'm stopping next test config files runs (if any) to let you investigate the cluster"
    exit 0
  else
    delete_cluster
  fi

  extra=""
  if [[ $config_file != "" ]]; then
    extra=" and config file \"$config_file\""
  fi
  info "Test successful for chart \"${chart_name}\"${extra}"
}

parse_args () {
  args=$@

  while [[ $# -gt 0 ]]; do
    case $1 in
      -h|--help) 
        print_help
        exit 0
        ;;
      -c|--chart) 
        CHART_NAME=$2
        shift 2
        ;;
      -k|--keep-after-test) 
        KEEP_AFTER_TEST=1
        shift
        ;;
      -i|--kind-config-file)
        KIND_CONFIG_FILE=$2
        shift 2
        ;;
      -p|--pre-script-path)
        OVERRIDEN_PRE_SCRIPT_PATH=$2
        shift 2
        ;;
      *) 
        print_help
        exit 2
        ;;
    esac
  done

  if [[ ! -d "helm/${CHART_NAME}" ]]; then
    err "The 'helm/' directory doesn't contain chart named '${CHART_NAME}'."
    exit 3
  fi

  if [[ ! -z $KIND_CONFIG_FILE && ! -f $KIND_CONFIG_FILE ]]; then
    err "KinD config file '$KIND_CONFIG_FILE' was specified, but doesn't exist."
    exit 3 
  fi
}

validate_tools () {
  info "Cheking for necessary tools being installed"
  set +e
  for app in "kind" "pipenv" "helm"; do
    which $app 1>/dev/null 2>&1
    exit_code=$?
    if [[ $exit_code -gt 0 ]]; then
      err "'$app' binary not found. Please make sure to install it."
      exit 4
    fi
  done
  info "Listing kind version"
  kind version
  info "Listing helm version"
  helm version 2>/dev/null
  info "Listing pipenv version"
  pipenv --version
  set -e
}

main () {
  chart_name=$1

  delete_cluster
  set +e
  ls helm/${chart_name}/${TEST_CONFIG_FILES_SUBPATH} 1>/dev/null 2>&1
  out=$?
  set -e
  if [[ $out > 0 ]]; then
    info "No sample configuration files found for the tested chart. Running single test without any ConfigMap."
    run_tests_for_single_config ${chart_name} ""
  else
    for file in $(ls helm/${chart_name}/${TEST_CONFIG_FILES_SUBPATH}); do
      info "Starting test run for configuration file $file"
      run_tests_for_single_config ${chart_name} "$file"
    done
  fi
}

parse_args $@
validate_tools
main ${CHART_NAME}

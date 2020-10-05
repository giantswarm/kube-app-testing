#!/bin/bash -e

# TODO:
# - do we need tools versions (helm, kind, python) validation?
# - add option to create worker nodes as well (and how many)
# - add option to use diffrent k8s version
# - already available option to use custom kind config: docs necessary, as we need some options there
# - switch CNI to calico to be compatible(-ish, screw AWS CNI)
# - use external kubeconfig - to run on already existing cluster

# const
KAT_VERSION=0.6.0

# config
CONFIG_DIR=/tmp/kat_test
TMP_DIR=/tmp/kat
ENV_DETAILS_FILE=/tmp/env-details
export KUBECONFIG=${CONFIG_DIR}/kube.config
export KUBECONFIG_I=${CONFIG_DIR}/kube_internal.config
DEFAULT_CLUSTER_NAME=kt
TOOLS_NAMESPACE=giantswarm
CHART_DEPLOY_NAMESPACE=default
MAX_WAIT_FOR_HELM_STATUS_DEPLOY_SEC=180
TEST_CONFIG_FILES_SUBPATH="ci/*.yaml"
PRE_TEST_SCRIPT_PATH="ci/pre-test-hook.sh"
DEFAULT_CLUSTER_TYPE=kind
PYTHON_TESTS_DIR="test/kat"

# gs cluster config
DEFAULT_PROVIDER="aws"
DEFAULT_REGION="eu-central-1"
DEFAULT_AVAILABILITY_ZONE="eu-central-1a"
DEFAULT_SCALING_MIN=1
DEFAULT_SCALING_MAX=2

# docker image tags
ARCHITECT_VERSION_TAG=latest
APP_OPERATOR_VERSION_TAG=${APP_OPERATOR_VERSION_TAG:-1.0.7}
CHART_OPERATOR_VERSION_TAG=${CHART_OPERATOR_VERSION_TAG:-0.13.1}
CHART_MUSEUM_VERSION_TAG=${CHART_MUSEUM_VERSION_TAG:-v0.12.0}
PYTHON_VERSION_TAG=3.7-alpine
CHART_TESTING_VERSION_TAG=v2.4.0

####################
# Files & templates
####################

chart_museum_deploy () {
  cluster_type=$1
  name="chart-museum"
  image=chartmuseum/chartmuseum:${CHART_MUSEUM_VERSION_TAG}

  kubectl -n ${TOOLS_NAMESPACE} create serviceaccount ${name}

  kubectl create -f - << EOF
---
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: ${name}-psp
rules:
- apiGroups:
  - extensions
  resources:
  - podsecuritypolicies
  resourceNames:
  - ${name}-psp
  verbs:
  - use
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: ${name}-psp
subjects:
- kind: ServiceAccount
  name: ${name}
  namespace: ${TOOLS_NAMESPACE}
roleRef:
  kind: ClusterRole
  name: ${name}-psp
  apiGroup: rbac.authorization.k8s.io
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
      serviceAccountName: ${name}
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
apiVersion: policy/v1beta1
kind: PodSecurityPolicy
metadata:
  name: ${name}-psp
spec:
  allowPrivilegeEscalation: true
  fsGroup:
    rule: RunAsAny
  hostIPC: false
  hostNetwork: false
  hostPID: false
  hostPorts:
  - max: 65536
    min: 1
  privileged: true
  runAsUser:
    rule: RunAsAny
  seLinux:
    rule: RunAsAny
  supplementalGroups:
    rule: RunAsAny
  volumes:
  - '*'
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${name}-network-policy
  namespace: ${TOOLS_NAMESPACE}
spec:
  egress:
  - {}
  ingress:
  - ports:
    - port: 8080
      protocol: TCP
  podSelector:
    matchLabels:
      app: ${name}
  policyTypes:
  - Egress
  - Ingress
EOF

# kind clusters use nodeports for access
if [[ "${cluster_type}" == "kind" ]]; then
  kubectl create -f - << EOF
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
# giant swarm clusters use clusterips for access
elif [[ "${cluster_type}" == "giantswarm" ]]; then
  kubectl create -f - << EOF
---
apiVersion: v1
kind: Service
metadata:
  name: ${name}
  namespace: ${TOOLS_NAMESPACE}
  labels:
    app: ${name}
spec:
  type: ClusterIP
  ports:
  - port: 8080
    protocol: TCP
    targetPort: 8080
  selector:
    app: ${name}
EOF
fi
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

create_app_operator_netpol () {
  kubectl create -f - << EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: app-operator-network-policy
  namespace: ${TOOLS_NAMESPACE}
spec:
  podSelector:
    matchLabels:
      app: app-operator
  egress:
  - {}
  ingress:
  - {}
  policyTypes:
  - Egress
  - Ingress
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
  config:
    configMap:
      name: ""
      namespace: ""
    secret:
      name: ""
      namespace: ""
  description: 'Catalog to hold charts for testing.'
  logoURL: /favicon.ico
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
  date -u +"%Y-%m-%dT%H:%M:%SZ" | tr -d '\n'
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

create_kind_cluster () {
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

  kind create cluster --name ${CLUSTER_NAME} --config ${KIND_CONFIG_FILE}
  kind get kubeconfig --name ${CLUSTER_NAME} > ${KUBECONFIG}
  kind get kubeconfig --name ${CLUSTER_NAME} --internal > ${KUBECONFIG_I}
  info "Cluster created, waiting for basic services to come up"
  kubectl -n kube-system rollout status deployment coredns

  # write cluster details to file to run a manual cleanup later if required.
  echo "export CLUSTER_NAME=${CLUSTER_NAME}" > ${ENV_DETAILS_FILE}
  echo "export CLUSTER_TYPE=${CLUSTER_TYPE}" >> ${ENV_DETAILS_FILE}
  if [ $KEEP_AFTER_TEST ]; then
    echo "export KEEP_AFTER_TEST=${KEEP_AFTER_TEST}" >> ${ENV_DETAILS_FILE}
  fi

  kubeconfig=$(cat ${KUBECONFIG})
  # create tools namespace
  kubectl create ns $TOOLS_NAMESPACE
}

delete_kind_cluster () {
  info "Deleting KinD cluster ${CLUSTER_NAME}"
  if ! kind delete cluster --name ${CLUSTER_NAME}; then
    err "Cluster deletion failed - please investigate."
    exit 3
  else
    # tidy up after ourselves
    if [[ -f ${ENV_DETAILS_FILE} ]]; then
      rm ${ENV_DETAILS_FILE}
    fi

    # exit successfully
    exit 0
  fi
}

update_aws_sec_group () {
  cluster_id=$1

  info "Getting Security Group details for cluster ${cluster_id}"
  # get the security group details for the new cluster's K8S API ingress
  if ! SECGROUP_DATA=$(aws ec2 describe-security-groups --region ${REGION} \
      --filters Name=tag:giantswarm.io/cluster,Values=${cluster_id} \
      Name=tag:aws:cloudformation:logical-id,Values=MasterSecurityGroup) ; then
    err "Error describing the Security Group."
    exit 3
  fi

  # loop over the rules - each rule dict must be base64 encoded as
  # whitespace breaks the looping
  for rule in $(echo "${SECGROUP_DATA}" | jq -r '.SecurityGroups[0].IpPermissions[] | @base64'); do
    # get the port for this rule
    _FROM_PORT=$(echo "${rule}" | base64 -d | jq -r .FromPort)

    # only examine it if it is the K8S API rule
    if [[ $_FROM_PORT -eq 443 ]]; then
      # get the allowed IP range to this port
      _CIDR_IP=$(echo "${rule}" | base64 -d | jq -r .IpRanges[0].CidrIp)
      # if the port is already open to the world then return from the function
      if [[ "${_CIDR_IP}" == "0.0.0.0/0" ]]; then
        echo "API ingress already allowed from \"0.0.0.0/0\""
        return
      fi
    fi
  done

  # rule doesn't exist or isn't open to the world, so we need to create a new rule
  SEC_GROUP_ID=$(jq .SecurityGroups[0].GroupId <<< ${SECGROUP_DATA})

  info "Adding ingress rule for 0.0.0.0/0 to Security Group ${SEC_GROUP_ID}"
  # add a new rule to allow ingress from anywhere on 443
  if ! aws ec2 authorize-security-group-ingress --region ${REGION} --group-id ${SEC_GROUP_ID} \
      --protocol tcp --port 443 --cidr 0.0.0.0/0 ; then
    err "Could not add ingress rule to the Security Group."
    exit 3
  fi
}

create_gs_cluster () {
  info "Creating new tenant cluster."

  # create a new cluster
  if ! CLUSTER_DETAILS="$(gsctl create cluster --output=json --file - <<EOF
api_version: v5
owner: conformance-testing
release_version: ${GS_RELEASE}
name: ${CLUSTER_NAME}
master_nodes:
  high_availability: false
labels:
  circleci-branch: "${CIRCLE_BRANCH:-no}"
  circleci-build-num: "${CIRCLE_BUILD_NUM:-no}"
  github-repo: "${CIRCLE_PROJECT_REPONAME:-no}"
  github-user: "${CIRCLE_PROJECT_USERNAME:-no}"
  owner: "ci"
nodepools:
- availability_zones:
    zones:
    - "${AVAILABILITY_ZONE}"
  scaling:
    min: ${SCALING_MIN}
    max: ${SCALING_MAX}
  node_spec:
    aws:
      instance_type: m5.xlarge
      use_alike_instance_types: true
EOF
)" ; then
    err "Cluster creation failed."
    exit 3
  fi

  CLUSTER_ID=$(jq -r .id <<< "${CLUSTER_DETAILS}")

  # write cluster details to file to run a manual cleanup later if required.
  echo "export CLUSTER_ID=${CLUSTER_ID}" > ${ENV_DETAILS_FILE}
  echo "export CLUSTER_TYPE=${CLUSTER_TYPE}" >> ${ENV_DETAILS_FILE}
  if [ $KEEP_AFTER_TEST ]; then
    echo "export KEEP_AFTER_TEST=${KEEP_AFTER_TEST}" >> ${ENV_DETAILS_FILE}
  fi

  # align config with kind clusters
  if [[ ! -d ${CONFIG_DIR} ]]; then
    mkdir ${CONFIG_DIR}
  fi

  info "Sleeping 10 seconds before create kubeconfig attempt"
  sleep 10

  # declare a counter
  _counter=0
  info "Writing kubeconfig into ${KUBECONFIG}"
  until gsctl create kubeconfig \
    --cluster="${CLUSTER_ID}" \
    --certificate-organizations=system:masters \
    --force \
    --self-contained="${KUBECONFIG}"
  do
    # exit if the kubeconfig hasn't been created in 30 minutes
    if [[ "$_counter" -gt 60 ]]; then
      err "Kubeconfig not created after 30 minutes."
      exit 3
    fi

    # increment the counter
    _counter=$((_counter+1))
    info "Waiting for kubeconfig for cluster ${CLUSTER_ID} to be created."
    sleep 30
  done

  if [[ -z ${NO_EXTERNAL_KUBE_API} ]]; then
    # update Security Group to allow access
    update_aws_sec_group ${CLUSTER_ID}

    info "Sleeping for 30 seconds to ensure ingress rule has been applied."
    sleep 30
  fi

  # wait for the cluster to be ready
  # declare a counter
  _counter=0
  until kubectl get nodes; do
    # exit if the cluster hasn't been created in 30 minutes
    if [[ "$_counter" -gt 60 ]]; then
      err "Cluster not created after 30 minutes."
      exit 3
    fi

    # increment the counter
    _counter=$((_counter+1))
    info "Waiting for cluster ${CLUSTER_ID} to be ready."
    sleep 30
  done

  info "Waiting for cluster nodes of ${CLUSTER_ID} to be ready. (kubectl wait)"
  sleep 30
  kubectl wait --for=condition=ready --timeout=5m --all node

  info "Testing tenant cluster by listing pods in 'kube-system' namespace."
  # test connectivity
  kubectl get pods -n kube-system
  if [[ "$?" -gt 0 ]]; then
    err "Could not list pods in the kube-system namespace."
    exit 3
  fi
}

delete_gs_cluster () {
  info "Deleting Giant Swarm tenant cluster ${CLUSTER_ID}"
  if ! gsctl delete cluster --force "${CLUSTER_ID}" ; then
    err "Cluster deletion failed - please investigate."
    exit 3
  else
    # tidy up after ourselves
    if [[ -f ${ENV_DETAILS_FILE} ]]; then
      rm ${ENV_DETAILS_FILE}
    fi

    # exit successfully
    exit 0
  fi
}

create_cluster () {
  cluster_type=$1

  case $cluster_type in
    "kind")
      create_kind_cluster
      ;;
    "giantswarm")
      create_gs_cluster
      ;;
    *)
      err "Cluster of type \"$cluster_type\" is not supported"
      exit 4
      ;;
  esac
}

force_cleanup () {
  # check if the cluster details file exists - if not then we do nothing.
  if [[ ! -f ${ENV_DETAILS_FILE} ]]; then
    log "No previous cluster info found at ${ENV_DETAILS_FILE}, nothing to do."
    exit 0
  fi

  # pick up cluster details from previous run.
  source ${ENV_DETAILS_FILE}

  if [[ $KEEP_AFTER_TEST -eq 1 ]]; then
    warn "--keep-after-test was set, cluster will not be cleaned up even though --force-cleanup was set."
    exit 0
  fi

  # call for cluster deletion using the existing functions.
  delete_cluster ${CLUSTER_TYPE}
}

delete_cluster () {
  cluster_type=$1

  case $cluster_type in
    "kind")
      delete_kind_cluster
      ;;
    "giantswarm")
      delete_gs_cluster
      ;;
    *)
      err "Cluster of type \"$cluster_type\" is not supported"
      exit 4
      ;;
  esac
}

start_tools () {
  cluster_type=$1

  # we need to wait for the namespace to be created for us in GS clusters.
  _counter=0
  until kubectl get ns | grep -q ${TOOLS_NAMESPACE}; do
    if [[ "$_counter" -gt 30 ]]; then
      err "namespace: ${TOOLS_NAMESPACE} not created after 5 minutes."
      exit 3
    fi

    # increment the counter
    _counter=$((_counter+1))
    info "waiting for namespace ${TOOLS_NAMESPACE} to be created."
    sleep 10
  done
  unset _counter

  info "Deploying \"chart-museum\" ${CHART_MUSEUM_VERSION_TAG}"
  chart_museum_deploy ${cluster_type}

  # deploy app-operator to all cluster types
  info "Deploying \"app-operator\" ${APP_OPERATOR_VERSION_TAG}"
  kubectl -n ${TOOLS_NAMESPACE} create serviceaccount appcatalog
  kubectl create clusterrolebinding appcatalog_cluster-admin --clusterrole=cluster-admin --serviceaccount=${TOOLS_NAMESPACE}:appcatalog
  # tenant clusters have a default deny-all network policy which breaks app-operator
  if [[ "$cluster_type" == "giantswarm" ]]; then
    create_app_operator_netpol
  fi
  kubectl -n ${TOOLS_NAMESPACE} run app-operator --serviceaccount=appcatalog -l app=app-operator --image=quay.io/giantswarm/app-operator:${APP_OPERATOR_VERSION_TAG} -- daemon --service.kubernetes.incluster="true"

  # only deploy chart-operator to kind clusters
  if [[ "$cluster_type" == "kind" ]]; then
    info "Deploying \"chart-operator\" ${CHART_OPERATOR_VERSION_TAG}"
    kubectl -n ${TOOLS_NAMESPACE} run chart-operator --serviceaccount=appcatalog -l app=chart-operator --image=quay.io/giantswarm/chart-operator:${CHART_OPERATOR_VERSION_TAG} -- daemon --server.listen.address="http://127.0.0.1:7000" --service.kubernetes.incluster="true"
  fi

  info "Waiting for app-operator to come up"
  kubectl -n ${TOOLS_NAMESPACE} wait --for=condition=Ready pods -l app=app-operator

  # we may have to wait for the deployment to be created in a GS cluster, otherwise
  # the following 'kubectl wait' will fail
  _counter=0
  until kubectl -n ${TOOLS_NAMESPACE} get pods -l app=chart-operator 2> /dev/null | grep -q chart-operator; do
    # timeout after 10 minutes
    if [[ "$_counter" -gt 60 ]]; then
      err "chart-operator not running after 10 minutes."
      exit 3
    fi

    # increment the counter
    _counter=$((_counter+1))
    info "Waiting for chart-operator to start"
    sleep 10
  done
  unset _counter

  info "Waiting for chart-operator to become ready (times out after 120s)"
  kubectl -n ${TOOLS_NAMESPACE} wait --timeout=120s --for=condition=Ready pods -l app=chart-operator

  info "Waiting for AppCatalog/App/Chart CRDs to be registered with API server"
  wait_for_resource ${TOOLS_NAMESPACE} crd/appcatalogs.application.giantswarm.io
  wait_for_resource ${TOOLS_NAMESPACE} crd/apps.application.giantswarm.io
  wait_for_resource ${TOOLS_NAMESPACE} crd/charts.application.giantswarm.io

  info "Creating AppCatalog CR for \"chart-museum\""
  create_app_catalog_cr
}

validate_chart () {
  chart_name=$1

  if [[ ! -d ${HOME}/.helm ]]; then
    helm init -c
  fi

  info "Taking backups of 'Chart.yaml' and 'values.yaml' before 'architect' alters them"
  cp helm/${chart_name}/Chart.yaml helm/${chart_name}/Chart.yaml.back
  cp helm/${chart_name}/values.yaml helm/${chart_name}/values.yaml.back

  info "Validating chart \"${chart_name}\" with architect"
  docker run -it --rm -v $(pwd):/workdir -w /workdir quay.io/giantswarm/architect:${ARCHITECT_VERSION_TAG} helm template --validate --dir helm/${chart_name}

  info "Linting chart \"${chart_name}\" with \"ct\""
  CT_DOCKER_RUN="docker run -it --rm -v $(pwd):/chart -w /chart quay.io/helmpack/chart-testing:${CHART_TESTING_VERSION_TAG}"
  if [[ -n "${CT_CONFIG_FILE}" ]]
  then
    $CT_DOCKER_RUN sh -c "helm init -c && ct lint --config $CT_CONFIG_FILE --validate-maintainers=false --charts=\"helm/${chart_name}\""
  else
    $CT_DOCKER_RUN sh -c "helm init -c && ct lint --validate-maintainers=false --charts=\"helm/${chart_name}\""
  fi

  if [[ $VALIDATE_ONLY -eq 1 ]]; then
    info "Only validation was requested, exiting."
    exit 0
  fi
}

build_chart () {
  chart_name=$1

  info "Packaging chart \"${chart_name}\" with helm"
  chart_log=$(helm package helm/$chart_name)
  echo $chart_log
  CHART_FILE_NAME=${chart_log##*/}

  info "Restoring backups of 'Chart.yaml' and 'values.yaml' to revert changes 'architect' did."
  mv helm/${chart_name}/Chart.yaml.back helm/${chart_name}/Chart.yaml
  mv helm/${chart_name}/values.yaml.back helm/${chart_name}/values.yaml
}

upload_chart () {
  # $1 is passed but not used
  cluster_type=$2

  info "Uploading chart ${CHART_FILE_NAME} to chart-museum..."
  # we need to port-foward to the remote cluster to upload the chart.
  if [[ "$cluster_type" == "giantswarm" ]]; then
    kubectl port-forward -n ${TOOLS_NAMESPACE} service/chart-museum 8080:8080 &
    sleep 5
  fi
  curl --data-binary "@${CHART_FILE_NAME}" http://localhost:8080/api/charts
}

create_app () {
  name=$1
  config_file=$2

  info "Creating 'app CR' with version=${CHART_VERSION} and name=${name}"
  create_app_cr $name $CHART_VERSION $config_file
}

verify_helm () {
  chart_name=$1

  timer=0
  expected="DEPLOYED"
  while true; do
    set +e
    status_out=$(helm --kubeconfig ${KUBECONFIG} --tiller-namespace giantswarm status ${chart_name} 2>&1 | head -n 3 | grep "STATUS:")
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
    sleep 5
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

  if [[ $SKIP_PYTEST -eq 1 ]]; then
    info "Pytest skip was requested."
    return
  fi

  if [[ ! -d "$PYTHON_TESTS_DIR" ]]; then
    info "No pytest tests found in \"$PYTHON_TESTS_DIR\", skipping"
    return
  fi

  test_res_file="junit-${chart_name}"
  if [[ $config_file != "" ]]; then
    test_res_file="${test_res_file}-${config_file##*/}"
  fi
  test_res_file="test-results/${test_res_file}.xml"

  for dir in ".local" ".cache"; do
    if [[ -d ${TMP_DIR}/${dir} ]]; then
      mkdir -p ${TMP_DIR}/${dir}
    fi
  done

  info "Starting tests with pipenv+pytest, saving results to \"${test_res_file}\""
  # if the tests are running against a KinD cluster then we want to use the internal
  # config we generated earlier. if this isn't a KinD cluster then we just skip past
  # and use the kubeconfig generated for external access
  if [[ "${CLUSTER_TYPE}" == "kind" ]]; then
    KUBECONFIG=${KUBECONFIG_I}
  fi
  pipenv_cmd='PATH=$HOME/.local/bin:$PATH pipenv sync && PATH=$HOME/.local/bin:$PATH pipenv run pytest --log-cli-level info --full-trace --verbosity=8 .'
  KUBECONFIG_STR="$(cat ${KUBECONFIG})"
  docker run -it \
    --network host \
    -v ${TMP_DIR}/.local:/root/.local \
    -v ${TMP_DIR}/.cache:/root/.cache \
    -v `pwd`:/chart -w /chart \
    python:${PYTHON_VERSION_TAG} sh \
    -c "echo \"${KUBECONFIG_STR}\" > /kube.config \
    && pip install pipenv \
    && cd ${PYTHON_TESTS_DIR} \
    && $pipenv_cmd \
      --cluster-type existing \
      --kube-config /kube.config \
      --values-file ../../${config_file} \
      --chart-path \"helm/${chart_name}\" \
      --chart-version ${CHART_VERSION} \
      --chart-extra-info \"external_cluster_type=${CLUSTER_TYPE}\" \
      --log-cli-level info \
      --junitxml=../../${test_res_file}"
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

  create_cluster ${CLUSTER_TYPE}
  start_tools ${CLUSTER_TYPE}
  CHART_VERSION=$(docker run -it --rm -v $(pwd):/workdir -w /workdir quay.io/giantswarm/architect:${ARCHITECT_VERSION_TAG} project version | tr -d '\r')
  upload_chart ${chart_name} ${CLUSTER_TYPE}
  run_pre_test_hook ${chart_name}
  create_app ${chart_name} $config_file
  verify_helm ${chart_name}
  run_pytest ${chart_name} $config_file
  if [ $KEEP_AFTER_TEST ]; then
    warn "--keep-after-test was used, I'm stopping next test config files runs (if any) to let you investigate the cluster"
    exit 0
  else
    delete_cluster $CLUSTER_TYPE
  fi

  extra=""
  if [[ $config_file != "" ]]; then
    extra=" and config file \"$config_file\""
  fi
  info "Test successful for chart \"${chart_name}\"${extra}"
}

print_help () {
  echo "KAT v${KAT_VERSION} - Kube App Testing"
  echo ""
  echo "Usage:"
  echo ""
  echo "  ${0##*/} [OPTION...] -j|-c [chart name in helm/ dir]"
  echo ""
  echo "Options:"
  echo "  -h, --help                      display this help screen"
  echo "  -v, --validate-only             only validate and lint the chart using 'chart-testing'"
  echo "                                  (runs tests that don't require any cluster)."
  echo "  -j, --just-cluster              just create the cluster with tools installed; ignore everything"
  echo "                                  related to testing and building the chart. Ignores '-c'."
  echo "  -s, --skip-pytest               skip running the pytest test suite, even if present."
  echo "  --force-cleanup                 using force cleanup allows the script to be run independently"
  echo "                                  of the main job. This allows it to clean up any dangling resources"
  echo "                                  left by a failure mid-job. Must be run in a CircleCI job with the"
  echo "                                  'when: on_fail' value set. If the cluster is a GS cluster then the"
  echo "                                  auth token must also be provided with '-a'."
  echo "  -k, --keep-after-test           after first test is successful, abort and keep"
  echo "                                  the test cluster running. If this is provided then '--force-cleanup'"
  echo "                                  will be ignored and resources will always be retained."
  echo "  -i, --kind-config-file [path]   don't use the default kind.yaml config file,"
  echo "                                  but provide your own"
  echo "  -p, --pre-script-file [path]    override the default path to look for the"
  echo "                                  pre-test hook script file"
  echo "  -t, --cluster-type              type of cluster to use for testing"
  echo "                                  available types: kind, giantswarm"
  echo "  --cluster-name                  name of the cluster."
  echo "  -n, --namespace                 namespace to deploy the tested app to"
  echo "  -r, --release-version           giantswarm release to use (only applies to"
  echo "                                  giantswarm cluster type)"
  echo "  --provider                      provider to deploy tenant cluster on"
  echo "                                  available providers: aws (default)"
  echo "  --availability-zone             availability zone to deploy the cluster into, defaults to"
  echo "                                  'eu-central-1a'"
  echo "  --min-scaling                   minimum number of nodes (applies to GS clusters only)"
  echo "  --max-scaling                   maximum number of nodes (applies to GS clusters only). If the max"
  echo "                                  value is set to _less_ than the min value then the provided max will"
  echo "                                  be ignored and max will be set to the same as min, resulting in a"
  echo "                                  statically-sized nodepool"
  echo "  --no-external-kube-api          do not make GS clusters kubernetes api available from the internet"
  echo "                                  (applies to GS clusters only)"
  echo ""
  echo "Requirements: kind, helm, curl, jq, gsctl."
  echo ""
  echo "In the '-c' mode, this script builds and tests a helm chart using a dedicated cluster."
  echo "The only required parameter is [chart name], which needs to be a name of the chart and "
  echo "also a directory name in the \"helm/\" directory. If there are YAML files present in the directory"
  echo "helm/[chart name]/ci\", a full test starting with creation of a new clean cluster"
  echo "will be executed for each one of them".
  echo "If there's a file \"helm/[chart name]/si/pre-test-hook.sh\", it will be executed after"
  echo "the cluster is ready to deploy the tested application, but before the application"
  echo "is deployed. KUBECONFIG variable is set to the test cluster for the script execution."
  echo "In the next step the chart is built, pushed to the chart repository in the cluster"
  echo "and the App CR is created to deploy the application."
  echo "The last (and optional) step is to execute functional test. If the directory"
  echo "\"${PYTHON_TESTS_DIR}\" is present in the top level directory, the command \"pipenv run pytest\""
  echo "is executed as the last step."
  echo ""
  echo "In the '-j' mode, no testing of any chart is done. In this mode only the specified cluster is created."
  echo "The cluster has 'app-operator', 'chart-operator' and 'chart-museum' already installed."
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
      -j|--just-cluster)
        JUST_CLUSTER=1
        shift 1
        ;;
      -p|--pre-script-path)
        OVERRIDEN_PRE_SCRIPT_PATH=$2
        shift 2
        ;;
      -v|--validate-only)
        VALIDATE_ONLY=1
        shift 1
        ;;
      -s|--skip-pytest)
        SKIP_PYTEST=1
        shift 1
        ;;
      -t|--cluster-type)
        CLUSTER_TYPE=$2
        shift 2
        ;;
      -n|--namespace)
        CHART_DEPLOY_NAMESPACE=$2
        shift 2
        ;;
      --cluster-name)
        CLUSTER_NAME=$2
        shift 2
        ;;
      --provider)
        PROVIDER=$2
        shift 2
        ;;
      -r|--release-version)
        GS_RELEASE=$2
        shift 2
        ;;
      --availability-zone)
        AVAILABILITY_ZONE=$2
        shift 2
        ;;
      --min-scaling)
        SCALING_MIN=$2
        shift 2
        ;;
      --max-scaling)
        SCALING_MAX=$2
        shift 2
        ;;
      --force-cleanup)
        FORCE_CLEANUP=1
        shift 1
        ;;
      --no-external-kube-api)
        NO_EXTERNAL_KUBE_API=1
        shift 1
        ;;
      *)
        print_help
        exit 2
        ;;
    esac
  done

  CLUSTER_NAME=${CLUSTER_NAME:-$DEFAULT_CLUSTER_NAME}
  # generate and apply a random suffix to the cluster name to avoid cluster name
  # collisions when spawning a TC.
  CLUSTER_NAME_SUFFIX=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 10 | head -n 1)
  CLUSTER_NAME=${CLUSTER_NAME}-${CLUSTER_NAME_SUFFIX}

  CLUSTER_TYPE=${CLUSTER_TYPE:-$DEFAULT_CLUSTER_TYPE}

  # don't parse any other flags as we don't need them for the cleanup stage.
  if [[ ! -z ${FORCE_CLEANUP} ]]; then
    force_cleanup
  fi

  if [[ "$CLUSTER_TYPE" == "kind" ]]; then
    if [[ ! -z $KIND_CONFIG_FILE && ! -f $KIND_CONFIG_FILE ]]; then
      err "KinD config file '$KIND_CONFIG_FILE' was specified, but doesn't exist."
      exit 3
    fi
  elif [[ "$CLUSTER_TYPE" == "giantswarm" ]]; then
    if [[ -z $GS_RELEASE ]]; then
      err "GS release version must be provided with the '-r' option."
      exit 3
    fi

    PROVIDER=${PROVIDER:-$DEFAULT_PROVIDER}
    AVAILABILITY_ZONE=${AVAILABILITY_ZONE:-$DEFAULT_AVAILABILITY_ZONE}
    SCALING_MIN=${SCALING_MIN:-$DEFAULT_SCALING_MIN}
    SCALING_MAX=${SCALING_MAX:-$DEFAULT_SCALING_MAX}

    if [[ $SCALING_MIN -gt $SCALING_MAX ]]; then
      info "Min scaling value is greater than the max scaling value ("${SCALING_MIN}" > "${SCALING_MAX}"), setting max scaling to "${SCALING_MIN}"."
      SCALING_MAX=${SCALING_MIN}
    fi

    # infer the region from the AZ (trims last character).
    REGION=$(echo ${AVAILABILITY_ZONE} | rev | cut -c 2- | rev)

    info "Testing with release $GS_RELEASE in AZ $AVAILABILITY_ZONE."
    info "Cluster will scale between $SCALING_MIN and $SCALING_MAX nodes."
  else
    err "Only clusters of types: [kind, giantswarm] are supported now"
    exit 3
  fi

  # don't validate chart related options, if we're just creating a cluster
  if [[ ! -z ${JUST_CLUSTER} ]]; then
    just_cluster
  fi

  if [[ -z $CHART_NAME ]]; then
    err "Chart name must be given with '-c' option or '-j' must be used. Run '-h' for help."
    exit 3
  fi

  if [[ ! -d "helm/${CHART_NAME}" ]]; then
    err "The 'helm/' directory doesn't contain chart named '${CHART_NAME}'. Run '-h' for help."
    exit 3
  fi
}

validate_tools () {
  info "Checking for necessary tools being installed"
  set +e
  for app in "kind" "helm" "curl" "jq" "gsctl"; do
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
  info "Listing gsctl version"
  gsctl --version
  set -e
}

test_main () {
  chart_name=$1

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

just_cluster() {
  create_cluster ${CLUSTER_TYPE}
  start_tools ${CLUSTER_TYPE}
  info "Cluster created"
  exit 0
}

info "kube-app-testing v${KAT_VERSION}"
parse_args $@
validate_tools
validate_chart ${CHART_NAME}
build_chart ${CHART_NAME}
test_main ${CHART_NAME}

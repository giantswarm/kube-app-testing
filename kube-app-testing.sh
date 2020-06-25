#!/bin/bash -e

# TODO:
# - do we need tools versions (helm, kind, python) validation?
# - add option to create worker nodes as well (and how many)
# - add option to use diffrent k8s version
# - already available option to use custom kind config: docs necessary, as we need some options there
# - switch CNI to calico to be compatible(-ish, screw AWS CNI)
# - use external kubeconfig - to run on already existing cluster

# const
KAT_VERSION=0.3.11

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
DEFAULT_GS_API_URL="https://api.g8s.gorilla.eu-central-1.aws.gigantic.io"
DEFAULT_REGION="eu-central-1"
DEFAULT_AVAILABILITY_ZONE="eu-central-1a"
DEFAULT_SCALING_MIN=1
DEFAULT_SCALING_MAX=2

# docker image tags
ARCHITECT_VERSION_TAG=latest
APP_OPERATOR_VERSION_TAG=1.0.7
CHART_OPERATOR_VERSION_TAG=0.13.1
CHART_MUSEUM_VERSION_TAG=v0.12.0
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
  if  [[ "${CLUSTER_TYPE}" == "kind" ]]; then
    K8S_BASE_DOMAIN="cluster.local"
  elif [[ "${CLUSTER_TYPE}" == "giantswarm" ]]; then
    # Gorilla uses a different base domain
    K8S_BASE_DOMAIN="eu-central-1.local"
  fi

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
    URL: http://chart-museum.${TOOLS_NAMESPACE}.svc.${K8S_BASE_DOMAIN}:8080/charts/
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
  kind delete cluster --name ${CLUSTER_NAME}

  if [[ -f ${ENV_DETAILS_FILE} ]]; then
    rm ${ENV_DETAILS_FILE}
  fi
}

gen_gs_blob () {
  # one function to generate different JSON blobs

  # payload for creating a cluster
  if [[ "$1" == "cluster" ]]; then
  cat <<EOF
{
	"owner": "giantswarm",
	"release_version": "${GS_RELEASE}",
	"name": "${CLUSTER_NAME}",
	"master": {
		"availability_zone": "${AVAILABILITY_ZONE}"
	}
}
EOF
  # payload for creating a nodepool
  elif [[ "$1" == "nodepool" ]]; then
  cat <<EOF
{
  "name": "${CLUSTER_NAME}",
  "availability_zones": {
    "number": 1
  },
  "scaling": {
    "min": ${SCALING_MIN},
    "max": ${SCALING_MAX}
  }
}
EOF
  # payload for labelling a cluster
  elif [[ "${1}" == "addlabels" ]]; then
  cat <<EOF
{
  "labels": {
    "circleci-branch": "${CIRCLE_BRANCH}",
    "circleci-build-num": "${CIRCLE_BUILD_NUM}",
    "github-repo": "${CIRCLE_PROJECT_REPONAME}",
    "github-user": "${CIRCLE_PROJECT_USERNAME}",
    "owner": "ci"
  }
}
EOF
  # payload for creating a client key pair
  elif [[ "$1" == "keypair" ]]; then
  cat <<EOF
{
  "description": "CI-generated key pair",
  "ttl_hours": 6,
  "certificate_organizations": "system:masters"
}
EOF
  # template a kubeconfig based on the created key pair.
  # expects a file path as the second argument
  elif [[ "$1" == "kubeconfig" ]]; then
  cat > $2 << EOF
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: "${CA_CERT}"
    server: "${TC_API_URI}"
  name: giantswarm-${CLUSTER_ID}
contexts:
- context:
    cluster: giantswarm-${CLUSTER_ID}
    user: giantswarm-${CLUSTER_ID}-user
  name: giantswarm-${CLUSTER_ID}
current-context: giantswarm-${CLUSTER_ID}
kind: Config
preferences: {}
users:
- name: giantswarm-${CLUSTER_ID}-user
  user:
    client-certificate-data: "${CLIENT_CERT}"
    client-key-data: "${CLIENT_KEY}"
EOF
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
  if ! CLUSTER_DETAILS=$(curl ${GS_API_URL}/v5/clusters/ -X POST \
      -H "Content-Type: application/json" \
      -H "Authorization: giantswarm ${GSAPI_AUTH_TOKEN}" \
      -d "$(gen_gs_blob cluster)") ; then
    err "Cluster creation failed."
    exit 3
  fi

  CLUSTER_ID=$(jq -r .id <<< "${CLUSTER_DETAILS}")

  # make sure we're not too fast for the API
  sleep 5

  # write cluster details to file to run a manual cleanup later if required.
  echo "export CLUSTER_ID=${CLUSTER_ID}" > ${ENV_DETAILS_FILE}
  echo "export CLUSTER_TYPE=${CLUSTER_TYPE}" >> ${ENV_DETAILS_FILE}
  echo "export GS_API_URL=${GS_API_URL}" >> ${ENV_DETAILS_FILE}
  if [ $KEEP_AFTER_TEST ]; then
    echo "export KEEP_AFTER_TEST=${KEEP_AFTER_TEST}" >> ${ENV_DETAILS_FILE}
  fi

  info "Creating nodepool for cluster ${CLUSTER_ID}"
  # create a nodepool
  curl ${GS_API_URL}/v5/clusters/${CLUSTER_ID}/nodepools/ -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: giantswarm ${GSAPI_AUTH_TOKEN}" \
    -d "$(gen_gs_blob nodepool)"

  if [[ "$?" -gt 0 ]]; then
    err "Nodepool creation failed."
    exit 3
  fi

  info "Adding labels to cluster ${CLUSTER_ID}"
  # label the cluster with some useful information. failure to label a cluster
  # doesn't cause a job failure
  if ! curl ${GS_API_URL}/v5/clusters/${CLUSTER_ID}/labels/ -X PUT \
      -H "Content-Type: application/json" \
      -H "Authorization: giantswarm ${GSAPI_AUTH_TOKEN}" \
      -d "$(gen_gs_blob addlabels)" ; then
    err "Could not label cluster, however the job will continue."
  fi

  # wait for the cluster to be ready
  # declare a counter
  _counter=0
  until [ `curl -s -H "Authorization: giantswarm ${GSAPI_AUTH_TOKEN}" ${GS_API_URL}/v5/clusters/${CLUSTER_ID}/ | jq .conditions | grep -i "created" | wc -l` -gt 0 ]; do
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

  info "Creating key-pair for tenant cluster access."
  # create a key pair (must be stored directly in a variable)
  _key_pair=$(curl ${GS_API_URL}/v4/clusters/${CLUSTER_ID}/key-pairs/ -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: giantswarm ${GSAPI_AUTH_TOKEN}" \
    -d "$(gen_gs_blob keypair)")

  # check that we actually got a key pair back
  grep -q "certificate_authority_data" <<< $_key_pair
  if [[ "$?" -gt 0 ]]; then
    err "Key pair creation failed."
    exit 3
  fi

  # parse required fields from key pair creation response in order to
  # create a kubeconfig for the tenant cluster
  TC_API_URI=$(curl -s -H "Authorization: giantswarm ${GSAPI_AUTH_TOKEN}" ${GS_API_URL}/v5/clusters/${CLUSTER_ID}/ | jq -r .api_endpoint)
  CA_CERT=$(echo $_key_pair | jq -r '.certificate_authority_data | @base64')
  CLIENT_CERT=$(echo $_key_pair | jq -r '.client_certificate_data | @base64')
  CLIENT_KEY=$(echo $_key_pair | jq -r '.client_key_data | @base64')

  # align config with kind clusters
  if [[ ! -d ${CONFIG_DIR} ]]; then
    mkdir ${CONFIG_DIR}
  fi

  info "Templating kubeconfig out to ${KUBECONFIG}"
  # create the kubeconfig
  gen_gs_blob kubeconfig ${KUBECONFIG}

  # update Security Group to allow access
  update_aws_sec_group ${CLUSTER_ID}

  # make sure the ingress rule has taken effect before we attempt to connect
  info "Sleeping for 30 seconds to ensure ingress rule has been applied."
  sleep 30

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
  curl ${GS_API_URL}/v4/clusters/${CLUSTER_ID}/ -X DELETE \
    -H "Authorization: giantswarm ${GSAPI_AUTH_TOKEN}"

  if [[ "$?" -gt 0 ]]; then
    err "Cluster deletion failed - please investigate."
    exit 3
  fi

  if [[ -f ${ENV_DETAILS_FILE} ]]; then
    rm ${ENV_DETAILS_FILE}
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

  # the GS API token must be provided again - this is because it shouldn't be written
  # to the filesystem at any point.
  if [[ -z ${GSAPI_AUTH_TOKEN} ]] && [[ "${CLUSTER_TYPE}" == "giantswarm" ]]; then
    err "Auth token must be provided to enable GS cluster teardown."
    exit 3
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

  info "Deploying \"chart-museum\""
  chart_museum_deploy ${cluster_type}

  # deploy app-operator to all cluster types
  info "Deploying \"app-operator\""
  kubectl -n ${TOOLS_NAMESPACE} create serviceaccount appcatalog
  kubectl create clusterrolebinding appcatalog_cluster-admin --clusterrole=cluster-admin --serviceaccount=${TOOLS_NAMESPACE}:appcatalog
  # tenant clusters have a default deny-all network policy which breaks app-operator
  if [[ "$cluster_type" == "giantswarm" ]]; then
    create_app_operator_netpol
  fi
  kubectl -n ${TOOLS_NAMESPACE} run app-operator --serviceaccount=appcatalog -l app=app-operator --image=quay.io/giantswarm/app-operator:${APP_OPERATOR_VERSION_TAG} -- daemon --service.kubernetes.incluster="true"

  # only deploy chart-operator to kind clusters
  if [[ "$cluster_type" == "kind" ]]; then
    info "Deploying \"chart-operator\""
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
  docker run -it --rm \
    -v ${TMP_DIR}/.local:/root/.local \
    -v ${TMP_DIR}/.cache:/root/.cache \
    -v `pwd`:/chart -w /chart \
    -v ${KUBECONFIG}:/kube.config:ro \
    python:${PYTHON_VERSION_TAG} sh \
    -c "pip install pipenv \
    && cd ${PYTHON_TESTS_DIR} \
    && $pipenv_cmd \
      --kube-config /kube.config \
      --chart-name ${chart_name} \
      --chart-version ${CHART_VERSION} \
      --values-file ../../${config_file} \
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
  echo "  ${0##*/} [OPTION...] -c [chart name in helm/ dir]"
  echo ""
  echo "Options:"
  echo "  -h, --help                      display this help screen"
  echo "  -v, --validate-only             only validate and lint the chart using 'chart-testing'"
  echo "                                  (runs tests that don't require any cluster)."
  echo "  -s, --skip-pytest               skip running the pytest test suite, even if present."
  echo "  --force-cleanup                 using force cleanup allows the script to be run independently"
  echo "                                  of the main job. This allows it to clean up any dangling resources"
  echo "                                  left by a failure mid-job. Must be run in a CircleCI job with the"
  echo "                                  `when: on_fail` value set. If the cluster is a GS cluster then the"
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
  echo "  -a, --auth-token                auth token for the giantswarm API (only applies to"
  echo "                                  giantswarm cluster type)"
  echo "  -r, --release-version           giantswarm release to use (only applies to"
  echo "                                  giantswarm cluster type)"
  echo "  --provider                      provider to deploy tenant cluster on"
  echo "                                  available providers: aws (default)"
  echo "  --availability-zone             availability zone to deploy the cluster into, defaults to"
  echo "                                  'eu-central-1a'"
  echo "  --giantswarm-api-url            URL of the Giantswarm installation API, defaults to Gorilla."
  echo "                                  e.g. 'https://api.g8s.gorilla.eu-central-1.aws.gigantic.io'"
  echo "  --min-scaling                   minimum number of nodes (applies to GS clusters only)"
  echo "  --max-scaling                   maximum number of nodes (applies to GS clusters only). If the max"
  echo "                                  value is set to _less_ than the min value then the provided max will"
  echo "                                  be ignored and max will be set to the same as min, resulting in a"
  echo "                                  statically-sized nodepool"
  echo ""
  echo "Requirements: kind, helm, curl, jq."
  echo ""
  echo "This script builds and tests a helm chart using a dedicated cluster. The only required"
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
  echo "\"${PYTHON_TESTS_DIR}\" is present in the top level directory, the command \"pipenv run pytest\""
  echo "is executed as the last step."
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
      -a|--auth-token)
        GSAPI_AUTH_TOKEN=$2
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
      --giantswarm-api-url)
        GS_API_URL=$2
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

  if [[ -z $CHART_NAME ]]; then
    err "chart name must be given with '-c' option"
    exit 3
  fi

  if [[ ! -d "helm/${CHART_NAME}" ]]; then
    err "The 'helm/' directory doesn't contain chart named '${CHART_NAME}'."
    exit 3
  fi

  if [[ "$CLUSTER_TYPE" == "kind" ]]; then
    if [[ ! -z $KIND_CONFIG_FILE && ! -f $KIND_CONFIG_FILE ]]; then
      err "KinD config file '$KIND_CONFIG_FILE' was specified, but doesn't exist."
      exit 3
    fi
  elif [[ "$CLUSTER_TYPE" == "giantswarm" ]]; then
    if [[ -z $GSAPI_AUTH_TOKEN ]]; then
      err "Auth token for the Giant Swarm API must be provided with the '-a' option."
      exit 3
    fi

    if [[ -z $GS_RELEASE ]]; then
      err "GS release version must be provided with the '-r' option."
      exit 3
    fi

    PROVIDER=${PROVIDER:-$DEFAULT_PROVIDER}
    GS_API_URL=${GS_API_URL:-$DEFAULT_GS_API_URL}
    AVAILABILITY_ZONE=${AVAILABILITY_ZONE:-$DEFAULT_AVAILABILITY_ZONE}
    SCALING_MIN=${SCALING_MIN:-$DEFAULT_SCALING_MIN}
    SCALING_MAX=${SCALING_MAX:-$DEFAULT_SCALING_MAX}

    if [[ $SCALING_MIN -gt $SCALING_MAX ]]; then
      info "Min scaling value is greater than the max scaling value ("${SCALING_MIN}" > "${SCALING_MAX}"), setting max scaling to "${SCALING_MIN}"."
      SCALING_MAX=${SCALING_MIN}
    fi

    # infer the region from the AZ (trims last character).
    REGION=$(echo ${AVAILABILITY_ZONE} | rev | cut -c 2- | rev)

    info "Testing with release $GS_RELEASE against $GS_API_URL in AZ $AVAILABILITY_ZONE."
    info "Cluster will scale between $SCALING_MIN and $SCALING_MAX nodes."
  else
    err "Only clusters of types: [kind, giantswarm] are supported now"
    exit 3
  fi
}

validate_tools () {
  info "Checking for necessary tools being installed"
  set +e
  for app in "kind" "helm" "curl" "jq"; do
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

parse_args $@
info "kube-app-testing v${KAT_VERSION}"
validate_tools
validate_chart ${CHART_NAME}
build_chart ${CHART_NAME}
test_main ${CHART_NAME}

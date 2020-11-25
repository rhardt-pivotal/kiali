#/bin/bash

##############################################################################
# k8s-minikube.sh
#
# This script can be used to help run Kubernetes via minikube.
# The typical order of commands used is the following:
#   start - starts the Kubernetes cluster via minikube
#   istio - installs Istio using Kiali's install hack script
#   docker - shows what is needed to put images in minikube's image registry
#   podman - shows what is needed to put images in minikube's image registry
#   (at this point, you can install Kiali into your Kubernetes environment)
#   dashboard - shows the Kubernetes GUI console
#   port-forward - forward a local port to the Kiali server
#   ingress - shows the Ingress URL which can get you to the Kiali GUI
#   bookinfo - installs bookinfo demo into your cluster
#   stop - shuts down the Kubernetes cluster, you can start it up again
#   delete - if you don't want your cluster anymore, this deletes it
#
##############################################################################

set -u

DEFAULT_DEX_ENABLED="false"
DEFAULT_DEX_REPO="https://github.com/dexidp/dex"
DEFAULT_DEX_VERSION="v2.24.0"
DEFAULT_DEX_USER_NAMESPACES="bookinfo"
DEFAULT_INSECURE_REGISTRY_IP="192.168.99.100"
DEFAULT_K8S_CPU="4"
DEFAULT_K8S_DISK="40g"
DEFAULT_K8S_DRIVER="virtualbox"
DEFAULT_K8S_MEMORY="16g"
DEFAULT_K8S_VERSION="stable"
DEFAULT_MINIKUBE_EXEC="minikube"
DEFAULT_MINIKUBE_PROFILE="minikube"
DEFAULT_MINIKUBE_START_FLAGS=""
DEFAULT_OUTPUT_PATH="/tmp/k8s-minikube-tmpdir"

_VERBOSE="false"

debug() {
  if [ "$_VERBOSE" == "true" ]; then
    echo "DEBUG: $1"
  fi
}

ensure_minikube_is_running() {
  if ! ${MINIKUBE_EXEC_WITH_PROFILE} status > /dev/null 2>&1 ; then
    echo 'Minikube must be running in order to continue. Aborting.'
    exit 1
  fi
}

get_gateway_url() {
  if [ "$1" == "" ] ; then
    INGRESS_PORT="<port>"
  else
    jsonpath="{.spec.ports[?(@.name==\"$1\")].nodePort}"
    INGRESS_PORT=$(${MINIKUBE_EXEC_WITH_PROFILE} kubectl -- -n istio-system get service istio-ingressgateway -o jsonpath=${jsonpath})
  fi

  INGRESS_HOST=$(${MINIKUBE_EXEC_WITH_PROFILE} ip)
  GATEWAY_URL=$INGRESS_HOST:${INGRESS_PORT:-?}
}

print_all_gateway_urls() {
  echo "Gateway URLs for all known ports are:"
  allnames=$(${MINIKUBE_EXEC_WITH_PROFILE} kubectl -- -n istio-system get service istio-ingressgateway -o jsonpath={.spec.ports['*'].name})
  for n in ${allnames}
  do
    get_gateway_url ${n}
    echo ${n}: ${GATEWAY_URL}
  done
}

check_insecure_registry() {
  local _registry="$(${MINIKUBE_EXEC_WITH_PROFILE} ip):5000"
  pgrep -a dockerd | grep "[-]-insecure-registry.*${_registry}" > /dev/null 2>&1
  if [ "$?" != "0" ]; then
    grep "OPTIONS=.*--insecure-registry.*${_registry}" /etc/sysconfig/docker > /dev/null 2>&1
    if [ "$?" != "0" ]; then
      grep "insecure-registries.*${_registry}" /etc/docker/daemon.json > /dev/null 2>&1
      if [ "$?" != "0" ]; then
        echo "WARNING: You must tell Docker about the insecure image registry (e.g. --insecure-registry ${_registry})."
      else
        debug "/etc/docker/daemon.json has the insecure-registry setting. This is good."
      fi
    else
      debug "/etc/sysconfig/docker has defined the insecure-registry setting. This is good."
    fi
  else
    debug "Docker daemon is running with --insecure-registry setting. This is good."
  fi
}

install_dex() {
  echo 'Installing Dex for OpenID Connect support...'

  # Download dex - prepare a clean copy
  DEX_VERSION_PATH="${OUTPUT_PATH}/dex/${DEX_VERSION}"
  rm -rf ${DEX_VERSION_PATH}
  if [ ! -d "${DEX_VERSION_PATH}" ]; then
    echo "Will download Dex version [${DEX_VERSION}] to [${DEX_VERSION_PATH}]"
    mkdir -p ${DEX_VERSION_PATH}

    if command -v wget >/dev/null 2>&1; then
      wget ${DEX_REPO}/archive/${DEX_VERSION}.tar.gz -O - | tar -C ${DEX_VERSION_PATH} --strip-components 1 -zxf -
    else
      curl -L -o - | tar -C ${DEX_VERSION_PATH} --strip-components 1 -zxf -
    fi
  else
    echo "Will use existing Dex version [${DEX_VERSION}] found at [${DEX_VERSION_PATH}]"
  fi

  # Find minikube ip
  MINIKUBE_IP=$(${MINIKUBE_EXEC_WITH_PROFILE} ip)
  echo "Minikube IP is ${MINIKUBE_IP}"

  MINIKUBE_IP_DASHED=$(echo -n ${MINIKUBE_IP} | sed 's/\./-/g')
  KUBE_HOSTNAME="${MINIKUBE_IP_DASHED}.nip.io"
  echo "Hostname will be ${KUBE_HOSTNAME}"

  # Generate certs for the minikube instance, if we still don't have them
  CERTS_PATH="${DEX_VERSION_PATH}/examples/k8s/ssl_${KUBE_HOSTNAME}"
  if [ ! -d "${CERTS_PATH}" ]; then
    # Patch gencert.sh script from dex
    rm -f ${DEX_VERSION_PATH}/examples/k8s/kiali.gencert.sh
    rm -rf ${DEX_VERSION_PATH}/examples/k8s/ssl
    patch -i - -o ${DEX_VERSION_PATH}/examples/k8s/kiali.gencert.sh ${DEX_VERSION_PATH}/examples/k8s/gencert.sh <<EOF
18c18
< DNS.1 = dex.example.com
---
> DNS.1 = ${KUBE_HOSTNAME}
EOF

    $(cd ${DEX_VERSION_PATH}/examples/k8s/; bash ./kiali.gencert.sh)
    mv ${DEX_VERSION_PATH}/examples/k8s/ssl ${CERTS_PATH}

  fi

  # Copy certificates to minikube cluster
  # Because the user may destroy and create many minikube VMs, expect the VM fingerprint to change (i.e. avoid known_hosts checks)
  mkdir -p ${OUTPUT_PATH}
  local tmp_known_hosts="${OUTPUT_PATH}/minikube-known-hosts"
  rm -f ${tmp_known_hosts}
  ${MINIKUBE_EXEC_WITH_PROFILE} ssh -- mkdir dex_certs
  scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=${tmp_known_hosts} -i $(${MINIKUBE_EXEC_WITH_PROFILE} ssh-key) ${CERTS_PATH}/* docker@$(${MINIKUBE_EXEC_WITH_PROFILE} ip):dex_certs/
  ${MINIKUBE_EXEC_WITH_PROFILE} ssh -- sudo mkdir -p /var/lib/minikube/certs/
  ${MINIKUBE_EXEC_WITH_PROFILE} ssh -- sudo cp /home/docker/dex_certs/* /var/lib/minikube/certs/

  # Patch dex file
  rm -rf ${DEX_VERSION_PATH}/examples/k8s/dex.kiali.yaml
  patch -i - -o ${DEX_VERSION_PATH}/examples/k8s/dex.kiali.yaml ${DEX_VERSION_PATH}/examples/k8s/dex.yaml << EOF
1c1
< apiVersion: extensions/v1beta1
---
> apiVersion: apps/v1
8a9,11
>   selector:
>     matchLabels:
>       app: dex
30,40d32
<         env:
<         - name: GITHUB_CLIENT_ID
<           valueFrom:
<             secretKeyRef:
<               name: github-client
<               key: client-id
<         - name: GITHUB_CLIENT_SECRET
<           valueFrom:
<             secretKeyRef:
<               name: github-client
<               key: client-secret
58c50
<     issuer: https://dex.example.com:32000
---
>     issuer: https://${KUBE_HOSTNAME}:32000
68,75d59
<     - type: github
<       id: github
<       name: GitHub
<       config:
<         clientID: \$GITHUB_CLIENT_ID
<         clientSecret: \$GITHUB_CLIENT_SECRET
<         redirectURI: https://dex.example.com:32000/callback
<         org: kubernetes
77a62
>       responseTypes: ["code", "id_token"]
84a70,74
>     - id: kiali-app
>       redirectURIs:
>       - 'http://${MINIKUBE_IP}/kiali'
>       name: 'Kiali'
>       secret: notNeeded
139c129
<   namespace: default  # The namespace dex is running in
---
>   namespace: dex      # The namespace dex is running in
EOF

  # Install dex
  echo "Deploying dex..."
  ${MINIKUBE_EXEC_WITH_PROFILE} kubectl -- create namespace dex
  ${MINIKUBE_EXEC_WITH_PROFILE} kubectl -- create secret tls dex.example.com.tls --cert=${CERTS_PATH}/cert.pem --key=${CERTS_PATH}/key.pem -n dex
  ${MINIKUBE_EXEC_WITH_PROFILE} kubectl -- apply -n dex -f ${DEX_VERSION_PATH}/examples/k8s/dex.kiali.yaml

  # Restart minikube
  echo "Restarting minikube with proper flags for API server and the autodetected registry IP..."
  ${MINIKUBE_EXEC_WITH_PROFILE} stop
  ${MINIKUBE_EXEC_WITH_PROFILE} start \
    ${MINIKUBE_START_FLAGS} \
    --insecure-registry ${INSECURE_REGISTRY_IP}:5000 \
    --insecure-registry ${MINIKUBE_IP}:5000 \
    --cpus=${K8S_CPU} \
    --memory=${K8S_MEMORY} \
    --disk-size=${K8S_DISK} \
    --driver=${K8S_DRIVER} \
    --kubernetes-version=${K8S_VERSION} \
    --extra-config=apiserver.oidc-issuer-url=https://${KUBE_HOSTNAME}:32000 \
    --extra-config=apiserver.oidc-username-claim=email \
    --extra-config=apiserver.oidc-ca-file=/var/lib/minikube/certs/ca.pem \
    --extra-config=apiserver.oidc-client-id=kiali-app \
    --extra-config=apiserver.oidc-groups-claim=groups

  echo "Minikube should now be configured with OpenID connect. Just wait for all pods to start."
  cat <<EOF
Commands to query Dex deployments and pods:
  ${MINIKUBE_EXEC_WITH_PROFILE} kubectl -- get deployments -n dex
  ${MINIKUBE_EXEC_WITH_PROFILE} kubectl -- get pods -n dex

OpenID configuration for Kiali CR:
  auth:
    strategy: openid
    openid:
      client_id: "kiali-app"
      insecure_skip_verify_tls: true
      issuer_uri: "https://${KUBE_HOSTNAME}:32000"
      username_claim: "email"

OpenID user is:
  Username: admin@example.com
  Password: password
EOF

  if [ "${DEX_USER_NAMESPACES}" != "none" ]; then
    if [ "${DEX_USER_NAMESPACES}" == "all" ]; then
      echo "Command to grant the user 'admin@example.com' cluster-admin permissions:"
      echo ${MINIKUBE_EXEC_WITH_PROFILE} kubectl -- create clusterrolebinding openid-rolebinding-admin --clusterrole=cluster-admin --user="admin@example.com"
    else
      echo "Commands to grant the user 'admin@example.com' permission to see specific namespaces:"
      for ns in ${DEX_USER_NAMESPACES}; do
        echo ${MINIKUBE_EXEC_WITH_PROFILE} kubectl -- create rolebinding openid-rolebinding-${ns} --clusterrole=kiali --user="admin@example.com" --namespace=${ns}
      done
    fi
  fi
}

# Change to the directory where this script is and set our env
cd "$(dirname "${BASH_SOURCE[0]}")"

_CMD=""
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    start|up) _CMD="start"; shift ;;
    stop|down) _CMD="stop"; shift ;;
    status) _CMD="status"; shift ;;
    delete) _CMD="delete"; shift ;;
    docker) _CMD="docker"; shift ;;
    podman) _CMD="podman"; shift ;;
    dashboard) _CMD="dashboard"; shift ;;
    port-forward) _CMD="port-forward"; shift ;;
    ingress) _CMD="ingress"; shift ;;
    istio) _CMD="istio"; shift ;;
    bookinfo) _CMD="bookinfo"; shift ;;
    gwurl)
      _CMD="gwurl"
      if [ "${2:-}" != "" ]; then
        _CMD_OPT="$2"
        shift
      else
        _CMD_OPT="all"
      fi
      shift
      ;;
    resetclock) _CMD="resetclock"; shift ;;
    -de|--dex-enabled) DEX_ENABLED="$2"; shift;shift ;;
    -dr|--dex-repo) DEX_REPO="$2"; shift;shift ;;
    -dun|--dex-user-namespaces) DEX_USER_NAMESPACES="$2"; shift;shift ;;
    -dv|--dex-version) DEX_VERSION="$2"; shift;shift ;;
    -iri|--insecure-registry-ip) INSECURE_REGISTRY_IP="$2"; shift;shift ;;
    -kc|--kubernetes-cpu) K8S_CPU="$2"; shift;shift ;;
    -kd|--kubernetes-disk) K8S_DISK="$2"; shift;shift ;;
    -kdr|--kubernetes-driver) K8S_DRIVER="$2"; shift;shift ;;
    -km|--kubernetes-memory) K8S_MEMORY="$2"; shift;shift ;;
    -kv|--kubernetes-version) K8S_VERSION="$2"; shift;shift ;;
    -me|--minikube-exec) MINIKUBE_EXEC="$2"; shift;shift ;;
    -mf|--minikube-flags) MINIKUBE_START_FLAGS="$2"; shift;shift ;;
    -mp|--minikube-profile) MINIKUBE_PROFILE="$2"; shift;shift ;;
    -op|--output-path) OUTPUT_PATH="$2"; shift;shift ;;
    -v|--verbose) _VERBOSE=true; shift ;;
    -h|--help)
      cat <<HELPMSG

$0 [option...] command

Valid options:
  -de|--dex-enabled
      If true, install and configure Dex. This provides an OpenID Connect implementation.
      Only used for the 'start' command.
      Default: ${DEFAULT_DEX_ENABLED}
  -dr|--dex-repo
      The github repo where the Dex archive is to be found.
      Only used for the 'start' command and when Dex is to be installed (--dex-enabled=true).
      Default: ${DEFAULT_DEX_REPO}
  -dun|--dex-user-namespaces
      A space-separated list of namespaces that you would like the admin@example.com user to be able to see.
      This option will not trigger actual creation of the role bindings; instead, it merely outputs the
      commands in the final summary that you should then execute in order to grant those permissions. This is
      because the namespaces may not exist yet (such as "bookinfo") nor will the kiali role exist.
      If this value is set to "none", no commands will be output.
      If this value is set to "all", the command that will be output will grant cluster-admin permissions.
      Only used for the 'start' command and when Dex is to be installed (--dex-enabled=true).
      Default: ${DEFAULT_DEX_USER_NAMESPACES}
  -dv|--dex-version
      The version of Dex to be installed.
      Only used for the 'start' command and when Dex is to be installed (--dex-enabled=true).
      Default: ${DEFAULT_DEX_VERSION}
  -iri|--insecure-registry-ip
      This is used for the setting up an insecure registry IP within the minikube docker daemon.
      This is needed to easily authenticate and push images to the docker daemon.
      This IP is usually the minikube IP, but that IP varies depending on the driver being used.
      This IP is needed during startup, but it cannot be determined until after minikube starts;
      hence that is why this script cannot auto-detect what you need. If the default is incorrect
      for the driver you are using, you can set this value if you know what it will be. Otherwise,
      you will need to obtain the minikube IP, then 'stop' and then 'start' minikube with this
      value appropriately set.
      Only used for the 'start' commmand.
      Default: ${DEFAULT_INSECURE_REGISTRY_IP}
  -kc|--kubernetes-cpu
      The number of CPUs to give to Kubernetes at startup.
      Only used for the 'start' command.
      Default: ${DEFAULT_K8S_CPU}
  -kd|--kubernetes-disk
      The amount of disk space to give to Kubernetes at startup.
      Only used for the 'start' command.
      Default: ${DEFAULT_K8S_DISK}
  -kdr|--kubernetes-driver
      The hypervisor to use. Examples of valid values: virtualbox, hyperkit, kvm2, none.
      Only used for the 'start' command.
      Default: ${DEFAULT_K8S_DRIVER}
  -km|--kubernetes-memory
      The amount of memory to give to Kubernetes at startup.
      Only used for the 'start' command.
      Default: ${DEFAULT_K8S_MEMORY}
  -kv|--kubernetes-version
      The version of Kubernetes to start.
      Only used for the 'start' command.
      Default: ${DEFAULT_K8S_VERSION}
  -me|--minikube-exec
      The minikube executable.
      Default: ${DEFAULT_MINIKUBE_EXEC}
  -mf|--minikube-flags
      Additional flags to pass to the 'minikube start' command.
      Only used for the 'start' command.
      Default: ${DEFAULT_MINIKUBE_START_FLAGS}
  -mp|--minikube-profile
      The profile which minikube will be started with.
      Default: ${DEFAULT_MINIKUBE_PROFILE}
  -op|--output-path
      A path this script can use to store files it needs or generates.
      This path will be created if it does not exist, but it will
      only be created if it is needed by the script.
      Default: ${DEFAULT_OUTPUT_PATH}
  -v|--verbose
      Enable logging of debug messages from this script.

The command must be either:
  start:        starts the minikube cluster (alias: up)
  stop:         stops the minikube cluster (alias: down)
  status:       gets the status of the minikube cluster
  delete:       completely removes the minikube cluster VM destroying all state
  docker:       information on the minikube docker environment
  podman:       information on the minikube podman environment
  dashboard:    enables access to the Kubernetes GUI within minikube
  port-forward: forward a local port to the Kiali server
  ingress:      enables access to the Kubernetes ingress URL within minikube
  istio:        installs Istio into the minikube cluster
  bookinfo:     installs Istio's bookinfo demo (make sure Istio is installed first)
  gwurl [<portName>|'all']:
                displays the Ingress Gateway URL. If a port name is given, the gateway port is also shown.
                If the port name is "all" then all the URLs for all known ports are shown.
  resetclock:   If the VM's clock gets skewed (e.g. by sleeping) run this to reset it to the current time.
HELPMSG
      exit 1
      ;;
    *)
      echo "Unknown argument [$key]. Aborting."
      exit 1
      ;;
  esac
done

# Prepare some env vars
: ${DEX_ENABLED:=${DEFAULT_DEX_ENABLED}}
: ${DEX_REPO:=${DEFAULT_DEX_REPO}}
: ${DEX_USER_NAMESPACES:=${DEFAULT_DEX_USER_NAMESPACES}}
: ${DEX_VERSION:=${DEFAULT_DEX_VERSION}}
: ${INSECURE_REGISTRY_IP:=${DEFAULT_INSECURE_REGISTRY_IP}}
: ${K8S_CPU:=${DEFAULT_K8S_CPU}}
: ${K8S_DISK:=${DEFAULT_K8S_DISK}}
: ${K8S_DRIVER:=${DEFAULT_K8S_DRIVER}}
: ${K8S_VERSION:=${DEFAULT_K8S_VERSION}}
: ${K8S_MEMORY:=${DEFAULT_K8S_MEMORY}}
: ${MINIKUBE_EXEC:=${DEFAULT_MINIKUBE_EXEC}}
: ${MINIKUBE_START_FLAGS:=${DEFAULT_MINIKUBE_START_FLAGS}}
: ${MINIKUBE_PROFILE:=${DEFAULT_MINIKUBE_PROFILE}}
: ${OUTPUT_PATH:=${DEFAULT_OUTPUT_PATH}}

MINIKUBE_EXEC_WITH_PROFILE="${MINIKUBE_EXEC} -p ${MINIKUBE_PROFILE}"

debug "DEX_ENABLED=$DEX_ENABLED"
debug "DEX_REPO=$DEX_REPO"
debug "DEX_USER_NAMESPACES=$DEX_USER_NAMESPACES"
debug "DEX_VERSION=$DEX_VERSION"
debug "INSECURE_REGISTRY_IP=$INSECURE_REGISTRY_IP"
debug "K8S_CPU=$K8S_CPU"
debug "K8S_DISK=$K8S_DISK"
debug "K8S_DRIVER=$K8S_DRIVER"
debug "K8S_MEMORY=$K8S_MEMORY"
debug "K8S_VERSION=$K8S_VERSION"
debug "MINIKUBE_EXEC=$MINIKUBE_EXEC"
debug "MINIKUBE_START_FLAGS=$MINIKUBE_START_FLAGS"
debug "MINIKUBE_PROFILE=$MINIKUBE_PROFILE"
debug "OUTPUT_PATH=$OUTPUT_PATH"

# If minikube executable is not found, abort.
if ! which ${MINIKUBE_EXEC} > /dev/null 2>&1 ; then
  echo 'You do not have minikube installed [${MINIKUBE_EXEC}]. Aborting.'
  exit 1
fi

debug "This script is located at $(pwd)"
debug "minikube is located at $(which ${MINIKUBE_EXEC})"

if [ "$_CMD" = "start" ]; then
  echo 'Starting minikube...'
  ${MINIKUBE_EXEC_WITH_PROFILE} start \
    ${MINIKUBE_START_FLAGS} \
    --insecure-registry ${INSECURE_REGISTRY_IP}:5000 \
    --cpus=${K8S_CPU} \
    --memory=${K8S_MEMORY} \
    --disk-size=${K8S_DISK} \
    --driver=${K8S_DRIVER} \
    --kubernetes-version=${K8S_VERSION}
  echo 'Enabling the ingress addon'
  ${MINIKUBE_EXEC_WITH_PROFILE} addons enable ingress
  echo 'Enabling the image registry'
  ${MINIKUBE_EXEC_WITH_PROFILE} addons enable registry

  if [ "${DEX_ENABLED}" == "true" ]; then
    install_dex
  fi

elif [ "$_CMD" = "stop" ]; then
  ensure_minikube_is_running
  echo 'Stopping minikube'
  ${MINIKUBE_EXEC_WITH_PROFILE} stop

elif [ "$_CMD" = "status" ]; then
  ensure_minikube_is_running
  check_insecure_registry
  echo 'Status report for minikube'
  ${MINIKUBE_EXEC_WITH_PROFILE} status

elif [ "$_CMD" = "delete" ]; then
  echo 'Deleting the entire minikube VM'
  ${MINIKUBE_EXEC_WITH_PROFILE} delete

elif [ "$_CMD" = "dashboard" ]; then
  ensure_minikube_is_running
  echo 'Accessing the Kubernetes console GUI. This runs in foreground, press Control-C to kill it.'
  ${MINIKUBE_EXEC_WITH_PROFILE} dashboard

elif [ "$_CMD" = "port-forward" ]; then
  ensure_minikube_is_running
  echo 'Forwarding port 20001 to the Kiali server. This runs in foreground, press Control-C to kill it.'
  echo 'To access Kiali, point your browser to https://localhost:20001/kiali/console'
  ${MINIKUBE_EXEC_WITH_PROFILE} kubectl -- -n istio-system port-forward $(${MINIKUBE_EXEC_WITH_PROFILE} kubectl -- -n istio-system get pod -l app.kubernetes.io/name=kiali -o jsonpath='{.items[0].metadata.name}') 20001:20001

elif [ "$_CMD" = "ingress" ]; then
  ensure_minikube_is_running
  echo 'Accessing the Kubernetes Ingress URL.'
  gio open "http://$(${MINIKUBE_EXEC_WITH_PROFILE} ip)"

elif [ "$_CMD" = "istio" ]; then
  ensure_minikube_is_running
  echo 'Installing Istio'
  ./istio/install-istio-via-istioctl.sh -c kubectl

elif [ "$_CMD" = "bookinfo" ]; then
  ensure_minikube_is_running
  echo 'Installing Bookinfo'
  ./istio/install-bookinfo-demo.sh --mongo -tg -c kubectl
  get_gateway_url http2
  echo 'To access the Bookinfo application, access this URL:'
  echo "http://${GATEWAY_URL}/productpage"
  echo 'To push requests into the Bookinfo application, execute this command:'
  echo "watch -n 1 curl -o /dev/null -s -w '%{http_code}' http://${GATEWAY_URL}/productpage"

elif [ "$_CMD" = "gwurl" ]; then
  ensure_minikube_is_running
  if [ "${_CMD_OPT}" == "all" ]; then
    print_all_gateway_urls
  else
    get_gateway_url $_CMD_OPT
    echo 'The Gateway URL is:'
    echo "${GATEWAY_URL}"
  fi

elif [ "$_CMD" = "docker" ]; then
  ensure_minikube_is_running
  echo 'Your current minikube docker environment is the following:'
  ${MINIKUBE_EXEC_WITH_PROFILE} docker-env
  echo 'Run the above command in your shell before building container images so your images will go in the minikube image registry'

elif [ "$_CMD" = "podman" ]; then
  ensure_minikube_is_running
  echo 'Your current minikube podman environment is the following:'
  ${MINIKUBE_EXEC_WITH_PROFILE} podman-env
  echo 'Run the above command in your shell before building container images so your images will go in the minikube image registry'

elif [ "$_CMD" = "resetclock" ]; then
  ensure_minikube_is_running
  echo "Resetting the clock in the minikube VM"
  ${MINIKUBE_EXEC_WITH_PROFILE} ssh -- sudo date -u $(date -u +%m%d%H%M%Y.%S)

else
  echo "ERROR: Missing required command"
  exit 1
fi

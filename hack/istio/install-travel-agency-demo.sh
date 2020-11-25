#/bin/bash

# This deploys the travel agency demo

: ${CLIENT_EXE:=oc}
: ${NAMESPACE_AGENCY:=travel-agency}
: ${NAMESPACE_PORTAL:=travel-portal}
: ${NAMESPACE_CONTROL:=travel-control}
: ${ENABLE_OPERATION_METRICS:=false}
: ${DELETE_DEMO:=false}
: ${SHOW_GUI:=false}

while [ $# -gt 0 ]; do
  key="$1"
  case $key in
    -c|--client)
      CLIENT_EXE="$2"
      shift;shift
      ;;
    -d|--delete)
      DELETE_DEMO="$2"
      shift;shift
      ;;
    -eo|--enable-operation-metrics)
      ENABLE_OPERATION_METRICS="$2"
      shift;shift
      ;;
    -sg|--show-gui)
      SHOW_GUI="$2"
      shift;shift
      ;;
    -h|--help)
      cat <<HELPMSG
Valid command line arguments:
  -c|--client: either 'oc' or 'kubectl'
  -d|--delete: either 'true' or 'false'. If 'true' the travel agency demo will be deleted, not installed.
  -eo|--enable-operation-metrics: either 'true' or 'false' (default is false). Only works on Istio 1.7 installed in istio-system.
  -sg|--show-gui: do not install anything, but bring up the travel agency GUI in a browser window
  -h|--help: this text
HELPMSG
      exit 1
      ;;
    *)
      echo "Unknown argument [$key]. Aborting."
      exit 1
      ;;
  esac
done

if [ "${SHOW_GUI}" == "true" ]; then
  echo "Will not install anything. Creating port-forward now. (control-c to exit)"
  echo "Point your browser to here: "
  echo "  http://localhost:8080"
  ${CLIENT_EXE} port-forward svc/control 8080:8080 -n travel-control
  exit 0
fi

echo Will deploy Travel Agency using these settings:
echo CLIENT_EXE=${CLIENT_EXE}
echo NAMESPACE_AGENCY=${NAMESPACE_AGENCY}
echo NAMESPACE_PORTAL=${NAMESPACE_PORTAL}
echo NAMESPACE_CONTROL=${NAMESPACE_CONTROL}
echo ENABLE_OPERATION_METRICS=${ENABLE_OPERATION_METRICS}

# If we are to delete, remove everything and exit immediately after
if [ "${DELETE_DEMO}" == "true" ]; then
  echo "Deleting Travel Agency Demo (the envoy filters, if previously created, will remain)"
  if [ "${CLIENT_EXE}" == "oc" ]; then
    ${CLIENT_EXE} adm policy remove-scc-from-group privileged system:serviceaccounts:${NAMESPACE_AGENCY}
    ${CLIENT_EXE} adm policy remove-scc-from-group anyuid system:serviceaccounts:${NAMESPACE_AGENCY}
    ${CLIENT_EXE} delete network-attachment-definition istio-cni -n ${NAMESPACE_AGENCY}

    ${CLIENT_EXE} adm policy remove-scc-from-group privileged system:serviceaccounts:${NAMESPACE_PORTAL}
    ${CLIENT_EXE} adm policy remove-scc-from-group anyuid system:serviceaccounts:${NAMESPACE_PORTAL}
    ${CLIENT_EXE} delete network-attachment-definition istio-cni -n ${NAMESPACE_PORTAL}

    ${CLIENT_EXE} adm policy remove-scc-from-group privileged system:serviceaccounts:${NAMESPACE_CONTROL}
    ${CLIENT_EXE} adm policy remove-scc-from-group anyuid system:serviceaccounts:${NAMESPACE_CONTROL}
    ${CLIENT_EXE} delete network-attachment-definition istio-cni -n ${NAMESPACE_CONTROL}
  fi
  ${CLIENT_EXE} delete namespace ${NAMESPACE_AGENCY}
  ${CLIENT_EXE} delete namespace ${NAMESPACE_PORTAL}
  ${CLIENT_EXE} delete namespace ${NAMESPACE_CONTROL}
  exit 0
fi

# Create and prepare the demo namespaces

if ! ${CLIENT_EXE} get namespace ${NAMESPACE_AGENCY} 2>/dev/null; then
  ${CLIENT_EXE} create namespace ${NAMESPACE_AGENCY}
  ${CLIENT_EXE} label namespace ${NAMESPACE_AGENCY} istio-injection=enabled
  if [ "${CLIENT_EXE}" == "oc" ]; then
    ${CLIENT_EXE} adm policy add-scc-to-group privileged system:serviceaccounts:${NAMESPACE_AGENCY}
    ${CLIENT_EXE} adm policy add-scc-to-group anyuid system:serviceaccounts:${NAMESPACE_AGENCY}
    cat <<EOF | ${CLIENT_EXE} -n ${NAMESPACE_AGENCY} create -f -
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: istio-cni
EOF
  fi
fi

if ! ${CLIENT_EXE} get namespace ${NAMESPACE_PORTAL} 2>/dev/null; then
  ${CLIENT_EXE} create namespace ${NAMESPACE_PORTAL}
  ${CLIENT_EXE} label namespace ${NAMESPACE_PORTAL} istio-injection=enabled
  if [ "${CLIENT_EXE}" == "oc" ]; then
    ${CLIENT_EXE} adm policy add-scc-to-group privileged system:serviceaccounts:${NAMESPACE_PORTAL}
    ${CLIENT_EXE} adm policy add-scc-to-group anyuid system:serviceaccounts:${NAMESPACE_PORTAL}
    cat <<EOF | ${CLIENT_EXE} -n ${NAMESPACE_PORTAL} create -f -
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: istio-cni
EOF
  fi
fi

if ! ${CLIENT_EXE} get namespace ${NAMESPACE_CONTROL} 2>/dev/null; then
  ${CLIENT_EXE} create namespace ${NAMESPACE_CONTROL}
  ${CLIENT_EXE} label namespace ${NAMESPACE_CONTROL} istio-injection=enabled
  if [ "${CLIENT_EXE}" == "oc" ]; then
    ${CLIENT_EXE} adm policy add-scc-to-group privileged system:serviceaccounts:${NAMESPACE_CONTROL}
    ${CLIENT_EXE} adm policy add-scc-to-group anyuid system:serviceaccounts:${NAMESPACE_CONTROL}
    cat <<EOF | ${CLIENT_EXE} -n ${NAMESPACE_CONTROL} create -f -
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: istio-cni
EOF
  fi
fi

# Deploy the demo

${CLIENT_EXE} apply -f <(curl -L https://raw.githubusercontent.com/kiali/demos/master/travels/travel_agency.yaml) -n ${NAMESPACE_AGENCY}
${CLIENT_EXE} apply -f <(curl -L https://raw.githubusercontent.com/kiali/demos/master/travels/travel_portal.yaml) -n ${NAMESPACE_PORTAL}
${CLIENT_EXE} apply -f <(curl -L https://raw.githubusercontent.com/kiali/demos/master/travels/travel_control.yaml) -n ${NAMESPACE_CONTROL}

# Set up metric classification

if [ "${ENABLE_OPERATION_METRICS}" != "true" ]; then
  # No need to keep going - we are done and the user doesn't want to do anything else.
  exit 0
fi

# This only works if you have Istio 1.7 installed, and it is in istio-system namespace.
${CLIENT_EXE} -n istio-system get envoyfilter stats-filter-1.7 -o yaml > stats-filter-1.7.yaml
cat <<EOF | patch -o - | ${CLIENT_EXE} -n istio-system apply -f - && rm stats-filter-1.7.yaml
--- stats-filter-1.7.yaml	2020-06-02 11:10:29.476537126 -0400
+++ stats-filter-1.7.yaml.new	2020-06-02 09:59:26.434300000 -0400
@@ -79,7 +79,20 @@ spec:
                 value: |
                   {
                     "debug": "false",
-                    "stat_prefix": "istio"
+                    "stat_prefix": "istio",
+                    "metrics": [
+                     {
+                       "name": "requests_total",
+                       "dimensions": {
+                         "request_operation": "istio_operationId"
+                       }
+                     },
+                     {
+                       "name": "request_duration_milliseconds",
+                       "dimensions": {
+                         "request_operation": "istio_operationId"
+                       }
+                     }]
                   }
               root_id: stats_inbound
               vm_config:
EOF

cat <<EOF | ${CLIENT_EXE} -n istio-system apply -f -
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: attribgen-travelagency
spec:
  configPatches:
  - applyTo: HTTP_FILTER
    match:
      context: SIDECAR_INBOUND
      listener:
        filterChain:
          filter:
            name: envoy.http_connection_manager
            subFilter:
              name: istio.stats
      proxy:
        proxyVersion: 1\.7.*
    patch:
      operation: INSERT_BEFORE
      value:
        name: istio.attributegen
        typed_config:
          '@type': type.googleapis.com/udpa.type.v1.TypedStruct
          type_url: type.googleapis.com/envoy.extensions.filters.http.wasm.v3.Wasm
          value:
            config:
              configuration:
                '@type': type.googleapis.com/google.protobuf.StringValue
                value: |
                  {
                    "attributes": [
                      {
                        "output_attribute": "istio_operationId",
                        "match": [
                          {
                            "value": "TravelQuote",
                            "condition": "request.url_path.matches('^/travels/[[:alpha:]]+$') && request.method == 'GET'"
                          },
                          {
                            "value": "ListCities",
                            "condition": "request.url_path.matches('^/travels$') && request.method == 'GET'"
                          }
                        ]
                      }
                    ]
                  }
              vm_config:
                code:
                  local:
                    inline_string: envoy.wasm.attributegen
                runtime: envoy.wasm.runtime.null
  workloadSelector:
    labels:
      app: travels
---
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: attribgen-travelagency-hotels
spec:
  workloadSelector:
    labels:
      app: hotels
  configPatches:
  - applyTo: HTTP_FILTER
    match:
      context: SIDECAR_INBOUND
      proxy:
        proxyVersion: '1\.7.*'
      listener:
        filterChain:
          filter:
            name: "envoy.http_connection_manager"
            subFilter:
              name: "istio.stats"
    patch:
      operation: INSERT_BEFORE
      value:
        name: istio.attributegen
        typed_config:
          "@type": type.googleapis.com/udpa.type.v1.TypedStruct
          type_url: type.googleapis.com/envoy.extensions.filters.http.wasm.v3.Wasm
          value:
            config:
              configuration:
                '@type': type.googleapis.com/google.protobuf.StringValue
                value: |
                  {
                    "attributes": [
                      {
                        "output_attribute": "istio_operationId",
                        "match": [
                          {
                            "value": "New",
                            "condition": "request.headers['user'] == 'new'"
                          },
                          {
                            "value": "Registered",
                            "condition": "request.headers['user'] != 'new'"
                          }
                        ]
                      }
                    ]
                  }
              vm_config:
                runtime: envoy.wasm.runtime.null
                code:
                  local: { inline_string: "envoy.wasm.attributegen" }
---
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: attribgen-travelagency-cars
spec:
  workloadSelector:
    labels:
      app: cars
  configPatches:
  - applyTo: HTTP_FILTER
    match:
      context: SIDECAR_INBOUND
      proxy:
        proxyVersion: '1\.7.*'
      listener:
        filterChain:
          filter:
            name: "envoy.http_connection_manager"
            subFilter:
              name: "istio.stats"
    patch:
      operation: INSERT_BEFORE
      value:
        name: istio.attributegen
        typed_config:
          "@type": type.googleapis.com/udpa.type.v1.TypedStruct
          type_url: type.googleapis.com/envoy.extensions.filters.http.wasm.v3.Wasm
          value:
            config:
              configuration:
                '@type': type.googleapis.com/google.protobuf.StringValue
                value: |
                  {
                    "attributes": [
                      {
                        "output_attribute": "istio_operationId",
                        "match": [
                          {
                            "value": "New",
                            "condition": "request.headers['user'] == 'new'"
                          },
                          {
                            "value": "Registered",
                            "condition": "request.headers['user'] != 'new'"
                          }
                        ]
                      }
                    ]
                  }
              vm_config:
                runtime: envoy.wasm.runtime.null
                code:
                  local: { inline_string: "envoy.wasm.attributegen" }
EOF

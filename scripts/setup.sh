#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


INSTALLER_KUSTOMIZE_OVERLAY=${INSTALLER_KUSTOMIZE_OVERLAY:-"development"}
INSTALLER_NAMESPACE=${INSTALLER_NAMESPACE:-$(grep "^namespace:" "overlays/${INSTALLER_KUSTOMIZE_OVERLAY}/kustomization.yaml" | awk '{print $2}')}
[[ -z "${INSTALLER_NAMESPACE}" ]] && echo "ERROR: Could not determine namespace from overlays/${INSTALLER_KUSTOMIZE_OVERLAY}/kustomization.yaml" && exit 1
INSTALLER_VM_TEMPLATE=${INSTALLER_VM_TEMPLATE:-"osac.templates.ocp_virt_vm"}

# Retry a condition until it succeeds or times out, optionally running a command each iteration
# Usage: retry_until <timeout_seconds> <interval_seconds> <condition_command> [loop_command]
# Returns: 0 on success, 1 on timeout
retry_until() {
    local timeout="$1"
    local interval="$2"
    local condition="$3"
    local loop_cmd="${4:-}"

    local start=${SECONDS}
    until eval "${condition}"; do
        if (( SECONDS - start >= timeout )); then
            return 1
        fi
        [[ -n "${loop_cmd}" ]] && eval "${loop_cmd}" || true
        sleep "${interval}"
    done
}

# Wait for a namespace to exist and a resource within it to match a condition
# Usage: wait_for_resource <resource> <condition> [timeout_seconds] [namespace]
wait_for_resource() {
    local resource="$1"
    local condition="$2"
    local timeout="${3:-300}"
    local namespace="${4:-}"
    local ns_args=()

    if [[ -n "${namespace}" ]]; then
        ns_args=(-n "${namespace}")

        retry_until 300 5 '[[ -n "$(oc get namespace --ignore-not-found "${namespace}")" ]]' || {
            echo "Timed out waiting for namespace ${namespace} to exist"
            exit 1
        }
    fi

    retry_until 300 5 '[[ -n "$(oc get "${resource}" --ignore-not-found "${ns_args[@]}")" ]]' || {
        echo "Timed out waiting for ${resource} to exist"
        exit 1
    }

    oc wait --for="${condition}" "${resource}" "${ns_args[@]}" --timeout="${timeout}s"
}

# Apply default network attachment definition for VMs
cat <<EOF | oc apply -f -
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: default
  namespace: openshift-ovn-kubernetes
spec:
  config: '{"cniVersion": "0.4.0", "name": "ovn-kubernetes", "type": "ovn-k8s-cni-overlay"}'
EOF

# Apply cert-manager prerequisites and wait for it to be ready
retry_until 300 3 '[[ -n "$(oc get crd --ignore-not-found certmanagers.operator.openshift.io)" ]]' 'oc apply -k prerequisites/cert-manager || true' || {
    echo "Timed out waiting for cert-manager CRD to exist"
    exit 1
}
wait_for_resource deployment/cert-manager condition=Available 300 cert-manager
wait_for_resource deployment/cert-manager-webhook condition=Available 300 cert-manager
wait_for_resource deployment/cert-manager-cainjector condition=Available 300 cert-manager

# Apply trust-manager prerequisites and wait for it to be ready
oc apply -f prerequisites/trust-manager.yaml
wait_for_resource deployment/trust-manager condition=Available 300 cert-manager

# Apply CA issuer prerequisites and wait for it to be ready
oc apply -f prerequisites/ca-issuer.yaml
wait_for_resource clusterissuer/default-ca condition=Ready 300

# Apply authorino prerequisites and wait for it to be ready
oc apply -f prerequisites/authorino-operator.yaml
retry_until 300 3 '[[ -n "$(oc get csv --no-headers -n openshift-operators | grep authorino)" ]]' 'oc apply -f prerequisites/authorino-operator.yaml || true' || {
    echo "Timed out waiting for authorino CSV to exist"
    exit 1
}
AUTHORINO_CSV=$(oc get csv --no-headers -n openshift-operators | awk '/authorino/ { print $1 }')
wait_for_resource clusterserviceversion/${AUTHORINO_CSV} jsonpath='{.status.phase}'=Succeeded 300 openshift-operators
wait_for_resource deployment/authorino-operator condition=Available 300 openshift-operators

# Apply keycloak prerequisites and wait for it to be ready
oc apply -k prerequisites/keycloak/
wait_for_resource deployment/keycloak-service condition=Available 600 keycloak

# Apply AAP prerequisites and wait for it to be ready
oc apply -f prerequisites/aap-installation.yaml
retry_until 300 3 '[[ -n "$(oc get csv --no-headers -n ansible-aap | grep aap)" ]]' 'oc apply -f prerequisites/aap-installation.yaml || true' || {
    echo "Timed out waiting for AAP CSV to exist"
    exit 1
}
AAP_CSV=$(oc get csv --no-headers -n ansible-aap | awk '/aap/ { print $1 }')
wait_for_resource clusterserviceversion/${AAP_CSV} jsonpath='{.status.phase}'=Succeeded 300 ansible-aap
wait_for_resource deployment/automation-controller-operator-controller-manager condition=Available 300 ansible-aap

# Apply kustomize overlay
oc apply -k overlays/${INSTALLER_KUSTOMIZE_OVERLAY}

# Wait for AAP bootstrap job to complete
wait_for_resource job/aap-bootstrap condition=complete 1200 ${INSTALLER_NAMESPACE}

# Update project context
oc project ${INSTALLER_NAMESPACE}

# Create hub access kubeconfig
./scripts/create-hub-access-kubeconfig.sh

# Login to fulfillment API and create hub
FULFILLMENT_API_URL=https://$(oc get route -n ${INSTALLER_NAMESPACE} fulfillment-api -o jsonpath='{.status.ingress[0].host}')
fulfillment-cli login --insecure --private --token-script "oc create token -n ${INSTALLER_NAMESPACE} admin" --address ${FULFILLMENT_API_URL}
fulfillment-cli create hub --kubeconfig=kubeconfig.hub-access --id hub --namespace ${INSTALLER_NAMESPACE}

# Wait for computeinstancetemplate to exist
retry_until 1200 5 '[[ -n "$(fulfillment-cli get computeinstancetemplate -o json | jq -r --arg tpl ${INSTALLER_VM_TEMPLATE} '"'"'select(.id == $tpl)'"'"' 2> /dev/null)" ]]' || {
    echo "Timed out waiting for computeinstancetemplate to exist"
    exit 1
}

# Create AAP token and configure the operator for direct AAP integration
AAP_PASSWORD=$(oc get secret osac-aap-admin-password -n ${INSTALLER_NAMESPACE} -o jsonpath='{.data.password}' | base64 -d)
[[ -z "${AAP_PASSWORD}" ]] && echo "ERROR: Failed to get AAP password from secret osac-aap-admin-password" && exit 1

AAP_TOKEN=$(oc exec deployment/fulfillment-grpc-server -n ${INSTALLER_NAMESPACE} -- \
    sh -c "curl -sf -X POST http://osac-aap:80/api/controller/v2/tokens/ \
    -u admin:${AAP_PASSWORD} -H 'Content-Type: application/json' -d '{}'" | jq -r '.token')
[[ -z "${AAP_TOKEN}" || "${AAP_TOKEN}" == "null" ]] && echo "ERROR: Failed to create AAP token" && exit 1

oc set env deployment/osac-operator-controller-manager -n ${INSTALLER_NAMESPACE} \
    OSAC_AAP_URL="http://osac-aap:80/api/controller" \
    OSAC_AAP_TOKEN="${AAP_TOKEN}" \
    OSAC_AAP_PROVISION_TEMPLATE="osac-create-compute-instance" \
    OSAC_AAP_DEPROVISION_TEMPLATE="osac-delete-compute-instance"

# Create Tenant CR
cat <<EOF | oc apply -f -
apiVersion: osac.openshift.io/v1alpha1
kind: Tenant
metadata:
  name: ${INSTALLER_NAMESPACE}
  namespace: ${INSTALLER_NAMESPACE}
spec: {}
EOF

# Label default StorageClass for the tenant
DEFAULT_SC=$(oc get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')
[[ -z "${DEFAULT_SC}" ]] && echo "ERROR: No default StorageClass found — Tenant requires a labeled SC to reach Ready" && exit 1
oc label sc "${DEFAULT_SC}" "osac.openshift.io/tenant=${INSTALLER_NAMESPACE}" --overwrite

# Wait for Tenant to be Ready
retry_until 120 5 '[[ "$(oc get tenant ${INSTALLER_NAMESPACE} -n ${INSTALLER_NAMESPACE} -o jsonpath='"'"'{.status.phase}'"'"' 2>/dev/null)" == "Ready" ]]' || {
    echo "Timed out waiting for Tenant to be Ready"
    exit 1
}

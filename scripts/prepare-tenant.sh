#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

INSTALLER_KUSTOMIZE_OVERLAY=${INSTALLER_KUSTOMIZE_OVERLAY:-"development"}
INSTALLER_NAMESPACE=${INSTALLER_NAMESPACE:-$(grep "^namespace:" "overlays/${INSTALLER_KUSTOMIZE_OVERLAY}/kustomization.yaml" | awk '{print $2}')}
[[ -z "${INSTALLER_NAMESPACE}" ]] && echo "ERROR: Could not determine namespace from overlays/${INSTALLER_KUSTOMIZE_OVERLAY}/kustomization.yaml" && exit 1
INSTALLER_VM_TEMPLATE=${INSTALLER_VM_TEMPLATE:-"osac.templates.ocp_virt_vm"}

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

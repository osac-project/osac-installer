#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

INSTALLER_KUSTOMIZE_OVERLAY=${INSTALLER_KUSTOMIZE_OVERLAY:-"development"}
if [[ -z "${INSTALLER_NAMESPACE:-}" ]]; then
    INSTALLER_NAMESPACE=$(grep "^namespace:" "overlays/${INSTALLER_KUSTOMIZE_OVERLAY}/kustomization.yaml" | awk '{print $2}')
    [[ -z "${INSTALLER_NAMESPACE}" ]] && echo "ERROR: INSTALLER_NAMESPACE not set and could not determine from overlay" && exit 1
fi
INSTALLER_VM_TEMPLATE=${INSTALLER_VM_TEMPLATE:-}

# Label default StorageClass as the shared default so all tenants can use it
DEFAULT_SC=$(oc get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')
[[ -z "${DEFAULT_SC}" ]] && echo "ERROR: No default StorageClass found — Tenant requires a labeled SC to reach Ready" && exit 1
oc label sc "${DEFAULT_SC}" "osac.openshift.io/tenant=Default" "osac.openshift.io/storage-tier=default" --overwrite

# Create the namespace-specific tenant
cat <<EOF | oc apply -f -
apiVersion: osac.openshift.io/v1alpha1
kind: Tenant
metadata:
  name: ${INSTALLER_NAMESPACE}
  namespace: ${INSTALLER_NAMESPACE}
spec: {}
EOF

# Create the shared tenant (default for admin operations).
# The fulfillment-service assigns tenant "shared" to objects created by admin
# users with universal tenant access.
oc create namespace shared --dry-run=client -o yaml | oc apply -f -
cat <<EOF | oc apply -f -
apiVersion: osac.openshift.io/v1alpha1
kind: Tenant
metadata:
  name: shared
  namespace: ${INSTALLER_NAMESPACE}
spec: {}
EOF

# Wait for both tenants to be Ready
retry_until 120 5 '[[ "$(oc get tenant ${INSTALLER_NAMESPACE} -n ${INSTALLER_NAMESPACE} -o jsonpath='"'"'{.status.phase}'"'"' 2>/dev/null)" == "Ready" ]]' || {
    echo "Timed out waiting for Tenant ${INSTALLER_NAMESPACE} to be Ready"
    exit 1
}
retry_until 120 5 '[[ "$(oc get tenant shared -n ${INSTALLER_NAMESPACE} -o jsonpath='"'"'{.status.phase}'"'"' 2>/dev/null)" == "Ready" ]]' || {
    echo "Timed out waiting for Tenant shared to be Ready"
    exit 1
}

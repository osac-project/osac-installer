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

echo "Creating AAP API token for OSAC operator (namespace: ${INSTALLER_NAMESPACE})..."

SECRET_B64=""
rc=0
SECRET_B64=$(oc get secret osac-aap-admin-password -n "${INSTALLER_NAMESPACE}" -o jsonpath='{.data.password}' 2>&1) || rc=$?
if (( rc != 0 )); then
    echo "ERROR: failed to get secret osac-aap-admin-password in ${INSTALLER_NAMESPACE}:" >&2
    echo "${SECRET_B64}" >&2
    exit 1
fi
AAP_ADMIN_PASSWORD=$(printf '%s' "${SECRET_B64}" | base64 -d)
[[ -n "${AAP_ADMIN_PASSWORD}" ]] || {
    echo "ERROR: Secret osac-aap-admin-password is missing or empty in ${INSTALLER_NAMESPACE}" >&2
    exit 1
}

AAP_TOKEN=$(http_json "Failed to create AAP API token (gateway may be rolling out)" 30 10 \
    '.token // empty' \
    -X POST -u "admin:${AAP_ADMIN_PASSWORD}" \
    -H "Content-Type: application/json" \
    -d '{"description": "osac-operator", "scope": "write"}' \
    "${AAP_URL}/api/gateway/v1/tokens/")

if [[ -z "${AAP_TOKEN}" || "${AAP_TOKEN}" == "null" ]]; then
    echo "ERROR: Failed to create AAP API token (empty or null token in response)" >&2
    exit 1
fi

oc create secret generic osac-aap-api-token \
    --from-literal=token="${AAP_TOKEN}" \
    -n "${INSTALLER_NAMESPACE}" \
    --dry-run=client -o yaml | oc apply -f -

# Set the AAP URL on operator deployments (triggers rollout).
for pattern in osac-operator bmf-operator; do
    deploy=$(oc get deploy -n "${INSTALLER_NAMESPACE}" -o name | grep -m1 "${pattern}" || true)
    if [[ -z "${deploy}" ]]; then
        echo "  ${pattern}: not found, skipping"
        continue
    fi
    oc set env "${deploy}" -n "${INSTALLER_NAMESPACE}" OSAC_AAP_URL="${AAP_URL}/api/controller"
done

echo "AAP API token created and stored in secret osac-aap-api-token"

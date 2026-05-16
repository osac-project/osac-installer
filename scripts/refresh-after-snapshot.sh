#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

INSTALLER_KUSTOMIZE_OVERLAY=${INSTALLER_KUSTOMIZE_OVERLAY:-"development"}
INSTALLER_NAMESPACE=${INSTALLER_NAMESPACE:-$(grep "^namespace:" "overlays/${INSTALLER_KUSTOMIZE_OVERLAY}/kustomization.yaml" | awk '{print $2}')}
[[ -z "${INSTALLER_NAMESPACE}" ]] && echo "ERROR: Could not determine namespace from overlays/${INSTALLER_KUSTOMIZE_OVERLAY}/kustomization.yaml" && exit 1
INSTALLER_VM_TEMPLATE=${INSTALLER_VM_TEMPLATE:-}

CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
echo "=== Refreshing OSAC after snapshot boot ==="
echo "Namespace: ${INSTALLER_NAMESPACE}"
echo "Overlay: ${INSTALLER_KUSTOMIZE_OVERLAY}"
echo "Cluster domain: ${CLUSTER_DOMAIN}"
echo ""

echo "[1/10] Patching stale routes with new domain..."
OLD_DOMAIN=$(oc get route osac-aap -n "${INSTALLER_NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null | sed "s/^osac-aap-${INSTALLER_NAMESPACE}\.//")
echo "  Old domain: ${OLD_DOMAIN}"
echo "  New domain: ${CLUSTER_DOMAIN}"
for ns in "${INSTALLER_NAMESPACE}" keycloak; do
    for route in $(oc get routes -n "${ns}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        OLD_HOST=$(oc get route "${route}" -n "${ns}" -o jsonpath='{.spec.host}')
        NEW_HOST=$(echo "${OLD_HOST}" | sed "s/${OLD_DOMAIN}/${CLUSTER_DOMAIN}/")
        oc patch route "${route}" -n "${ns}" --type=merge -p "{\"spec\":{\"host\":\"${NEW_HOST}\"}}"
    done
done

echo "[2/10] Updating Keycloak realm..."
KEYCLOAK_NS="keycloak"
oc create configmap keycloak-realm \
    --from-file=realm.json=prerequisites/keycloak/service/files/realm.json \
    -n "${KEYCLOAK_NS}" --dry-run=client -o yaml | oc apply -f -
oc rollout restart deploy/keycloak-service -n "${KEYCLOAK_NS}"
oc rollout status deploy/keycloak-service -n "${KEYCLOAK_NS}" --timeout=300s
if [[ -f prerequisites/keycloak/service/password-setup-job.yaml ]]; then
    oc delete job keycloak-set-passwords -n "${KEYCLOAK_NS}" --ignore-not-found
    oc apply -f prerequisites/keycloak/service/password-setup-job.yaml -n "${KEYCLOAK_NS}"
    oc wait --for=condition=Complete job/keycloak-set-passwords -n "${KEYCLOAK_NS}" --timeout=120s
fi

echo "[3/10] Recreating fulfillment controller credentials..."
KC_URL="https://$(oc get route keycloak -n "${KEYCLOAK_NS}" -o jsonpath='{.spec.host}')"
KC_ADMIN_TOKEN=$(curl -sk "${KC_URL}/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli" -d "username=admin" -d "password=admin" -d "grant_type=password" | jq -r '.access_token')
[[ -n "${KC_ADMIN_TOKEN}" && "${KC_ADMIN_TOKEN}" != "null" ]] || { echo "ERROR: Could not get Keycloak admin token from ${KC_URL}" >&2; exit 1; }
FC_CLIENT_ID=$(curl -sk -H "Authorization: Bearer ${KC_ADMIN_TOKEN}" \
    "${KC_URL}/admin/realms/osac/clients?first=0&max=100" | \
    jq -er '[.[] | select(.serviceAccountsEnabled == true)][0].clientId')
[[ -n "${FC_CLIENT_ID}" && "${FC_CLIENT_ID}" != "null" ]] || { echo "ERROR: Could not find service account client in Keycloak" >&2; exit 1; }
FC_CLIENT_SECRET=$(curl -sk -H "Authorization: Bearer ${KC_ADMIN_TOKEN}" \
    "${KC_URL}/admin/realms/osac/clients?clientId=${FC_CLIENT_ID}" | \
    jq -er '.[0].secret')
[[ -n "${FC_CLIENT_SECRET}" && "${FC_CLIENT_SECRET}" != "null" ]] || { echo "ERROR: Could not get secret for client ${FC_CLIENT_ID}" >&2; exit 1; }
oc delete secret fulfillment-controller-credentials -n "${INSTALLER_NAMESPACE}" --ignore-not-found
oc create secret generic fulfillment-controller-credentials \
    --from-literal=client-id="${FC_CLIENT_ID}" \
    --from-literal=client-secret="${FC_CLIENT_SECRET}" \
    -n "${INSTALLER_NAMESPACE}"
echo "  Credentials created for client: ${FC_CLIENT_ID}"

echo "[4/10] Applying kustomize overlay..."
oc delete job -n "${INSTALLER_NAMESPACE}" --all --ignore-not-found
oc apply -k "overlays/${INSTALLER_KUSTOMIZE_OVERLAY}"

echo "[5/10] Applying AAP configuration..."
INSTALLER_NAMESPACE="${INSTALLER_NAMESPACE}" \
INSTALLER_KUSTOMIZE_OVERLAY="${INSTALLER_KUSTOMIZE_OVERLAY}" \
    ./scripts/aap-configuration.sh

oc config set-context --current --namespace="${INSTALLER_NAMESPACE}"

echo "[6/10] Waiting for AAP controller..."
retry_until 300 10 '[[ "$(oc get automationcontroller osac-aap-controller -n '"${INSTALLER_NAMESPACE}"' -o jsonpath='"'"'{.status.conditions[?(@.type=="Running")].status}'"'"' 2>/dev/null)" == "True" ]]' || {
    echo "Timed out waiting for AAP controller to be Running"
    exit 1
}
AAP_ROUTE_HOST=$(oc get route osac-aap -n "${INSTALLER_NAMESPACE}" -o jsonpath='{.spec.host}')
retry_until 120 5 '[[ "$(curl -sk -o /dev/null -w %{http_code} https://'"${AAP_ROUTE_HOST}"'/api/gateway/v1/)" == "200" ]]' || {
    echo "Timed out waiting for AAP gateway API to respond"
    exit 1
}

echo "[7/10] Configuring AAP access..."
./scripts/prepare-aap.sh

echo "[8/10] Configuring fulfillment service..."
./scripts/prepare-fulfillment-service.sh

echo "[9/10] Restarting fulfillment pods..."
oc rollout restart deploy/fulfillment-controller -n "${INSTALLER_NAMESPACE}"
oc rollout restart deploy/fulfillment-grpc-server -n "${INSTALLER_NAMESPACE}"
oc rollout restart deploy/fulfillment-rest-gateway -n "${INSTALLER_NAMESPACE}"
oc rollout restart deploy/fulfillment-ingress-proxy -n "${INSTALLER_NAMESPACE}"
oc rollout status deploy/fulfillment-controller -n "${INSTALLER_NAMESPACE}" --timeout=120s
oc rollout status deploy/fulfillment-grpc-server -n "${INSTALLER_NAMESPACE}" --timeout=120s
oc rollout status deploy/fulfillment-rest-gateway -n "${INSTALLER_NAMESPACE}" --timeout=120s
oc rollout status deploy/fulfillment-ingress-proxy -n "${INSTALLER_NAMESPACE}" --timeout=120s

echo "[10/10] Configuring tenant..."
./scripts/prepare-tenant.sh

echo ""
echo "=== Refresh complete ==="
echo "Cluster domain: ${CLUSTER_DOMAIN}"
echo "Namespace: ${INSTALLER_NAMESPACE}"

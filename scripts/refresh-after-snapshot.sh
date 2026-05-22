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
KEYCLOAK_NS="keycloak"
REALM_JSON="prerequisites/keycloak/service/files/realm.json"

echo "=== Refreshing OSAC after snapshot boot ==="
echo "Namespace: ${INSTALLER_NAMESPACE}"
echo "Overlay: ${INSTALLER_KUSTOMIZE_OVERLAY}"
echo "Cluster domain: ${CLUSTER_DOMAIN}"
echo ""

echo "Waiting for cluster services to stabilize..."

patch_stale_routes() {
    echo "  Patching stale routes with new domain..."
    for ns in "${INSTALLER_NAMESPACE}" "${KEYCLOAK_NS}"; do
        for route in $(oc get routes -n "${ns}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
            OLD_HOST=$(oc get route "${route}" -n "${ns}" -o jsonpath='{.spec.host}')
            ROUTE_DOMAIN=$(echo "${OLD_HOST}" | sed "s/^[^.]*\.//")
            if [[ "${ROUTE_DOMAIN}" != "${CLUSTER_DOMAIN}" ]]; then
                ROUTE_NAME=$(echo "${OLD_HOST}" | sed "s/\.${ROUTE_DOMAIN}$//")
                NEW_HOST="${ROUTE_NAME}.${CLUSTER_DOMAIN}"
                echo "  ${ns}/${route}: ${OLD_HOST} -> ${NEW_HOST}"
                retry_command 300 10 oc patch route "${route}" -n "${ns}" --type=merge -p "{\"spec\":{\"host\":\"${NEW_HOST}\"}}"
            fi
        done
    done
}

oc rollout status deploy/trust-manager -n cert-manager --timeout=300s &
pid_tm=$!
oc wait --for=condition=Ready certificate/keycloak-tls -n "${KEYCLOAK_NS}" --timeout=300s &
pid_kc=$!
patch_stale_routes &
pid_rt=$!

failed=0
wait ${pid_tm} || failed=1
wait ${pid_kc} || failed=1
wait ${pid_rt} || failed=1
if (( failed )); then
    echo "ERROR: Cluster services did not stabilize within timeout"
    exit 1
fi
echo "Cluster services ready"
echo ""

echo "[1/8] Syncing Keycloak realm..."
NEW_HASH=$(md5sum "${REALM_JSON}" | awk '{print $1}')
OLD_HASH=$(oc get configmap keycloak-realm -n "${KEYCLOAK_NS}" -o jsonpath='{.data.realm\.json}' 2>/dev/null | md5sum | awk '{print $1}')
if [[ "${NEW_HASH}" != "${OLD_HASH}" ]]; then
    echo "  ConfigMap changed (${OLD_HASH:0:8} -> ${NEW_HASH:0:8}), restarting Keycloak..."
    oc create configmap keycloak-realm \
        --from-file=realm.json="${REALM_JSON}" \
        -n "${KEYCLOAK_NS}" --dry-run=client -o yaml | oc apply -f -
    oc rollout restart deploy/keycloak-service -n "${KEYCLOAK_NS}"
    oc rollout status deploy/keycloak-service -n "${KEYCLOAK_NS}" --timeout=300s
else
    echo "  ConfigMap unchanged, skipping Keycloak restart"
fi

KC_URL="https://$(oc get route keycloak -n "${KEYCLOAK_NS}" -o jsonpath='{.spec.host}')"
retry_until 60 5 '[[ "$(curl -sk -o /dev/null -w %{http_code} '"${KC_URL}"'/realms/osac)" == "200" ]]' || {
    echo "Timed out waiting for Keycloak"
    exit 1
}
KC_ADMIN_TOKEN=$(curl -sk "${KC_URL}/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli" -d "username=admin" -d "password=admin" -d "grant_type=password" | jq -r '.access_token')
[[ -n "${KC_ADMIN_TOKEN}" && "${KC_ADMIN_TOKEN}" != "null" ]] || { echo "ERROR: Could not get Keycloak admin token" >&2; exit 1; }

echo "  Syncing clients and users via admin API..."
jq -c '.clients[] | select(.protocol == "openid-connect" and .publicClient != true and .bearerOnly != true)' "${REALM_JSON}" | while IFS= read -r CLIENT_JSON; do
    CID=$(echo "${CLIENT_JSON}" | jq -r '.clientId')
    CLIENT_UUID=$(echo "${CLIENT_JSON}" | jq -r '.id')
    HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${KC_ADMIN_TOKEN}" "${KC_URL}/admin/realms/osac/clients/${CLIENT_UUID}")
    if [[ "${HTTP_CODE}" == "200" ]]; then
        curl -sk -X PUT -H "Authorization: Bearer ${KC_ADMIN_TOKEN}" -H "Content-Type: application/json" \
            "${KC_URL}/admin/realms/osac/clients/${CLIENT_UUID}" -d "${CLIENT_JSON}" >/dev/null
        echo "  Updated client: ${CID}"
    else
        curl -sk -X POST -H "Authorization: Bearer ${KC_ADMIN_TOKEN}" -H "Content-Type: application/json" \
            "${KC_URL}/admin/realms/osac/clients" -d "${CLIENT_JSON}" >/dev/null
        echo "  Created client: ${CID}"
    fi
done

jq -c '.users[]?' "${REALM_JSON}" | while IFS= read -r USER_JSON; do
    USERNAME=$(echo "${USER_JSON}" | jq -r '.username')
    USER_UUID=$(echo "${USER_JSON}" | jq -r '.id')
    HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${KC_ADMIN_TOKEN}" "${KC_URL}/admin/realms/osac/users/${USER_UUID}")
    if [[ "${HTTP_CODE}" == "200" ]]; then
        curl -sk -X PUT -H "Authorization: Bearer ${KC_ADMIN_TOKEN}" -H "Content-Type: application/json" \
            "${KC_URL}/admin/realms/osac/users/${USER_UUID}" -d "${USER_JSON}" >/dev/null
        echo "  Updated user: ${USERNAME}"
    else
        curl -sk -X POST -H "Authorization: Bearer ${KC_ADMIN_TOKEN}" -H "Content-Type: application/json" \
            "${KC_URL}/admin/realms/osac/users" -d "${USER_JSON}" >/dev/null
        echo "  Created user: ${USERNAME}"
    fi
done

if [[ -f prerequisites/keycloak/service/password-setup-job.yaml ]]; then
    oc delete job keycloak-set-passwords -n "${KEYCLOAK_NS}" --ignore-not-found
    oc apply -f prerequisites/keycloak/service/password-setup-job.yaml -n "${KEYCLOAK_NS}"
    oc wait --for=condition=Complete job/keycloak-set-passwords -n "${KEYCLOAK_NS}" --timeout=120s
fi

echo "[2/8] Recreating fulfillment controller credentials..."
FC_CLIENT_ID=$(jq -er '.clients[] | select(.serviceAccountsEnabled == true) | .clientId' "${REALM_JSON}")
FC_CLIENT_SECRET=$(jq -er ".clients[] | select(.clientId == \"${FC_CLIENT_ID}\") | .secret // empty" "${REALM_JSON}")
[[ -n "${FC_CLIENT_SECRET}" ]] || { echo "ERROR: Could not resolve secret for ${FC_CLIENT_ID} in realm.json" >&2; exit 1; }
oc delete secret fulfillment-controller-credentials -n "${INSTALLER_NAMESPACE}" --ignore-not-found
oc create secret generic fulfillment-controller-credentials \
    --from-literal=client-id="${FC_CLIENT_ID}" \
    --from-literal=client-secret="${FC_CLIENT_SECRET}" \
    -n "${INSTALLER_NAMESPACE}"
echo "  Credentials created for client: ${FC_CLIENT_ID}"

echo "[3/8] Applying kustomize overlay..."
oc delete job -n "${INSTALLER_NAMESPACE}" --all --ignore-not-found
oc apply -k "overlays/${INSTALLER_KUSTOMIZE_OVERLAY}"
echo "  Deleting aap-bootstrap job (AAP config survives from snapshot, bootstrap not needed)"
oc delete job aap-bootstrap -n "${INSTALLER_NAMESPACE}" --ignore-not-found
echo "  AAP jobs in namespace:"
oc get jobs -n "${INSTALLER_NAMESPACE}" --no-headers 2>/dev/null || echo "  (none)"

echo "[4/8] Waiting for fulfillment rollouts..."
pids=()
for deploy in fulfillment-controller fulfillment-grpc-server fulfillment-rest-gateway fulfillment-ingress-proxy; do
    oc rollout status "deploy/${deploy}" -n "${INSTALLER_NAMESPACE}" --timeout=300s &
    pids+=($!)
done
failed=0
for pid in "${pids[@]}"; do wait "${pid}" || failed=1; done
if (( failed )); then echo "ERROR: Fulfillment rollout failed"; exit 1; fi

echo "[5/8] Applying AAP configuration..."
INSTALLER_NAMESPACE="${INSTALLER_NAMESPACE}" \
INSTALLER_KUSTOMIZE_OVERLAY="${INSTALLER_KUSTOMIZE_OVERLAY}" \
    ./scripts/aap-configuration.sh

oc config set-context --current --namespace="${INSTALLER_NAMESPACE}"

echo "[6/8] Waiting for AAP controller..."
retry_until 300 10 '[[ "$(oc get automationcontroller osac-aap-controller -n '"${INSTALLER_NAMESPACE}"' -o jsonpath='"'"'{.status.conditions[?(@.type=="Running")].status}'"'"' 2>/dev/null)" == "True" ]]' || {
    echo "Timed out waiting for AAP controller to be Running"
    exit 1
}
AAP_ROUTE_HOST=$(oc get route osac-aap -n "${INSTALLER_NAMESPACE}" -o jsonpath='{.spec.host}')
retry_until 120 5 '[[ "$(curl -sk -o /dev/null -w %{http_code} https://'"${AAP_ROUTE_HOST}"'/api/gateway/v1/)" == "200" ]]' || {
    echo "Timed out waiting for AAP gateway API to respond"
    exit 1
}

echo "  AAP snapshot state diagnostics:"
echo "  - AutomationController status: $(oc get automationcontroller osac-aap-controller -n "${INSTALLER_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Running")].status}' 2>/dev/null || echo 'NOT FOUND')"
echo "  - AAP project revisions: $(curl -sk "https://${AAP_ROUTE_HOST}/api/controller/v2/projects/" -H "Authorization: Bearer $(oc create token -n "${INSTALLER_NAMESPACE}" admin 2>/dev/null)" 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'{d.get(\"count\",0)} projects, current_job statuses: {[p.get(\"status\",\"?\") for p in d.get(\"results\",[])]}' )" 2>/dev/null || echo 'could not query')"
echo "  - Job templates: $(curl -sk "https://${AAP_ROUTE_HOST}/api/controller/v2/job_templates/" -H "Authorization: Bearer $(oc create token -n "${INSTALLER_NAMESPACE}" admin 2>/dev/null)" 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'{d.get(\"count\",0)} templates: {[t[\"name\"] for t in d.get(\"results\",[])]}' )" 2>/dev/null || echo 'could not query')"
echo "  - Existing computeinstancetemplates: $(oc get computeinstancetemplate -n "${INSTALLER_NAMESPACE}" --no-headers 2>/dev/null | wc -l || echo 0)"

echo "[7/8] Configuring AAP access and fulfillment service..."
./scripts/prepare-aap.sh
./scripts/prepare-fulfillment-service.sh

echo "[8/8] Restarting fulfillment pods and configuring tenant..."
for deploy in fulfillment-controller fulfillment-grpc-server fulfillment-rest-gateway fulfillment-ingress-proxy; do
    oc rollout restart "deploy/${deploy}" -n "${INSTALLER_NAMESPACE}"
done
pids=()
for deploy in fulfillment-controller fulfillment-grpc-server fulfillment-rest-gateway fulfillment-ingress-proxy; do
    oc rollout status "deploy/${deploy}" -n "${INSTALLER_NAMESPACE}" --timeout=300s &
    pids+=($!)
done
failed=0
for pid in "${pids[@]}"; do wait "${pid}" || failed=1; done
if (( failed )); then echo "ERROR: Fulfillment rollout failed after restart"; exit 1; fi
./scripts/prepare-tenant.sh

echo ""
echo "=== Refresh complete ==="
echo "Cluster domain: ${CLUSTER_DOMAIN}"
echo "Namespace: ${INSTALLER_NAMESPACE}"

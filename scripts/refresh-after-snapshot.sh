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

# ---------------------------------------------------------------------------
# Diagnostic dump — prints everything needed to debug storage / AAP issues
# ---------------------------------------------------------------------------
diag_dump() {
    local label="${1:-DIAGNOSTIC DUMP}"
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║  ${label}"
    echo "║  $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "╚══════════════════════════════════════════════════════════════════╝"

    local NODE
    NODE=$(oc get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    echo ""
    echo "--- NODE CONDITIONS ---"
    oc get nodes -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,DISK_PRESSURE:.status.conditions[?(@.type=="DiskPressure")].status,MEMORY_PRESSURE:.status.conditions[?(@.type=="MemoryPressure")].status,PID_PRESSURE:.status.conditions[?(@.type=="PIDPressure")].status' 2>/dev/null || echo "  (failed to get node conditions)"

    echo ""
    echo "--- NODE RESOURCE USAGE ---"
    oc adm top nodes 2>/dev/null || echo "  (metrics not available)"

    echo ""
    echo "--- LVM THIN POOL (via oc debug) ---"
    if [[ -n "${NODE}" ]]; then
        oc debug "node/${NODE}" --quiet -- chroot /host bash -c '
            echo "=== lvs -a ==="
            lvs -a -o+data_percent,metadata_percent,lv_size 2>/dev/null || echo "(lvs failed)"
            echo ""
            echo "=== vgs ==="
            vgs -o+vg_free,vg_size 2>/dev/null || echo "(vgs failed)"
            echo ""
            echo "=== pvs ==="
            pvs 2>/dev/null || echo "(pvs failed)"
            echo ""
            echo "=== df -h (key dirs) ==="
            df -h / /var /var/lib/containers /var/lib/etcd /var/lib/kubelet 2>/dev/null || df -h / 2>/dev/null || echo "(df failed)"
            echo ""
            echo "=== du -sh big dirs ==="
            du -sh /var/lib/containers /var/lib/etcd /var/lib/kubelet /var/log /var/lib/ovn 2>/dev/null || echo "(du failed)"
            echo ""
            echo "=== container images disk usage ==="
            crictl images -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
total = 0
for img in data.get(\"images\", []):
    total += img.get(\"size\", 0)
print(f\"Total images: {len(data.get(\"images\", []))}, Total size: {total / 1024**3:.1f} GiB\")
" 2>/dev/null || echo "(crictl images failed)"
        ' 2>/dev/null || echo "  (oc debug failed — node ${NODE} may not be reachable)"
    else
        echo "  (no node found)"
    fi

    echo ""
    echo "--- STORAGE CLASSES ---"
    oc get sc 2>/dev/null || echo "  (failed)"

    echo ""
    echo "--- PVCs (all namespaces) ---"
    oc get pvc -A -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase,CAPACITY:.status.capacity.storage,STORAGECLASS:.spec.storageClassName' 2>/dev/null || echo "  (failed)"

    echo ""
    echo "--- PVs ---"
    oc get pv -o custom-columns='NAME:.metadata.name,CAPACITY:.spec.capacity.storage,STATUS:.status.phase,CLAIM:.spec.claimRef.name,STORAGECLASS:.spec.storageClassName' 2>/dev/null || echo "  (failed)"

    echo ""
    echo "--- PODS: ${INSTALLER_NAMESPACE} ---"
    oc get pods -n "${INSTALLER_NAMESPACE}" -o wide 2>/dev/null || echo "  (failed)"

    echo ""
    echo "--- PODS: ${KEYCLOAK_NS} ---"
    oc get pods -n "${KEYCLOAK_NS}" -o wide 2>/dev/null || echo "  (failed)"

    echo ""
    echo "--- PODS: openshift-cnv ---"
    oc get pods -n openshift-cnv --no-headers 2>/dev/null | grep -v Running | grep -v Completed || echo "  (all healthy or namespace missing)"

    echo ""
    echo "--- AAP COMPONENT HEALTH ---"
    for res in ansibleautomationplatform automationcontroller; do
        echo "  ${res}:"
        oc get "${res}" -n "${INSTALLER_NAMESPACE}" -o yaml 2>/dev/null | grep -A5 'conditions:' || echo "    (not found)"
    done

    echo ""
    echo "--- AAP POD RESTARTS ---"
    oc get pods -n "${INSTALLER_NAMESPACE}" -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,STATE:.status.containerStatuses[0].state' --sort-by='.status.containerStatuses[0].restartCount' 2>/dev/null | tail -20 || echo "  (failed)"

    echo ""
    echo "--- EVENTS: ${INSTALLER_NAMESPACE} (last 5 min, warnings only) ---"
    oc get events -n "${INSTALLER_NAMESPACE}" --sort-by='.lastTimestamp' --field-selector type=Warning 2>/dev/null | tail -30 || echo "  (no warning events)"

    echo ""
    echo "--- EVENTS: ${KEYCLOAK_NS} (warnings) ---"
    oc get events -n "${KEYCLOAK_NS}" --sort-by='.lastTimestamp' --field-selector type=Warning 2>/dev/null | tail -10 || echo "  (no warning events)"

    echo ""
    echo "--- POSTGRES POD STATUS ---"
    local PG_POD
    PG_POD=$(oc get pods -n "${INSTALLER_NAMESPACE}" -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "${PG_POD}" ]]; then
        echo "  Pod: ${PG_POD}"
        oc get pod "${PG_POD}" -n "${INSTALLER_NAMESPACE}" -o yaml 2>/dev/null | grep -A10 'containerStatuses:' || true
        echo "  Last 20 log lines:"
        oc logs "${PG_POD}" -n "${INSTALLER_NAMESPACE}" --tail=20 2>/dev/null || echo "    (no logs)"
        echo "  Previous container log (if crashed):"
        oc logs "${PG_POD}" -n "${INSTALLER_NAMESPACE}" --previous --tail=20 2>/dev/null || echo "    (no previous log)"
    else
        echo "  (postgres pod not found)"
    fi

    echo ""
    echo "--- GATEWAY POD STATUS ---"
    local GW_POD
    GW_POD=$(oc get pods -n "${INSTALLER_NAMESPACE}" -l app.kubernetes.io/name=gateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "${GW_POD}" ]]; then
        echo "  Pod: ${GW_POD}"
        oc get pod "${GW_POD}" -n "${INSTALLER_NAMESPACE}" -o jsonpath='{range .status.containerStatuses[*]}{.name}: ready={.ready} restarts={.restartCount}{"\n"}{end}' 2>/dev/null || true
        echo "  Last 10 log lines (api container):"
        oc logs "${GW_POD}" -n "${INSTALLER_NAMESPACE}" -c api --tail=10 2>/dev/null || echo "    (no logs)"
    else
        echo "  (gateway pod not found)"
    fi

    echo ""
    echo "--- CLUSTER OPERATORS (unhealthy only) ---"
    oc get co -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for co in data.get('items', []):
    name = co['metadata']['name']
    conds = {c['type']: c for c in co.get('status', {}).get('conditions', [])}
    avail = conds.get('Available', {}).get('status', '?')
    degraded = conds.get('Degraded', {}).get('status', '?')
    if avail != 'True' or degraded == 'True':
        msg = conds.get('Degraded', {}).get('message', '')[:120] if degraded == 'True' else conds.get('Available', {}).get('message', '')[:120]
        print(f'  {name}: Available={avail} Degraded={degraded} — {msg}')
" 2>/dev/null || echo "  (failed to parse)"

    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║  END ${label}"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
}

diag_brief() {
    local label="${1:-BRIEF STATUS}"
    local total running not_ready restarts
    total=$(oc get pods -n "${INSTALLER_NAMESPACE}" --no-headers 2>/dev/null | wc -l)
    running=$(oc get pods -n "${INSTALLER_NAMESPACE}" --no-headers --field-selector status.phase=Running 2>/dev/null | wc -l)
    not_ready=$(oc get pods -n "${INSTALLER_NAMESPACE}" --no-headers 2>/dev/null | grep -v Running | grep -v Completed || true)
    restarts=$(oc get pods -n "${INSTALLER_NAMESPACE}" -o jsonpath='{range .items[*]}{.metadata.name}{" restarts="}{range .status.containerStatuses[*]}{.restartCount}{" "}{end}{"\n"}{end}' 2>/dev/null | awk '{total=0; for(i=2;i<=NF;i++){split($i,a,"=");total+=a[2]} if(total>0) print $1" "total}' || true)
    echo "  [diag:${label}] $(date -u '+%H:%M:%S') — pods=${total} running=${running}"
    if [[ -n "${not_ready}" ]]; then
        echo "    Not running:"
        echo "${not_ready}" | sed 's/^/      /'
    fi
    if [[ -n "${restarts}" ]]; then
        echo "    Pods with restarts:"
        echo "${restarts}" | sed 's/^/      /'
    fi
}

trap 'echo ""; echo "!!! REFRESH SCRIPT FAILED — running failure diagnostics !!!"; diag_dump "FAILURE DUMP"; exit 1' ERR

echo "=== Refreshing OSAC after snapshot boot ==="
echo "Namespace: ${INSTALLER_NAMESPACE}"
echo "Overlay: ${INSTALLER_KUSTOMIZE_OVERLAY}"
echo "Cluster domain: ${CLUSTER_DOMAIN}"
echo ""

diag_dump "PRE-REFRESH (before any changes)"

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

diag_brief "post-stabilize"

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

diag_brief "post-kustomize-apply"

echo "[4/8] Waiting for fulfillment rollouts..."
pids=()
for deploy in fulfillment-controller fulfillment-grpc-server fulfillment-rest-gateway fulfillment-ingress-proxy; do
    oc rollout status "deploy/${deploy}" -n "${INSTALLER_NAMESPACE}" --timeout=300s &
    pids+=($!)
done
failed=0
for pid in "${pids[@]}"; do wait "${pid}" || failed=1; done
if (( failed )); then
    diag_dump "FULFILLMENT ROLLOUT FAILED"
    echo "ERROR: Fulfillment rollout failed"
    exit 1
fi

diag_brief "post-fulfillment-rollout"

echo "[5/8] Applying AAP configuration..."
INSTALLER_NAMESPACE="${INSTALLER_NAMESPACE}" \
INSTALLER_KUSTOMIZE_OVERLAY="${INSTALLER_KUSTOMIZE_OVERLAY}" \
    ./scripts/aap-configuration.sh

oc config set-context --current --namespace="${INSTALLER_NAMESPACE}"

echo "[6/8] Waiting for AAP controller..."
diag_brief "pre-aap-wait"
retry_until 300 10 '[[ "$(oc get automationcontroller osac-aap-controller -n '"${INSTALLER_NAMESPACE}"' -o jsonpath='"'"'{.status.conditions[?(@.type=="Running")].status}'"'"' 2>/dev/null)" == "True" ]]' || {
    diag_dump "AAP CONTROLLER TIMEOUT"
    echo "Timed out waiting for AAP controller to be Running"
    exit 1
}
AAP_ROUTE_HOST=$(oc get route osac-aap -n "${INSTALLER_NAMESPACE}" -o jsonpath='{.spec.host}')
retry_until 120 5 '[[ "$(curl -sk -o /dev/null -w %{http_code} https://'"${AAP_ROUTE_HOST}"'/api/gateway/v1/)" == "200" ]]' || {
    diag_dump "AAP GATEWAY TIMEOUT"
    echo "Timed out waiting for AAP gateway API to respond"
    exit 1
}

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
if (( failed )); then
    diag_dump "FULFILLMENT RESTART ROLLOUT FAILED"
    echo "ERROR: Fulfillment rollout failed after restart"
    exit 1
fi
./scripts/prepare-tenant.sh

diag_dump "POST-REFRESH (everything done)"

echo ""
echo "=== Refresh complete ==="
echo "Cluster domain: ${CLUSTER_DOMAIN}"
echo "Namespace: ${INSTALLER_NAMESPACE}"

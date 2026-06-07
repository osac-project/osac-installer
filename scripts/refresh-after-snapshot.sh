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
    for ns in "${INSTALLER_NAMESPACE}" "${KEYCLOAK_NS}" "multicluster-engine"; do
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
# Recert triggers an AAP controller rollout on boot. Wait for it to finish
# before mutating any resources, otherwise the operator cascade causes
# multiple waves of rollouts that kill in-flight AAP jobs.
oc rollout status deploy/osac-aap-controller-task -n "${INSTALLER_NAMESPACE}" --timeout=300s &
pid_aap1=$!
oc rollout status deploy/osac-aap-controller-web -n "${INSTALLER_NAMESPACE}" --timeout=300s &
pid_aap2=$!

failed=0
wait ${pid_tm} || failed=1
wait ${pid_kc} || failed=1
wait ${pid_rt} || failed=1
wait ${pid_aap1} || failed=1
wait ${pid_aap2} || failed=1
if (( failed )); then
    echo "ERROR: Cluster services did not stabilize within timeout"
    exit 1
fi
echo "Cluster services ready"
echo ""

# Recert rotates the cluster CA but the assisted-service JWT signing keypair
# (stored in the assisted-servicelocal-auth secret) is not rotated. Delete
# the secret now; assisted-service will be restarted after TLS certs are ready.
if oc get secret assisted-servicelocal-auth -n multicluster-engine &>/dev/null; then
    echo "Deleting stale assisted-service auth keypair..."
    oc delete secret assisted-servicelocal-auth -n multicluster-engine
fi

# Keycloak sync and fulfillment credentials run in parallel.
# Credentials read from realm.json (local file) — no dependency on Keycloak being up.
# Kustomize apply needs the credentials secret, so we wait for it before proceeding.

keycloak_sync() {
    echo "[1/9] Syncing Keycloak realm..."
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
    retry_until 300 5 '[[ "$(curl -sk -o /dev/null -w %{http_code} '"${KC_URL}"'/realms/osac)" == "200" ]]' || {
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
        oc wait --for=condition=Complete job/keycloak-set-passwords -n "${KEYCLOAK_NS}" --timeout=300s
    fi
    echo "[1/9] Keycloak sync complete"
}

create_fulfillment_credentials() {
    echo "[2/9] Recreating fulfillment controller credentials..."
    FC_CLIENT_ID=$(jq -er '.clients[] | select(.serviceAccountsEnabled == true) | .clientId' "${REALM_JSON}")
    FC_CLIENT_SECRET=$(jq -er ".clients[] | select(.clientId == \"${FC_CLIENT_ID}\") | .secret // empty" "${REALM_JSON}")
    [[ -n "${FC_CLIENT_SECRET}" ]] || { echo "ERROR: Could not resolve secret for ${FC_CLIENT_ID} in realm.json" >&2; exit 1; }
    oc delete secret fulfillment-controller-credentials -n "${INSTALLER_NAMESPACE}" --ignore-not-found
    oc create secret generic fulfillment-controller-credentials \
        --from-literal=client-id="${FC_CLIENT_ID}" \
        --from-literal=client-secret="${FC_CLIENT_SECRET}" \
        -n "${INSTALLER_NAMESPACE}"
    echo "[2/9] Credentials created for client: ${FC_CLIENT_ID}"
}

keycloak_sync &
pid_kc_sync=$!
create_fulfillment_credentials &
pid_creds=$!

failed=0
wait ${pid_creds} || failed=1
if (( failed )); then echo "ERROR: Failed to create fulfillment credentials"; exit 1; fi

oc scale deploy/fulfillment-controller -n "${INSTALLER_NAMESPACE}" --replicas=0 2>/dev/null || true
echo "[3/9] Applying kustomize overlay..."
oc delete job -n "${INSTALLER_NAMESPACE}" --all --ignore-not-found
# Exclude only the bootstrap job — it's redundant on snapshot boot and races
# the operator. The AnsibleAutomationPlatform CR (aap.yaml) IS included because
# it carries probe settings (task_readiness_period). Including it consolidates
# operator triggers into one reconciliation instead of a separate oc patch.
sed '/job\.yaml/d' base/osac-aap/config/base/kustomization.yaml > base/osac-aap/config/base/kustomization.yaml.tmp \
    && mv base/osac-aap/config/base/kustomization.yaml.tmp base/osac-aap/config/base/kustomization.yaml
oc apply -k "overlays/${INSTALLER_KUSTOMIZE_OVERLAY}"
oc scale deploy/fulfillment-controller -n "${INSTALLER_NAMESPACE}" --replicas=0 2>/dev/null || true

REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
PULL_SECRET="${REPO_ROOT}/overlays/${INSTALLER_KUSTOMIZE_OVERLAY}/files/quay-pull-secret.json"
[[ -f "${PULL_SECRET}" ]] || { echo "ERROR: Pull secret not found: ${PULL_SECRET}" >&2; exit 1; }
img_check_pids=()
img_check_imgs=()
img_check_logs=()
while IFS= read -r img; do
    [[ -z "${img}" ]] && continue
    img_check_imgs+=("${img}")
    log_file="$(mktemp)"
    img_check_logs+=("${log_file}")
    oc image info "${img}" -a "${PULL_SECRET}" &>"${log_file}" &
    img_check_pids+=($!)
done < <(oc get deploy,statefulset -n "${INSTALLER_NAMESPACE}" \
    -o jsonpath='{range .items[*]}{range .spec.template.spec.containers[*]}{.image}{"\n"}{end}{range .spec.template.spec.initContainers[*]}{.image}{"\n"}{end}{end}' \
    | sort -u | grep 'ghcr\.io/osac-project')

# After recert, cert-manager reissues TLS certificates with the new cluster CA.
# Pods that start before certs are ready crash loading the CA file. Wait for all
# certificates to be reissued, then restart pods so they mount fresh secrets.
refresh_cdi_certificates() {
    # CDI manages its own CA hierarchy (not cert-manager). After recert, the
    # signers and all leaf certs are stale. Delete the full chain so the operator
    # rebuilds everything from scratch. Deleting only the server cert secrets is
    # insufficient — the signer CAs are also past their refresh window, leaving
    # the operator unable to issue valid replacements and causing DataVolumeError
    # on every VM that needs a boot disk.
    # Skips silently when CDI is not installed (e.g., CaaS snapshots).
    if ! oc get namespace openshift-cnv &>/dev/null; then
        return 0
    fi
    echo "  Refreshing CDI certificates..."
    for secret in cdi-apiserver-signer cdi-uploadproxy-signer \
                  cdi-uploadserver-client-signer cdi-uploadserver-signer \
                  cdi-apiserver-server-cert cdi-uploadproxy-server-cert \
                  cdi-uploadserver-client-cert; do
        oc delete secret "${secret}" -n openshift-cnv --ignore-not-found
    done
    oc delete pod -n openshift-cnv -l app=cdi-operator --ignore-not-found
    retry_command 300 10 oc rollout status deploy/cdi-operator -n openshift-cnv --timeout=120s
    for deploy in cdi-deployment cdi-apiserver cdi-uploadproxy; do
        oc rollout restart "deploy/${deploy}" -n openshift-cnv 2>/dev/null || true
    done
    retry_command 300 10 oc rollout status deploy/cdi-deployment -n openshift-cnv --timeout=120s &
    local pid_cdi_deploy=$!
    retry_command 300 10 oc rollout status deploy/cdi-apiserver -n openshift-cnv --timeout=120s &
    local pid_cdi_api=$!
    wait ${pid_cdi_deploy}
    wait ${pid_cdi_api}
    echo "  CDI certificates refreshed"
}

refresh_metallb_certificates() {
    # After recert, the MetalLB webhook server still has certs signed by the old
    # CA. Delete the OLM-managed cert secret so it gets regenerated, then restart
    # the webhook server pod to pick up the new cert.
    if ! oc get crd ipaddresspools.metallb.io &>/dev/null; then
        return 0
    fi
    echo "  Refreshing MetalLB webhook certificates..."
    oc delete secret metallb-operator-webhook-server-cert -n metallb-system --ignore-not-found
    oc delete pod -n metallb-system -l control-plane=controller-manager --ignore-not-found 2>/dev/null || true
    oc delete pod -n metallb-system -l component=webhook-server --ignore-not-found 2>/dev/null || true
    retry_until 120 5 '[[ -n "$(oc get endpoints metallb-operator-webhook-server-service -n metallb-system -o jsonpath='"'"'{.subsets[*].addresses[*].ip}'"'"' 2>/dev/null)" ]]' || {
        echo "WARNING: MetalLB webhook service has no endpoints, continuing anyway"
    }
    echo "  MetalLB webhook certificates refreshed"
}

refresh_metallb_certificates

echo "[4/9] Reconfiguring MetalLB for current subnet..."
if oc get crd ipaddresspools.metallb.io &>/dev/null; then
    NODE_IP=$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
    SUBNET_PREFIX=$(echo "${NODE_IP}" | cut -d. -f1-3)
    echo "  Node IP: ${NODE_IP}, configuring pool: ${SUBNET_PREFIX}.240-${SUBNET_PREFIX}.250"
    METALLB_YAML=$(mktemp)
    cat > "${METALLB_YAML}" <<METALLBEOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: caas-address-pool
  namespace: metallb-system
spec:
  addresses:
    - ${SUBNET_PREFIX}.240-${SUBNET_PREFIX}.250
  autoAssign: true
METALLBEOF
    retry_command 120 10 oc apply -f "${METALLB_YAML}"
else
    echo "  MetalLB not installed, skipping"
fi

for i in "${!img_check_pids[@]}"; do
    if ! wait "${img_check_pids[$i]}"; then
        echo "ERROR: Image preflight failed for: ${img_check_imgs[$i]}"
        tail -5 "${img_check_logs[$i]}" 2>/dev/null || true
        exit 1
    fi
done

# Discover fulfillment deployments by label instead of maintaining a hardcoded
# list. The app=fulfillment-service label is set by kustomize on all
# fulfillment-service resources, so new deployments are picked up automatically.
read -ra FULFILLMENT_DEPLOYS <<< \
    "$(oc get deploy -n "${INSTALLER_NAMESPACE}" -l app=fulfillment-service \
       -o jsonpath='{.items[*].metadata.name}')"
if [[ ${#FULFILLMENT_DEPLOYS[@]} -eq 0 || -z "${FULFILLMENT_DEPLOYS[0]}" ]]; then
    echo "ERROR: No deployments found with label app=fulfillment-service in namespace ${INSTALLER_NAMESPACE}"
    exit 1
fi
echo "  Fulfillment deployments: ${FULFILLMENT_DEPLOYS[*]}"

echo "[5/9] Waiting for TLS certificates and restarting pods..."
refresh_cdi_certificates &
pid_cdi=$!
pids=()
read -ra fs_certs <<< \
    "$(oc get certificates.cert-manager.io -n "${INSTALLER_NAMESPACE}" \
       -l app=fulfillment-service -o jsonpath='{.items[*].metadata.name}')"
if [[ ${#fs_certs[@]} -eq 0 || -z "${fs_certs[0]}" ]]; then
    echo "ERROR: No certificates found with label app=fulfillment-service in namespace ${INSTALLER_NAMESPACE}"
    exit 1
fi
echo "  Certificates to wait for: ${fs_certs[*]}"
for cert in "${fs_certs[@]}"; do
    oc wait --for=condition=Ready "certificate.cert-manager.io/${cert}" \
        -n "${INSTALLER_NAMESPACE}" --timeout=300s &
    pids+=($!)
done
# Kustomize apply may have changed deployment images, triggering new rollouts
# that run DB migrations. Wait for those to finish before restarting pods —
# otherwise the restart kills pods mid-migration and leaves the DB dirty.
for deploy in "${FULFILLMENT_DEPLOYS[@]}"; do
    oc rollout status "deploy/${deploy}" -n "${INSTALLER_NAMESPACE}" --timeout=300s &
    pids+=($!)
done
failed=0
for pid in "${pids[@]}"; do wait "${pid}" || failed=1; done
wait ${pid_cdi} || failed=1
if (( failed )); then echo "ERROR: TLS certificates or fulfillment rollouts not ready"; exit 1; fi
echo "[5/9] TLS certificates ready, restarting pods..."
oc scale deploy/fulfillment-controller -n "${INSTALLER_NAMESPACE}" --replicas=1
for deploy in "${FULFILLMENT_DEPLOYS[@]}"; do
    oc rollout restart "deploy/${deploy}" -n "${INSTALLER_NAMESPACE}"
done
if oc get deploy assisted-service -n multicluster-engine &>/dev/null; then
    oc rollout restart deploy/assisted-service -n multicluster-engine
    oc rollout restart statefulset/assisted-image-service -n multicluster-engine
fi

# Fulfillment rollouts, AAP configuration, and AAP controller wait run in parallel.
# Keycloak sync from above also continues in the background.

wait_fulfillment_rollouts() {
    pids=()
    for deploy in "${FULFILLMENT_DEPLOYS[@]}"; do
        oc rollout status "deploy/${deploy}" -n "${INSTALLER_NAMESPACE}" --timeout=300s &
        pids+=($!)
    done
    local failed=0
    for pid in "${pids[@]}"; do wait "${pid}" || failed=1; done
    if (( failed )); then echo "ERROR: Fulfillment rollout failed"; exit 1; fi
    echo "[5/9] Fulfillment rollouts complete"
}

apply_aap_configuration() {
    echo "[6/9] Applying AAP configuration..."
    local hcbd=""
    if oc get configmap cluster-fulfillment-ig -n "${INSTALLER_NAMESPACE}" &>/dev/null; then
        hcbd="${HOSTED_CLUSTER_BASE_DOMAIN:-${CLUSTER_DOMAIN}}"
    fi
    HOSTED_CLUSTER_BASE_DOMAIN="${hcbd}" \
    INSTALLER_NAMESPACE="${INSTALLER_NAMESPACE}" \
    INSTALLER_KUSTOMIZE_OVERLAY="${INSTALLER_KUSTOMIZE_OVERLAY}" \
        ./scripts/aap-configuration.sh
    echo "[6/9] AAP configuration applied"
}

wait_aap_controller() {
    echo "[7/9] Waiting for AAP controller..."
    retry_until 300 10 '[[ "$(oc get automationcontroller osac-aap-controller -n '"${INSTALLER_NAMESPACE}"' -o jsonpath='"'"'{.status.conditions[?(@.type=="Running")].status}'"'"' 2>/dev/null)" == "True" ]]' || {
        echo "Timed out waiting for AAP controller to be Running"
        exit 1
    }
    AAP_ROUTE_HOST=$(oc get route osac-aap -n "${INSTALLER_NAMESPACE}" -o jsonpath='{.spec.host}')
    retry_until 120 5 '[[ "$(curl -sk -o /dev/null -w %{http_code} https://'"${AAP_ROUTE_HOST}"'/api/gateway/v1/)" == "200" ]]' || {
        echo "Timed out waiting for AAP gateway API to respond"
        exit 1
    }
    echo "[7/9] AAP controller Running, gateway responding"
}

wait_fulfillment_rollouts &
pid_fulfill=$!
apply_aap_configuration &
pid_aapconf=$!
wait_aap_controller &
pid_aapwait=$!

failed=0
wait ${pid_fulfill} || failed=1
if (( failed )); then echo "ERROR: Fulfillment rollout failed"; exit 1; fi
wait ${pid_aapconf} || { echo "ERROR: AAP configuration failed"; exit 1; }
wait ${pid_aapwait} || { echo "ERROR: AAP controller wait failed"; exit 1; }
wait ${pid_kc_sync} || { echo "ERROR: Keycloak sync failed"; exit 1; }

oc config set-context --current --namespace="${INSTALLER_NAMESPACE}"

echo "[8/9] Configuring AAP access and fulfillment service..."
./scripts/prepare-aap.sh
./scripts/prepare-fulfillment-service.sh

echo "[9/9] Restarting fulfillment pods and configuring tenant..."
for deploy in "${FULFILLMENT_DEPLOYS[@]}"; do
    oc rollout restart "deploy/${deploy}" -n "${INSTALLER_NAMESPACE}"
done
pids=()
for deploy in "${FULFILLMENT_DEPLOYS[@]}"; do
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

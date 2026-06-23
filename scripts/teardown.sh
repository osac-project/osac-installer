#!/usr/bin/env bash

set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

INSTALLER_KUSTOMIZE_OVERLAY=${INSTALLER_KUSTOMIZE_OVERLAY:-"development"}
INSTALLER_NAMESPACE=${INSTALLER_NAMESPACE:-$(grep "^namespace:" "overlays/${INSTALLER_KUSTOMIZE_OVERLAY}/kustomization.yaml" | awk '{print $2}')}
[[ -z "${INSTALLER_NAMESPACE}" ]] && echo "ERROR: Could not determine namespace from overlays/${INSTALLER_KUSTOMIZE_OVERLAY}/kustomization.yaml" && exit 1
EXTRA_SERVICES=${EXTRA_SERVICES:-"false"}
INGRESS_SERVICE=${INGRESS_SERVICE:-${EXTRA_SERVICES}}
STORAGE_SERVICE=${STORAGE_SERVICE:-${EXTRA_SERVICES}}
VIRT_SERVICE=${VIRT_SERVICE:-${EXTRA_SERVICES}}
MCE_SERVICE=${MCE_SERVICE:-${EXTRA_SERVICES}}

resource_type_exists() {
    local output
    output=$(timeout 10 oc get "$1" 2>&1) || true
    ! echo "${output}" | grep -q "the server doesn't have a resource type"
}

delete_manifests() {
    local tmpdir
    tmpdir=$(mktemp -d)
    awk -v d="${tmpdir}" '/^---$/{i++; next} {print >> d"/r-"sprintf("%04d",i)".yaml"}'
    for f in "${tmpdir}"/r-*.yaml; do
        [[ -f "$f" ]] || continue
        if ! output=$(timeout 30 oc delete --ignore-not-found --wait=false -f "$f" 2>&1); then
            if echo "${output}" | grep -q "resource mapping not found\|the server doesn't have a resource type"; then
                echo "  Skipping $(awk '/^kind:/{print $2}' "$f"): CRD not installed"
                continue
            fi
            rm -rf "${tmpdir}"
            echo "${output}" >&2
            return 1
        fi
        [[ -n "${output}" ]] && echo "${output}"
    done
    rm -rf "${tmpdir}"
}

echo "=== Tearing down OSAC deployment ==="
echo "Overlay: ${INSTALLER_KUSTOMIZE_OVERLAY}"
echo "Namespace: ${INSTALLER_NAMESPACE}"
echo ""

# Deletes a CR and waits for the operator to process its finalizers.
# If the operator can't process finalizers within the timeout (e.g. operator
# is dead or too slow), force-removes the finalizers so the CR can be garbage
# collected.
delete_cr() {
    local resource="$1"
    local name="$2"
    local namespace="${3:-}"
    local ns_args=""
    [[ -n "${namespace}" ]] && ns_args="-n ${namespace}"

    if ! resource_type_exists "${resource}"; then
        return 0
    fi

    # Start deletion (non-blocking — sets deletionTimestamp, doesn't wait for finalizers)
    timeout 30 oc delete "${resource}" "${name}" ${ns_args} --ignore-not-found --wait=false

    # Wait for the operator to process finalizers
    if retry_until 120 5 "[[ -z \"\$(timeout 10 oc get ${resource} ${name} --no-headers ${ns_args} 2>/dev/null)\" ]]"; then
        return 0
    fi

    # Operator didn't process finalizers in time — force-remove them
    echo "  WARNING: ${resource}/${name} stuck terminating, removing finalizers..."
    timeout 30 oc patch "${resource}" "${name}" ${ns_args} --type=merge -p '{"metadata":{"finalizers":null}}'
    if ! retry_until 30 3 "[[ -z \"\$(timeout 10 oc get ${resource} ${name} --no-headers ${ns_args} 2>/dev/null)\" ]]"; then
        echo "  WARNING: ${resource}/${name} still exists after finalizer removal, will be cleaned up during operator uninstall"
    fi
}

# Uninstalls an OLM-managed operator:
#   1. Delete subscription (stop OLM from managing it)
#   2. Delete CSV (OLM removes operator deployment + owned CRDs)
#   3. Delete operatorgroup
#   4. Delete namespace (unless it's openshift-operators)
uninstall_operator() {
    local namespace="$1"
    local subscription="$2"

    local csv=""
    if timeout 10 oc get subscription "${subscription}" -n "${namespace}" &>/dev/null; then
        csv=$(timeout 10 oc get subscription "${subscription}" -n "${namespace}" -o jsonpath='{.status.currentCSV}')
    fi

    timeout 30 oc delete subscription "${subscription}" -n "${namespace}" --ignore-not-found

    if [[ -n "${csv}" ]]; then
        timeout 120 oc delete csv "${csv}" -n "${namespace}" --ignore-not-found
        retry_until 120 5 "[[ -z \"\$(timeout 10 oc get csv ${csv} --no-headers -n ${namespace} 2>/dev/null)\" ]]"
    fi

    timeout 30 oc delete operatorgroup --all -n "${namespace}" --ignore-not-found

    if [[ "${namespace}" != "openshift-operators" ]]; then
        timeout 30 oc delete namespace "${namespace}" --ignore-not-found --wait=false
    fi
}
# Phase 0: Delete webhooks
#
# Webhook services may be down (partial setup, crashed operator). The API server
# hangs on every delete call that triggers a dead webhook. Remove them first so
# all subsequent oc commands are safe.
echo "Removing webhooks..."
for wh in $(timeout 10 oc get validatingwebhookconfiguration --no-headers 2>/dev/null \
    | awk '/virt|hco|trust-manager|authorino|cert-manager|hostpath|ssp|multicluster|open-cluster-management|managedcluster/ {print $1}'); do
    timeout 30 oc delete validatingwebhookconfiguration "${wh}" --ignore-not-found
done
for wh in $(timeout 10 oc get mutatingwebhookconfiguration --no-headers 2>/dev/null \
    | awk '/virt|hco|authorino|multicluster|open-cluster-management|managedcluster/ {print $1}'); do
    timeout 30 oc delete mutatingwebhookconfiguration "${wh}" --ignore-not-found
done
# Phase 1: Delete OSAC CRs while the operator is still running
#
# The operator must be alive to process finalizers on its CRs. Deleting the
# kustomize overlay kills the operator, so CRs must be cleaned up first.
echo "Deleting OSAC CRs..."
for resource in computeinstance virtualnetwork subnet securitygroup publicippool clusterorder tenant; do
    if resource_type_exists "${resource}"; then
        for name in $(timeout 10 oc get "${resource}" -n "${INSTALLER_NAMESPACE}" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null); do
            delete_cr "${resource}" "${name}" "${INSTALLER_NAMESPACE}"
        done
    fi
done
# Phase 2: Delete application-level resources
echo "Deleting kustomize overlay resources..."
oc kustomize "overlays/${INSTALLER_KUSTOMIZE_OVERLAY}" | delete_manifests

echo "Deleting namespace ${INSTALLER_NAMESPACE}..."
timeout 30 oc delete namespace "${INSTALLER_NAMESPACE}" --ignore-not-found --wait=false

echo "Deleting Keycloak resources..."
oc kustomize prerequisites/keycloak/ | delete_manifests
timeout 30 oc delete namespace keycloak --ignore-not-found --wait=false
# Phase 3: Delete operator CRs while operators are still running
#
# Operators need to be alive to process finalizers on their CRs. If we kill the
# operator first, the CR gets stuck in Terminating forever because nothing can
# remove its finalizers.
echo "Deleting AAP CR..."
if resource_type_exists ansibleautomationplatform; then
    timeout 60 oc delete ansibleautomationplatform --all -n "${INSTALLER_NAMESPACE}" --ignore-not-found --wait=false
fi

if [[ "${MCE_SERVICE}" == "true" ]]; then
    echo "Deleting AgentServiceConfig..."
    delete_cr agentserviceconfig agent
    echo "Deleting MultiClusterEngine..."
    if resource_type_exists multiclusterengine; then
        timeout 30 oc delete multiclusterengine --all --ignore-not-found --wait=false
        if ! retry_until 120 5 '[[ -z "$(timeout 10 oc get multiclusterengine --no-headers 2>/dev/null)" ]]'; then
            echo "  WARNING: MultiClusterEngine stuck, removing finalizers..."
            for name in $(timeout 10 oc get multiclusterengine -o name 2>/dev/null); do
                timeout 30 oc patch "${name}" --type=merge -p '{"metadata":{"finalizers":null}}'
            done
        fi
    fi
fi

if [[ "${VIRT_SERVICE}" == "true" ]]; then
    echo "Deleting HyperConverged..."
    delete_cr hyperconverged kubevirt-hyperconverged openshift-cnv
    for resource in kubevirt ssp cdi; do
        for name in $(timeout 10 oc get "${resource}" -n openshift-cnv --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null); do
            delete_cr "${resource}" "${name}" openshift-cnv
        done
    done
fi

if [[ "${STORAGE_SERVICE}" == "true" ]]; then
    echo "Deleting LVMCluster..."
    delete_cr lvmcluster lvms-cluster openshift-storage
    for resource in lvmvolumegroup lvmvolumegroupnodestatus; do
        for name in $(timeout 10 oc get "${resource}" -n openshift-storage --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null); do
            delete_cr "${resource}" "${name}" openshift-storage
        done
    done
fi

if [[ "${INGRESS_SERVICE}" == "true" ]]; then
    echo "Deleting MetalLB configuration..."
    delete_manifests < prerequisites/metallb/metallb-config.yaml
fi

echo "Deleting Authorino CRs..."
if resource_type_exists authorino; then
    timeout 30 oc delete authorino --all -A --ignore-not-found --wait=false
fi

echo "Deleting CA issuer and trust-manager..."
delete_manifests < prerequisites/ca-issuer.yaml
delete_manifests < prerequisites/trust-manager.yaml

echo "Deleting CertManager CR..."
delete_cr certmanager cluster

# Wait for PVC-holding namespaces before removing storage operators
for ns in keycloak "${INSTALLER_NAMESPACE}"; do
    if timeout 10 oc get namespace "${ns}" &>/dev/null; then
        echo "Waiting for namespace ${ns} to be deleted..."
        if ! timeout 300 oc wait --for=delete "namespace/${ns}" --timeout=300s 2>/dev/null; then
            echo "  WARNING: namespace ${ns} stuck, removing finalizers from remaining resources..."
            for crd in $(timeout 10 oc api-resources --namespaced -o name 2>/dev/null); do
                for name in $(timeout 10 oc get "${crd}" -n "${ns}" --no-headers -o name 2>/dev/null); do
                    timeout 10 oc patch "${name}" -n "${ns}" --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
                done
            done
            timeout 120 oc wait --for=delete "namespace/${ns}" --timeout=120s 2>/dev/null || echo "  WARNING: namespace ${ns} still terminating"
        fi
    fi
done
# Phase 4: Uninstall operators via OLM
#
# All CRs are gone (or had finalizers removed), so operators can be safely removed.
echo ""
echo "Uninstalling operators..."

echo "  AAP operator..."
uninstall_operator ansible-aap dev-ansible-automation-platform

if [[ "${MCE_SERVICE}" == "true" ]]; then
    echo "  MCE operator..."
    uninstall_operator multicluster-engine multicluster-engine
fi

if [[ "${VIRT_SERVICE}" == "true" ]]; then
    echo "  CNV operator..."
    uninstall_operator openshift-cnv kubevirt-hyperconverged
fi

if [[ "${STORAGE_SERVICE}" == "true" ]]; then
    echo "  LVMS operator..."
    uninstall_operator openshift-storage lvms-operator
fi

if [[ "${INGRESS_SERVICE}" == "true" ]]; then
    echo "  MetalLB operator..."
    uninstall_operator metallb-system metallb-operator
fi

echo "  Authorino operator..."
csv=$(timeout 10 oc get csv --no-headers -n openshift-operators 2>/dev/null | awk '/authorino/ {print $1}')
timeout 30 oc delete subscription authorino-operator -n openshift-operators --ignore-not-found
if [[ -n "${csv}" ]]; then
    timeout 120 oc delete csv "${csv}" -n openshift-operators --ignore-not-found
fi

echo "  cert-manager operator..."
uninstall_operator cert-manager-operator openshift-cert-manager-operator
if timeout 10 oc get certmanager cluster &>/dev/null; then
    echo "  Cleaning up recreated CertManager CR..."
    timeout 10 oc patch certmanager cluster --type=merge -p '{"metadata":{"finalizers":null}}'
fi
timeout 300 oc delete namespace cert-manager --ignore-not-found --timeout=300s
# Phase 5: Final cleanup of cluster-scoped resources
#
# OLM removes CRDs it directly owns, but sub-operators (CDI, kubevirt, topolvm)
# create additional CRDs that OLM doesn't track. CSIDriver topolvm.io has a
# controller that recreates CRDs, so it must be removed before the CRD sweep.
echo ""
if timeout 10 oc get crd networkattachmentdefinitions.k8s.cni.cncf.io &>/dev/null; then
    timeout 30 oc delete networkattachmentdefinition default -n openshift-ovn-kubernetes --ignore-not-found
fi
rm -f /tmp/kubeconfig.hub-access*

echo "Cleaning up stale API services..."
for api in $(timeout 10 oc get apiservice --no-headers 2>/dev/null | awk '/False/ {print $1}'); do
    echo "  Deleting stale apiservice ${api}..."
    timeout 30 oc delete apiservice "${api}" --ignore-not-found
done

echo "Cleaning up MCE-managed namespaces..."
for ns in hive hypershift local-cluster open-cluster-management-agent open-cluster-management-agent-addon open-cluster-management-global-set open-cluster-management-hub hardware-inventory; do
    if timeout 10 oc get namespace "${ns}" &>/dev/null; then
        timeout 30 oc delete namespace "${ns}" --ignore-not-found --wait=false
    fi
done

echo "Waiting for all namespaces to be fully deleted..."
for ns in "${INSTALLER_NAMESPACE}" keycloak ansible-aap multicluster-engine openshift-storage openshift-cnv metallb-system cert-manager cert-manager-operator hive hypershift local-cluster open-cluster-management-agent open-cluster-management-agent-addon open-cluster-management-global-set open-cluster-management-hub hardware-inventory; do
    if timeout 10 oc get namespace "${ns}" &>/dev/null; then
        echo "  Waiting for namespace ${ns}..."
        if ! timeout 120 oc wait --for=delete "namespace/${ns}" --timeout=120s 2>/dev/null; then
            echo "  Force-finalizing namespace ${ns}..."
            oc get namespace "${ns}" -o json | python3 -c "import json,sys; ns=json.load(sys.stdin); ns['spec']['finalizers']=[]; json.dump(ns,sys.stdout)" | oc replace --raw "/api/v1/namespaces/${ns}/finalize" -f - >/dev/null 2>&1 || true
        fi
    fi
done

echo "Cleaning up cluster-scoped resources..."
timeout 30 oc delete sc lvms-vg1 --ignore-not-found
timeout 30 oc delete csidriver topolvm.io --ignore-not-found

CRD_PATTERN='cert-manager\.io|certmanagers\.operator|authorino|ansible\.com|kubevirt\.io|networkaddonsoperator|hostpathprovisioner|metallb\.io|topolvm\.io|agentserviceconfig|multicluster|open-cluster-management|hive\.openshift|hiveinternal|agent-install|cluster\.x-k8s|hypershift|metal3\.io'

echo "Final CRD cleanup (retries until all gone)..."
for attempt in 1 2 3 4 5 6 7; do
    remaining_crds=$(timeout 10 oc get crd --no-headers 2>/dev/null | awk "/${CRD_PATTERN}/ {print \$1}")
    count=$(echo "${remaining_crds}" | grep -c . 2>/dev/null || true); count=${count//[^0-9]/}
    [[ "${count}" -eq 0 ]] && break
    echo "  Pass ${attempt}: ${count} CRDs remaining..."

    for crd in ${remaining_crds}; do
        resource="${crd%%.*}"
        if instances=$(timeout 5 oc get "${resource}" -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null); then
            while IFS=' ' read -r ns name; do
                [[ -z "${name}" ]] && continue
                ns_args=""; [[ -n "${ns}" ]] && ns_args="-n ${ns}"
                timeout 5 oc patch "${resource}" "${name}" ${ns_args} --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
                timeout 5 oc delete "${resource}" "${name}" ${ns_args} --wait=false --ignore-not-found 2>/dev/null || true
            done <<< "${instances}"
        fi
        timeout 5 oc patch crd "${crd}" --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
        timeout 5 oc delete crd "${crd}" --ignore-not-found --wait=false 2>/dev/null || true
    done
    sleep 3
done

final_count=$(timeout 10 oc get crd --no-headers 2>/dev/null | awk "/${CRD_PATTERN}/" | wc -l); final_count=${final_count//[^0-9]/}
if [[ "${final_count}" -gt 0 ]]; then
    echo "  WARNING: ${final_count} CRDs still remaining after 7 passes"
else
    echo "  All CRDs cleaned up"
fi

echo ""
echo "=== Teardown complete ==="

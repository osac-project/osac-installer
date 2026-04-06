#!/bin/bash

set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

INSTALLER_KUSTOMIZE_OVERLAY=${INSTALLER_KUSTOMIZE_OVERLAY:-"development"}
INSTALLER_NAMESPACE=${INSTALLER_NAMESPACE:-$(grep "^namespace:" "overlays/${INSTALLER_KUSTOMIZE_OVERLAY}/kustomization.yaml" | awk '{print $2}')}
[[ -z "${INSTALLER_NAMESPACE}" ]] && echo "ERROR: Could not determine namespace from overlays/${INSTALLER_KUSTOMIZE_OVERLAY}/kustomization.yaml" && exit 1
# EXTRA_SERVICES=true enables all optional services (storage, ingress, virtualization, MCE)
EXTRA_SERVICES=${EXTRA_SERVICES:-"false"}
INGRESS_SERVICE=${INGRESS_SERVICE:-${EXTRA_SERVICES}}
STORAGE_SERVICE=${STORAGE_SERVICE:-${EXTRA_SERVICES}}
VIRT_SERVICE=${VIRT_SERVICE:-${EXTRA_SERVICES}}
MCE_SERVICE=${MCE_SERVICE:-${EXTRA_SERVICES}}

echo "=== Tearing down OSAC deployment ==="
echo "Overlay: ${INSTALLER_KUSTOMIZE_OVERLAY}"
echo "Namespace: ${INSTALLER_NAMESPACE}"
echo ""

# Remove StorageClass label
DEFAULT_SC=$(oc get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null)
if [[ -n "${DEFAULT_SC}" ]]; then
    echo "Removing OSAC label from StorageClass ${DEFAULT_SC}..."
    oc label sc "${DEFAULT_SC}" "osac.openshift.io/tenant-" 2>/dev/null || true
fi

# Delete the kustomize overlay resources
echo "Deleting kustomize overlay resources..."
oc delete -k "overlays/${INSTALLER_KUSTOMIZE_OVERLAY}" --ignore-not-found --wait=false 2>/dev/null || true

# Delete the OSAC namespace
echo "Deleting namespace ${INSTALLER_NAMESPACE}..."
oc delete namespace "${INSTALLER_NAMESPACE}" --ignore-not-found --wait=false 2>/dev/null || true

# Delete Keycloak (before LVMS since keycloak PVCs depend on the LVMS storage class)
echo "Deleting Keycloak..."
oc delete -k prerequisites/keycloak/ --ignore-not-found --wait=false 2>/dev/null || true
oc delete namespace keycloak --ignore-not-found --wait=false 2>/dev/null || true

# Delete AAP operator
echo "Deleting AAP operator..."
oc delete -f prerequisites/aap-installation.yaml --ignore-not-found --wait=false 2>/dev/null || true
oc delete namespace ansible-aap --ignore-not-found --wait=false 2>/dev/null || true

# Optionally delete Multicluster Engine (before LVMS since AgentServiceConfig PVCs depend on storage)
if [[ "${MCE_SERVICE}" == "true" ]]; then
    echo "Deleting AgentServiceConfig..."
    oc delete agentserviceconfig agent --ignore-not-found --timeout=120s 2>/dev/null || true
    echo "Deleting MultiClusterEngine..."
    oc delete multiclusterengine --all --ignore-not-found --timeout=120s 2>/dev/null || true
    # Wait for MultiClusterEngine to be fully removed
    retry_until 120 5 '[[ -z "$(oc get multiclusterengine --no-headers 2>/dev/null)" ]]' || {
        echo "WARNING: MultiClusterEngine resources still exist, removing finalizers manually..."
        for name in $(oc get multiclusterengine -o name 2>/dev/null); do
            oc patch "${name}" --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
        done
    }
    echo "Deleting MCE operator..."
    oc delete -f prerequisites/mce/mce-operator.yaml --ignore-not-found --wait=false 2>/dev/null || true
    oc delete namespace multicluster-engine --ignore-not-found --wait=false 2>/dev/null || true
fi

# Wait for namespaces with LVMS-backed PVCs to be fully deleted before removing storage
for ns in keycloak "${INSTALLER_NAMESPACE}" multicluster-engine; do
    if oc get namespace "${ns}" &>/dev/null; then
        echo "Waiting for namespace ${ns} to be deleted before removing storage..."
        oc wait --for=delete "namespace/${ns}" --timeout=300s 2>/dev/null || echo "WARNING: namespace ${ns} still terminating"
    fi
done

# Optionally delete LVMS storage service
if [[ "${STORAGE_SERVICE}" == "true" ]]; then
    echo "Deleting LVMS configuration..."
    oc annotate sc lvms-vg1 storageclass.kubernetes.io/is-default-class- 2>/dev/null || true
    # Delete LVMCluster and wait for the operator to process finalizers before removing the operator
    oc delete -f prerequisites/lvms/lvms-config.yaml --ignore-not-found --timeout=120s 2>/dev/null || true
    # Wait for all LVMCluster CRs to be fully removed (finalizers processed by operator)
    retry_until 120 5 '[[ -z "$(oc get lvmcluster -n openshift-storage --no-headers 2>/dev/null)" ]]' || {
        echo "WARNING: LVMCluster resources still exist, removing finalizers manually..."
        for resource in lvmcluster lvmvolumegroup lvmvolumegroupnodestatus; do
            for name in $(oc get "${resource}" -n openshift-storage -o name 2>/dev/null); do
                oc patch "${name}" -n openshift-storage --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
            done
        done
    }
    echo "Deleting LVMS operator..."
    oc delete -f prerequisites/lvms/lvms-operator.yaml --ignore-not-found --wait=false 2>/dev/null || true
    oc delete namespace openshift-storage --ignore-not-found --wait=false 2>/dev/null || true
fi

# Optionally delete MetalLB ingress service
if [[ "${INGRESS_SERVICE}" == "true" ]]; then
    echo "Deleting MetalLB configuration..."
    oc delete -f prerequisites/metallb/metallb-config.yaml --ignore-not-found --wait=false 2>/dev/null || true
    echo "Deleting MetalLB operator..."
    oc delete -f prerequisites/metallb/metallb-operator.yaml --ignore-not-found --wait=false 2>/dev/null || true
    oc delete namespace metallb-system --ignore-not-found --wait=false 2>/dev/null || true
fi

# Optionally delete OpenShift Virtualization
if [[ "${VIRT_SERVICE}" == "true" ]]; then
    echo "Deleting OpenShift Virtualization configuration..."
    oc delete -f prerequisites/cnv/cnv-config.yaml --ignore-not-found --timeout=120s 2>/dev/null || true
    # Wait for HyperConverged CR to be fully removed
    retry_until 120 5 '[[ -z "$(oc get hyperconverged -n openshift-cnv --no-headers 2>/dev/null)" ]]' || {
        echo "WARNING: CNV resources still exist, removing finalizers manually..."
        for resource in hyperconverged kubevirt ssp cdi; do
            for name in $(oc get "${resource}" -n openshift-cnv -o name 2>/dev/null); do
                oc patch "${name}" -n openshift-cnv --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
            done
        done
    }
    # Clean up stale webhooks left behind by the operator
    for wh in $(oc get validatingwebhookconfiguration --no-headers 2>/dev/null | awk '/virt/ {print $1}'); do
        oc delete validatingwebhookconfiguration "${wh}" 2>/dev/null || true
    done
    for wh in $(oc get mutatingwebhookconfiguration --no-headers 2>/dev/null | awk '/virt/ {print $1}'); do
        oc delete mutatingwebhookconfiguration "${wh}" 2>/dev/null || true
    done
    echo "Deleting OpenShift Virtualization operator..."
    oc delete -f prerequisites/cnv/cnv-operator.yaml --ignore-not-found --wait=false 2>/dev/null || true
    oc delete namespace openshift-cnv --ignore-not-found --wait=false 2>/dev/null || true
fi

# Delete Authorino operator
echo "Deleting Authorino operator..."
oc delete -f prerequisites/authorino-operator.yaml --ignore-not-found --wait=false 2>/dev/null || true

# Delete CA issuer
echo "Deleting CA issuer..."
oc delete -f prerequisites/ca-issuer.yaml --ignore-not-found --wait=false 2>/dev/null || true

# Delete trust-manager
echo "Deleting trust-manager..."
oc delete -f prerequisites/trust-manager.yaml --ignore-not-found --wait=false 2>/dev/null || true

# Delete cert-manager
echo "Deleting cert-manager..."
oc delete -k prerequisites/cert-manager --ignore-not-found --wait=false 2>/dev/null || true
oc delete namespace cert-manager --ignore-not-found --wait=false 2>/dev/null || true
oc delete namespace cert-manager-operator --ignore-not-found --wait=false 2>/dev/null || true

# Delete the NetworkAttachmentDefinition
echo "Deleting NetworkAttachmentDefinition..."
oc delete networkattachmentdefinition default -n openshift-ovn-kubernetes --ignore-not-found 2>/dev/null || true

# Clean up local files created by setup
rm -f kubeconfig.hub-access

# Clean up stale API services left behind by removed operators (prevents namespace deletion from hanging)
echo "Cleaning up stale API services..."
for api in $(oc get apiservice --no-headers 2>/dev/null | awk '/False/ {print $1}'); do
    echo "  Deleting stale apiservice ${api}..."
    oc delete apiservice "${api}" 2>/dev/null || true
done

# Wait for namespaces to be fully deleted
echo ""
echo "Waiting for namespaces to be deleted..."
for ns in "${INSTALLER_NAMESPACE}" keycloak ansible-aap multicluster-engine openshift-storage openshift-cnv metallb-system cert-manager cert-manager-operator; do
    if oc get namespace "${ns}" &>/dev/null; then
        echo "  Waiting for namespace ${ns}..."
        oc wait --for=delete "namespace/${ns}" --timeout=300s 2>/dev/null || echo "  WARNING: namespace ${ns} still terminating"
    fi
done

echo ""
echo "=== Teardown complete ==="

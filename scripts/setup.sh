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
# EXTRA_SERVICES=true enables all optional services (storage, ingress, virtualization, MCE)
EXTRA_SERVICES=${EXTRA_SERVICES:-"false"}
INGRESS_SERVICE=${INGRESS_SERVICE:-${EXTRA_SERVICES}}
STORAGE_SERVICE=${STORAGE_SERVICE:-${EXTRA_SERVICES}}
VIRT_SERVICE=${VIRT_SERVICE:-${EXTRA_SERVICES}}
MCE_SERVICE=${MCE_SERVICE:-${EXTRA_SERVICES}}

echo "=== Setting up OSAC deployment ==="
echo "Overlay: ${INSTALLER_KUSTOMIZE_OVERLAY}"
echo "Namespace: ${INSTALLER_NAMESPACE}"
echo ""

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

# Optionally install LVMS as storage service (must be before keycloak which needs a default storage class)
if [[ "${STORAGE_SERVICE}" == "true" ]]; then
    wait_for_namespace_cleanup openshift-storage
    echo "Installing LVMS storage service..."
    oc apply -f prerequisites/lvms/lvms-operator.yaml
    retry_until 300 3 '[[ -n "$(oc get csv --no-headers -n openshift-storage | grep lvms)" ]]' 'oc apply -f prerequisites/lvms/lvms-operator.yaml || true' || {
        echo "Timed out waiting for LVMS CSV to exist"
        exit 1
    }
    LVMS_CSV=$(oc get csv --no-headers -n openshift-storage | awk '/lvms/ { print $1 }')
    wait_for_resource clusterserviceversion/${LVMS_CSV} jsonpath='{.status.phase}'=Succeeded 300 openshift-storage
    wait_for_resource deployment/lvms-operator condition=Available 300 openshift-storage

    # Apply LVMCluster configuration (requires operator CRDs to be installed)
    oc apply -f prerequisites/lvms/lvms-config.yaml

    # Wait for the storage class to be created and set it as default
    retry_until 300 5 '[[ -n "$(oc get sc --ignore-not-found lvms-vg1)" ]]' || {
        echo "Timed out waiting for lvms-vg1 StorageClass to exist"
        exit 1
    }
    oc annotate sc lvms-vg1 storageclass.kubernetes.io/is-default-class=true --overwrite
fi

# Optionally install MetalLB as ingress service
if [[ "${INGRESS_SERVICE}" == "true" ]]; then
    wait_for_namespace_cleanup metallb-system
    echo "Installing MetalLB ingress service..."
    oc apply -f prerequisites/metallb/metallb-operator.yaml
    retry_until 300 3 '[[ -n "$(oc get csv --no-headers -n metallb-system | grep metallb)" ]]' 'oc apply -f prerequisites/metallb/metallb-operator.yaml || true' || {
        echo "Timed out waiting for MetalLB CSV to exist"
        exit 1
    }
    METALLB_CSV=$(oc get csv --no-headers -n metallb-system | awk '/metallb/ { print $1 }')
    wait_for_resource clusterserviceversion/${METALLB_CSV} jsonpath='{.status.phase}'=Succeeded 300 metallb-system
    wait_for_resource deployment/metallb-operator-controller-manager condition=Available 300 metallb-system
    wait_for_resource deployment/metallb-operator-webhook-server condition=Available 300 metallb-system

    # Apply MetalLB CRD-based configuration (requires operator CRDs to be installed)
    oc apply -f prerequisites/metallb/metallb-config.yaml
fi

# Optionally install Multicluster Engine and infrastructure operator
if [[ "${MCE_SERVICE}" == "true" ]]; then
    wait_for_namespace_cleanup multicluster-engine
    echo "Installing Multicluster Engine..."
    oc apply -f prerequisites/mce/mce-operator.yaml
    retry_until 300 3 '[[ -n "$(oc get csv --no-headers -n multicluster-engine | grep multicluster-engine)" ]]' 'oc apply -f prerequisites/mce/mce-operator.yaml || true' || {
        echo "Timed out waiting for MCE CSV to exist"
        exit 1
    }
    MCE_CSV=$(oc get csv --no-headers -n multicluster-engine | awk '/multicluster-engine/ { print $1 }')
    wait_for_resource clusterserviceversion/${MCE_CSV} jsonpath='{.status.phase}'=Succeeded 600 multicluster-engine

    # Create MultiClusterEngine if one doesn't already exist (only one instance is allowed)
    if [[ -z "$(oc get multiclusterengine --no-headers 2>/dev/null)" ]]; then
        cat <<EOF | oc apply -f -
apiVersion: multicluster.openshift.io/v1
kind: MultiClusterEngine
metadata:
  name: multiclusterengine
spec: {}
EOF
    fi

    # Wait for MultiClusterEngine to be available
    MCE_NAME=$(oc get multiclusterengine -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    retry_until 600 10 '[[ "$(oc get multiclusterengine '"${MCE_NAME}"' -o jsonpath='"'"'{.status.phase}'"'"' 2>/dev/null)" == "Available" ]]' || {
        echo "Timed out waiting for MultiClusterEngine to be Available"
        exit 1
    }

    # Apply AgentServiceConfig (retry in case webhooks are not ready yet)
    retry_until 60 5 'oc apply -f prerequisites/mce/mce-config.yaml 2>/dev/null' || {
        echo "Failed to apply AgentServiceConfig"
        exit 1
    }

    # Wait for AgentServiceConfig deployment (infrastructure operator)
    echo "Waiting for infrastructure operator (assisted-service) to be ready..."
    wait_for_resource deployment/assisted-service condition=Available 600 multicluster-engine
fi

# Optionally install OpenShift Virtualization
if [[ "${VIRT_SERVICE}" == "true" ]]; then
    wait_for_namespace_cleanup openshift-cnv
    echo "Installing OpenShift Virtualization..."
    oc apply -f prerequisites/cnv/cnv-operator.yaml
    retry_until 300 3 '[[ -n "$(oc get csv --no-headers -n openshift-cnv | grep kubevirt-hyperconverged-operator)" ]]' 'oc apply -f prerequisites/cnv/cnv-operator.yaml || true' || {
        echo "Timed out waiting for OpenShift Virtualization CSV to exist"
        exit 1
    }
    CNV_CSV=$(oc get csv --no-headers -n openshift-cnv | awk '/kubevirt-hyperconverged-operator/ { print $1 }' | tail -1)
    wait_for_resource clusterserviceversion/${CNV_CSV} jsonpath='{.status.phase}'=Succeeded 600 openshift-cnv

    # Delete stale sub-CRs from previous installs that may block HyperConverged
    for cr in cdi kubevirt ssp; do
        for name in $(oc get "${cr}" -n openshift-cnv --no-headers -o name 2>/dev/null); do
            phase=$(oc get "${name}" -n openshift-cnv -o jsonpath='{.status.phase}' 2>/dev/null)
            if [[ "${phase}" == "Error" ]]; then
                echo "Deleting stale ${name} in Error phase..."
                oc delete "${name}" -n openshift-cnv --timeout=30s 2>/dev/null || \
                    oc patch "${name}" -n openshift-cnv --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
            fi
        done
    done

    # Apply HyperConverged CR (retry in case webhooks are not ready yet)
    retry_until 60 5 'oc apply -f prerequisites/cnv/cnv-config.yaml 2>/dev/null' || {
        echo "Failed to apply HyperConverged CR"
        exit 1
    }

    # Wait for HyperConverged to be available
    echo "Waiting for OpenShift Virtualization to be ready (this may take up to 10 minutes)..."
    retry_until 900 10 '[[ "$(oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv -o jsonpath='"'"'{.status.conditions[?(@.type=="Available")].status}'"'"' 2>/dev/null)" == "True" ]]' || {
        echo "Timed out waiting for HyperConverged to be Available"
        exit 1
    }
fi

# Apply cert-manager prerequisites and wait for it to be ready
oc apply -k prerequisites/cert-manager
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
wait_for_namespace_cleanup keycloak
oc apply -k prerequisites/keycloak/
wait_for_resource deployment/keycloak-service condition=Available 600 keycloak

# Apply AAP prerequisites and wait for it to be ready
wait_for_namespace_cleanup ansible-aap
oc apply -f prerequisites/aap-installation.yaml
retry_until 300 3 '[[ -n "$(oc get csv --no-headers -n ansible-aap | grep aap)" ]]' 'oc apply -f prerequisites/aap-installation.yaml || true' || {
    echo "Timed out waiting for AAP CSV to exist"
    exit 1
}
AAP_CSV=$(oc get csv --no-headers -n ansible-aap | awk '/aap/ { print $1 }')
wait_for_resource clusterserviceversion/${AAP_CSV} jsonpath='{.status.phase}'=Succeeded 300 ansible-aap
wait_for_resource deployment/automation-controller-operator-controller-manager condition=Available 300 ansible-aap

# Wait for OSAC namespace to finish terminating if needed
wait_for_namespace_cleanup "${INSTALLER_NAMESPACE}"

# Apply kustomize overlay
oc apply -k overlays/${INSTALLER_KUSTOMIZE_OVERLAY}

# Wait for AAP bootstrap job to complete
echo "Waiting for AAP bootstrap job to complete (this may take up to 20 minutes)..."
wait_for_resource job/aap-bootstrap condition=complete 1200 ${INSTALLER_NAMESPACE}

# Update project context
oc project ${INSTALLER_NAMESPACE}

# Create AAP API token for the OSAC operator
./scripts/prepare-aap.sh

# Setup fulfillment CLI, register hub
./scripts/prepare-fulfillment-service.sh

# Prepare tenant
./scripts/prepare-tenant.sh

echo ""
echo "=== Setup complete ==="

#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

command -v helm &>/dev/null || { echo "Error: helm not found in PATH" >&2; exit 1; }

VALUES_FILE=${VALUES_FILE:-"values/development/values.yaml"}
INSTALLER_NAMESPACE=${INSTALLER_NAMESPACE:-"osac"}
INSTALLER_VM_TEMPLATE=${INSTALLER_VM_TEMPLATE:-}
# EXTRA_SERVICES=true enables all optional services (storage, ingress, virtualization, MCE)
EXTRA_SERVICES=${EXTRA_SERVICES:-"false"}
INGRESS_SERVICE=${INGRESS_SERVICE:-${EXTRA_SERVICES}}
STORAGE_SERVICE=${STORAGE_SERVICE:-${EXTRA_SERVICES}}
VIRT_SERVICE=${VIRT_SERVICE:-${EXTRA_SERVICES}}
MCE_SERVICE=${MCE_SERVICE:-${EXTRA_SERVICES}}

# Setup phase: "all" (default), "prerequisites" (infra operators only), or "deploy" (skip infra operators)
SETUP_PHASE=${SETUP_PHASE:-"all"}

echo "=== Setting up OSAC deployment ==="
echo "Values file: ${VALUES_FILE}"
echo "Namespace: ${INSTALLER_NAMESPACE}"
echo "Setup phase: ${SETUP_PHASE}"
echo ""

if [[ "${SETUP_PHASE}" == "all" || "${SETUP_PHASE}" == "prerequisites" ]]; then

# Optionally install LVMS as storage service (must be before keycloak which needs a default storage class)
if [[ "${STORAGE_SERVICE}" == "true" ]]; then
    wait_for_namespace_cleanup openshift-storage
    echo "Installing LVMS storage service..."
    retry_until 300 3 '[[ -n "$(oc get csv --no-headers -n openshift-storage | grep lvms)" ]]' 'oc apply -f prerequisites/lvms/lvms-operator.yaml || true' || {
        echo "Timed out waiting for LVMS CSV to exist"
        exit 1
    }
    LVMS_CSV=$(oc get csv --no-headers -n openshift-storage | awk '/lvms/ { print $1 }' | tail -1)
    wait_for_resource clusterserviceversion/${LVMS_CSV} jsonpath='{.status.phase}'=Succeeded 600 openshift-storage
    wait_for_resource deployment/lvms-operator condition=Available 900 openshift-storage

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
    retry_until 300 3 '[[ -n "$(oc get csv --no-headers -n metallb-system | grep metallb)" ]]' 'oc apply -f prerequisites/metallb/metallb-operator.yaml || true' || {
        echo "Timed out waiting for MetalLB CSV to exist"
        exit 1
    }
    METALLB_CSV=$(oc get csv --no-headers -n metallb-system | awk '/metallb/ { print $1 }' | tail -1)
    wait_for_resource clusterserviceversion/${METALLB_CSV} jsonpath='{.status.phase}'=Succeeded 300 metallb-system
    wait_for_resource deployment/metallb-operator-controller-manager condition=Available 300 metallb-system
    wait_for_resource deployment/metallb-operator-webhook-server condition=Available 300 metallb-system

    # Apply MetalLB CRD-based configuration (requires operator CRDs to be installed)
    oc apply -f prerequisites/metallb/metallb-config.yaml

    # Patch IPAddressPool with address range matching this cluster's node subnet.
    NODE_IP=$(oc get nodes -o 'jsonpath={.items[0].status.addresses[?(@.type=="InternalIP")].address}')
    SUBNET_PREFIX="${NODE_IP%.*}"
    echo "Patching MetalLB address pool: ${SUBNET_PREFIX}.240-${SUBNET_PREFIX}.250"
    oc patch ipaddresspool caas-address-pool -n metallb-system --type=merge \
        -p "{\"spec\":{\"addresses\":[\"${SUBNET_PREFIX}.240-${SUBNET_PREFIX}.250\"]}}"
fi

# Optionally install Multicluster Engine and infrastructure operator
if [[ "${MCE_SERVICE}" == "true" ]]; then
    wait_for_namespace_cleanup multicluster-engine
    echo "Installing Multicluster Engine..."
    retry_until 300 3 '[[ -n "$(oc get csv --no-headers -n multicluster-engine | grep multicluster-engine)" ]]' 'oc apply -f prerequisites/mce/mce-operator.yaml || true' || {
        echo "Timed out waiting for MCE CSV to exist"
        exit 1
    }
    MCE_CSV=$(oc get csv --no-headers -n multicluster-engine | awk '/multicluster-engine/ { print $1 }' | tail -1)
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

fi # end SETUP_PHASE == all|prerequisites

if [[ "${SETUP_PHASE}" == "prerequisites" ]]; then
    echo ""
    echo "=== Infrastructure prerequisites installed ==="
    exit 0
fi

# Apply cert-manager prerequisites and wait for it to be ready
CERT_MANAGER_NS=""
if oc get deployment cert-manager -n cert-manager &>/dev/null; then
    CERT_MANAGER_NS="cert-manager"
elif oc get deployment cert-manager -n openshift-operators &>/dev/null; then
    CERT_MANAGER_NS="openshift-operators"
fi

if [[ -n "${CERT_MANAGER_NS}" ]]; then
    echo "cert-manager is already installed in ${CERT_MANAGER_NS}, skipping..."
else
    CERT_MANAGER_NS="cert-manager"
    retry_until 300 3 '[[ -n "$(oc get crd --ignore-not-found certmanagers.operator.openshift.io)" ]]' 'oc apply -f prerequisites/cert-manager/cert-manager.yaml || true' || {
        echo "Timed out waiting for cert-manager CRD to exist"
        exit 1
    }
fi
wait_for_resource deployment/cert-manager condition=Available 300 ${CERT_MANAGER_NS}
wait_for_resource deployment/cert-manager-webhook condition=Available 300 ${CERT_MANAGER_NS}
wait_for_resource deployment/cert-manager-cainjector condition=Available 300 ${CERT_MANAGER_NS}

# Apply trust-manager prerequisites and wait for it to be ready
if oc get deployment trust-manager -n ${CERT_MANAGER_NS} &>/dev/null; then
    echo "trust-manager is already installed in ${CERT_MANAGER_NS}, skipping..."
else
    retry_until 60 5 'oc apply -f prerequisites/trust-manager.yaml 2>/dev/null' || {
        echo "Failed to apply trust-manager prerequisites"
        exit 1
    }
fi
wait_for_resource deployment/trust-manager condition=Available 300 ${CERT_MANAGER_NS}

# Apply CA issuer prerequisites and wait for it to be ready
retry_until 60 5 'oc apply -f prerequisites/ca-issuer.yaml 2>/dev/null' || {
    echo "Failed to apply CA issuer prerequisites"
    exit 1
}
wait_for_resource clusterissuer/default-ca condition=Ready 300

# Apply keycloak prerequisites and wait for it to be ready
KEYCLOAK_NS=""
if oc get deployment keycloak-service -n keycloak &>/dev/null; then
    KEYCLOAK_NS="keycloak"
elif oc get deployment keycloak-service -n openshift-operators &>/dev/null; then
    KEYCLOAK_NS="openshift-operators"
fi

if [[ -n "${KEYCLOAK_NS}" ]]; then
    echo "Keycloak is already installed in ${KEYCLOAK_NS}, skipping..."
else
    KEYCLOAK_NS="keycloak"
    wait_for_namespace_cleanup keycloak
    oc apply -f prerequisites/keycloak/namespace.yaml
    oc create configmap keycloak-db-server-config \
        --from-file=server.conf=prerequisites/keycloak/database/files/server.conf \
        -n keycloak --dry-run=client -o yaml | oc apply -f -
    oc create configmap keycloak-db-access-config \
        --from-file=access.conf=prerequisites/keycloak/database/files/access.conf \
        -n keycloak --dry-run=client -o yaml | oc apply -f -
    oc create configmap keycloak-realm \
        --from-file=realm.json=prerequisites/keycloak/service/files/realm.json \
        -n keycloak --dry-run=client -o yaml | oc apply -f -
    oc apply -f prerequisites/keycloak/database/ -n keycloak
    oc apply -f prerequisites/keycloak/service/ -n keycloak
fi
wait_for_resource deployment/keycloak-service condition=Available 600 ${KEYCLOAK_NS}

# Apply AAP prerequisites and wait for it to be ready
AAP_NS=""
if oc get deployment automation-controller-operator-controller-manager -n aap &>/dev/null; then
    AAP_NS="aap"
elif oc get deployment automation-controller-operator-controller-manager -n ansible-aap &>/dev/null; then
    AAP_NS="ansible-aap"
elif oc get deployment automation-controller-operator-controller-manager -n openshift-operators &>/dev/null; then
    AAP_NS="openshift-operators"
fi

if [[ -n "${AAP_NS}" ]]; then
    echo "AAP operator is already installed in namespace ${AAP_NS}, skipping..."
else
    AAP_NS="ansible-aap"
    wait_for_namespace_cleanup ansible-aap
    oc apply -f prerequisites/aap-installation.yaml
    retry_until 300 3 '[[ -n "$(oc get csv --no-headers -n ansible-aap | grep aap)" ]]' 'oc apply -f prerequisites/aap-installation.yaml || true' || {
        echo "Timed out waiting for AAP CSV to exist"
        exit 1
    }
fi
AAP_CSV=$(oc get csv --no-headers -n ${AAP_NS} | awk '/aap/ { print $1 }' | tail -1)
wait_for_resource clusterserviceversion/${AAP_CSV} jsonpath='{.status.phase}'=Succeeded 300 ${AAP_NS}
wait_for_resource deployment/automation-controller-operator-controller-manager condition=Available 300 ${AAP_NS}

# Wait for OSAC namespace to finish terminating if needed
wait_for_namespace_cleanup "${INSTALLER_NAMESPACE}"

# Create the namespace early so pre-deploy resources can target it.
oc create namespace "${INSTALLER_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

# Ensure the shared ca-bundle Bundle exists and the ConfigMap is populated.
"${SCRIPT_DIR}/ensure-ca-bundle.sh" "${INSTALLER_NAMESPACE}"
echo "Waiting for ca-bundle ConfigMap..."
retry_until 120 3 'oc get configmap ca-bundle -n '"${INSTALLER_NAMESPACE}"' -o jsonpath='"'"'{.data.bundle\.pem}'"'"' 2>/dev/null | grep -q "BEGIN CERTIFICATE"'

# Create controller OAuth credentials from the Keycloak realm config.
FC_CLIENT_SECRET=$(jq -er '.clients[] | select(.clientId == "osac-controller") | .secret // empty' prerequisites/keycloak/service/files/realm.json || true)
[[ -n "${FC_CLIENT_SECRET}" ]] || { echo "ERROR: Could not resolve secret for osac-controller in realm.json" >&2; exit 1; }
oc create secret generic fulfillment-controller-credentials \
    --from-literal=client-id=osac-controller \
    --from-literal=client-secret="${FC_CLIENT_SECRET}" \
    -n "${INSTALLER_NAMESPACE}" \
    --dry-run=client -o yaml | oc apply -f -

# In-cluster PostgreSQL must exist before Helm install (operator-managed per
# INSTALL.md). Creates fulfillment-db and postgres-client-cert-service secrets
# separately, or enable bundledPostgres in values for secret auto-generation.
maybe_deploy_ci_postgres "${INSTALLER_NAMESPACE}" "${VALUES_FILE}"
check_postgres_prerequisites "${INSTALLER_NAMESPACE}" "${VALUES_FILE}"

# Create AAP license secret (required by the bootstrap job).
VALUES_DIR="$(dirname "${VALUES_FILE}")"
AAP_LICENSE_FILE=${AAP_LICENSE_FILE:-"${VALUES_DIR}/license.zip"}
if [[ -f "${AAP_LICENSE_FILE}" ]]; then
    echo "Creating config-as-code-manifest-ig secret from ${AAP_LICENSE_FILE}..."
    oc create secret generic config-as-code-manifest-ig \
        --from-file=license.zip="${AAP_LICENSE_FILE}" \
        -n "${INSTALLER_NAMESPACE}" \
        --dry-run=client -o yaml | oc apply -f -
    oc label secret config-as-code-manifest-ig \
        osac.openshift.io/project=osac-aap \
        -n "${INSTALLER_NAMESPACE}" --overwrite
else
    echo "WARNING: AAP license file not found at ${AAP_LICENSE_FILE}"
    echo "The AAP bootstrap job will fail without it."
    echo "Set AAP_LICENSE_FILE or place license.zip in ${VALUES_DIR}/"
fi

# Create AAP config-as-code secret (EE image, git URI, git branch).
# Values can be overridden via environment variables.
AAP_EE_IMAGE=${AAP_EE_IMAGE:-"ghcr.io/osac-project/osac-aap:latest"}
AAP_PROJECT_GIT_URI=${AAP_PROJECT_GIT_URI:-"https://github.com/osac-project/osac-aap"}
AAP_PROJECT_GIT_BRANCH=${AAP_PROJECT_GIT_BRANCH:-"main"}
echo "Creating config-as-code-ig secret..."
oc create secret generic config-as-code-ig \
    --from-literal=AAP_EE_IMAGE="${AAP_EE_IMAGE}" \
    --from-literal=AAP_PROJECT_GIT_URI="${AAP_PROJECT_GIT_URI}" \
    --from-literal=AAP_PROJECT_GIT_BRANCH="${AAP_PROJECT_GIT_BRANCH}" \
    -n "${INSTALLER_NAMESPACE}" \
    --dry-run=client -o yaml | oc apply -f -

# Label pre-created resources for Helm adoption.
echo "Labeling pre-created resources for Helm adoption..."
for resource in \
    secret/config-as-code-ig \
    secret/config-as-code-manifest-ig \
    secret/fulfillment-controller-credentials \
    secret/fulfillment-db; do
  if oc get "${resource}" -n "${INSTALLER_NAMESPACE}" &>/dev/null; then
    oc label "${resource}" -n "${INSTALLER_NAMESPACE}" \
        app.kubernetes.io/managed-by=Helm --overwrite
    oc annotate "${resource}" -n "${INSTALLER_NAMESPACE}" \
        meta.helm.sh/release-name=osac \
        meta.helm.sh/release-namespace="${INSTALLER_NAMESPACE}" --overwrite
  fi
done

echo "Deploying OSAC using Helm..."
CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
EXTERNAL_HOSTNAME="fulfillment-api-${INSTALLER_NAMESPACE}.${CLUSTER_DOMAIN}"
INTERNAL_HOSTNAME="fulfillment-internal-api-${INSTALLER_NAMESPACE}.${CLUSTER_DOMAIN}"
helm dependency update charts/osac/
helm upgrade --install osac charts/osac/ \
    --namespace "${INSTALLER_NAMESPACE}" \
    --values "${VALUES_FILE}" \
    --set "service.externalHostname=${EXTERNAL_HOSTNAME}" \
    --set "service.internalHostname=${INTERNAL_HOSTNAME}" \
    --timeout 40m \
    --wait

# Apply cluster-fulfillment-ig configmap/secret overrides from environment variables
INSTALLER_NAMESPACE="${INSTALLER_NAMESPACE}" \
    ./scripts/aap-configuration.sh

CONSOLE_PROXY_NS="${INSTALLER_NAMESPACE}"
CONSOLE_PROXY_DEPLOY="fulfillment-console-proxy"
wait_for_resource deployment/${CONSOLE_PROXY_DEPLOY} condition=Available 300 "${CONSOLE_PROXY_NS}"

# Wait for AAP bootstrap job to complete.
# helm --wait does not wait for hook jobs, so we must wait explicitly.
echo "Waiting for AAP bootstrap job to complete (this may take up to 40 minutes)..."
wait_for_resource job/osac-aap-bootstrap condition=complete 2400 "${INSTALLER_NAMESPACE}"

# Wait for fulfillment stack to be ready before running prepare scripts
wait_for_resource deployment/fulfillment-grpc-server condition=Available 300 ${INSTALLER_NAMESPACE}
wait_for_resource deployment/fulfillment-ingress-proxy condition=Available 300 ${INSTALLER_NAMESPACE}

# Update project context
oc project ${INSTALLER_NAMESPACE}

# Create AAP API token for the OSAC operator
INSTALLER_NAMESPACE="${INSTALLER_NAMESPACE}" ./scripts/prepare-aap.sh

# Setup OSAC CLI, register hub
INSTALLER_NAMESPACE="${INSTALLER_NAMESPACE}" ./scripts/prepare-fulfillment-service.sh

# Prepare tenant
INSTALLER_NAMESPACE="${INSTALLER_NAMESPACE}" ./scripts/prepare-tenant.sh

echo ""
echo "=== Setup complete ==="

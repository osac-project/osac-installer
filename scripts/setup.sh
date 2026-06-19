#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

# Deploy mode: "helm" (default) or "kustomize" (legacy)
DEPLOY_MODE=${DEPLOY_MODE:-"helm"}
if [[ "${DEPLOY_MODE}" == "helm" ]]; then
    # Ensure helm is installed
    command -v helm &>/dev/null || { echo "Error: helm not found in PATH" >&2; exit 1; }
fi

INSTALLER_KUSTOMIZE_OVERLAY=${INSTALLER_KUSTOMIZE_OVERLAY:-"development"}
VALUES_FILE=${VALUES_FILE:-"values/development/values.yaml"}

if [[ "${DEPLOY_MODE}" == "kustomize" ]]; then
    INSTALLER_NAMESPACE=${INSTALLER_NAMESPACE:-$(grep "^namespace:" "overlays/${INSTALLER_KUSTOMIZE_OVERLAY}/kustomization.yaml" | awk '{print $2}')}
    [[ -z "${INSTALLER_NAMESPACE}" ]] && echo "ERROR: Could not determine namespace from overlays/${INSTALLER_KUSTOMIZE_OVERLAY}/kustomization.yaml" && exit 1
else
    INSTALLER_NAMESPACE=${INSTALLER_NAMESPACE:-"osac"}
fi

INSTALLER_VM_TEMPLATE=${INSTALLER_VM_TEMPLATE:-}
# EXTRA_SERVICES=true enables all optional services (storage, ingress, virtualization, MCE)
EXTRA_SERVICES=${EXTRA_SERVICES:-"false"}
INGRESS_SERVICE=${INGRESS_SERVICE:-${EXTRA_SERVICES}}
STORAGE_SERVICE=${STORAGE_SERVICE:-${EXTRA_SERVICES}}
VIRT_SERVICE=${VIRT_SERVICE:-${EXTRA_SERVICES}}
MCE_SERVICE=${MCE_SERVICE:-${EXTRA_SERVICES}}

echo "=== Setting up OSAC deployment ==="
echo "Deploy mode: ${DEPLOY_MODE}"
if [[ "${DEPLOY_MODE}" == "kustomize" ]]; then
    echo "Overlay: ${INSTALLER_KUSTOMIZE_OVERLAY}"
else
    echo "Values file: ${VALUES_FILE}"
fi
echo "Namespace: ${INSTALLER_NAMESPACE}"
echo ""

# Optionally install LVMS as storage service (must be before keycloak which needs a default storage class)
if [[ "${STORAGE_SERVICE}" == "true" ]]; then
    wait_for_namespace_cleanup openshift-storage
    echo "Installing LVMS storage service..."
    retry_until 300 3 '[[ -n "$(oc get csv --no-headers -n openshift-storage | grep lvms)" ]]' 'oc apply -f prerequisites/lvms/lvms-operator.yaml || true' || {
        echo "Timed out waiting for LVMS CSV to exist"
        exit 1
    }
    LVMS_CSV=$(oc get csv --no-headers -n openshift-storage | awk '/lvms/ { print $1 }' | tail -1)
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
    retry_until 300 3 '[[ -n "$(oc get crd --ignore-not-found certmanagers.operator.openshift.io)" ]]' 'oc apply -k prerequisites/cert-manager || true' || {
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

# Apply authorino prerequisites and wait for it to be ready
if oc get deployment authorino-operator -n openshift-operators &>/dev/null; then
    echo "Authorino operator is already installed, skipping..."
else
    oc apply -f prerequisites/authorino-operator.yaml
    retry_until 300 3 '[[ -n "$(oc get csv --no-headers -n openshift-operators | grep authorino)" ]]' 'oc apply -f prerequisites/authorino-operator.yaml || true' || {
        echo "Timed out waiting for authorino CSV to exist"
        exit 1
    }
fi
AUTHORINO_CSV=$(oc get csv --no-headers -n openshift-operators | awk '/authorino/ { print $1 }' | tail -1)
wait_for_resource clusterserviceversion/${AUTHORINO_CSV} jsonpath='{.status.phase}'=Succeeded 300 openshift-operators
wait_for_resource deployment/authorino-operator condition=Available 300 openshift-operators

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
    oc apply -k prerequisites/keycloak/
fi
wait_for_resource deployment/keycloak-service condition=Available 600 ${KEYCLOAK_NS}

# Apply AAP prerequisites and wait for it to be ready
AAP_NS=""
if oc get deployment automation-controller-operator-controller-manager -n aap &>/dev/null; then
    AAP_NS="aap"
elif oc get deployment automation-controller-operator-controller-manager -n ansible-aap &>/dev/null; then
    AAP_NS="ansible-aap"
elif oc get deployment automation-controller-operator-controller-manager -n aap &>/dev/null; then
    AAP_NS="aap"
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

if [[ "${DEPLOY_MODE}" == "helm" ]]; then
    # --- Helm deployment mode ---
    #
    # helm --wait blocks until all pods are Ready. Several resources that pods
    # mount as required volumes must exist before the install starts.

    # Create the namespace early so pre-deploy resources can target it.
    oc create namespace "${INSTALLER_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

    # Ensure the shared ca-bundle Bundle exists and the ConfigMap is populated.
    "${SCRIPT_DIR}/ensure-ca-bundle.sh" "${INSTALLER_NAMESPACE}"
    echo "Waiting for ca-bundle ConfigMap..."
    retry_until 120 3 'oc get configmap ca-bundle -n '"${INSTALLER_NAMESPACE}"' -o jsonpath='"'"'{.data.bundle\.pem}'"'"' 2>/dev/null | grep -q "BEGIN CERTIFICATE"'

    # Create controller OAuth credentials from the Keycloak realm config.
    FC_CLIENT_SECRET=$(jq -er '.clients[] | select(.clientId == "osac-controller") | .secret // empty' prerequisites/keycloak/service/files/realm.json)
    [[ -n "${FC_CLIENT_SECRET}" ]] || { echo "ERROR: Could not resolve secret for osac-controller in realm.json" >&2; exit 1; }
    oc create secret generic fulfillment-controller-credentials \
        --from-literal=client-id=osac-controller \
        --from-literal=client-secret="${FC_CLIENT_SECRET}" \
        -n "${INSTALLER_NAMESPACE}" \
        --dry-run=client -o yaml | oc apply -f -

    # Deploy the fulfillment database. The fulfillment-service chart expects an
    # external PostgreSQL with connection details in 'fulfillment-db' and client
    # TLS in 'postgres-client-cert-service'.
    echo "Deploying fulfillment database..."
    helm upgrade --install fulfillment-db \
        base/osac-fulfillment-service/it/charts/postgres/ \
        --namespace "${INSTALLER_NAMESPACE}" \
        --set certs.issuerRef.name=default-ca \
        --set certs.caBundle.configMap=ca-bundle \
        --set 'databases[0].name=service' \
        --set 'databases[0].user=service' \
        --timeout 5m \
        --wait

    # Create client certificate for the 'service' database user.
    # The postgres chart does not generate per-user client certs yet.
    oc apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  namespace: ${INSTALLER_NAMESPACE}
  name: postgres-client-cert-service
spec:
  issuerRef:
    kind: ClusterIssuer
    name: default-ca
  commonName: service
  usages:
  - client auth
  secretName: postgres-client-cert-service
  privateKey:
    rotationPolicy: Always
EOF
    oc wait certificate/postgres-client-cert-service -n "${INSTALLER_NAMESPACE}" --for=condition=Ready --timeout=60s

    # Create the connection secret for the fulfillment gRPC server.
    DB_URL="postgres://service@postgres:5432/service?sslmode=verify-full"
    DB_URL+="&sslcert=/etc/fulfillment-grpc-server/db/sslcert"
    DB_URL+="&sslkey=/etc/fulfillment-grpc-server/db/sslkey"
    DB_URL+="&sslrootcert=/etc/fulfillment-grpc-server/db/sslrootcert"
    oc create secret generic fulfillment-db \
        --from-literal=url="${DB_URL}" \
        -n "${INSTALLER_NAMESPACE}" \
        --dry-run=client -o yaml | oc apply -f -

    # Create AAP license secret (required by the bootstrap job).
    # In kustomize mode this is handled by secretGenerator; in Helm mode we
    # must create it explicitly. The license.zip can be provided via:
    #   1. AAP_LICENSE_FILE env var (absolute path)
    #   2. overlays/<overlay>/files/license.zip (default convention)
    AAP_LICENSE_FILE=${AAP_LICENSE_FILE:-"overlays/${INSTALLER_KUSTOMIZE_OVERLAY}/files/license.zip"}
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
        echo "Set AAP_LICENSE_FILE or place license.zip in overlays/${INSTALLER_KUSTOMIZE_OVERLAY}/files/"
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
else
    # --- Kustomize deployment mode (legacy) ---
    echo "Deploying OSAC using Kustomize..."
    oc apply -k "overlays/${INSTALLER_KUSTOMIZE_OVERLAY}" --server-side --force-conflicts

    # Ensure the shared ca-bundle Bundle exists and includes our namespace
    "${SCRIPT_DIR}/ensure-ca-bundle.sh" "${INSTALLER_NAMESPACE}"

    # Create controller OAuth credentials from the Keycloak realm config
    FC_CLIENT_SECRET=$(jq -er '.clients[] | select(.clientId == "osac-controller") | .secret // empty' prerequisites/keycloak/service/files/realm.json)
    [[ -n "${FC_CLIENT_SECRET}" ]] || { echo "ERROR: Could not resolve secret for osac-controller in realm.json" >&2; exit 1; }
    oc create secret generic fulfillment-controller-credentials \
        --from-literal=client-id=osac-controller \
        --from-literal=client-secret="${FC_CLIENT_SECRET}" \
        -n "${INSTALLER_NAMESPACE}" \
        --dry-run=client -o yaml | oc apply -f -
fi

# Apply cluster-fulfillment-ig configmap/secret overrides from environment variables
INSTALLER_NAMESPACE="${INSTALLER_NAMESPACE}" \
INSTALLER_KUSTOMIZE_OVERLAY="${INSTALLER_KUSTOMIZE_OVERLAY}" \
    ./scripts/aap-configuration.sh

# Detect console-proxy namespace (shared-dev pins it to "osac")
if grep -q 'console-proxy-shared-dev' \
    "overlays/${INSTALLER_KUSTOMIZE_OVERLAY}/kustomization.yaml" 2>/dev/null; then
  CONSOLE_PROXY_NS="osac"
else
  CONSOLE_PROXY_NS="${INSTALLER_NAMESPACE}"
fi
wait_for_resource deployment/osac-console-proxy condition=Available 300 "${CONSOLE_PROXY_NS}"

# Wait for AAP bootstrap job to complete.
# In kustomize mode, the job is named "aap-bootstrap".
# In helm mode, the job is a post-install hook named "osac-aap-bootstrap".
# helm --wait does not wait for hook jobs, so we must wait explicitly.
echo "Waiting for AAP bootstrap job to complete (this may take up to 40 minutes)..."
if [[ "${DEPLOY_MODE}" == "kustomize" ]]; then
    wait_for_resource job/aap-bootstrap condition=complete 2400 "${INSTALLER_NAMESPACE}"
else
    wait_for_resource job/osac-aap-bootstrap condition=complete 2400 "${INSTALLER_NAMESPACE}"
fi

# Wait for Authorino to be ready (gRPC auth depends on it)
wait_for_resource deployment/authorino condition=Available 300 ${INSTALLER_NAMESPACE}

# Ensure Authorino can perform token reviews (required for Kubernetes SA authentication)
if oc get clusterrolebinding authorino-tokenreview &>/dev/null; then
    if ! oc get clusterrolebinding authorino-tokenreview -o json | \
        jq -e '.subjects[] | select(.name=="authorino-authorino" and .namespace=="'"${INSTALLER_NAMESPACE}"'")' &>/dev/null; then
        echo "Adding ${INSTALLER_NAMESPACE} Authorino SA to authorino-tokenreview ClusterRoleBinding..."
        oc patch clusterrolebinding authorino-tokenreview --type=json \
            -p '[{"op":"add","path":"/subjects/-","value":{"kind":"ServiceAccount","name":"authorino-authorino","namespace":"'"${INSTALLER_NAMESPACE}"'"}}]'
    fi
fi

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

#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

INSTALLER_KUSTOMIZE_OVERLAY=${INSTALLER_KUSTOMIZE_OVERLAY:-"development"}
INSTALLER_NAMESPACE=${INSTALLER_NAMESPACE:-$(grep "^namespace:" "overlays/${INSTALLER_KUSTOMIZE_OVERLAY}/kustomization.yaml" | awk '{print $2}')}
[[ -z "${INSTALLER_NAMESPACE}" ]] && echo "ERROR: Could not determine namespace from overlays/${INSTALLER_KUSTOMIZE_OVERLAY}/kustomization.yaml" && exit 1

OVERLAY_FILES="overlays/${INSTALLER_KUSTOMIZE_OVERLAY}/files"
CONFIG_FILE="${OVERLAY_FILES}/osac-aap-configuration.env"
SECRETS_FILE="${OVERLAY_FILES}/osac-aap-secrets.env"

# Source env files. Shell environment variables take precedence (set -a exports
# only new variables; existing ones are not overwritten by source).
load_env_file() {
    local file="$1"
    if [[ ! -f "${file}" ]]; then
        return
    fi
    echo "Loading ${file}..."
    while IFS='=' read -r key value; do
        key="${key%%#*}"
        key="${key// /}"
        [[ -z "${key}" ]] && continue
        if [[ "${value}" =~ ^\"(.*)\"$ ]] || [[ "${value}" =~ ^\'(.*)\'$ ]]; then
            value="${BASH_REMATCH[1]}"
        fi
        value="${value//\\n/$'\n'}"
        if [[ -z "${!key:-}" ]]; then
            export "${key}=${value}"
        fi
    done < <(grep -v '^\s*#' "${file}" | grep -v '^\s*$')
}

load_env_file "${CONFIG_FILE}"
load_env_file "${SECRETS_FILE}"

CM_VARS=(
    NETWORK_CLASS NETWORK_STEPS_COLLECTION
    EXTERNAL_ACCESS_BASE_DOMAIN EXTERNAL_ACCESS_SUPPORTED_BASE_DOMAINS
    EXTERNAL_ACCESS_API_INTERNAL_NETWORK
    HOSTED_CLUSTER_BASE_DOMAIN
    HOSTED_CLUSTER_CONTROLLER_AVAILABILITY_POLICY
    HOSTED_CLUSTER_INFRASTRUCTURE_AVAILABILITY_POLICY
    NETRIS_CONTROLLER_URL NETRIS_USERNAME
    NETRIS_SITE_ID NETRIS_TENANT_ID NETRIS_TENANT_NAME
    NETRIS_MGMT_VPC_ID NETRIS_MGMT_VPC_NAME
    NETRIS_RESOURCE_CLASS_MAP
    SERVER_MGMT_ROUTE_DESTINATION SERVER_MGMT_ROUTE_GATEWAY
    SERVER_SSH_BASTION_HOST SERVER_SSH_BASTION_USER SERVER_SSH_USER
)

SECRET_VARS=(
    NETRIS_PASSWORD
    AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
)

# SSH keys are read from files rather than env vars so that multi-line
# PEM content does not need to be collapsed into a single line.
SSH_KEY_FILES=(
    "SERVER_SSH_KEY=server-ssh-key"
    "SERVER_SSH_BASTION_KEY=server-ssh-bastion-key"
)

# --- ConfigMap overrides ---
patch_file=$(mktemp)
has_cm_overrides=false

echo "data:" > "${patch_file}"
for var in "${CM_VARS[@]}"; do
    if [[ -n "${!var:-}" ]]; then
        escaped="${!var//\'/\'\'}"
        printf "  %s: '%s'\n" "${var}" "${escaped}" >> "${patch_file}"
        has_cm_overrides=true
    fi
done

if [[ "${has_cm_overrides}" == "true" ]]; then
    echo "Applying cluster-fulfillment-ig configmap overrides..."
    oc patch configmap/cluster-fulfillment-ig -n "${INSTALLER_NAMESPACE}" \
        --patch-file="${patch_file}" --type=merge
fi
rm -f "${patch_file}"

# --- Secret overrides ---
secret_patch=""
has_secret_overrides=false

for var in "${SECRET_VARS[@]}"; do
    if [[ -n "${!var:-}" ]]; then
        encoded=$(printf '%s' "${!var}" | base64 | tr -d '\n')
        [[ "${has_secret_overrides}" == "true" ]] && secret_patch+=","
        secret_patch+="\"${var}\":\"${encoded}\""
        has_secret_overrides=true
    fi
done

for entry in "${SSH_KEY_FILES[@]}"; do
    var="${entry%%=*}"
    filename="${entry#*=}"
    filepath="${OVERLAY_FILES}/${filename}"
    if [[ -f "${filepath}" ]]; then
        encoded=$(base64 < "${filepath}" | tr -d '\n')
        [[ "${has_secret_overrides}" == "true" ]] && secret_patch+=","
        secret_patch+="\"${var}\":\"${encoded}\""
        has_secret_overrides=true
    fi
done

if [[ "${has_secret_overrides}" == "true" ]]; then
    echo "Applying cluster-fulfillment-ig secret overrides..."
    oc patch secret/cluster-fulfillment-ig -n "${INSTALLER_NAMESPACE}" \
        -p "{\"data\":{${secret_patch}}}" --type=merge
fi

if [[ "${has_cm_overrides}" == "true" ]] || [[ "${has_secret_overrides}" == "true" ]]; then
    echo "cluster-fulfillment-ig configuration applied"
else
    echo "No cluster-fulfillment-ig overrides detected, using kustomize defaults"
fi

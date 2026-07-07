#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

INSTALLER_NAMESPACE=${INSTALLER_NAMESPACE:-"osac"}

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
    DNS_CLASS DNS_ZONE DNS_HOST
)

SECRET_VARS=(
    NETRIS_PASSWORD
    AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_SECRET
    OS_AUTH_TYPE OS_AUTH_URL
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

if [[ "${has_secret_overrides}" == "true" ]]; then
    echo "Applying cluster-fulfillment-ig secret overrides..."
    oc patch secret/cluster-fulfillment-ig -n "${INSTALLER_NAMESPACE}" \
        -p "{\"data\":{${secret_patch}}}" --type=merge
fi

if [[ "${has_cm_overrides}" == "true" ]] || [[ "${has_secret_overrides}" == "true" ]]; then
    echo "cluster-fulfillment-ig configuration applied"
else
    echo "No cluster-fulfillment-ig overrides detected, using Helm defaults"
fi

# --- network-fulfillment-ig ---
# The networking-operations-ig instance group uses a separate ConfigMap/Secret
# for Netris credentials. The values are sourced from environment variables.

NET_CM_VARS=(
    NETRIS_CONTROLLER_URL NETRIS_USERNAME
    NETRIS_SITE_ID NETRIS_TENANT_ID NETRIS_TENANT_NAME
)

NET_SECRET_VARS=(
    NETRIS_PASSWORD
)

net_patch_file=$(mktemp)
has_net_cm_overrides=false

echo "data:" > "${net_patch_file}"
for var in "${NET_CM_VARS[@]}"; do
    if [[ -n "${!var:-}" ]]; then
        escaped="${!var//\'/\'\'}"
        printf "  %s: '%s'\n" "${var}" "${escaped}" >> "${net_patch_file}"
        has_net_cm_overrides=true
    fi
done

if [[ "${has_net_cm_overrides}" == "true" ]]; then
    echo "Applying network-fulfillment-ig configmap overrides..."
    oc patch configmap/network-fulfillment-ig -n "${INSTALLER_NAMESPACE}" \
        --patch-file="${net_patch_file}" --type=merge
fi
rm -f "${net_patch_file}"

net_secret_patch=""
has_net_secret_overrides=false

for var in "${NET_SECRET_VARS[@]}"; do
    if [[ -n "${!var:-}" ]]; then
        encoded=$(printf '%s' "${!var}" | base64 | tr -d '\n')
        [[ "${has_net_secret_overrides}" == "true" ]] && net_secret_patch+=","
        net_secret_patch+="\"${var}\":\"${encoded}\""
        has_net_secret_overrides=true
    fi
done

if [[ "${has_net_secret_overrides}" == "true" ]]; then
    echo "Applying network-fulfillment-ig secret overrides..."
    oc patch secret/network-fulfillment-ig -n "${INSTALLER_NAMESPACE}" \
        -p "{\"data\":{${net_secret_patch}}}" --type=merge
fi

if [[ "${has_net_cm_overrides}" == "true" ]] || [[ "${has_net_secret_overrides}" == "true" ]]; then
    echo "network-fulfillment-ig configuration applied"
else
    echo "No network-fulfillment-ig overrides detected, using Helm defaults"
fi

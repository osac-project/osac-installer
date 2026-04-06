#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

INSTALLER_NAMESPACE=${INSTALLER_NAMESPACE:-"osac-devel"}

# Get the AAP gateway route URL
AAP_ROUTE_HOST=$(oc get routes -n ${INSTALLER_NAMESPACE} --no-headers | awk '$1 ~ /osac-aap/ {print $2; exit}')
AAP_URL="https://${AAP_ROUTE_HOST}"

# Get the AAP admin password
AAP_ADMIN_PASSWORD=$(oc get secret osac-aap-admin-password -n ${INSTALLER_NAMESPACE} -o jsonpath='{.data.password}' | base64 -d)

# Create an API token using basic auth against the AAP gateway
AAP_TOKEN=$(curl -sk -X POST \
    -u "admin:${AAP_ADMIN_PASSWORD}" \
    -H "Content-Type: application/json" \
    -d '{"description": "osac-operator", "scope": "write"}' \
    "${AAP_URL}/api/gateway/v1/tokens/" | jq -r '.token')

if [[ -z "${AAP_TOKEN}" || "${AAP_TOKEN}" == "null" ]]; then
    echo "Failed to create AAP API token"
    exit 1
fi

# Store the token in a Kubernetes secret
oc create secret generic osac-aap-api-token \
    --from-literal=token="${AAP_TOKEN}" \
    -n ${INSTALLER_NAMESPACE} \
    --dry-run=client -o yaml | oc apply -f -

# Set the correct AAP URL on the operator deployment (triggers rollout)
oc set env deployment/osac-operator-controller-manager \
    -n ${INSTALLER_NAMESPACE} \
    OSAC_AAP_URL="${AAP_URL}/api/controller"

echo "AAP API token created and stored in secret osac-aap-api-token"

#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

INSTALLER_KUSTOMIZE_OVERLAY=${INSTALLER_KUSTOMIZE_OVERLAY:-"development"}
INSTALLER_NAMESPACE=${INSTALLER_NAMESPACE:-$(grep "^namespace:" "overlays/${INSTALLER_KUSTOMIZE_OVERLAY}/kustomization.yaml" | awk '{print $2}')}
[[ -z "${INSTALLER_NAMESPACE}" ]] && echo "ERROR: Could not determine namespace from overlays/${INSTALLER_KUSTOMIZE_OVERLAY}/kustomization.yaml" && exit 1
INSTALLER_VM_TEMPLATE=${INSTALLER_VM_TEMPLATE:-}

# Create hub access kubeconfig
./scripts/create-hub-access-kubeconfig.sh

# Login to fulfillment internal API and create hub.
# The private API (osac.private.v1.*) is only available via the internal listener
# (fulfillment-internal-api route, port 8001). The external listener
# (fulfillment-api route, port 8000) only routes public API methods.
FULFILLMENT_INTERNAL_API_URL=https://$(oc get route -n ${INSTALLER_NAMESPACE} fulfillment-internal-api -o jsonpath='{.status.ingress[0].host}')
osac login --insecure --private --token-script "oc create token -n ${INSTALLER_NAMESPACE} admin" --address ${FULFILLMENT_INTERNAL_API_URL}
osac create hub --kubeconfig=/tmp/kubeconfig.hub-access --id hub --namespace ${INSTALLER_NAMESPACE}

if [[ -n "${INSTALLER_VM_TEMPLATE}" ]]; then
    # Trigger a one-time publish-templates AAP job
    AAP_ROUTE_HOST=$(oc get routes -n "${INSTALLER_NAMESPACE}" --no-headers osac-aap -o jsonpath='{.spec.host}')
    AAP_URL="https://${AAP_ROUTE_HOST}"
    AAP_TOKEN=$(oc get secret osac-aap-api-token -n "${INSTALLER_NAMESPACE}" -o jsonpath='{.data.token}' | base64 -d)
    JT_ID=$(curl -kfsS -H "Authorization: Bearer ${AAP_TOKEN}" \
        "${AAP_URL}/api/controller/v2/job_templates/?name=osac-publish-templates" | jq -er '.results[0].id // empty') || {
        echo "Failed to find osac-publish-templates AAP job template"
        exit 1
    }
    echo "Launching publish-templates AAP job (template ID: ${JT_ID})..."
    curl -kfsS -X POST -H "Authorization: Bearer ${AAP_TOKEN}" -H "Content-Type: application/json" \
        "${AAP_URL}/api/controller/v2/job_templates/${JT_ID}/launch/" >/dev/null || {
        echo "Failed to launch osac-publish-templates AAP job"
        exit 1
    }

    echo "Waiting for computeinstancetemplate ${INSTALLER_VM_TEMPLATE} to be published..."
    retry_until 1200 5 '[[ -n "$(osac get computeinstancetemplate -o json | jq -r --arg tpl "$INSTALLER_VM_TEMPLATE" '"'"'select(.id == $tpl)'"'"' 2> /dev/null)" ]]' || {
        echo "Timed out waiting for computeinstancetemplate to exist"
        exit 1
    }
fi

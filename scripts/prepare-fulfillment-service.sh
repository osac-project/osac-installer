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
EXTRA_SERVICES=${EXTRA_SERVICES:-"false"}
VIRT_SERVICE=${VIRT_SERVICE:-${EXTRA_SERVICES}}

# Create hub access kubeconfig
./scripts/create-hub-access-kubeconfig.sh

# Login to fulfillment API and create hub
FULFILLMENT_API_URL=https://$(oc get route -n ${INSTALLER_NAMESPACE} fulfillment-api -o jsonpath='{.status.ingress[0].host}')
osac login --insecure --private --token-script "oc create token -n ${INSTALLER_NAMESPACE} admin" --address ${FULFILLMENT_API_URL}
osac create hub --kubeconfig=kubeconfig.hub-access --id hub --namespace ${INSTALLER_NAMESPACE}

# Wait for computeinstancetemplate to exist (VMaaS only)
if [[ "${VIRT_SERVICE}" == "true" ]]; then
    retry_until 1200 5 '[[ -n "$(osac get computeinstancetemplate -o json | jq -r --arg tpl ${INSTALLER_VM_TEMPLATE} '"'"'select(.id == $tpl)'"'"' 2> /dev/null)" ]]' || {
        echo "Timed out waiting for computeinstancetemplate to exist"
        exit 1
    }
fi

#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${KEYCLOAK_NAMESPACE:-keycloak}"
SECRET_NAME="keycloak-client-secrets"
KC_CR_NAME="${KEYCLOAK_CR_NAME:-osac-keycloak}"

echo "Resolving Keycloak realm secrets..."

if ! oc get secret "${SECRET_NAME}" -n "${NAMESPACE}" 2>/dev/null; then
    echo "Generating osac-controller/osac-admin client secrets..."
    oc create secret generic "${SECRET_NAME}" -n "${NAMESPACE}" \
        --from-literal=osac-controller="$(openssl rand -base64 18)" \
        --from-literal=osac-admin="$(openssl rand -base64 18)"
fi

CONTROLLER_SECRET=$(oc get secret "${SECRET_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.data.osac-controller}' | base64 -d)
ADMIN_SECRET=$(oc get secret "${SECRET_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.data.osac-admin}' | base64 -d)

[[ -n "${CONTROLLER_SECRET}" ]] || { echo "ERROR: ${SECRET_NAME} missing osac-controller key" >&2; exit 1; }
[[ -n "${ADMIN_SECRET}" ]] || { echo "ERROR: ${SECRET_NAME} missing osac-admin key" >&2; exit 1; }

RESOLVED=$(sed \
    -e "s#__OSAC_CONTROLLER_CLIENT_SECRET__#${CONTROLLER_SECRET}#" \
    -e "s#__OSAC_ADMIN_CLIENT_SECRET__#${ADMIN_SECRET}#" \
    /realm-raw/realm.json)

echo "Creating KeycloakRealmImport CR..."
echo "${RESOLVED}" | python3 -c "
import json, os, sys
realm = json.load(sys.stdin)
cr = {
    'apiVersion': 'k8s.keycloak.org/v2alpha1',
    'kind': 'KeycloakRealmImport',
    'metadata': {
        'name': 'osac-realm-import',
        'namespace': os.environ['KEYCLOAK_NAMESPACE']
    },
    'spec': {
        'keycloakCRName': os.environ['KEYCLOAK_CR_NAME'],
        'realm': realm
    }
}
json.dump(cr, sys.stdout)
" | oc apply -f -

echo "Waiting for realm import to complete..."
for i in $(seq 1 60); do
  STATUS=$(oc get keycloakrealmimport osac-realm-import -n "${NAMESPACE}" \
      -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || true)
  if [[ "${STATUS}" == "True" ]]; then
    echo "Realm import CR reports Done. Verifying realm exists in Keycloak..."
    KC_SVC="https://${KC_CR_NAME}-service.${NAMESPACE}.svc.cluster.local:8443"
    for v in $(seq 1 12); do
      if curl -k -sf "${KC_SVC}/realms/osac" > /dev/null 2>&1; then
        echo "Realm import completed and verified."
        exit 0
      fi
      echo "  Waiting for realm to become accessible (attempt ${v}/12)..."
      sleep 5
    done
    echo "WARNING: CR reports Done but realm not accessible yet (Keycloak may be restarting). Continuing."
    exit 0
  fi
  ERROR=$(oc get keycloakrealmimport osac-realm-import -n "${NAMESPACE}" \
      -o jsonpath='{.status.conditions[?(@.type=="HasErrors")].status}' 2>/dev/null || true)
  if [[ "${ERROR}" == "True" ]]; then
    MSG=$(oc get keycloakrealmimport osac-realm-import -n "${NAMESPACE}" \
        -o jsonpath='{.status.conditions[?(@.type=="HasErrors")].message}' 2>/dev/null || true)
    echo "ERROR: Realm import failed: ${MSG}" >&2
    exit 1
  fi
  sleep 5
done

echo "ERROR: Realm import did not complete within 300s" >&2
exit 1

#!/usr/bin/env bash
set -euo pipefail

echo "Waiting for Keycloak CR to be ready..."
for i in $(seq 1 120); do
  READY=$(oc get keycloak osac-keycloak -n keycloak \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  if [[ "${READY}" == "True" ]]; then
    echo "Keycloak is ready."
    exit 0
  fi
  sleep 5
done

echo "ERROR: Keycloak CR not ready after 600s" >&2
oc get keycloak osac-keycloak -n keycloak -o yaml 2>/dev/null || true
exit 1

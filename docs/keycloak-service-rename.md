# Keycloak Service Rename Migration

The in-cluster Keycloak `Service` and `Route` were renamed from `keycloak` to
`osac-keycloak` to avoid clashing with generic `keycloak` service names on shared
clusters.

This guide covers upgrading existing environments. Greenfield installs can ignore
it — `oc apply -k prerequisites/keycloak/` already creates `osac-keycloak`.

## What changed

| Resource | Before | After |
|----------|--------|-------|
| Service | `keycloak` | `osac-keycloak` |
| Route | `keycloak` | `osac-keycloak` |
| In-cluster DNS | `keycloak.keycloak.svc.cluster.local` | `osac-keycloak.keycloak.svc.cluster.local` |
| TLS cert SANs | `keycloak`, `keycloak.keycloak.svc.cluster.local` | `osac-keycloak`, `osac-keycloak.keycloak.svc.cluster.local` |
| `KC_HOSTNAME` | `keycloak.keycloak.svc.cluster.local` | `osac-keycloak.keycloak.svc.cluster.local` |

**Unchanged:** the `keycloak` namespace, `keycloak-service` Deployment, database,
and realm ConfigMap names.

## Who is affected

Apply this migration if your environment uses any of:

- Fulfillment auth URLs pointing at `keycloak.keycloak.svc.cluster.local`
- `scripts/refresh-after-snapshot.sh` (looks up the Keycloak Route by name)
- An overlay with hardcoded external route hostnames derived from the old Route
  name (for example `keycloak-keycloak.apps.<cluster>`)

Installer overlays updated in the rename PR: `development`, `caas-ci`,
`vmaas-ci`, `osac-integration`.

**Not updated (separate follow-up if needed):**

- `base/osac-fulfillment-service` submodule defaults (`:8000` hostname, used by
  kind/local dev and overlays that do not patch auth URLs, such as `hypershift2`)
- Personal or fork-specific overlays (for example `tohughes-dev`)

## Upgrade procedure

Run these steps in order. Expect a brief auth outage while JWT issuer URLs change.

### 1. Apply updated Keycloak prerequisites

```bash
oc apply -k prerequisites/keycloak/
```

Wait for the deployment and certificate:

```bash
oc wait deployment/keycloak-service -n keycloak --for=condition=Available --timeout=600s
oc wait --for=condition=Ready certificate/keycloak-tls -n keycloak --timeout=300s
```

Kustomize creates the new `osac-keycloak` Service and Route but does **not**
remove the old `keycloak` Service/Route. Both may point at the same pods until
you clean up in step 4.

### 2. Verify Keycloak on the new service

From a pod in the `keycloak` namespace:

```bash
curl -k -s -o /dev/null -w '%{http_code}\n' https://osac-keycloak:443/realms/osac
```

Expect `200`. The password-setup job uses this short name.

For external access, confirm the new Route hostname:

```bash
oc get route osac-keycloak -n keycloak -o jsonpath='{.spec.host}{"\n"}'
```

OpenShift route hostnames follow `<route-name>-<namespace>.apps.<domain>`. After
the rename, external URLs change from `keycloak-keycloak.apps...` to
`osac-keycloak-keycloak.apps...`.

### 3. Apply the fulfillment overlay

Re-apply your installer overlay so fulfillment auth issuer/idp URLs match the
new hostname. For example:

```bash
oc apply -k overlays/development/
# or overlays/caas-ci/, overlays/vmaas-ci/, overlays/osac-integration/, etc.
```

Wait for fulfillment deployments to roll out:

```bash
oc rollout status deployment/fulfillment-controller -n <namespace> --timeout=300s
oc rollout status deployment/fulfillment-grpc-server -n <namespace> --timeout=300s
```

### 4. Delete orphaned resources

After fulfillment auth works against `osac-keycloak`, remove the old Service and
Route:

```bash
oc delete route keycloak -n keycloak --ignore-not-found
oc delete service keycloak -n keycloak --ignore-not-found
```

### 5. Re-authenticate clients

`KC_HOSTNAME` and issuer URLs change with the rename. Existing JWTs issued under
the old hostname are rejected until clients obtain new tokens.

## Environment-specific notes

### CI overlays (`caas-ci`, `vmaas-ci`, `development`)

Auth URLs use in-cluster DNS on port 443 (via the Service port mapping):

```
https://osac-keycloak.keycloak.svc.cluster.local/realms/osac
```

### `osac-integration`

This overlay uses the external Route hostname, not in-cluster DNS. After
redeploying prerequisites, update auth URLs to match the new route host (or
re-apply the overlay from a branch that includes the rename).

### Helm deployments

Set values explicitly:

```yaml
service:
  auth:
    issuerUrl: https://osac-keycloak.keycloak.svc.cluster.local/realms/osac
  idp:
    url: https://osac-keycloak.keycloak.svc.cluster.local
```

See `values/development.yaml` and `charts/osac/ci/full-values.yaml` for examples.

## Rollback

If you need to revert before deleting the old resources:

1. Re-apply the previous installer/overlay revision with old auth URLs.
2. Re-apply previous `prerequisites/keycloak/` manifests (old Service/Route names).
3. Delete `osac-keycloak` Service and Route if they were created.

Rollback is only straightforward if step 4 cleanup has not run yet.

## Verification checklist

- [ ] `https://osac-keycloak:443/realms/osac` returns 200 from inside the `keycloak` namespace
- [ ] Fulfillment controller and gRPC server pods are running
- [ ] `osac login` (or equivalent API call with a fresh token) succeeds
- [ ] `scripts/refresh-after-snapshot.sh` keycloak sync completes (uses `route/osac-keycloak`)
- [ ] Old `service/keycloak` and `route/keycloak` are deleted

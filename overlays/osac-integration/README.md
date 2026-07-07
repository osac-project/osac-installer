# osac-integration overlay

This overlay targets the OSAC integration environment.

## Prerequisites

The following components must be installed manually before applying this overlay:

| Component | Manifest |
|---|---|
| Keycloak | [prerequisites/keycloak/](../../prerequisites/keycloak/) |
| Trust Manager | [prerequisites/trust-manager.yaml](../../prerequisites/trust-manager.yaml) |
| AAP Operator | [prerequisites/aap-installation.yaml](../../prerequisites/aap-installation.yaml) |
| CA Issuer | [prerequisites/ca-issuer.yaml](../../prerequisites/ca-issuer.yaml) |

## Keycloak

The Keycloak admin password is stored in the `keycloak-admin` secret in the `keycloak` namespace:

```sh
oc get secret keycloak-admin -n keycloak -o jsonpath='{.data.password}' | base64 -d
```

## Manual secrets

The following secret must be created manually in the target namespace:

```sh
oc create secret generic fulfillment-controller-credentials \
  --from-literal=client-id=osac-controller \
  --from-literal=client-secret=<client-secret>
```

`client-secret` must match the `osac-controller` value generated at first boot by the
`keycloak-service` init container, stored in the `keycloak-client-secrets` Secret in the
`keycloak` namespace:

```sh
oc get secret keycloak-client-secrets -n keycloak -o jsonpath='{.data.osac-controller}' | base64 -d
```

## Deployment

Review changes before applying:

```sh
oc diff -k overlays/osac-integration/
```

Apply the configuration:

```sh
oc apply -k overlays/osac-integration/
```

# AAP Configuration

The OSAC automation backend (AAP) receives its runtime configuration via
Kubernetes ConfigMaps and Secrets that are mounted into AAP instance group
execution pods via `envFrom`. This makes every key available as an environment
variable during playbook execution.

Currently only the **cluster-fulfillment-ig** instance group mounts these
variables, as it is the only instance group that consumes them (for cluster provisioning workflows).
This will be expanded to additional instance groups in the future as more automation workflows are added.

## Configuration Files

Each overlay contains a tracked configuration file under `files/`; add a local
secrets file only when credential overrides are needed:

| File | Tracked in git | Purpose |
|------|---------------|---------|
| `osac-aap-configuration.env` | Yes | Non-sensitive settings (network class, domains, hosted cluster defaults) |
| `osac-aap-secrets.env` | No (gitignored, optional) | Sensitive credentials (passwords, SSH keys, AWS keys) |

The `scripts/aap-configuration.sh` script reads `osac-aap-configuration.env`
and, when present, `osac-aap-secrets.env`, then patches the
`cluster-fulfillment-ig` ConfigMap and Secret on the cluster. The setup script
(`setup.sh`) calls this automatically after applying the Kustomize overlay.

For manual deployments, run the script standalone after `oc apply -k`:

```bash
INSTALLER_NAMESPACE=<project-name> ./scripts/aap-configuration.sh
```

Shell environment variables override values from the env files, which is useful
for CI pipelines.

## ConfigMap Variables (`osac-aap-configuration.env`)

| Variable | Default | Description |
|----------|---------|-------------|
| `NETWORK_CLASS` | `esi` | Network backend (`netris` or `esi`) |
| `NETWORK_STEPS_COLLECTION` | `massopencloud.steps` | Ansible collection for network steps |
| `EXTERNAL_ACCESS_BASE_DOMAIN` | `box.massopen.cloud` | Base domain for cluster DNS records |
| `EXTERNAL_ACCESS_SUPPORTED_BASE_DOMAINS` | `box.massopen.cloud` | Comma-separated list of allowed domains |
| `EXTERNAL_ACCESS_API_INTERNAL_NETWORK` | `hypershift` | Internal network for API access |
| `HOSTED_CLUSTER_BASE_DOMAIN` | `box.massopen.cloud` | Base domain for hosted clusters |
| `HOSTED_CLUSTER_CONTROLLER_AVAILABILITY_POLICY` | `HighlyAvailable` | Control plane HA policy |
| `HOSTED_CLUSTER_INFRASTRUCTURE_AVAILABILITY_POLICY` | `HighlyAvailable` | Infrastructure HA policy |

## Secret Variables (`osac-aap-secrets.env`)

Values must be **plaintext** — the script base64-encodes them when patching the
Kubernetes Secret. Do not pre-encode them.

| Variable | Description |
|----------|-------------|
| `AWS_ACCESS_KEY_ID` | AWS credentials for Route53 DNS |
| `AWS_SECRET_ACCESS_KEY` | AWS credentials for Route53 DNS |

Additional variables are added by specific network backends — see
[Network Backend Configuration](network-backend.md).

> **Note on SSH keys:** The env file parser reads one line at a time. For
> multi-line values like SSH private keys, replace newlines with literal `\n`
> on a single line, or pass them via shell environment variables instead of the
> env file.

## Reference

See `base/osac-aap/config/base/configmap-cluster-fulfillment-ig-example.yaml` and
`base/osac-aap/config/base/secret-cluster-fulfillment-ig-example.yaml` for full
examples.

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

## Bootstrap job image vs `AAP_EE_IMAGE`

The `aap-bootstrap` Job uses two independent mechanisms to reference the OSAC
execution environment (EE) image. Overlays must keep both aligned when pinning a
custom registry or tag.

| Mechanism | Where to set | What it controls |
|-----------|--------------|------------------|
| Kustomize `images:` | Overlay `kustomization.yaml` — match resolved name `ghcr.io/osac-project/osac-aap` | Container image for the `aap-bootstrap` pod (runs `ansible-playbook`) |
| `AAP_EE_IMAGE` | `config-as-code-ig` secret literal (or Helm equivalent) | EE image registered **inside AAP** by `osac.config_as_code.configure` |

Base `kustomization.yaml` maps placeholder `osac-aap` to `ghcr.io/osac-project/osac-aap:<tag>`.
Overlays that only set `AAP_EE_IMAGE` in `config-as-code-ig` do not change the bootstrap
pod image — the Job will still pull from `ghcr.io` unless the overlay also adds an
`images:` entry. Match the **resolved** image name from base (not the placeholder):

```yaml
images:
  - name: ghcr.io/osac-project/osac-aap
    newName: quay.io/<your-registry>/osac-aap
    newTag: sha-<commit>
```

Use the same registry and tag for `AAP_EE_IMAGE` so bootstrap, AAP EE registration, and
subsequent job pods stay consistent.

## ConfigMap Variables (`osac-aap-configuration.env`)

| Variable | Default | Description |
|----------|---------|-------------|
| `NETWORK_CLASS` | `esi` | Network backend (`netris` or `esi`) |
| `NETWORK_STEPS_COLLECTION` | `osac.steps` | Ansible collection for network steps |
| `EXTERNAL_ACCESS_BASE_DOMAIN` | `box.massopen.cloud` | Base domain for cluster DNS records |
| `EXTERNAL_ACCESS_SUPPORTED_BASE_DOMAINS` | `box.massopen.cloud` | Comma-separated list of allowed domains |
| `EXTERNAL_ACCESS_API_INTERNAL_NETWORK` | `hypershift` | Internal network for API access |
| `HOSTED_CLUSTER_BASE_DOMAIN` | `box.massopen.cloud` | Base domain for hosted clusters |
| `HOSTED_CLUSTER_CONTROLLER_AVAILABILITY_POLICY` | `HighlyAvailable` | Control plane HA policy |
| `HOSTED_CLUSTER_INFRASTRUCTURE_AVAILABILITY_POLICY` | `HighlyAvailable` | Infrastructure HA policy |
| `DNS_CLASS` | `dns.route53.dns` | DNS backend driver role (see [DNS Backend](dns-backend.md)) |
| `DNS_ZONE` | `EXTERNAL_ACCESS_BASE_DOMAIN` | DNS zone for record management |

## Secret Variables (`osac-aap-secrets.env`)

Values must be **plaintext** — the script base64-encodes them when patching the
Kubernetes Secret. Do not pre-encode them.

| Variable | Description |
|----------|-------------|
| `AWS_ACCESS_KEY_ID` | AWS credentials for Route53 DNS |
| `AWS_SECRET_ACCESS_KEY` | AWS credentials for Route53 DNS |

Additional variables are added by specific network backends — see
[Network Backend Configuration](network-backend.md).

> **Note on SSH keys:** SSH private keys are read from files in the overlay's
> `files/` directory (`server-ssh-key` and `server-ssh-bastion-key`), not from
> the env file. Place the key files there and the script base64-encodes them
> automatically.

## Reference

See `base/osac-aap/config/base/configmap-cluster-fulfillment-ig-example.yaml` and
`base/osac-aap/config/base/secret-cluster-fulfillment-ig-example.yaml` for full
examples.

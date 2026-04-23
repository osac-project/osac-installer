# Network Backend Configuration

The network backend controls how hosted clusters get their networking
infrastructure (server clusters, NAT, DNS, MetalLB). The backend is selected by
the `NETWORK_CLASS` variable in `osac-aap-configuration.env`.

For general AAP configuration (env files, how the script works, base variables),
see [AAP Configuration](aap-configuration.md).

## Supported Backends

| `NETWORK_CLASS` | `NETWORK_STEPS_COLLECTION` | Description |
|-----------------|---------------------------|-------------|
| `esi` (default) | `massopencloud.steps` | ESI (Elastic System Infrastructure) |
| `netris` | `netris.steps` | Netris controller API |

## Netris Configuration

When using `NETWORK_CLASS=netris`, the following additional variables must be set.

### ConfigMap Variables (add to `osac-aap-configuration.env`)

| Variable | Description |
|----------|-------------|
| `NETRIS_CONTROLLER_URL` | Netris controller API URL |
| `NETRIS_USERNAME` | Netris API username |
| `NETRIS_SITE_ID` | Netris site ID (integer) |
| `NETRIS_TENANT_ID` | Netris tenant ID (integer) |
| `NETRIS_TENANT_NAME` | Netris tenant name |
| `NETRIS_MGMT_VPC_ID` | Management VPC ID |
| `NETRIS_MGMT_VPC_NAME` | Management VPC name |
| `NETRIS_RESOURCE_CLASS_MAP` | JSON dict mapping resource classes to config (see below) |
| `SERVER_SSH_BASTION_HOST` | Bastion hostname/IP for SSH to bare-metal servers |
| `SERVER_SSH_BASTION_USER` | Bastion SSH username |
| `SERVER_SSH_USER` | Server SSH username |
| `SERVER_MGMT_ROUTE_DESTINATION` | Management route destination CIDR |
| `SERVER_MGMT_ROUTE_GATEWAY` | Management route gateway IP |

### Secret Variables (add to `osac-aap-secrets.env`)

Values must be plaintext — the script base64-encodes them automatically.

| Variable | Description |
|----------|-------------|
| `NETRIS_PASSWORD` | Netris API password |
| `SERVER_SSH_KEY` | Private key for SSH to bare-metal servers |
| `SERVER_SSH_BASTION_KEY` | Private key for SSH to the bastion host |

### `NETRIS_RESOURCE_CLASS_MAP` Format

```json
{
  "fc430": {
    "server_cluster_template_id": 89,
    "mgmt_interface": "ens4",
    "vpc_interfaces": ["ens13"]
  }
}
```

Each key is a resource class name. `server_cluster_template_id` is the Netris server
cluster template ID, `mgmt_interface` is the management NIC name, and `vpc_interfaces`
lists the data-plane NIC names.

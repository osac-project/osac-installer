# AGENTS.md

## Overview

Kustomize-based deployment system that assembles fulfillment-service, osac-operator, osac-aap, and bare-metal-fulfillment-operator (Git submodules under `base/`) into OpenShift overlays.

## Common Commands

```bash
# Initialize submodules (required before any build or deploy)
git submodule update --init --recursive

# Validate all kustomize builds (runs in CI)
./scripts/kustomize-build-all.sh

# Build a specific overlay
kustomize build overlays/<overlay-name>

# Deploy to OpenShift (always specify namespace explicitly on shared clusters)
oc apply -k overlays/<overlay-name> -n <namespace>

# Automated end-to-end deployment (installs prerequisites + deploys + configures)
INSTALLER_NAMESPACE=<namespace> INSTALLER_KUSTOMIZE_OVERLAY=<overlay-name> ./scripts/setup.sh

# Run pre-commit hooks
pre-commit run --all-files

# YAML lint only
yamllint --strict .
```

## Architecture

### Kustomize Composition

```
base/kustomization.yaml                        # Composes all submodule components + hub-access
  base/osac-fulfillment-service/                 # Git submodule -> fulfillment-service repo
  base/osac-operator/                            # Git submodule -> osac-operator repo
  base/osac-aap/                                 # Git submodule -> osac-aap repo
  base/bare-metal-fulfillment-operator/          # Git submodule -> bare-metal-fulfillment-operator repo
  base/hub-access/                               # Local: ServiceAccount + RBAC for hub cluster access

overlays/<name>/kustomization.yaml  # Extends base with env-specific config
  - namespace, image pins, patches, secretGenerator
  - prefixTransformer.yaml for cluster-scoped resource prefixes
  - files/ directory for secrets (gitignored)
```

Base sets the default namespace (`osac`), common labels, and image references. Overlays override namespace, pin image digests/tags, patch operator configuration, and generate secrets from local files.

### Overlays

An overlay's `files/` directory must contain `quay-pull-secret.json` and `license.zip` before building -- these are gitignored. The `.buildfiles` file lists files that CI creates as empty stubs to satisfy `kustomize build`.

#### Overlay Types

| Overlay | Namespace | Cluster Type | Notes |
|---------|-----------|-------------|-------|
| development | osac-devel | shared (hypershift1) | Uses `console-proxy-shared-dev` Component |
| hypershift2 | osac | shared (hypershift1) | |
| vmaas-ci | osac-e2e-ci | dedicated (CI) | Isolated per-test cluster |
| caas-ci | osac-e2e-ci | dedicated (CI) | Isolated per-test cluster |
| osac-integration | osac-integration | dedicated (CI) | Isolated per-test cluster |

`console-proxy-shared-dev` Component must only be used on shared cluster overlays. Do not add it to dedicated/CI overlays -- the `osac` namespace does not exist on isolated per-test clusters, so deployment will fail with `namespaces "osac" not found`. Dedicated/CI overlays get the standard replacements only.

### Prerequisites

`prerequisites/` contains cluster-wide operator manifests (cert-manager, trust-manager, Authorino, Keycloak, AAP). Some require the apply-wait-reapply pattern because operator CRDs must exist before dependent resources can be created. `setup.sh` handles this automatically.

### Scripts

- **setup.sh** -- Full automated deployment: installs prerequisites, applies overlay, creates hub-access kubeconfig, registers hub with fulfillment-cli, configures operator with AAP credentials, creates Tenant CR. Requires `fulfillment-cli` in PATH.
- **setup-remote-cluster.sh** -- CI-only script for preparing a remote cluster (LVMS, CNV, service accounts).
- **create-hub-access-kubeconfig.sh** -- Generates `kubeconfig.hub-access` from the hub-access ServiceAccount token.
- **kustomize-build-all.sh** -- Finds and builds all kustomization.yaml files (skips submodules and `.skip-build` dirs). Used in CI.
- **lib.sh** -- Shared shell functions: `retry_until` (retry with timeout) and `wait_for_resource` (wait for k8s resource condition).

## Submodules and Local Development

Submodules under `base/` (osac-operator, osac-fulfillment-service, osac-aap, bare-metal-fulfillment-operator) are pinned snapshots of the real working repos. They do not auto-sync -- to test local changes, synchronize modified files from the working repo into the submodule directory, without committing. During active development the submodule pointers are often dirty; this is expected.

Do not `cd` into submodule directories and run git commands there -- you will operate on the submodule repo, not the installer. Always run git commands from the installer root.

Image tags in `base/kustomization.yaml` (`sha-XXXXXX`) must match the submodule commit SHAs. CI enforces this via `scripts/sync-image-tags.sh`. After updating a submodule pointer, update the corresponding image tag.

## Validation Workflow

Always capture baseline kustomize build output before making changes, then diff after to catch unintended side effects:

```bash
# Before changes, capture baselines
for d in overlays/*/; do kustomize build "$d" > "/tmp/baseline-$(basename $d).yaml" 2>/dev/null; done

# After changes, rebuild and diff
for d in overlays/*/; do kustomize build "$d" > "/tmp/after-$(basename $d).yaml" 2>/dev/null && diff "/tmp/baseline-$(basename $d).yaml" "/tmp/after-$(basename $d).yaml"; done

# Final CI-equivalent check
./scripts/kustomize-build-all.sh
```

## Helm Chart Conventions

- **Every new value must have a matching schema entry** -- when adding or modifying keys in `charts/osac/values.yaml`, always add the corresponding property definition to `charts/osac/values.schema.json`. Use `enum` constraints for fields with a known set of valid values (e.g., network/DNS backend classes). The schema is both validation and documentation -- incomplete schemas allow silent misconfiguration.

## Key Conventions

- Overlay secrets (`files/`) are never committed. Place `.buildfiles` in an overlay to list files that CI should stub out for build validation.
- Mark a directory with `.skip-build` to exclude it from `kustomize-build-all.sh`.
- Mark a directory with `.expect-build-failure` if the build is expected to fail (CI will warn instead of error).
- Cluster-scoped resources (ClusterRole, ClusterRoleBinding) get prefixed via `prefixTransformer.yaml` to avoid collisions between overlays on the same cluster.
- `nameReference.yaml` in base configures cross-resource name references for kustomize.

## Kustomize Pitfalls

- **Namespace transformer overwrites all `metadata.namespace`** -- resources that must target a different namespace (e.g., `kube-system`) need a separate kustomization directory applied independently, or kustomize replacements to restore the correct namespace.
- **Replacements in Components run before the namespace transformer** -- a replacement that sets `metadata.namespace: kube-system` inside a Component will be overwritten by the overlay's namespace transformer. Replacements that fix namespace fields must live at the overlay level.
- **Kustomize blocks `../` in file paths** -- replacements files cannot reference parent directories. Each overlay that needs replacements must have its own copy.
- **Embedded namespace references** -- `APIService.spec.service.namespace`, `cert-manager.io/inject-ca-from` annotations, and Certificate `dnsNames` embed namespaces that the transformer cannot update. These require kustomize replacements with `delimiter`/`index` fields.
- **`ca-bundle` Bundle is cluster-scoped and managed by `setup.sh`** -- trust-manager names the generated ConfigMap after the Bundle, so it must stay named `ca-bundle` (pods mount this ConfigMap by name). The Bundle is **not** applied via kustomize -- `setup.sh` creates it on first deploy and additively patches the namespace selector on subsequent deploys, so it never overwrites other developers' namespaces. For manual deployments, patch the selector to add your namespace:
  ```bash
  oc patch bundle ca-bundle --type=json -p '[
    {"op":"add","path":"/spec/target/namespaceSelector/matchExpressions/0/values/-","value":"<your-namespace>"}
  ]'
  ```
  Or run `scripts/ensure-ca-bundle.sh <your-namespace>` which handles both creation and patching.

## Shared Cluster Constraints

- The development cluster is shared. Each developer has their own namespace overlay, created per the README.
- **Always set `-n <namespace>` explicitly in all `oc` commands** -- never rely on the current context namespace. On a shared cluster, operating in the wrong namespace breaks other developers' deployments.
- Personal overlays (e.g., `overlays/osac-<username>`) are created per the README, they are not part of this repo and should not be committed. Build failures in personal overlays do not block PRs in CI -- `kustomize-build-all.sh` only validates committed overlays in CI. If a personal overlay fails locally, ask the user whether to fix it or skip it -- do not attempt to fix or ignore without asking.

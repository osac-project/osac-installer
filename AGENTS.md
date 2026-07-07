# AGENTS.md

## Overview

Helm-based deployment system for the OSAC platform. Component repos (fulfillment-service, osac-operator, osac-aap, bare-metal-fulfillment-operator) are aggregated as Git submodules under `base/` for version tracking. Deployment uses Helm charts under `charts/osac/`.

## Common Commands

```bash
# Initialize submodules (required before sync-image-tags)
git submodule update --init --recursive

# Helm lint
helm lint charts/osac/

# Helm template render (dry-run validation)
helm template osac charts/osac/ --values values/development/values.yaml

# Deploy to OpenShift
INSTALLER_NAMESPACE=<namespace> VALUES_FILE=values/<env>/values.yaml ./scripts/setup.sh

# Teardown
INSTALLER_NAMESPACE=<namespace> ./scripts/teardown.sh

# Run pre-commit hooks
pre-commit run --all-files

# YAML lint only
yamllint --strict .
```

## Architecture

### Helm Chart

```text
charts/osac/                         # Umbrella chart
  Chart.yaml                         # Dependencies on subchart repos
  values.yaml                        # Default values
  values.schema.json                 # JSON Schema for values validation
  templates/                         # Deployment templates

values/
  development/values.yaml            # All controllers, latest images
  vmaas-ci/values.yaml               # VMaaS CI: computeInstance + tenant + networking, pinned images
  caas-ci/values.yaml                # CaaS CI: clusterOrder + tenant + networking, pinned images
```

### Submodules

Submodules under `base/` (osac-operator, osac-fulfillment-service, osac-aap, bare-metal-fulfillment-operator, osac-ui) are pinned snapshots used for version tracking. Image tags in `values/*/values.yaml` must match submodule commit SHAs. CI enforces this via `scripts/sync-image-tags.sh`.

### Prerequisites

`prerequisites/` contains cluster-wide operator manifests (cert-manager, trust-manager, Keycloak, AAP). Some require the apply-wait-reapply pattern because operator CRDs must exist before dependent resources can be created. `setup.sh` handles this automatically.

### Scripts

- **setup.sh** -- Full automated deployment: installs prerequisites, deploys via Helm, configures operator with AAP credentials, creates Tenant CR.
- **teardown.sh** -- Full teardown: uninstalls Helm release, removes operators and CRDs.
- **sync-image-tags.sh** -- Syncs image tags in Helm values files to match submodule commits.
- **setup-remote-cluster.sh** -- CI-only script for preparing a remote cluster (LVMS, CNV, service accounts).
- **create-hub-access-kubeconfig.sh** -- Generates `kubeconfig.hub-access` from the hub-access ServiceAccount token.
- **lib.sh** -- Shared shell functions: `retry_until` (retry with timeout) and `wait_for_resource` (wait for k8s resource condition).

## Submodules and Local Development

Submodules under `base/` are pinned snapshots of the real working repos. They do not auto-sync -- to test local changes, synchronize modified files from the working repo into the submodule directory, without committing. During active development the submodule pointers are often dirty; this is expected.

Do not `cd` into submodule directories and run git commands there -- you will operate on the submodule repo, not the installer. Always run git commands from the installer root.

After updating a submodule pointer, update the corresponding image tag via `./scripts/sync-image-tags.sh --fix`.

## Helm Chart Conventions

- **Every new value must have a matching schema entry** -- when adding or modifying keys in `charts/osac/values.yaml`, always add the corresponding property definition to `charts/osac/values.schema.json`. Use `enum` constraints for fields with a known set of valid values (e.g., network/DNS backend classes). The schema is both validation and documentation -- incomplete schemas allow silent misconfiguration.

## Key Conventions

- Values files are organized per environment under `values/<env>/values.yaml`.
- Pull secrets and AAP license files are stored alongside values files (e.g., `values/<env>/pull-secret.json`, `values/<env>/license.zip`).
- `ca-bundle` Bundle is cluster-scoped and managed by `setup.sh` -- run `scripts/ensure-ca-bundle.sh <your-namespace>` to add your namespace.

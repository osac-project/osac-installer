This is a **Helm-based infrastructure/deployment repository**. It
assembles component submodules (osac-operator, fulfillment-service,
osac-aap, bare-metal-fulfillment-operator, osac-ui) and deploys them
via a Helm umbrella chart. There is no Go code, no container builds,
and no unit tests in this repo. All validation is structural.

## Validation Commands

After making changes, run the following commands in order. Every command
must pass -- CI enforces all of them on every PR.

1. **YAML lint** (strict mode, repo-level `.yamllint.yaml` config):
   ```
   yamllint --strict .
   ```

2. **Pre-commit hooks** (trailing whitespace, merge conflicts, large
   files, private key detection, YAML lint):
   ```
   pre-commit run --all-files
   ```

3. **Helm lint** (validates chart structure and templates):
   ```bash
   helm lint charts/osac/
   ```

4. **Helm template render** (renders chart against each values file):
   ```bash
   for f in values/*/values.yaml; do helm template osac charts/osac/ --values "$f" > /dev/null; done
   ```

5. **Image tag sync** (verifies Helm values image tags match submodule
   commit SHAs):
   ```bash
   bash scripts/sync-image-tags.sh
   ```

If image tags are out of sync, run `scripts/sync-image-tags.sh --fix`
and verify the output before committing.

## Submodule Rules (Critical)

- Submodules live under `base/` (osac-operator, osac-fulfillment-service,
  osac-aap, bare-metal-fulfillment-operator, osac-ui). They are pinned
  snapshots of upstream repos.
- **Never `cd` into a submodule directory and run git commands there.**
  You will operate on the submodule repo, not the installer.
- Always run git commands from the installer repo root.
- After updating a submodule pointer, run `bash scripts/sync-image-tags.sh --fix`
  to update the corresponding image tags in Helm values files.
- Image tags use the format `sha-XXXXXXX` (first 7 chars of the
  submodule commit).

## Repository Structure

```
charts/osac/                     # Helm umbrella chart
  Chart.yaml                     # Dependencies on subchart repos
  values.yaml                    # Default values
  values.schema.json             # JSON Schema for values validation
  templates/                     # Deployment templates

values/
  development/values.yaml        # All controllers, latest images
  vmaas-ci/values.yaml           # VMaaS CI: pinned images
  caas-ci/values.yaml            # CaaS CI: pinned images

base/                            # Git submodules (version tracking)
  osac-operator/
  osac-fulfillment-service/
  osac-aap/
  bare-metal-fulfillment-operator/
  osac-ui/

prerequisites/                   # Cluster-wide operator manifests
scripts/                         # Automation scripts (setup, teardown, sync)
```

## Coding Conventions

- All YAML files must pass `yamllint --strict` with the repo's
  `.yamllint.yaml` config (line-length disabled, document-start disabled,
  indent-sequences: whatever).
- Shell scripts must use `set -o nounset`, `set -o errexit`,
  `set -o pipefail`. Source `scripts/lib.sh` for shared functions
  (`retry_until`, `wait_for_resource`, `wait_for_namespace_cleanup`).
- Always use explicit `-n <namespace>` flags in `oc` commands -- never
  rely on the current context namespace.
- Every new Helm value must have a matching entry in
  `charts/osac/values.schema.json`.

## What Not to Modify

- Do not modify files inside `base/osac-operator/`, `base/osac-fulfillment-service/`,
  `base/osac-aap/`, or `base/bare-metal-fulfillment-operator/` -- these are
  submodules. Changes to component manifests belong in the component repos.

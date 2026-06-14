This is a **Kustomize-based infrastructure/deployment repository**. It
assembles three component submodules (osac-operator, fulfillment-service,
osac-aap) into OpenShift overlays. There is no Go code, no container
builds, and no unit tests in this repo. All validation is structural.

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

3. **Kustomize build** (builds all committed overlays, stubs `.buildfiles`,
   skips submodule dirs and `.skip-build` dirs):
   ```
   bash scripts/kustomize-build-all.sh
   ```

4. **Image tag sync** (verifies `base/kustomization.yaml` image tags
   match submodule commit SHAs):
   ```
   bash scripts/sync-image-tags.sh
   ```

5. **AuthConfig Rego sync** (verifies overlay Rego patches match the
   base AuthConfig in the fulfillment-service submodule):
   ```
   python3 scripts/sync-authconfig-rego.py
   ```

If image tags or Rego policies are out of sync, the scripts support
`--fix` mode. Run them with `--fix` and verify the output before
committing.

## Submodule Rules (Critical)

- Submodules live under `base/` (osac-operator, osac-fulfillment-service,
  osac-aap). They are pinned snapshots of upstream repos.
- **Never `cd` into a submodule directory and run git commands there.**
  You will operate on the submodule repo, not the installer.
- Always run git commands from the installer repo root.
- After updating a submodule pointer, run `bash scripts/sync-image-tags.sh --fix`
  to update the corresponding image tag in `base/kustomization.yaml`.
- Image tags use the format `sha-XXXXXXX` (first 7 chars of the
  submodule commit).
- **After bumping any submodule under `base/`, always run
  `scripts/sync-image-tags.sh --fix` to update image tags in overlays.
  CI will fail if tags don't match submodule SHAs.** (OSAC-912)

## Repository Structure

```
base/kustomization.yaml          # Composes all submodule components
  base/osac-operator/            # Git submodule
  base/osac-fulfillment-service/ # Git submodule
  base/osac-aap/                 # Git submodule
  base/hub-access/               # Local RBAC manifests

overlays/<name>/                 # Env-specific overlay
  kustomization.yaml             # Namespace, image pins, patches, secrets
  prefixTransformer.yaml         # Cluster-scoped resource name prefix
  files/                         # Secrets (gitignored)

prerequisites/                   # Cluster-wide operator manifests
scripts/                         # Automation scripts (setup, teardown, sync)
```

## Coding Conventions

- All YAML files must pass `yamllint --strict` with the repo's
  `.yamllint.yaml` config (line-length disabled, document-start disabled,
  indent-sequences: whatever).
- Overlay `files/` directories contain secrets (pull-secrets, license
  files, SSH keys). These are **gitignored** -- never commit them.
- The `.buildfiles` file in an overlay lists files that CI creates as
  empty stubs to satisfy `kustomize build` (e.g., `files/license.zip`).
- Mark directories with `.skip-build` to exclude from
  `kustomize-build-all.sh`. Mark with `.expect-build-failure` if the
  build is expected to fail.
- Cluster-scoped resources (ClusterRole, ClusterRoleBinding) must use
  `prefixTransformer.yaml` to avoid collisions between overlays on the
  same cluster.
- Shell scripts must use `set -o nounset`, `set -o errexit`,
  `set -o pipefail`. Source `scripts/lib.sh` for shared functions
  (`retry_until`, `wait_for_resource`, `wait_for_namespace_cleanup`).
- Always use explicit `-n <namespace>` flags in `oc` commands -- never
  rely on the current context namespace.

## Kustomize Pitfalls

- The namespace transformer overwrites all `metadata.namespace`. Resources
  targeting a different namespace (e.g., kube-system) need separate
  kustomization directories or kustomize replacements.
- Replacements inside Components run before the namespace transformer --
  namespace-fixing replacements must live at the overlay level.
- Kustomize blocks `../` in file paths.
- Embedded namespace references (APIService, cert-manager annotations,
  Certificate dnsNames) require kustomize replacements with
  `delimiter`/`index` fields.
- The `ca-trust-bundle.yaml` Bundle is cluster-scoped. On shared clusters,
  last apply wins. Never re-apply the Bundle -- patch it to append your
  namespace instead.

## Baseline Diff Workflow

When modifying Kustomize resources, always capture baseline output before
changes and diff after to catch unintended side effects:

```bash
# Before changes
for d in overlays/*/; do
  kustomize build "$d" > "/tmp/baseline-$(basename $d).yaml" 2>/dev/null
done

# After changes
for d in overlays/*/; do
  kustomize build "$d" > "/tmp/after-$(basename $d).yaml" 2>/dev/null
  diff "/tmp/baseline-$(basename $d).yaml" "/tmp/after-$(basename $d).yaml"
done
```

## What Not to Modify

- Do not modify files inside `base/osac-operator/`, `base/osac-fulfillment-service/`,
  or `base/osac-aap/` -- these are submodules. Changes to component
  manifests belong in the component repos.
- Do not commit overlay `files/` contents (pull secrets, license.zip,
  SSH keys, `.env` files with credentials).
- Do not add personal overlays (e.g., `overlays/osac-<username>`) to
  the repo.

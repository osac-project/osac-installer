# OSAC Installer Instructions

This is a **Helm-based infrastructure/deployment repository**. It
assembles component submodules (osac-operator, fulfillment-service,
osac-aap, bare-metal-fulfillment-operator, osac-ui) and deploys them
via a Helm umbrella chart. There is no Go code, no container builds,
and no unit tests in this repo. All validation is structural.

## Validation Commands

After making changes, run the following commands in order. Every command
must pass -- CI enforces all of them on every PR.

1. **YAML lint** (strict mode, repo-level `.yamllint.yaml` config):

   ```bash
   yamllint --strict /path/to/osac-installer
   ```

2. **Pre-commit hooks** (trailing whitespace, merge conflicts, large
   files, private key detection, YAML lint):

   ```bash
   (cd /path/to/osac-installer && pre-commit run --all-files)
   ```

3. **Helm lint** (validates chart structure and templates -- see `Makefile` for full command):

   ```bash
   make -C /path/to/osac-installer helm-lint
   ```

4. **Helm template render** (validates against all values files -- see `Makefile` for full command):

   ```bash
   make -C /path/to/osac-installer VALUES_FILE=/path/to/osac-installer/values/development/values.yaml helm-validate
   ```

## Coding Conventions

- All YAML files must pass `yamllint --strict` with the repo's
  `.yamllint.yaml` config (line-length disabled, document-start disabled,
  indent-sequences: whatever).
- Shell scripts must use `set -euo pipefail`. Source `scripts/lib.sh` for shared functions
  (`retry_until`, `wait_for_resource`, `wait_for_namespace_cleanup`).
- Always use explicit `-n <namespace>` flags in `oc` commands -- never
  rely on the current context namespace.
- Every new Helm value must have a matching entry in
  `charts/osac/values.schema.json`.

## What Not to Modify

- Do not modify files inside any `base/*/` directories (discover with:
  `git submodule status`) -- these are submodules. Changes to component
  manifests belong in the component repos.

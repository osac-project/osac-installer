@AGENTS.md

## Claude Code Tooling

This is an infrastructure/deployment repository (Helm-based) with no Go code, container builds, or unit tests. All validation is structural (YAML lint, Helm lint/template). Legacy overlay directories under `overlays/` store environment-specific secret files (no kustomization.yaml).

### Read Tool

Use for reading YAML manifests, Helm chart files, scripts, submodule metadata. Primary targets:

- `charts/osac/values.yaml`, `charts/osac/values.schema.json` -- Helm default values and schema
- `values/<env>/values.yaml` -- Helm environment-specific values
- `scripts/*.sh`, `scripts/*.py` -- Automation scripts
- `prerequisites/` -- Operator manifests

### Edit Tool

Use for updating Helm chart files, YAML manifests, shell scripts. Common edits:

- New/changed keys in `charts/osac/values.yaml` -- always add a matching property in `charts/osac/values.schema.json`
- Script logic in `scripts/*.sh` (follow `set -euo pipefail`)

Never use Edit for files in submodule directories (`base/*/` -- discover with: `git submodule status`).

### Write Tool

Use sparingly. Most work is editing existing files. Valid use cases:

- New prerequisite manifests in `prerequisites/`
- New Helm values files in `values/<env>/`
- Session artifacts (`.ai-bot/diagnosis.md`, `.ai-bot/pr.md`)

Never use Write for files in submodule directories (`base/*/` -- discover with: `git submodule status`).

### Bash Tool

Use for validation commands, Helm operations, git operations. Always use absolute paths since the thread cwd resets between calls. Always specify `-n <namespace>` explicitly in `oc` commands on shared clusters.

Example commands (replace placeholders with absolute paths):

```bash
# Validation suite (run in order, all must pass)
yamllint --strict /path/to/osac-installer
(cd /path/to/osac-installer && pre-commit run --all-files)
make -C /path/to/osac-installer helm-lint
make -C /path/to/osac-installer VALUES_FILE=/path/to/osac-installer/values/development/values.yaml helm-validate

# Git operations (always from installer root, never inside submodules)
git -C /path/to/osac-installer status
git -C /path/to/osac-installer add /path/to/file1 /path/to/file2
git -C /path/to/osac-installer commit -s -m "OSAC-XXXX: description

Assisted-by: Claude Code <noreply@anthropic.com>"
git -C /path/to/osac-installer push fork <branch>
```

Read and execute .ai-workflows/bugfix/skills/feedback.md with
the following repo-specific context.

## Context Recovery

Read `.ai-bot/session-context.md` and `.ai-bot/implementation-notes.md`
to understand the prior session's decisions and changes.

## Feedback Handling Rules

1. **Submodule boundaries**: If feedback asks you to change a file inside
   `base/osac-operator/`, `base/osac-fulfillment-service/`, or
   `base/osac-aap/`, explain that these are submodules and the change
   belongs in the component repo. Suggest what the reviewer should do
   instead.

2. **Overlay consistency**: If feedback applies to one overlay, check
   whether parallel overlays (development, vmaas-ci, caas-ci,
   osac-integration) need the same change. Call this out in your
   response.

3. **Namespace pitfalls**: If feedback involves namespace references,
   verify that the change works with the kustomize namespace transformer.
   Embedded namespace references (APIService, annotations, dnsNames)
   need kustomize replacements, not direct edits.

## Post-Change Validation

After addressing all review comments, run the full validation suite:

```
yamllint --strict .
pre-commit run --all-files
bash scripts/kustomize-build-all.sh
bash scripts/sync-image-tags.sh
python3 scripts/sync-authconfig-rego.py
```

Diff the kustomize build output for affected overlays against the
baseline to confirm only intended changes appear.

## Session Artifacts

Update `.ai-bot/session-context.md` with a summary of this feedback
round (what changed, what was kept, why).

Write `.ai-bot/comment-responses.json` with per-comment response
summaries matching the comment IDs from the task file.

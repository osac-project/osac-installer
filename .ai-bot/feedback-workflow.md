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

2. **Values consistency**: If feedback applies to one values file, check
   whether other values files (development, vmaas-ci, caas-ci)
   need the same change. Call this out in your response.

## Post-Change Validation

After addressing all review comments, run the full validation suite:

```
yamllint --strict .
pre-commit run --all-files
helm lint charts/osac/
for f in values/*/values.yaml; do helm template osac charts/osac/ --values "$f" > /dev/null; done
bash scripts/sync-image-tags.sh
```

## Session Artifacts

Update `.ai-bot/session-context.md` with a summary of this feedback
round (what changed, what was kept, why).

Write `.ai-bot/comment-responses.json` with per-comment response
summaries matching the comment IDs from the task file.

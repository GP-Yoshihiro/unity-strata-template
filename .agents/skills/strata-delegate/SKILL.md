---
name: strata-delegate
description: Hand cheap or bulky sub-work (log triage, summaries, first-draft code or tests, diff pre-review) to the local Strata model instead of spending cloud tokens, with Codex or Claude Code staying in charge. Use when a sub-step needs lots of reading but little judgement, or during long unattended loops.
---

# Delegating to the local Strata model

You (Codex / Claude Code) are the lead; Strata (`.strata/launch.json`, http://127.0.0.1:8080) is a worker.

## Check it is running
`tools\strata.cmd health` → prints `"loaded":true` and the model. If not: `tools\strata.cmd up` (ask the user first:
it loads ~60 GB into memory and can take minutes).

## Single question → `ask`
```
tools\strata.cmd ask "List each failing test and the first error line" -File Logs\UnityTest-EditMode.log
git diff | tools\strata.ps1 ask "Point out Unity lifecycle or serialization mistakes in this diff"
tools\strata.cmd ask "Write NUnit EditMode tests for this class" -File Assets\Scripts\Runtime\MathUtil.cs -MaxTokens 4096
```
Good fits: extracting errors from long logs, summarising, boilerplate, test skeletons, naming, first-pass review.
Poor fits: architecture decisions, subtle bugs, anything you cannot verify — keep those yourself.

## Larger sub-task → local Codex
`tools\agent.cmd codex-local "<precise instructions incl. files and acceptance>"` — runs Codex on the local model
in this checkout (use a separate worktree: `tools\task.cmd claim <id> -Worktree`). It is recorded in the private run history (.history/, see team.config.json).

## Rules
- Always verify the worker's output (build/test it, read it) before committing. The local model is small and makes mistakes.
- Send only what is needed (extract the relevant log lines / files); the context window is 64K.
- When you run under `tools\agent.cmd`, each `ask` is appended to the same run record automatically.

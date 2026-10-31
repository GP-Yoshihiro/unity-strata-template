---
name: team-workflow
description: Claim, work on and finish a task in this repo without clashing with other people or agents (atomic claims, task paths, one branch and PR per task). Use before starting any change, when picking a task, before pushing, and when asked who is working on what.
---

# Team workflow (this repository)

Several humans and AI agents may work here at the same time. Never start editing before you hold a claim.

## Start
1. `tools\task.cmd list` — open tasks and who holds which claim (`doing (stale Nh)` = probably abandoned; ask).
2. Pick a `todo` task, or create one: `tools\task.cmd new "title" -Paths <folders/files> -Refs cs:...`.
   spec-kit plans become tasks with `tools\task.cmd import specs\<feature>\tasks.md` (review the imported `paths`,
   commit `Tasks/items`). Do not run `/speckit.implement` on unclaimed work.
3. `tools\task.cmd claim <id> -Agent <claude|codex|codex-local|claude-local>`; add `-Worktree` when another agent
   works in the same checkout. "already claimed" or "Paths overlap" → do NOT work on it; pick another or ask.
4. You are now on branch `task/<id>-...`. Only edit the task's `paths`.

## While working
- Scenes / prefabs only if listed in `paths`. Binary art (psd/fbx/blend): `git lfs lock <file>` first.
- End every commit message with a `Task: <id>` line (the loop does this itself), so `git log --grep "Task: <id>"`
  finds the task's commits.
- Pre-commit blocks missing/orphan `.meta`, files over 5 MB outside LFS and a stale context index: fix, never
  `--no-verify`.

## Finish
1. `tools\unity.cmd test All` → 0 and `tools\strata-index.cmd -Verify` → 0.
2. `tools\task.cmd done <id>` (claim → "review"; released automatically when the PR is merged or closed),
   `git push -u origin <branch>`, open a PR from the template.
3. Need a human decision: `tools\task.cmd block <id> -Note "why"`. Giving up: `tools\task.cmd release <id>`.
   Never release someone else's claim.

---
name: team-workflow
description: Claim, work on and finish a task in this shared multi-person / multi-agent repo without clashing with others, and keep work attributable (who, which agent, which instructions). Use before starting any change, when picking a task, before pushing, and when asked who is working on what or what an agent was told.
---

# Team workflow (this repository)

Several humans and AI agents work here at the same time. Never start editing before you hold a claim.

## Start
1. `tools\task.cmd list` — open tasks and who holds which claim.
2. Pick a `todo` task (or create one: `tools\task.cmd new "title" -Paths <folders/files> -Refs cs:...`).
3. `tools\task.cmd claim <id> -Agent <claude|codex|codex-local>`; add `-Worktree` when another agent works in the same checkout.
   - "already claimed" or "Paths overlap" → do NOT work on it; pick another task or ask the user.
4. You are now on branch `task/<id>-...`. Only edit the task's `paths`.

## While working
- Scenes / prefabs: only if listed in your task's `paths`. Binary art (psd/fbx/blend): `git lfs lock <file>` first.
- Commit normally; hooks add `Task:` (and `Agent:` / `Run-Record:` inside `tools\agent.cmd`). Never `--no-verify`.
- Pre-commit blocks missing/orphan `.meta`, files >5 MB outside LFS, stale context index: fix, don't bypass.

## Finish
1. `tools\unity.cmd test All` → exit 0; `tools\strata-index.cmd -Verify` → exit 0.
2. `tools\task.cmd done <id>` (the claim moves to "review" and is released automatically when the PR is merged
   or closed), `git push -u origin <branch>`, open a PR and fill the template. In the PR, reference agent runs only
   as `history:runs/...` -- never paste prompts (this repository is public).
3. Need a human decision: `tools\task.cmd block <id> -Note "why"`. Giving up instead: `tools\task.cmd release <id>`.

## Questions about the team
- Who is doing what: `tools\team.cmd status`
- What an agent was told / did: `tools\team.cmd history [-Task <id>] [-User <name>] [-Agent <name>] [-Days n]`,
  then `tools\team.cmd run <run-id>` for the full prompt and result.
- Commits of a task: `git log --all --grep "Task: <id>"`

---
name: autonomous-loop
description: Run and look after the unattended 24-hour development loop (tools/loop.ps1) with Claude Code, Codex or the local Strata model — prepare a loop clone, start/stop it, choose its agent, read its log and metrics, review its self-improvement PRs, and fix what makes it stall. Use when asked to run the project unattended / overnight / 24時間稼働, or when the loop misbehaves.
---

# Unattended 24h loop

Per task, `tools\loop.cmd` does: pick the highest-priority `todo` task on `main` → claim it (`refs/claims/<id>`)
→ the agent edits only the task's `paths` (child process, stopped after `-AgentTimeoutMinutes`, default 30) →
the runner reverts out-of-scope changes, generates `.meta`, updates the index and runs the Unity tests
(`UNITY_TIMEOUT_MINUTES`, default 60) → failures go back to the agent (`-MaxFixRounds`, default 2) → commit,
`done` / `block`, push, PR (draft when failing) → reset the tree → next task.
Every 24 h (`-ImproveEveryHours`; at most every 6 h when the queue is empty) a self-improvement pass turns the
metrics into a **draft PR** (report, `Docs/agent-lessons.md`, prompt fixes, task splits). The loop only uses what
is on `main`, so nothing it proposes takes effect before a human merges it.

## Prepare (once per loop machine)
1. A dedicated clone nobody opens in the Editor, at a short path:
   `git clone <repo> C:\dev\<name>-agent`, then `git config core.hooksPath .githooks` and
   `git lfs install --local --skip-repo` and `git lfs pull` in it.
2. `tools\unity.cmd test EditMode` exits 0 there (licence active, project compiles).
3. `gh auth status` OK (the loop opens PRs). The agent CLI is logged in; for `codex-local` / `claude-local`,
   `tools\strata.cmd health` shows the model (the loop runs `up` itself when Strata is down).
4. Tasks on `main` with narrow `paths` and `acceptance` (`tools\task.cmd new ...` or `tools\task.cmd import <tasks.md>`).

## Run
- First `tools\loop.cmd -Once`, then `tools\loop.cmd`. Agent: `team.config.json` `loopAgent`, or
  `-Agent claude | codex | codex-local | claude-local`. Options: `-TestPlatform All`, `-MaxTasks n`, `-ImproveNow`.
- Survive reboots: a Windows Task Scheduler task "At log on" running `tools\loop.cmd` in the loop clone
  (create it only when the user asks).
- Stop: `tools\loop.cmd -Stop` (finishes the current task first).

## Watch and fix
- `Logs\loop.log` (what happened), `Logs\loop-metrics.jsonl` (one line per task: rounds, passed, compiler error
  codes, out-of-scope files, minutes), `tools\task.cmd list` (`doing (stale Nh)` = a crashed loop; check, then
  `tools\task.cmd release <id>`), open draft PRs.
- Exit 124 = agent or Unity timeout. "No test results" = licence, compile error or Unity did not start.
  Preflight refusal = dirty tree or `Temp/UnityLockfile` (Editor open). Uncommitted work is saved to
  `Logs\loop-unsaved-*.patch` before each reset.
- A failure that keeps coming back → a one-line rule in `Docs/agent-lessons.md` (prepended to every loop prompt).

## Rules for agents started by the loop
Edit files only, inside the task's `paths`. Never run Unity, `tools\unity.*`, `git commit` or `git push`; never
create or edit `.meta` files -- the runner does all of that outside the sandbox.

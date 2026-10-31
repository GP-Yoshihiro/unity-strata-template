---
name: unity-workflow
description: Run this Unity project's batch-mode tests, regenerate .meta files, move/delete assets safely, and refresh the Strata context index. Use whenever C# code under Assets/ is added, changed, moved or deleted, or before committing.
---

# Unity workflow (this repository)

The Unity Editor path is resolved per machine by `tools/find-unity.ps1`.
Never hard-code an editor path.

## Implement → verify loop
1. Read your claimed task in `Tasks/items/<id>.json` (see the team-workflow skill); open only the files behind
   its `strataRefs` (look the ids up in `.strata/strata_index.json` → `symbols[].path`). Read `Docs/agent-lessons.md`.
2. Edit / add C# files.
3. If files were added: `tools\unity.cmd refresh` — Unity writes the `.meta` files. Commit them.
4. Run tests: `tools\unity.cmd test EditMode` (`PlayMode`, `All`).
   Exit code 0 = pass, 2 = tests failed (see `Logs/editmode-results.xml`), anything else = Unity error (see `Logs/UnityTest-EditMode.log`; grep `error CS`).
5. `tools\strata-index.cmd` then `tools\strata-index.cmd -Verify`.
6. Commit, then finish the task with `tools\task.cmd done <id>` and open a PR (team-workflow skill).

## Moving / deleting assets
Never touch `.meta` files by hand:
- `tools\unity.cmd exec Game.Editor.BatchEntry.MoveAsset -from Assets/Old.cs -to Assets/New/Old.cs`
- `tools\unity.cmd exec Game.Editor.BatchEntry.DeleteAsset -path Assets/Old.cs`

## Local model (Strata)
Long-running loops use the local Strata server (`.strata/launch.json`), reached by Codex through
`tools\codex-local.cmd` (its own `CODEX_HOME` in `.codex-local/`, generated from `tools/templates/codex-local.config.toml`).
- `tools\strata.cmd health` — is the server up and which model is loaded
- `tools\strata.cmd up` / `stop` — start (downloads on first run) / unload and free memory
- Keep prompts in L1 → L2 → L3 order (`.strata/cache_config.json`) so the unchanged prefix is served from the prompt cache;
  pass extracted errors (`error CS\d{4}`, failed test names), not whole logs.

## Editor version
- `tools\unity.cmd install` installs the exact version + changeset from `ProjectVersion.txt`
  with the Unity Hub CLI. Extra args go to the Hub, e.g. `--module android`.
- Moving the project to another Unity version is a task of its own (paths `ProjectSettings/`, `Packages/`):
  `tools\unity.cmd upgrade <version>` installs it, opens the project once in batch mode, then run `test All` and open a PR.
- The finder never silently uses an older editor or another major.minor (only a newer patch, with a warning).

## Troubleshooting
- "Unity Editor ... not found": `tools\unity.cmd install`, or set `UNITY_EDITOR_PATH`, or write the path
  (absolute or repo-relative) into `.unity-path.local`.
  `tools\unity.cmd path` / `tools\find-unity.ps1 -List` show what was found.
- Exit code 124: the run hit `UNITY_TIMEOUT_MINUTES` (default 60) and was stopped.
- Exit code 1 with no result XML: Unity never ran the tests (licence not activated, compile error, start-up failure).
- Batch run exits immediately with code 1 and an empty log: the project is open in the Editor
  (`Temp/UnityLockfile`), or (Windows) the repo path is too long — clone to e.g. `C:\dev\<name>`.
- Sandboxed agents (Codex): Unity needs licence files, `%LOCALAPPDATA%\Unity` and network for packages;
  request escalated execution for `tools/unity.*`.

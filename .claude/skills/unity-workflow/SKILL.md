---
name: unity-workflow
description: Run this Unity project's batch-mode tests, regenerate .meta files, move/delete assets safely, and refresh the Strata context index. Use whenever C# code under Assets/ is added, changed, moved or deleted, or before committing.
---

# Unity workflow (this repository)

The Unity Editor path is resolved per machine by `tools/find-unity.ps1` / `tools/find-unity.sh`.
Never hard-code an editor path.

## Implement → verify loop
1. Read the task in `Tasks/backlog.json`; open only the files behind its `strataRefs`
   (look the ids up in `.strata/strata_index.json` → `symbols[].path`).
2. Edit / add C# files.
3. If files were added: `tools/unity.cmd refresh` (Windows) or `tools/unity.sh refresh` — Unity writes the `.meta` files. Commit them.
4. Run tests:
   - Windows: `tools\unity.cmd test EditMode` (`PlayMode`, `All`)
   - macOS/Linux/Git Bash: `tools/unity.sh test EditMode`
   Exit code 0 = pass, 2 = tests failed (see `Logs/editmode-results.xml`), anything else = Unity error (see `Logs/UnityTest-EditMode.log`; grep `error CS`).
5. `tools\strata-index.cmd` then `tools\strata-index.cmd -Verify` (or `pwsh tools/strata-index.ps1 [-Verify]`).
6. Move the task to `Tasks/completed.json`, commit (one task per commit).

## Moving / deleting assets
Never touch `.meta` files by hand:
- `tools\unity.cmd exec Game.Editor.BatchEntry.MoveAsset -from Assets/Old.cs -to Assets/New/Old.cs`
- `tools\unity.cmd exec Game.Editor.BatchEntry.DeleteAsset -path Assets/Old.cs`

## Local model (Strata)
Long-running loops use the local Strata server (`.strata/launch.json`), reached by Codex with `--profile strata`.
- `tools\strata.cmd health` — is the server up and which model is loaded
- `tools\strata.cmd up` / `stop` — start (downloads on first run) / unload and free memory
- Keep prompts in L1 → L2 → L3 order (`.strata/cache_config.json`) so the unchanged prefix is served from the prompt cache;
  pass extracted errors (`error CS\d{4}`, failed test names), not whole logs.

## Troubleshooting
- "Unity Editor ... not found": install the version in `ProjectSettings/ProjectVersion.txt` with Unity Hub,
  or set `UNITY_EDITOR_PATH`, or write the path (absolute or repo-relative) into `.unity-path.local`.
  `tools\unity.cmd path` / `tools/find-unity.sh --list` show what was found.
- Batch run exits immediately with code 1 and an empty log: the project is open in the Editor
  (`Temp/UnityLockfile`), or (Windows) the repo path is too long — clone to e.g. `C:\dev\<name>`.
- Sandboxed agents (Codex): Unity needs licence files, `%LOCALAPPDATA%\Unity` and network for packages;
  request escalated execution for `tools/unity.*`.

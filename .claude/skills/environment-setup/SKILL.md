---
name: environment-setup
description: Set up this Unity + AI template on a Windows PC from the downloaded ZIP, end to end — new GitHub repository, Unity version, Strata local model, main-AI connection, Unity dev environment, skills/plugins/spec-kit, first verification run. Use when the user asks to set up / bootstrap / 環境を立ち上げて, or when tools fail because git hooks, Unity or Strata are not set up yet.
---

# Environment setup (done by the main AI)

You (Claude Code or Codex) do the work; the user only makes the choices marked **Ask**. Use PowerShell from the
repo root. Every step is re-runnable: check first, skip what is done, report what you changed. Never install or
download anything without the user's OK. Until step 7 protects `main`, commit setup changes directly to `main`
(`$env:ALLOW_MAIN_PUSH=1; git push origin main; Remove-Item Env:ALLOW_MAIN_PUSH` -- the pre-push hook guards it).

## 0. Prerequisites
- Location: if the folder is under Downloads / Desktop / OneDrive or the path is longer than ~60 characters,
  **Ask** to copy it to `C:\dev\<repo name>` and continue there (deep paths break Unity and agent sandboxes).
- `git`, `git lfs`, `gh` missing → **Ask**, then `winget install --id Git.Git -e` / `GitHub.GitLFS` / `GitHub.cli`
  (refresh PATH or open a new shell). `git config --global user.name` / `user.email` set (**Ask** for values).
  `gh auth status`, else `gh auth login --web`.

## 1. New GitHub repository
**Ask**: owner (the user or an org from `gh api user/orgs --jq '.[].login'`), repository name, visibility
(private = recommended / public / internal for orgs).
```powershell
git init -q; git symbolic-ref HEAD refs/heads/main
git lfs install --local --skip-repo          # LFS filters before the first add, or binaries go in as plain blobs
git add -A; git commit -q -m "Import unity-strata-template"
git config core.hooksPath .githooks; git config lfs.locksverify true
```
If the folder is already a clone of the template, skip `init` and run `git remote rename origin template` instead.
Personalise: replace any `GP-Yoshihiro/unity-strata-template` reference with `<owner>/<name>`; set `productName:` in
`ProjectSettings/ProjectSettings.asset` to the name. Commit, then
`gh repo create <owner>/<name> --private --source . --remote origin` and push `main` as above.

## 2. Unity version
- Project version: `ProjectSettings/ProjectVersion.txt`; installed editors: `tools\find-unity.ps1 -List`.
- Latest releases: `Invoke-RestMethod "https://services.api.unity.com/unity/editor/release/v1/releases?limit=3&order=RELEASE_DATE_DESC&stream=LTS"`
  (and `stream=TECH`) → `results[].version`, `.shortRevision`, `.releaseDate`. If unreachable, offer the project
  version or a typed one.
- **Ask**: version (project's / latest LTS -- recommended for 24h and team work / latest Update / installed) and
  build modules (`windows-il2cpp`, `android` + `--childModules`, `ios`, `webgl`).
- `tools\unity.cmd install <version> [--changeset <rev>] [--module <id> ...]` (no Unity Hub → **Ask**,
  `winget install --id Unity.UnityHub -e`). Then ask the user to sign in to Unity Hub once and activate a licence
  (batch mode needs it) and wait for their confirmation.
- Different from the project version → `tools\unity.cmd upgrade <version>`, commit `ProjectSettings/` + `Packages/`.
- Merge driver for scenes/prefabs: with `<tools>` = the editor's `Data\Tools` folder (forward slashes),
  `git config merge.unityyamlmerge.name "Unity SmartMerge"`,
  `git config merge.unityyamlmerge.driver "'<tools>/UnityYAMLMerge.exe' merge -p %O %B %A %A"`,
  `git config merge.unityyamlmerge.recursive binary`.

## 3. Strata local model (optional)
**Ask** whether to use a local model (saves cloud tokens; needs a strong PC). If yes:
- Not installed (`tools\strata.cmd where` fails) → **Ask**; download
  `https://github.com/Niko1221/Strata/releases/latest/download/install.ps1` to a file, show its path and
  `Get-FileHash` SHA256, run it with `powershell -ExecutionPolicy Bypass -File <file>` after the OK. Never pipe a
  download into `iex`.
- Hardware: RAM `(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory`, GPUs `Get-CimInstance Win32_VideoController`,
  VRAM `nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits`, free space on the `%LOCALAPPDATA%` drive.
- Show `.strata/models.json` as a table **sorted by `rank` (smartest first)**: name, GPU load (`tier`: 超高/高/中/低,
  meanings in `tiers`), `memGB` (VRAM+RAM), `downloadGB`, fit on this PC (o = RAM+VRAM ≥ memGB×1.15, enough disk,
  vendor in `vendors`; ~ = ≥ memGB; x = otherwise) and `note` (`codexOk: false` = 8K context, not for Codex).
  Recommend the highest-ranked "o" model. **Ask** which one.
- Write `.strata/launch.json`: `family`, `model`, `vision: "off"`, `port: 8080`, `contextTokens`, `launchArgs`
  (models.json's, plus `--context`, `64k` as a first try). Check with `tools\strata.cmd plan`; if refused retry with
  the lower-case model id, then without `--context`.
- **Ask** before `tools\strata.cmd up` (downloads `downloadGB`), then `tools\strata.cmd health`.

## 4. Main AI and Strata
**Ask**: main AI (Claude Code / Codex / both) and the agent of the 24h loop (`codex-local` with Strata, else
`claude` or `codex`; `claude-local` = Claude Code on Strata, experimental).
- Missing CLI → **Ask**: `npm install -g @anthropic-ai/claude-code` / `npm install -g @openai/codex`
  (Node: `winget install --id OpenJS.NodeJS.LTS -e`). Log in: run `claude` once / `codex login`.
- Strata running: copy `(Invoke-RestMethod http://127.0.0.1:8080/v1/models).data[0].id` into
  `tools/templates/codex-local.config.toml` (`model`; `model_context_window` = contextTokens;
  `model_auto_compact_token_limit` ≈ half). Check `tools\strata.cmd check` (Codex) and `tools\strata.cmd ask "Reply OK"`.
- Save `mainAgent` and `loopAgent` in `team.config.json`.

## 5. Unity development environment
- IDE (**Ask**): VS Code → `code --install-extension visualstudiotoolsforunity.vstuc`; Visual Studio → Visual Studio
  Installer → Import configuration → `.vsconfig`; Rider. Then Unity → Preferences → External Tools.
- Packages (**Ask**, several): `com.unity.inputsystem`, `com.unity.ugui`, `com.unity.render-pipelines.universal`,
  `com.unity.cinemachine`, `com.unity.ai.navigation`, `com.unity.timeline`, `com.unity.addressables`
  → `tools\unity.cmd packages add <id>,<id>`.
- `tools\unity.cmd refresh`, `tools\unity.cmd test EditMode` (must exit 0), `tools\strata-index.cmd`. Commit.

## 6. Skills, plugins, spec-kit
- Skills: Codex reads `.agents/skills`; copy them for Claude Code: `Copy-Item .agents\skills\* .claude\skills -Recurse -Force`.
- Claude Code plugins (**Ask**): `claude plugin install <name> --scope project` (shared via `.claude/settings.json`).
  If a name is not found, tell the user to search with `/plugin` in Claude Code.
- spec-kit (**Ask**): `winget install --id astral-sh.uv -e` → `uv tool install specify-cli` →
  `specify init --here --integration claude` (or `codex`; read `specify init --help` for the exact flags, add
  `--script ps --force`). Replace `.specify/memory/constitution.md` with `constitution.ja.md` from this folder
  (fill `{PROJECT}`, `{DATE}`). Afterwards: `/speckit.specify` → `/speckit.plan` → `/speckit.tasks` →
  `tools\task.cmd import specs\<feature>\tasks.md` → claim → implement (or the loop).

## 7. Verify and finish
- **Ask** for a verification instruction: a file path or a typed prompt. Then
  `tools\task.cmd new "Try: <short title>" -Paths Assets/Scripts/Runtime/Sandbox,Assets/Tests/EditMode/Sandbox`,
  `tools\task.cmd claim <id> -Agent <agent>`, `tools\agent.cmd <agent> -PromptFile <file>` (or `"<prompt>"`),
  `tools\unity.cmd refresh`, `tools\unity.cmd test EditMode`, show `git status`.
  **Ask**: draft PR (commit, `tools\task.cmd done <id>`, push, `gh pr create --draft`) / keep the branch / discard
  (`git reset --hard; git clean -fd; git switch main; git branch -D <branch>; tools\task.cmd release <id>`).
- **Ask** to protect `main`: `gh api -X PUT repos/<owner>/<name>/branches/main/protection --input <json>` with
  `required_status_checks {strict: true, contexts: ["repo-checks"]}`, `required_pull_request_reviews
  {required_approving_review_count: 0}`, `enforce_admins: false`, `restrictions: null`, `allow_force_pushes: false`.
  (Not available for private repos on GitHub Free -- say so.)
- Summarise: repository URL, Unity version, Strata model, main AI, loop agent, and the next step
  (the autonomous-loop skill).

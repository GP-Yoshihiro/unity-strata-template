<#
.SYNOPSIS
  Per-machine setup after cloning OR after downloading the project as a ZIP. Safe to re-run.
  - ZIP download (no .git): initialises git, commits the downloaded files and starts a new branch
  - checks git / git-lfs, enables LFS and the shared team hooks for this repo
  - creates the hidden private run-history folder (.history), synced with the private history repo
    from team.config.json when you have access, otherwise local only
  - locates the Unity Editor and registers UnityYAMLMerge as a merge driver (repo-local git config)
  - syncs the shared agent skills (.agents/skills -> .claude/skills)
  - rebuilds the context index (.strata/strata_index.json)
  - reports whether the Strata local model server is installed

.PARAMETER Branch
  Branch to create. For a ZIP download it defaults to local/<your git user name>; for a clone it is only
  created when given.

.PARAMETER Remote
  For a ZIP download: URL to add as origin (for example your team's fork). Optional.

.EXAMPLE
  tools\setup.cmd
  tools\setup.cmd -Branch feature/my-game -Remote https://github.com/me/my-game.git
#>
param(
    [string]$Branch,
    [string]$Remote
)
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $RepoRoot
try {
    Write-Host '== git'
    git --version
    git lfs version
    if ($LASTEXITCODE -ne 0) { throw 'git-lfs is not installed: https://git-lfs.com' }
    if (-not (git config user.name)) { throw 'git user.name is not set -- task claims and history need it: git config --global user.name "<name>" (and user.email)' }

    # A "Download ZIP" copy has no .git: turn it into a repository and work on a new branch
    # (.git is a folder in clones and a file in worktrees; a ZIP unpacked inside another repo has neither)
    . (Join-Path $PSScriptRoot 'lib/team.ps1')
    $zipImport = -not (Test-Path -LiteralPath (Join-Path $RepoRoot '.git'))
    if ($zipImport) {
        Write-Host 'No git repository here (ZIP download): initialising one'
        git init -q
        git symbolic-ref HEAD refs/heads/main   # same as `git init -b main`, but works on git < 2.28
        # LFS filters must be active BEFORE the first `git add`, or binaries are committed as plain blobs
        git lfs install --local --skip-repo | Out-Null   # filters only: .githooks already chain the LFS hooks
        git add -A
        git commit -q -m 'Import unity-strata-template (ZIP download)'
        if (-not $Branch) { $Branch = 'local/' + ((git config user.name) -replace '[^A-Za-z0-9_-]', '').ToLower() }
        if ($Remote) { git remote add origin $Remote; Write-Host "origin -> $Remote" }
    }
    if ($Branch) {
        $exists = git branch --list $Branch
        if ($exists) { git switch -q $Branch } else { git switch -q -c $Branch }
        Write-Host "Working branch: $Branch"
    }

    git lfs install --local --skip-repo | Out-Null   # filters only: .githooks already chain the LFS hooks
    if (git remote) { git lfs pull }
    # Shared team hooks (meta check, attribution trailers, no direct push to main); they chain to LFS.
    git config --local core.hooksPath .githooks
    git config --local lfs.locksverify true
    Write-Host 'Team hooks enabled (.githooks)'

    Write-Host '== private run history'
    $history = Sync-History
    $where = if (Test-HistoryRepo $history) { "synced with $((Get-TeamConfig).historyRepo)" } else { 'local only' }
    Write-Host "History folder: $history (hidden, ignored by git, $where)"

    Write-Host '== Unity'
    & (Join-Path $PSScriptRoot 'find-unity.ps1') -List
    $unity = $null
    try { $unity = & (Join-Path $PSScriptRoot 'find-unity.ps1') } catch {
        # Keep going: hooks, history, skills and the index do not need Unity. Install it, then re-run setup.
        Write-Warning "$($_.Exception.Message)`nInstall it with: tools\unity.cmd install   (then re-run tools\setup.cmd)"
    }
    $yamlMerge = $null
    if ($unity) {
        Write-Host "Using: $unity"
        $editorDir = Split-Path -Parent $unity
        $yamlMerge = @(
            (Join-Path $editorDir 'Data/Tools/UnityYAMLMerge.exe'),
            (Join-Path $editorDir 'Data/Tools/UnityYAMLMerge'),
            (Join-Path $editorDir '../Resources/Tools/UnityYAMLMerge')
        ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    }
    if ($yamlMerge) {
        $yamlMerge = (Resolve-Path -LiteralPath $yamlMerge).Path.Replace('\', '/')
        git config --local merge.unityyamlmerge.name 'Unity SmartMerge'
        git config --local merge.unityyamlmerge.driver "'$yamlMerge' merge -p %O %B %A %A"
        git config --local merge.unityyamlmerge.recursive binary
        Write-Host "UnityYAMLMerge registered: $yamlMerge"
    } else {
        Write-Warning 'UnityYAMLMerge not found; scene/prefab conflicts will use the default text merge.'
    }

    Write-Host '== agent skills'
    $src = Join-Path $RepoRoot '.agents/skills'
    $dst = Join-Path $RepoRoot '.claude/skills'
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force
    Write-Host "Synced $src -> $dst"

    Write-Host '== context index'
    & (Join-Path $PSScriptRoot 'strata-index.ps1')

    Write-Host '== strata (local model server)'
    try {
        & (Join-Path $PSScriptRoot 'strata.ps1') version
        Write-Host 'Next: tools\strata.cmd plan, then tools\strata.cmd up'
    } catch {
        Write-Warning "Strata Terminal not installed (optional, for local-model runs). Install: $(& (Join-Path $PSScriptRoot 'strata.ps1') install)"
    }

    Write-Host '== new-project check'
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $origin = git remote get-url origin 2>$null
    $ErrorActionPreference = $prevEap
    $histRepo = (Get-TeamConfig).historyRepo
    $ownerOf = { param($u) $m = [regex]::Match("$u", 'github\.com[:/]([^/]+)/'); if ($m.Success) { $m.Groups[1].Value } else { '' } }
    if ($histRepo -and $origin -and ((& $ownerOf $histRepo) -ne (& $ownerOf $origin))) {
        Write-Warning "team.config.json historyRepo ($histRepo) belongs to a different owner than origin ($origin). For a new project: create your own PRIVATE history repo, then edit team.config.json and .github/CODEOWNERS."
    }
    if ($zipImport -and $Remote) {
        Write-Host 'First push of a new repository (the pre-push hook blocks main otherwise):'
        Write-Host '  $env:ALLOW_MAIN_PUSH = 1; git push -u origin main; Remove-Item Env:ALLOW_MAIN_PUSH'
        Write-Host "  git push -u origin $Branch"
    }

    Write-Host "`nSetup complete. Try: tools\unity.cmd test EditMode"
} finally { Pop-Location }

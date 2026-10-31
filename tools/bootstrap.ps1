<#
.SYNOPSIS
  One-stop setup wizard for a new project made from this template (Windows PowerShell 5.1 / PowerShell 7).

.DESCRIPTION
  Run it from the folder you unpacked (ZIP) or cloned:  bootstrap.cmd   (or: tools\bootstrap.ps1)
  Steps -- each one can be re-run alone with -Step <name>; answers and progress are kept in
  .bootstrap.local.json (machine-local, ignored by git):
    prereq    git / Git LFS / GitHub CLI / git user name, installed with winget when missing
    repo      create the new GitHub repository (name + visibility), personalise the template, first push
    unity     choose the Unity version (this template's / LTS / latest / installed / typed) and install it
    strata    install Strata and pick a model, listed by capability with GPU load and fit for this PC
    connect   connect the main AI (Claude Code / Codex) with Strata; choose the agent of the 24h loop
    unitydev  IDE, Unity packages, first import and first EditMode test
    skills    agent skills, Claude Code plugins and spec-kit
    verify    try everything with a prompt file or a typed prompt (tools/try.ps1)
    finish    branch protection and a summary
  On-screen text lives in tools/bootstrap/messages.ja.json, model and package lists in tools/bootstrap/*.json
  (PowerShell files stay ASCII so Windows PowerShell 5.1 reads them correctly).

.EXAMPLE
  bootstrap.cmd
  tools\bootstrap.ps1 -Step strata
  tools\bootstrap.ps1 -RepoName my-game -Visibility private -MainAI claude
  tools\bootstrap.ps1 -Reset            # forget the saved progress and start over
#>
param(
    [ValidateSet('all', 'prereq', 'repo', 'unity', 'strata', 'connect', 'unitydev', 'skills', 'verify', 'finish')][string]$Step = 'all',
    [string]$RepoName,
    [string]$Owner,
    [ValidateSet('', 'private', 'public', 'internal')][string]$Visibility = '',
    [ValidateSet('', 'claude', 'codex', 'both')][string]$MainAI = '',
    [switch]$Reset
)
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Tools = $PSScriptRoot
$OnWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows
$Utf8 = New-Object Text.UTF8Encoding $false
try { [Console]::OutputEncoding = $Utf8 } catch { }
# Windows PowerShell 5.1 may default to TLS 1.0/1.1, which GitHub and Unity's API refuse
if ($PSVersionTable.PSEdition -eq 'Desktop') { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 }
$TemplateSlug = 'GP-Yoshihiro/unity-strata-template'
$TemplateOwner = 'GP-Yoshihiro'
$StateFile = Join-Path $RepoRoot '.bootstrap.local.json'
$StepNames = @('prereq', 'repo', 'unity', 'strata', 'connect', 'unitydev', 'skills', 'verify', 'finish')

. (Join-Path $Tools 'lib/team.ps1')
$Msg = Get-Content -LiteralPath (Join-Path $Tools 'bootstrap/messages.ja.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$Catalog = Get-Content -LiteralPath (Join-Path $Tools 'bootstrap/catalog.json') -Raw -Encoding UTF8 | ConvertFrom-Json

# ---------------------------------------------------------------- UI helpers

function T([string]$Key) {
    $s = $Msg.$Key
    if (-not $s) { $s = $Key }
    if ($args.Count -gt 0) { return [string]::Format($s, [object[]]$args) }
    return $s
}
function Say([string]$Key) { Write-Host (T $Key @args) }
function Note([string]$Key) { Write-Host (T $Key @args) -ForegroundColor DarkGray }
function Good([string]$Key) { Write-Host (T $Key @args) -ForegroundColor Green }
function Warn([string]$Key) { Write-Host (T $Key @args) -ForegroundColor Yellow }

function Ask-Text([string]$Prompt, [string]$Default) {
    $p = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
    $a = Read-Host $p
    if (-not $a) { $a = $Default }
    return "$a".Trim()
}

function Ask-YesNo([string]$Prompt, [bool]$Default = $true) {
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $a = "$(Read-Host "$Prompt $hint")".Trim().ToLower()
        if (-not $a) { return $Default }
        if ($a -in 'y', 'yes') { return $true }
        if ($a -in 'n', 'no') { return $false }
    }
}

function Ask-Choice([string]$Prompt, [string[]]$Items, [int]$Default = 1) {
    for ($i = 0; $i -lt $Items.Count; $i++) { Write-Host ('  {0,2}) {1}' -f ($i + 1), $Items[$i]) }
    while ($true) {
        $a = "$(Read-Host "$Prompt [$Default]")".Trim()
        if (-not $a) { return ($Default - 1) }
        $n = 0
        if ([int]::TryParse($a, [ref]$n) -and $n -ge 1 -and $n -le $Items.Count) { return ($n - 1) }
        Say 'invalid_choice'
    }
}

function Ask-Multi([string]$Prompt, [string[]]$Items, [int[]]$Defaults) {
    # Returns the chosen 0-based indexes. Input: "1,3,4"; Enter = defaults; 0 = none.
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $mark = if ($Defaults -contains $i) { '*' } else { ' ' }
        Write-Host ('  {0,2}) [{1}] {2}' -f ($i + 1), $mark, $Items[$i])
    }
    Note 'multi_hint'
    while ($true) {
        $a = "$(Read-Host $Prompt)".Trim()
        if (-not $a) { return @($Defaults) }
        if ($a -eq '0') { return @() }
        $picked = @()
        $ok = $true
        foreach ($part in ($a -split '[,\s]+' | Where-Object { $_ })) {
            $n = 0
            if ([int]::TryParse($part, [ref]$n) -and $n -ge 1 -and $n -le $Items.Count) { $picked += ($n - 1) } else { $ok = $false }
        }
        if ($ok) { return @($picked | Select-Object -Unique) }
        Say 'invalid_choice'
    }
}

function Show-Section([int]$Index, [string]$Name) {
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host (T 'section' $Index $StepNames.Count (T "step_$Name")) -ForegroundColor Cyan
    Write-Host (T "step_$($Name)_desc") -ForegroundColor DarkGray
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
}

# ---------------------------------------------------------------- state

function Get-State {
    if (Test-Path -LiteralPath $StateFile) { return (Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json) }
    return [pscustomobject]@{ done = @() }
}
function Save-State($State) { [IO.File]::WriteAllText($StateFile, ($State | ConvertTo-Json -Depth 6), $Utf8) }
function Get-StateValue([string]$Key) { return (Get-State).$Key }
function Set-StateValue([string]$Key, $Value) {
    $s = Get-State
    $s | Add-Member -NotePropertyName $Key -NotePropertyValue $Value -Force
    Save-State $s
}
function Complete-Step([string]$Name) {
    $s = Get-State
    $s.done = @(@($s.done) + $Name | Where-Object { $_ } | Select-Object -Unique)
    Save-State $s
}

# ---------------------------------------------------------------- process helpers

function Test-Cmd([string]$Name) { return [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

function Update-SessionPath {
    # Picks up tools installed by winget / installers without reopening the terminal
    if ($OnWindows) {
        $m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $u = [Environment]::GetEnvironmentVariable('Path', 'User')
        $env:Path = (@($m, $u, $env:Path) | Where-Object { $_ }) -join ';'
    }
    $local = Join-Path $HOME '.local/bin'
    $sep = [IO.Path]::PathSeparator
    if ((Test-Path -LiteralPath $local) -and ($env:Path -split [regex]::Escape($sep)) -notcontains $local) { $env:Path = "$local$sep$env:Path" }
}

function Invoke-Tool([scriptblock]$Block) {
    # Runs a tools/*.ps1 call (or any command) and returns its exit code; output goes to the screen.
    # A script block, not an argument array: array splatting would pass "-Name" switches as plain values.
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    $code = 0
    try {
        & $Block 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { Write-Host $_.Exception.Message -ForegroundColor Yellow } else { Write-Host "$_" }
        }
        $code = $LASTEXITCODE
    } catch { Write-Host $_.Exception.Message -ForegroundColor Red; $code = 1 }
    finally { $ErrorActionPreference = $prev }
    if ($null -eq $code) { $code = 0 }
    return $code
}

function Invoke-Quiet([string]$Exe) {
    # Native command, output captured as strings (stderr included), never throws
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & $Exe @args 2>&1 | ForEach-Object { "$_" } } catch { $out = @("$_"); $global:LASTEXITCODE = 1 }
    finally { $ErrorActionPreference = $prev }
    return $out
}

function Tool([string]$Name) { return (Join-Path $Tools $Name) }

function Install-WithWinget([string]$Id, [string]$Label, [bool]$Default = $true) {
    if (-not $OnWindows -or -not (Test-Cmd 'winget')) { Warn 'install_manual' $Label; return $false }
    if (-not (Ask-YesNo (T 'ask_install' $Label) $Default)) { return $false }
    $null = Invoke-Tool { & winget install --id $Id -e --accept-source-agreements --accept-package-agreements }
    Update-SessionPath
    return $true
}

function Invoke-RemoteInstaller([string]$Label, [string]$PsUrl, [string]$ShUrl) {
    # Official installer scripts (Strata, uv, Claude Code). Never piped straight into a shell: the script is
    # saved to a file first and its path and SHA256 are shown, so it can be inspected (or scanned) before it runs.
    $url = if ($OnWindows) { $PsUrl } else { $ShUrl }
    if (-not (Ask-YesNo (T 'ask_install_script' $Label $url) $true)) { return $false }
    $ext = if ($OnWindows) { '.ps1' } else { '.sh' }
    $file = Join-Path ([IO.Path]::GetTempPath()) ('installer-' + [Guid]::NewGuid().ToString('N') + $ext)
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $file -TimeoutSec 120
        Say 'installer_downloaded' $file (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
        if (-not (Ask-YesNo (T 'ask_run_installer') $true)) { return $false }
        if ($OnWindows) {
            $shell = (Get-Process -Id $PID).Path
            $null = Invoke-Tool { & $shell -NoProfile -ExecutionPolicy Bypass -File $file }
        } else {
            $null = Invoke-Tool { & sh $file }
        }
    } catch { Warn 'installer_failed' $url $_.Exception.Message; return $false }
    finally { Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue }
    Update-SessionPath
    return $true
}

# ---------------------------------------------------------------- git helpers

function Test-GitRepo { return (Test-Path -LiteralPath (Join-Path $RepoRoot '.git')) }
function Get-OriginUrl {
    if (-not (Test-GitRepo)) { return $null }
    $u = Invoke-Quiet git -C $RepoRoot remote get-url origin
    if ($LASTEXITCODE -ne 0) { return $null }
    return ("$($u | Select-Object -First 1)").Trim()
}
function Get-SlugFromUrl([string]$Url) {
    $m = [regex]::Match("$Url", 'github\.com[:/]([^/]+)/([^/]+?)(\.git)?$')
    if ($m.Success) { return "$($m.Groups[1].Value)/$($m.Groups[2].Value)" }
    return $null
}

function Save-Progress([string]$Message) {
    # Bootstrap commits go straight to main until branch protection is switched on in the last step;
    # after that they go through a branch and a PR like any other change.
    if (-not (Test-GitRepo)) { return }
    $dirty = Invoke-Quiet git -C $RepoRoot status --porcelain
    if (-not ($dirty | Where-Object { $_ })) { return }
    $origin = Get-OriginUrl
    if ((Get-StateValue 'protected') -and $origin) {
        $branch = 'bootstrap/' + (Get-Date).ToString('yyyyMMdd-HHmmss')
        $null = Invoke-Quiet git -C $RepoRoot switch -q -c $branch
        $null = Invoke-Quiet git -C $RepoRoot add -A
        $null = Invoke-Quiet git -C $RepoRoot commit -q -m $Message
        $null = Invoke-Tool { & git -C $RepoRoot push -q -u origin $branch }
        $null = Invoke-Tool { & gh pr create --base main --head $branch --title $Message --body 'tools/bootstrap.ps1' }
        $null = Invoke-Quiet git -C $RepoRoot switch -q main
        return
    }
    $null = Invoke-Quiet git -C $RepoRoot add -A
    $out = Invoke-Quiet git -C $RepoRoot commit -q -m $Message
    if ($LASTEXITCODE -ne 0) { Warn 'commit_failed' ($out -join ' '); return }
    Good 'committed' $Message
    if ($origin) {
        $env:ALLOW_MAIN_PUSH = '1'
        try { $code = Invoke-Tool { & git -C $RepoRoot push -q origin main } } finally { Remove-Item Env:ALLOW_MAIN_PUSH -ErrorAction SilentlyContinue }
        if ($code -ne 0) { Warn 'push_failed' }
    }
}

function Edit-RepoFile([string]$Rel, [scriptblock]$Transform) {
    $p = Join-Path $RepoRoot $Rel
    if (-not (Test-Path -LiteralPath $p)) { return }
    $t = [IO.File]::ReadAllText($p, $Utf8)
    $n = & $Transform $t
    if ($n -ne $t) { [IO.File]::WriteAllText($p, $n, $Utf8) }
}

function Get-ProjectUnityVersion {
    $text = Get-Content -LiteralPath (Join-Path $RepoRoot 'ProjectSettings/ProjectVersion.txt') -Raw
    $m = [regex]::Match($text, 'm_EditorVersionWithRevision:\s*(\S+)\s*\(([0-9a-f]+)\)')
    if ($m.Success) { return [pscustomobject]@{ Version = $m.Groups[1].Value; Changeset = $m.Groups[2].Value } }
    return [pscustomobject]@{ Version = [regex]::Match($text, 'm_EditorVersion:\s*(\S+)').Groups[1].Value; Changeset = $null }
}

# ================================================================ 1. prerequisites

function Step-Prereq {
    foreach ($t in @(
            @{ Cmd = 'git'; Id = 'Git.Git'; Label = 'Git' },
            @{ Cmd = 'git-lfs'; Id = 'GitHub.GitLFS'; Label = 'Git LFS' },
            @{ Cmd = 'gh'; Id = 'GitHub.cli'; Label = 'GitHub CLI (gh)' })) {
        if (-not (Test-Cmd $t.Cmd)) { $null = Install-WithWinget $t.Id $t.Label }
        if (-not (Test-Cmd $t.Cmd)) { throw (T 'missing_required' $t.Label) }
        Good 'found' $t.Label
    }
    if ($OnWindows -and -not (Test-Cmd 'pwsh')) { $null = Install-WithWinget 'Microsoft.PowerShell' 'PowerShell 7' $false }

    foreach ($k in @(@{ Key = 'user.name'; Ask = 'ask_git_name' }, @{ Key = 'user.email'; Ask = 'ask_git_email' })) {
        $v = "$(Invoke-Quiet git config --global $k.Key)".Trim()
        if (-not $v) {
            while (-not $v) { $v = Ask-Text (T $k.Ask) '' }
            $null = Invoke-Quiet git config --global $k.Key $v
        }
        Good 'git_config' $k.Key $v
    }

    $null = Invoke-Quiet gh auth status
    if ($LASTEXITCODE -ne 0) {
        Say 'gh_login'
        $null = Invoke-Tool { & gh auth login --web --git-protocol https }
        $null = Invoke-Quiet gh auth status
        if ($LASTEXITCODE -ne 0) { throw (T 'gh_login_failed') }
    }
    $null = Invoke-Quiet gh auth setup-git   # git push uses the same GitHub login
    Good 'gh_ok' ("$(Invoke-Quiet gh api user --jq .login)".Trim())
}

# ================================================================ 2. new repository

function Step-Repo {
    $origin = Get-OriginUrl
    if ($origin -and ((Get-SlugFromUrl $origin) -ne $TemplateSlug)) {
        Good 'repo_already' $origin
        return
    }
    $login = "$(Invoke-Quiet gh api user --jq .login)".Trim()
    if (-not $login) { throw (T 'gh_login_failed') }

    if (-not $Owner) {
        $orgs = @(Invoke-Quiet gh api user/orgs --jq '.[].login' | Where-Object { $_ -and $_ -notmatch '\s' })
        $script:Owner = $login
        if ($orgs.Count -gt 0) { $opts = @($login) + $orgs; $script:Owner = $opts[(Ask-Choice (T 'ask_owner') $opts 1)] }
    }
    $defaultName = (Split-Path -Leaf $RepoRoot) -replace '-(main|master)$', ''
    if ($defaultName -eq 'unity-strata-template') { $defaultName = 'my-unity-game' }
    while ($true) {
        if (-not $RepoName) {
            $n = Ask-Text (T 'ask_repo_name') $defaultName
            if ($n -notmatch '^[A-Za-z0-9._-]+$') { Say 'bad_repo_name'; continue }
            $script:RepoName = $n
        }
        $null = Invoke-Quiet gh repo view "$Owner/$RepoName" --json name
        if ($LASTEXITCODE -ne 0) { break }
        Warn 'repo_exists' "$Owner/$RepoName"
        $script:RepoName = ''
    }
    if (-not $Visibility) {
        $vis = @('private', 'public')
        if ($Owner -ne $login) { $vis += 'internal' }
        $labels = @($vis | ForEach-Object { T "vis_$_" })
        $script:Visibility = $vis[(Ask-Choice (T 'ask_visibility') $labels 1)]
    }
    $slug = "$Owner/$RepoName"
    Set-StateValue 'owner' $Owner; Set-StateValue 'repoName' $RepoName; Set-StateValue 'visibility' $Visibility

    # A ZIP unpacked under Downloads / a deep path breaks Unity and agent sandboxes on Windows: offer a short path
    if (-not (Test-GitRepo) -and $OnWindows) {
        $target = Join-Path 'C:\dev' $RepoName
        $risky = ($RepoRoot.Length -gt 60) -or ($RepoRoot -match '\\(Downloads|Desktop|OneDrive[^\\]*|Temp)(\\|$)')
        if (-not (Test-SamePath $RepoRoot $target) -and (Ask-YesNo (T 'ask_relocate' $RepoRoot $target) $risky)) {
            if ((Test-Path -LiteralPath $target) -and (Get-ChildItem -LiteralPath $target -Force | Select-Object -First 1)) {
                Warn 'relocate_exists' $target
            } else {
                New-Item -ItemType Directory -Force -Path $target | Out-Null
                Get-ChildItem -LiteralPath $RepoRoot -Force | Copy-Item -Destination $target -Recurse -Force
                Good 'relocated' $target $RepoRoot
                & (Join-Path $target 'tools/bootstrap.ps1') -Step $Step -RepoName $RepoName -Owner $Owner -Visibility $Visibility -MainAI $MainAI
                exit $LASTEXITCODE
            }
        }
    }

    # git init (ZIP), LFS, team hooks, private history folder -- tools/setup.ps1 is idempotent
    if ((Invoke-Tool { & (Tool 'setup.ps1') -Branch main }) -ne 0) { throw (T 'setup_failed') }
    if ($origin) { $null = Invoke-Quiet git -C $RepoRoot remote rename origin template; Note 'template_remote' }

    # Personalise what still points at the template author
    $historyRepo = ''
    if (Ask-YesNo (T 'ask_history_repo' "$slug-history") $true) {
        $hc = Invoke-Tool { & gh repo create "$slug-history" --private --add-readme --description 'Private agent run history (prompts and results)' }
        if ($hc -eq 0) { $historyRepo = "https://github.com/$slug-history.git"; Good 'history_created' "$slug-history" } else { Warn 'history_failed' }
    }
    Edit-RepoFile 'team.config.json' { param($t) [regex]::Replace($t, '"historyRepo":\s*"[^"]*"', ('"historyRepo": "' + $historyRepo + '"')) }
    Edit-RepoFile 'README.md' {
        param($t)
        $t.Replace("$TemplateOwner/unity-strata-history", "$slug-history").Replace($TemplateSlug, $slug).Replace('C:\dev\unity-strata-template', "C:\dev\$RepoName").Replace('unity-strata-agent', "$RepoName-agent")
    }
    Edit-RepoFile '.github/CODEOWNERS' { param($t) $t.Replace("@$TemplateOwner", "@$login") }
    Edit-RepoFile 'ProjectSettings/ProjectSettings.asset' { param($t) ([regex]'(?m)^(  productName:)[^\r\n]*').Replace($t, "`$1 $RepoName", 1) }
    # Re-point the private history folder at the new history repo (only while it holds no records yet)
    $hist = Get-HistoryRoot
    if ((Test-Path -LiteralPath $hist) -and -not (Test-Path -LiteralPath (Join-Path $hist '.git')) -and -not (Get-ChildItem -LiteralPath (Join-Path $hist 'runs') -Recurse -File -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $hist -Recurse -Force
    }
    $null = Sync-History

    $null = Invoke-Quiet git -C $RepoRoot add -A
    $null = Invoke-Quiet git -C $RepoRoot commit -q -m "Initialize $slug from unity-strata-template"
    $code = Invoke-Tool { & gh repo create $slug "--$Visibility" --source $RepoRoot --remote origin --description 'Unity project (unity-strata-template)' }
    if ($code -ne 0) { throw (T 'repo_create_failed' $slug) }
    $env:ALLOW_MAIN_PUSH = '1'
    try { $code = Invoke-Tool { & git -C $RepoRoot push -u origin main } } finally { Remove-Item Env:ALLOW_MAIN_PUSH -ErrorAction SilentlyContinue }
    if ($code -ne 0) { throw (T 'push_failed') }
    Set-StateValue 'slug' $slug
    Good 'repo_created' "https://github.com/$slug" (T "vis_$Visibility")
}

# ================================================================ 3. Unity version

function Get-UnityReleases([string]$Stream, [int]$Count = 2) {
    # Unity's public release API; the wizard falls back to the Hub CLI / manual input when it is unreachable
    try {
        $u = "https://services.api.unity.com/unity/editor/release/v1/releases?limit=$Count&order=RELEASE_DATE_DESC&stream=$Stream"
        $r = Invoke-RestMethod -Uri $u -TimeoutSec 20
        return @($r.results | Where-Object { $_.version } | ForEach-Object {
                [pscustomobject]@{ Version = "$($_.version)"; Changeset = "$($_.shortRevision)"; Date = "$($_.releaseDate)".Split('T')[0] } })
    } catch { return @() }
}

function Step-Unity {
    $hub = $null
    try { $hub = & (Tool 'find-unity.ps1') -Hub } catch {
        $null = Install-WithWinget 'Unity.UnityHub' 'Unity Hub'
        try { $hub = & (Tool 'find-unity.ps1') -Hub } catch { Warn 'hub_missing' }
    }
    $current = Get-ProjectUnityVersion
    $installed = @()
    try { $installed = @(& (Tool 'find-unity.ps1') -ListObjects 3>$null) } catch { }
    $isInstalled = { param($v) [bool]($installed | Where-Object { $_.Version -eq $v }) }
    $mark = { param($v) if (& $isInstalled $v) { ' ' + (T 'installed_mark') } else { '' } }

    Say 'unity_fetching'
    $opts = New-Object System.Collections.Generic.List[object]
    $opts.Add([pscustomobject]@{ Label = (T 'unity_opt_current' $current.Version) + (& $mark $current.Version); Version = $current.Version; Changeset = $current.Changeset })
    foreach ($r in (Get-UnityReleases 'LTS' 2)) { $opts.Add([pscustomobject]@{ Label = (T 'unity_opt_lts' $r.Version $r.Date) + (& $mark $r.Version); Version = $r.Version; Changeset = $r.Changeset }) }
    foreach ($r in (Get-UnityReleases 'TECH' 2)) { $opts.Add([pscustomobject]@{ Label = (T 'unity_opt_tech' $r.Version $r.Date) + (& $mark $r.Version); Version = $r.Version; Changeset = $r.Changeset }) }
    if ($opts.Count -eq 1) { Warn 'unity_api_unavailable' }
    foreach ($e in $installed) { $opts.Add([pscustomobject]@{ Label = (T 'unity_opt_installed' $e.Version); Version = $e.Version; Changeset = '' }) }
    $seen = @{}
    $list = @($opts | Where-Object { if ($seen.ContainsKey($_.Version)) { $false } else { $seen[$_.Version] = 1; $true } })
    $list += [pscustomobject]@{ Label = (T 'unity_opt_manual'); Version = ''; Changeset = '' }
    Note 'unity_lts_note'

    $pick = $list[(Ask-Choice (T 'ask_unity_version') @($list | ForEach-Object { $_.Label }) 1)]
    $ver = $pick.Version; $cs = $pick.Changeset
    while (-not $ver) {
        $v = Ask-Text (T 'ask_unity_manual') ''
        if ($v -match '^\d+\.\d+\.\d+[abfp]\d+$') { $ver = $v } else { Say 'bad_unity_version' }
    }

    $mods = @($Catalog.unityModules)
    $chosen = @(Ask-Multi (T 'ask_unity_modules') @($mods | ForEach-Object { $_.label }) @())
    $hubArgs = @()
    foreach ($i in $chosen) { $hubArgs += @('--module', $mods[$i].id) }
    if ($chosen | Where-Object { $mods[$_].childModules }) { $hubArgs += '--childModules' }
    if ($cs -and $ver -ne $current.Version) { $hubArgs = @('--changeset', $cs) + $hubArgs }

    # 1) install the editor  2) licence  3) move the project to the chosen version if it differs
    $code = Invoke-Tool { & (Tool 'unity.ps1') install $ver @hubArgs }
    if ($code -ne 0) { throw (T 'unity_install_failed' $ver) }
    Say 'unity_license'
    if ($hub -and (Ask-YesNo (T 'ask_open_hub') $true)) { Start-Process -FilePath $hub | Out-Null }
    $null = Read-Host (T 'press_enter')
    if ($ver -ne $current.Version) {
        Say 'unity_upgrading' $current.Version $ver
        $code = Invoke-Tool { & (Tool 'unity.ps1') upgrade $ver }
        if ($code -ne 0) { throw (T 'unity_upgrade_failed' $ver) }
        Save-Progress "Move the project to Unity $ver"
    }
    Set-StateValue 'unityVersion' $ver
    Good 'unity_ready' $ver
}

# ================================================================ 4. Strata

function Get-Hardware {
    $hw = [ordered]@{ RamGB = 0; VramGB = 0; Gpu = ''; Vendor = ''; DiskFreeGB = 0 }
    try {
        if ($OnWindows) {
            $hw.RamGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
            $hw.Gpu = (@(Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name }) -join ', ')
        } elseif ($IsMacOS) {
            $hw.RamGB = [math]::Round([double](& sysctl -n hw.memsize) / 1GB)
            $hw.Gpu = 'Apple Silicon (unified memory)'
        } else {
            $kb = [double]([regex]::Match((Get-Content /proc/meminfo -Raw), 'MemTotal:\s+(\d+)').Groups[1].Value)
            $hw.RamGB = [math]::Round($kb / 1MB)
            if (Test-Cmd 'lspci') { $hw.Gpu = (@(& lspci | Where-Object { $_ -match 'VGA|3D' }) -join ', ') }
        }
    } catch { }
    if (Test-Cmd 'nvidia-smi') {
        try {
            $mb = @(& nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits) | ForEach-Object { [double]"$_".Trim() } | Measure-Object -Maximum
            $hw.VramGB = [math]::Round($mb.Maximum / 1024)
        } catch { }
    } elseif ($OnWindows) {
        try {
            $keys = Get-ChildItem 'HKLM:\SYSTEM\ControlSet001\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}' -ErrorAction Stop
            $max = 0
            foreach ($k in $keys) { $v = (Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue).'HardwareInformation.qwMemorySize'; if ($v -and [double]$v -gt $max) { $max = [double]$v } }
            $hw.VramGB = [math]::Round($max / 1GB)
        } catch { }
    }
    $hw.Vendor = if ($IsMacOS) { 'apple' } elseif ($hw.Gpu -match 'NVIDIA|GeForce|RTX|Quadro') { 'nvidia' } elseif ($hw.Gpu -match 'AMD|Radeon') { 'amd' } elseif ($hw.Gpu -match 'Arc') { 'intel' } else { '' }
    try {
        $dataRoot = if ($OnWindows -and $env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { $HOME }
        $hw.DiskFreeGB = [math]::Round((New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($dataRoot))).AvailableFreeSpace / 1GB)
    } catch { }
    return [pscustomobject]$hw
}

function Get-ModelFit($Model, $Hw) {
    $total = $Hw.RamGB + $(if ($Hw.Vendor -eq 'apple') { 0 } else { $Hw.VramGB })
    if ($Hw.Vendor -and @($Model.vendors) -notcontains $Hw.Vendor) { return [pscustomobject]@{ Mark = 'x'; Text = (T 'fit_vendor') } }
    if ($Hw.DiskFreeGB -gt 0 -and $Hw.DiskFreeGB -lt $Model.downloadGB) { return [pscustomobject]@{ Mark = 'x'; Text = (T 'fit_disk') } }
    if ($total -le 0) { return [pscustomobject]@{ Mark = '?'; Text = (T 'fit_unknown') } }
    if ($total -ge $Model.memGB * 1.15) { return [pscustomobject]@{ Mark = 'o'; Text = (T 'fit_ok') } }
    if ($total -ge $Model.memGB) { return [pscustomobject]@{ Mark = '~'; Text = (T 'fit_tight') } }
    return [pscustomobject]@{ Mark = 'x'; Text = (T 'fit_short') }
}

function Test-StrataInstalled { return ((Invoke-Tool { & (Tool 'strata.ps1') where }) -eq 0) }

function Step-Strata {
    if (-not (Ask-YesNo (T 'ask_use_strata') $true)) { Set-StateValue 'strata' $false; Note 'strata_skipped'; return }
    Set-StateValue 'strata' $true
    if (-not (Test-StrataInstalled)) {
        $null = Invoke-RemoteInstaller 'Strata' 'https://github.com/Niko1221/Strata/releases/latest/download/install.ps1' 'https://github.com/Niko1221/Strata/releases/latest/download/install.sh'
        if (-not (Test-StrataInstalled)) { throw (T 'strata_missing') }
    }

    $hw = Get-Hardware
    Say 'hw_summary' $hw.Gpu $hw.VramGB $hw.RamGB $hw.DiskFreeGB
    $models = @((Get-Content -LiteralPath (Tool 'bootstrap/strata-models.json') -Raw -Encoding UTF8 | ConvertFrom-Json).models | Sort-Object rank)
    $tiers = (Get-Content -LiteralPath (Tool 'bootstrap/strata-models.json') -Raw -Encoding UTF8 | ConvertFrom-Json).tiers
    Write-Host ''
    Say 'model_table_title'
    foreach ($p in $tiers.PSObject.Properties) { Note 'tier_legend' $p.Name $p.Value }
    Note 'fit_legend'
    $wantCodex = "$((Get-TeamConfig).loopAgent)" -eq 'codex-local'
    $labels = @(); $recommended = 0
    for ($i = 0; $i -lt $models.Count; $i++) {
        $m = $models[$i]
        $fit = Get-ModelFit $m $hw
        $m | Add-Member -NotePropertyName fit -NotePropertyValue $fit -Force
        $codexNote = if ($m.codexOk) { '' } else { ' ' + (T 'codex_unsuitable') }
        $labels += (T 'model_row' $m.rank $m.name $m.tier $m.memGB $m.downloadGB $fit.Mark $fit.Text) + "`n        $($m.note)$codexNote"
        if (-not $recommended -and $fit.Mark -eq 'o' -and ($m.codexOk -or -not $wantCodex)) { $recommended = $i + 1 }
    }
    if (-not $recommended) {
        # nothing fits comfortably: suggest the lightest model that is not ruled out
        for ($i = $models.Count - 1; $i -ge 0; $i--) { if ($models[$i].fit.Mark -ne 'x') { $recommended = $i + 1; break } }
    }
    if (-not $recommended) { $recommended = $models.Count }
    Good 'model_recommended' $models[$recommended - 1].name

    $launchPath = Join-Path $RepoRoot '.strata/launch.json'
    $backup = [IO.File]::ReadAllText($launchPath, $Utf8)
    while ($true) {
        $m = $models[(Ask-Choice (T 'ask_model') $labels $recommended)]
        if ($m.fit.Mark -eq 'x' -and -not (Ask-YesNo (T 'ask_model_anyway' $m.fit.Text) $false)) { continue }
        $ok = $false
        # The previous launch.json used "--context 64k" (not in Strata's docs): try it first, then documented flags only
        $prevCtx = "$(($backup | ConvertFrom-Json).context)"
        $argSets = @()
        if ($prevCtx -and $m.contextTokens -gt 8192) { $argSets += , (@($m.launchArgs) + @('--context', $prevCtx)) }
        $argSets += , @($m.launchArgs)
        foreach ($id in (@($m.model, $m.model.ToLower()) | Select-Object -Unique)) {
            foreach ($extra in $argSets) {
                $launch = [ordered]@{
                    description = 'Local model served by Strata (https://github.com/Niko1221/Strata) for Codex / Claude Code. Chosen with tools/bootstrap.ps1; used by tools/strata.ps1 up|plan. launchArgs = extra `strata launch` flags.'
                    name = $m.name; family = $m.family; model = $id; vision = 'off'; port = 8080
                    contextTokens = $m.contextTokens; launchArgs = @($extra | Where-Object { $_ })
                }
                [IO.File]::WriteAllText($launchPath, (ConvertTo-PrettyJson ([pscustomobject]$launch)), $Utf8)
                Say 'model_plan' $m.family $id (@($extra) -join ' ')
                if ((Invoke-Tool { & (Tool 'strata.ps1') plan }) -eq 0) { $ok = $true; break }
            }
            if ($ok) { break }
        }
        if ($ok) { break }
        [IO.File]::WriteAllText($launchPath, $backup, $Utf8)
        Warn 'model_plan_failed'
    }
    Set-StateValue 'strataModel' "$($m.family)/$($m.model)"

    if (Ask-YesNo (T 'ask_strata_up' $m.downloadGB) ($m.fit.Mark -eq 'o')) {
        $null = Invoke-Tool { & (Tool 'strata.ps1') up }
        $id = $null
        for ($i = 0; $i -lt 60 -and -not $id; $i++) {
            try { $id = (Invoke-RestMethod 'http://127.0.0.1:8080/v1/models' -TimeoutSec 5).data[0].id } catch { Start-Sleep -Seconds 10 }
        }
        if ($id) { Set-StateValue 'strataModelId' $id; Good 'strata_running' $id } else { Warn 'strata_not_ready' }
    } else { Note 'strata_up_later' }
    Save-Progress "Use Strata model $($m.name)"
}

# ================================================================ 5. main AI <-> Strata

function Install-NodeCli([string]$Package, [string]$Label) {
    if (-not (Test-Cmd 'npm')) { $null = Install-WithWinget 'OpenJS.NodeJS.LTS' 'Node.js LTS' }
    if (-not (Test-Cmd 'npm')) { Warn 'install_manual' $Label; return }
    if (Ask-YesNo (T 'ask_install' $Label) $true) {
        $npm = if ($OnWindows) { 'npm.cmd' } else { 'npm' }
        $null = Invoke-Tool { & $npm install -g $Package }
        Update-SessionPath
    }
}

function Step-Connect {
    if (-not $MainAI) {
        $keys = @('claude', 'codex', 'both')
        $script:MainAI = $keys[(Ask-Choice (T 'ask_main_ai') @($keys | ForEach-Object { T "main_$_" }) 1)]
    }
    Set-StateValue 'mainAI' $MainAI
    $useClaude = $MainAI -in @('claude', 'both')
    $useCodex = $MainAI -in @('codex', 'both')

    if ($useClaude -and -not (Test-Cmd 'claude')) {
        if (Test-Cmd 'npm') { Install-NodeCli '@anthropic-ai/claude-code' 'Claude Code' }
        else { $null = Invoke-RemoteInstaller 'Claude Code' 'https://claude.ai/install.ps1' 'https://claude.ai/install.sh' }
    }
    if ($useCodex -and -not (Test-Cmd 'codex')) { Install-NodeCli '@openai/codex' 'Codex CLI' }
    if ($useClaude) { if (Test-Cmd 'claude') { Good 'found' 'Claude Code'; Note 'login_claude' } else { Warn 'cli_missing' 'claude' } }
    if ($useCodex) {
        if (Test-Cmd 'codex') {
            Good 'found' 'Codex CLI'
            $null = Invoke-Quiet codex login status
            if ($LASTEXITCODE -ne 0 -and (Ask-YesNo (T 'ask_codex_login') $true)) { $null = Invoke-Tool { & codex login } }
        } else { Warn 'cli_missing' 'codex' }
    }

    $strata = [bool](Get-StateValue 'strata')
    $modelInfo = $null
    if ($strata) {
        $launch = Get-Content -LiteralPath (Join-Path $RepoRoot '.strata/launch.json') -Raw | ConvertFrom-Json
        $modelInfo = @((Get-Content -LiteralPath (Tool 'bootstrap/strata-models.json') -Raw -Encoding UTF8 | ConvertFrom-Json).models) |
            Where-Object { $_.family -eq $launch.family -and $_.model -ieq $launch.model } | Select-Object -First 1
        $id = $null
        try { $id = (Invoke-RestMethod 'http://127.0.0.1:8080/v1/models' -TimeoutSec 5).data[0].id } catch { }
        if (-not $id) {
            Warn 'strata_down_for_connect'
            if (Ask-YesNo (T 'ask_strata_up_now') $true) {
                $null = Invoke-Tool { & (Tool 'strata.ps1') up }
                try { $id = (Invoke-RestMethod 'http://127.0.0.1:8080/v1/models' -TimeoutSec 30).data[0].id } catch { }
            }
        }
        if ($id) {
            # Codex on the local model: model id and window come from the running server / chosen model
            $ctx = if ($modelInfo -and $modelInfo.contextTokens) { [int]$modelInfo.contextTokens } else { 65536 }
            Edit-RepoFile 'tools/templates/codex-local.config.toml' {
                param($t)
                # no "$" anchors: the file may have CRLF line endings, and .NET's "$" does not match before "\r"
                $t = [regex]::Replace($t, '(?m)^model = "[^"\r\n]*"', "model = `"$id`"")
                $t = [regex]::Replace($t, '(?m)^model_context_window = \d+', "model_context_window = $ctx")
                [regex]::Replace($t, '(?m)^model_auto_compact_token_limit = \d+', "model_auto_compact_token_limit = $([int]($ctx * 0.49))")
            }
            Good 'codex_local_config' $id $ctx
            if ($useCodex) { $null = Invoke-Tool { & (Tool 'strata.ps1') check } }
            Say 'strata_roundtrip'
            $code = Invoke-Tool { & (Tool 'strata.ps1') ask 'Reply with exactly one word: OK' -MaxTokens 32 }
            if ($code -eq 0) { Good 'strata_connected' } else { Warn 'strata_roundtrip_failed' }
            if ($useClaude) { Note 'claude_delegation' }
        }
    }

    # Agent of the unattended loop (team default, tools/loop.ps1 -Agent overrides it)
    $choices = @()
    if ($strata -and (-not $modelInfo -or $modelInfo.codexOk)) { $choices += 'codex-local' }
    if ($useClaude) { $choices += 'claude' }
    if ($useCodex) { $choices += 'codex' }
    if ($strata -and $useClaude) { $choices += 'claude-local' }
    if (-not $choices) { $choices = @('claude') }
    $loopAgent = $choices[(Ask-Choice (T 'ask_loop_agent') @($choices | ForEach-Object { T "agent_$_" }) 1)]
    $cfgPath = Join-Path $RepoRoot 'team.config.json'
    $cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $cfg | Add-Member -NotePropertyName mainAgent -NotePropertyValue $(if ($useClaude) { 'claude' } else { 'codex' }) -Force
    $cfg | Add-Member -NotePropertyName loopAgent -NotePropertyValue $loopAgent -Force
    [IO.File]::WriteAllText($cfgPath, (ConvertTo-PrettyJson $cfg), $Utf8)
    Good 'agents_set' $cfg.mainAgent $loopAgent
    Save-Progress 'Connect the main AI with Strata'
}

# ================================================================ 6. Unity development environment

function Step-Unitydev {
    $null = Invoke-Tool { & (Tool 'setup.ps1') }   # registers UnityYAMLMerge now that the editor is installed

    $ides = @()
    $vswhere = Join-Path "${env:ProgramFiles(x86)}" 'Microsoft Visual Studio\Installer\vswhere.exe'
    $vsPath = $null
    if ($OnWindows -and (Test-Path -LiteralPath $vswhere)) { $vsPath = "$(& $vswhere -latest -property installationPath)".Trim() }
    if ($vsPath) { $ides += 'vs' }
    if (Test-Cmd 'code') { $ides += 'vscode' }
    if ((Test-Cmd 'rider64') -or (Test-Cmd 'rider') -or ($env:LOCALAPPDATA -and (Test-Path (Join-Path $env:LOCALAPPDATA 'JetBrains\Toolbox\scripts\rider.cmd')))) { $ides += 'rider' }
    if ($ides -notcontains 'vscode') { $ides += 'vscode-install' }
    $ides += 'skip'
    $ide = $ides[(Ask-Choice (T 'ask_ide') @($ides | ForEach-Object { T "ide_$_" }) 1)]
    if ($ide -eq 'vscode-install') {
        $null = Install-WithWinget 'Microsoft.VisualStudioCode' 'Visual Studio Code'
        $ide = if (Test-Cmd 'code') { 'vscode' } else { 'skip' }
    }
    switch ($ide) {
        'vscode' { $null = Invoke-Tool { & code --install-extension visualstudiotoolsforunity.vstuc } }
        'vs' {
            if (Ask-YesNo (T 'ask_vs_workload') $true) {
                $setup = Join-Path "${env:ProgramFiles(x86)}" 'Microsoft Visual Studio\Installer\setup.exe'
                $null = Invoke-Tool { & $setup modify --installPath $vsPath --config (Join-Path $RepoRoot '.vsconfig') --passive --norestart }
            }
        }
    }
    if ($ide -ne 'skip') { Note 'ide_unity_pref' }

    $pk = @($Catalog.unityPackages)
    $defaults = @(for ($i = 0; $i -lt $pk.Count; $i++) { if ($pk[$i].default) { $i } })
    $chosen = @(Ask-Multi (T 'ask_packages') @($pk | ForEach-Object { "$($_.label)  ($($_.id))" }) $defaults)
    if ($chosen.Count -gt 0) {
        $ids = (@($chosen | ForEach-Object { $pk[$_].id }) -join ',')
        Say 'packages_adding' $ids
        if ((Invoke-Tool { & (Tool 'unity.ps1') packages add $ids }) -ne 0) { Warn 'packages_failed' }
    }

    Say 'unity_first_import'
    $null = Invoke-Tool { & (Tool 'unity.ps1') refresh }
    $code = Invoke-Tool { & (Tool 'unity.ps1') test EditMode }
    if ($code -eq 0) { Good 'unity_test_ok' } else { Warn 'unity_test_failed' $code }
    $null = Invoke-Tool { & (Tool 'strata-index.ps1') }
    Save-Progress 'Set up the Unity development environment'
}

# ================================================================ 7. skills, plugins, spec-kit

function Step-Skills {
    $skills = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot '.agents/skills') -Directory | ForEach-Object { $_.Name })
    Good 'skills_synced' ($skills -join ', ')

    $mainAI = "$(Get-StateValue 'mainAI')"
    if (-not $mainAI) { $mainAI = if ($MainAI) { $MainAI } else { 'claude' } }

    if (($mainAI -in @('claude', 'both')) -and (Test-Cmd 'claude')) {
        $pl = @($Catalog.claudePlugins)
        $defaults = @(for ($i = 0; $i -lt $pl.Count; $i++) { if ($pl[$i].default) { $i } })
        $chosen = @(Ask-Multi (T 'ask_plugins') @($pl | ForEach-Object { "$($_.label)  ($($_.id))" }) $defaults)
        $failed = @()
        foreach ($i in $chosen) {
            # project scope: recorded in .claude/settings.json, so every teammate gets the same plugins
            if ((Invoke-Tool { & claude plugin install $pl[$i].id --scope project }) -ne 0) { $failed += $pl[$i].id }
        }
        if ($failed) { Warn 'plugins_failed' ($failed -join ', ') }
    }

    if (Ask-YesNo (T 'ask_speckit') $true) {
        if (-not (Test-Cmd 'uv')) {
            if (-not (Install-WithWinget 'astral-sh.uv' 'uv (Python package manager)') -or -not (Test-Cmd 'uv')) {
                $null = Invoke-RemoteInstaller 'uv' 'https://astral.sh/uv/install.ps1' 'https://astral.sh/uv/install.sh'
            }
        }
        if (-not (Test-Cmd 'uv')) { Warn 'speckit_no_uv' }
        else {
            if (-not (Test-Cmd 'specify')) {
                $code = Invoke-Tool { & uv tool install $Catalog.speckit.package }
                if ($code -ne 0) { $null = Invoke-Tool { & uv tool install $Catalog.speckit.package --from $Catalog.speckit.gitSource } }
                Update-SessionPath
            }
            if (-not (Test-Cmd 'specify')) { Warn 'speckit_missing' }
            else {
                $help = (Invoke-Quiet specify init --help) -join "`n"
                $integrations = switch ($mainAI) { 'codex' { @('codex') } 'both' { @('claude', 'codex') } default { @('claude') } }
                Push-Location $RepoRoot
                try {
                    foreach ($integ in $integrations) {
                        $a = @('init', '--here')
                        if ($help -match '--integration') { $a += @('--integration', $integ) } elseif ($help -match '--ai') { $a += @('--ai', $integ) }
                        if ($OnWindows -and $help -match '--script') { $a += @('--script', 'ps') }
                        foreach ($flag in @('--force', '--no-git', '--ignore-agent-tools')) { if ($help -match [regex]::Escape($flag)) { $a += $flag } }
                        Say 'speckit_init' ($a -join ' ')
                        if ((Invoke-Tool { & specify @a }) -ne 0) { Warn 'speckit_init_failed' $integ }
                    }
                } finally { Pop-Location }
                # Project constitution (spec-kit's own template only has placeholders)
                $const = Join-Path $RepoRoot '.specify/memory/constitution.md'
                if ((Test-Path -LiteralPath (Join-Path $RepoRoot '.specify')) -and (-not (Test-Path -LiteralPath $const) -or ([IO.File]::ReadAllText($const, $Utf8) -match '\[PROJECT_NAME\]'))) {
                    $project = if (Get-StateValue 'repoName') { Get-StateValue 'repoName' } else { Split-Path -Leaf $RepoRoot }
                    $text = [IO.File]::ReadAllText((Tool 'bootstrap/constitution.ja.md'), $Utf8).Replace('{PROJECT}', $project).Replace('{DATE}', (Get-Date).ToString('yyyy-MM-dd'))
                    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $const) | Out-Null
                    [IO.File]::WriteAllText($const, $text, $Utf8)
                    Good 'speckit_constitution'
                }
                Note 'speckit_flow'
            }
        }
    }
    # Skills added under .agents/skills (by spec-kit or by hand) are mirrored for Claude Code
    $src = Join-Path $RepoRoot '.agents/skills'; $dst = Join-Path $RepoRoot '.claude/skills'
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force
    Save-Progress 'Add agent skills, Claude Code plugins and spec-kit'
}

# ================================================================ 8. try it

function Step-Verify {
    if (-not (Get-OriginUrl)) { Warn 'try_need_origin'; return }
    $modes = @('file', 'prompt', 'skip')
    $mode = $modes[(Ask-Choice (T 'ask_verify_mode') @($modes | ForEach-Object { T "verify_$_" }) 2)]
    if ($mode -eq 'skip') { return }
    $code = if ($mode -eq 'file') {
        $f = ''
        while (-not $f -or -not (Test-Path -LiteralPath $f)) { $f = Ask-Text (T 'ask_prompt_file') 'Docs/agent-lessons.md'; if (-not (Test-Path -LiteralPath $f)) { Say 'file_not_found' $f } }
        Invoke-Tool { & (Tool 'try.ps1') -File $f }
    } else {
        Invoke-Tool { & (Tool 'try.ps1') }
    }
    if ($code -ne 0) { Warn 'try_failed' $code }
}

# ================================================================ 9. finish

function Step-Finish {
    $slug = Get-SlugFromUrl (Get-OriginUrl)
    if ($slug -and -not (Get-StateValue 'protected') -and (Ask-YesNo (T 'ask_protect') $true)) {
        $body = @{
            required_status_checks = @{ strict = $true; contexts = @('repo-checks') }
            enforce_admins = $false
            required_pull_request_reviews = @{ required_approving_review_count = 0; require_code_owner_reviews = $false }
            restrictions = $null
            required_conversation_resolution = $true
            allow_force_pushes = $false
            allow_deletions = $false
        } | ConvertTo-Json -Depth 5
        $tmp = Join-Path ([IO.Path]::GetTempPath()) 'branch-protection.json'
        [IO.File]::WriteAllText($tmp, $body, $Utf8)
        $code = Invoke-Tool { & gh api -X PUT "repos/$slug/branches/main/protection" --input $tmp }
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
        if ($code -eq 0) { Set-StateValue 'protected' $true; Good 'protected' } else { Warn 'protect_failed' }
    }
    $s = Get-State
    Write-Host ''
    Good 'summary_title'
    Say 'summary_repo' $(if ($slug) { "https://github.com/$slug" } else { '-' })
    Say 'summary_unity' "$($s.unityVersion)"
    Say 'summary_strata' $(if ($s.strata) { "$($s.strataModel) $($s.strataModelId)" } else { '-' })
    $cfg = Get-TeamConfig
    Say 'summary_agents' $cfg.mainAgent $cfg.loopAgent
    Write-Host ''
    Say 'next_steps'
}

# ================================================================ main

if ($Reset -and (Test-Path -LiteralPath $StateFile)) { Remove-Item -LiteralPath $StateFile -Force }
Write-Host ''
Write-Host (T 'banner') -ForegroundColor Cyan
Note 'banner_desc' $RepoRoot
$done = @((Get-State).done)
$todo = if ($Step -eq 'all') { @($StepNames | Where-Object { $done -notcontains $_ }) } else { @($Step) }
if (-not $todo) { Good 'all_done'; Note 'rerun_hint'; exit 0 }
foreach ($name in $todo) {
    $index = [array]::IndexOf($StepNames, $name) + 1
    Show-Section $index $name
    if ($Step -eq 'all' -and -not (Ask-YesNo (T 'ask_run_step') $true)) { Note 'step_skipped' $name; continue }
    try {
        & "Step-$name"
        Complete-Step $name
        Good 'step_done' (T "step_$name")
    } catch {
        Write-Host (T 'step_failed' (T "step_$name") $_.Exception.Message) -ForegroundColor Red
        Note 'resume_hint' $name
        exit 1
    }
}
Good 'wizard_end'

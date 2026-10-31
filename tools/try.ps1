<#
.SYNOPSIS
  Try the whole setup with your own instruction -- from a prompt FILE or a typed PROMPT.

.DESCRIPTION
  strata agent : the local model just answers (nothing is changed).
  other agents : a throw-away task is created and claimed (branch task/<id>-try-...), the agent edits only the
                 allowed paths, then this script generates .meta files, updates the context index and runs the
                 Unity tests, shows what changed and asks what to do: open a draft PR, keep the branch, or
                 discard everything (branch, claim and task).
  Every agent run is recorded in the private history (tools\team.cmd history).

.EXAMPLE
  tools\try.cmd                                            # asks: file or prompt, which agent, which paths
  tools\try.cmd -File specs\001-jump\spec.md               # instruction from a UTF-8 file
  tools\try.cmd "Add a Health component with Damage(int) and EditMode tests"
  tools\try.cmd "Summarise AGENTS.md in 5 lines" -Agent strata
  tools\try.cmd -File prompt.txt -Agent codex-local -Paths Assets/Scripts/Runtime/Player -Then pr
#>
param(
    [Parameter(Position = 0)][string]$Prompt,
    [string]$File,
    [ValidateSet('', 'claude', 'codex', 'codex-local', 'claude-local', 'strata')][string]$Agent = '',
    [string[]]$Paths,
    [ValidateSet('EditMode', 'PlayMode', 'All', 'None')][string]$Test = 'EditMode',
    [ValidateSet('', 'pr', 'keep', 'discard')][string]$Then = ''
)
$ErrorActionPreference = 'Stop'
$Tools = $PSScriptRoot
. (Join-Path $Tools 'lib/team.ps1')
$RepoRoot = $script:RepoRoot
try { [Console]::OutputEncoding = $script:Utf8 } catch { }
$Msg = Get-Content -LiteralPath (Join-Path $Tools 'bootstrap/messages.ja.json') -Raw -Encoding UTF8 | ConvertFrom-Json
function T([string]$Key) { $s = $Msg.$Key; if (-not $s) { $s = $Key }; if ($args.Count -gt 0) { return [string]::Format($s, [object[]]$args) }; return $s }
function Say([string]$Key) { Write-Host (T $Key @args) }
function Good([string]$Key) { Write-Host (T $Key @args) -ForegroundColor Green }
function Warn([string]$Key) { Write-Host (T $Key @args) -ForegroundColor Yellow }
function Ask-Choice([string]$PromptText, [string[]]$Items, [int]$Default = 1) {
    for ($i = 0; $i -lt $Items.Count; $i++) { Write-Host ('  {0,2}) {1}' -f ($i + 1), $Items[$i]) }
    while ($true) {
        $a = "$(Read-Host "$PromptText [$Default]")".Trim()
        if (-not $a) { return ($Default - 1) }
        $n = 0
        if ([int]::TryParse($a, [ref]$n) -and $n -ge 1 -and $n -le $Items.Count) { return ($n - 1) }
        Say 'invalid_choice'
    }
}
function Invoke-Step([scriptblock]$Block) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0; $code = 0
    try { & $Block 2>&1 | ConvertTo-OutputLine | Write-Host; $code = $LASTEXITCODE } catch { Write-Host $_.Exception.Message -ForegroundColor Red; $code = 1 }
    finally { $ErrorActionPreference = $prev }
    if ($null -eq $code) { $code = 0 }
    return $code
}
$interactive = -not $Prompt -and -not $File

# ---- the instruction: a file or typed text
if ($interactive) {
    $mode = Ask-Choice (T 'try_ask_mode') @((T 'verify_file'), (T 'verify_prompt')) 2
    if ($mode -eq 0) {
        while (-not $File -or -not (Test-Path -LiteralPath $File)) { $File = "$(Read-Host (T 'ask_prompt_file'))".Trim().Trim('"'); if ($File -and -not (Test-Path -LiteralPath $File)) { Say 'file_not_found' $File } }
    } else {
        Say 'try_type_prompt'
        $lines = @()
        while ($true) { $l = Read-Host '>'; if ($l -eq '.' -or ($l -eq '' -and $lines.Count -gt 0)) { break }; if ($l) { $lines += $l } }
        $Prompt = $lines -join "`n"
    }
}
if ($File) {
    if (-not (Test-Path -LiteralPath $File)) { throw (T 'file_not_found' $File) }
    $Prompt = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $File).Path, $script:Utf8)
    Good 'try_file_loaded' $File $Prompt.Length
}
if (-not "$Prompt".Trim()) { throw (T 'try_empty') }

# ---- which agent
if (-not $Agent) {
    $cfg = Get-TeamConfig
    $agents = @('claude', 'codex', 'codex-local', 'claude-local', 'strata')
    $def = [Math]::Max(1, [array]::IndexOf($agents, "$($cfg.mainAgent)") + 1)
    $Agent = if ($interactive) { $agents[(Ask-Choice (T 'try_ask_agent') @($agents | ForEach-Object { T "agent_$_" }) $def)] } else { $agents[$def - 1] }
}

# ---- strata: answer only
if ($Agent -eq 'strata') {
    $code = Invoke-Step { & (Join-Path $Tools 'agent.ps1') strata $Prompt }
    exit $code
}

# ---- editing agents: throw-away task, claim, agent, Unity, decision
if (-not (Invoke-Git remote -AllowFail)) { throw (T 'try_need_origin') }
if (Invoke-Git status --porcelain -AllowFail) { throw (T 'try_dirty') }
if (-not $Paths) {
    $defaultPaths = 'Assets/Scripts/Runtime/Sandbox,Assets/Tests/EditMode/Sandbox'
    $answer = if ($interactive) { "$(Read-Host ((T 'try_ask_paths') + " [$defaultPaths]"))".Trim() } else { '' }
    $Paths = @($(if ($answer) { $answer } else { $defaultPaths }) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
$Paths = @($Paths | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$default = (Get-TeamConfig).defaultBranch
$first = ("$Prompt" -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1).Trim()
if ($first.Length -gt 50) { $first = $first.Substring(0, 50) + '...' }
$title = "Try: $first"

$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
$id = & (Join-Path $Tools 'task.ps1') new $title -Paths ($Paths -join ',') -Priority 5 6>$null | Select-Object -Last 1
$ErrorActionPreference = $prev
if ("$id" -notmatch '^T-\d{6}-[0-9a-f]{4}$') { throw (T 'try_task_failed') }
if ((Invoke-Step { & (Join-Path $Tools 'task.ps1') claim $id -Agent $Agent }) -ne 0 -or (Get-CurrentBranch) -notlike "task/$id*") {
    Remove-Item -LiteralPath (Join-Path (Get-TaskDir) "$id.json") -ErrorAction SilentlyContinue
    throw (T 'try_claim_failed' $id)
}
$branch = Get-CurrentBranch
Good 'try_claimed' $id $branch ($Paths -join ', ')

$full = @"
Trial run of this project's AI setup (task $id).
Change files only under: $($Paths -join ', ')
New runtime code goes under Assets/Scripts/Runtime (namespace Game), EditMode tests under Assets/Tests/EditMode (namespace Game.Tests).
Do not run Unity, tools\unity.*, git commit or git push: the runner generates .meta files, runs the tests and commits.
Read Docs/agent-lessons.md first. When done, reply with a short summary.

Instruction:
$Prompt
"@
$pf = Join-Path ([IO.Path]::GetTempPath()) ("try-prompt-" + [Guid]::NewGuid().ToString('N') + '.txt')
[IO.File]::WriteAllText($pf, $full, $script:Utf8)
try { $agentCode = Invoke-Step { & (Join-Path $Tools 'agent.ps1') $Agent -PromptFile $pf -Task $id } } finally { Remove-Item -LiteralPath $pf -ErrorAction SilentlyContinue }
Say 'try_agent_done' $agentCode

$testCode = $null
if ($Test -ne 'None') {
    Say 'try_unity'
    $null = Invoke-Step { & (Join-Path $Tools 'unity.ps1') refresh }
    $null = Invoke-Step { & (Join-Path $Tools 'strata-index.ps1') }
    $testCode = Invoke-Step { & (Join-Path $Tools 'unity.ps1') test $Test }
}
Write-Host ''
Say 'try_changes'
Invoke-Git -c core.quotepath=false status --short -AllowFail | ForEach-Object { Write-Host "  $_" }
$outside = @(Invoke-Git -c core.quotepath=false status --porcelain --untracked-files=all -AllowFail | Where-Object { $_.Length -gt 3 } |
    ForEach-Object { $_.Substring(3).Trim('"') } | Where-Object { -not (Test-InTaskPaths $_ $Paths $id) })
if ($outside) { Warn 'try_outside' ($outside -join ', ') }
if ($null -ne $testCode) { if ($testCode -eq 0) { Good 'try_tests_ok' } else { Warn 'try_tests_failed' $testCode } }

# ---- what now
if (-not $Then) {
    $opts = @('pr', 'keep', 'discard')
    $Then = if ($interactive) { $opts[(Ask-Choice (T 'try_ask_then') @($opts | ForEach-Object { T "try_then_$_" }) 1)] } else { 'keep' }
}
$env:AGENT_NAME = $Agent; $env:AGENT_TASK = $id
switch ($Then) {
    'discard' {
        $null = Invoke-Git reset -q --hard HEAD -AllowFail
        $null = Invoke-Git clean -fdq -AllowFail
        $null = Invoke-Git switch -q $default -AllowFail
        $null = Invoke-Git branch -D $branch -AllowFail
        $null = Invoke-Step { & (Join-Path $Tools 'task.ps1') release $id }
        Good 'try_discarded' $id
    }
    default {
        $null = Invoke-Git add -A -AllowFail
        $null = Invoke-Git commit -q -m "task($id): try -- $first" -AllowFail
        if ($Then -eq 'keep') { Good 'try_kept' $branch $id; break }
        $done = if ($testCode -eq 0) { Invoke-Step { & (Join-Path $Tools 'task.ps1') done $id } } else { Invoke-Step { & (Join-Path $Tools 'task.ps1') block $id -Note 'try: tests failing' } }
        $null = Invoke-Step { & git -C $RepoRoot push -q -u origin $branch }
        $body = "Task: $id`n`nTrial run via tools/try.ps1 ($Agent). Unity $($Test): $(if ($testCode -eq 0) { 'passed' } elseif ($null -eq $testCode) { 'not run' } else { 'FAILING' })`n"
        $bf = Join-Path ([IO.Path]::GetTempPath()) ("try-pr-$id.md")
        [IO.File]::WriteAllText($bf, $body, $script:Utf8)
        $null = Invoke-Step { & gh pr create --draft --base $default --head $branch --title "$($id): $title" --body-file $bf }
        Remove-Item -LiteralPath $bf -ErrorAction SilentlyContinue
        Good 'try_pr' $branch
    }
}
Remove-Item Env:AGENT_NAME, Env:AGENT_TASK -ErrorAction SilentlyContinue
exit 0

<#
.SYNOPSIS
  Unattended development loop: pick a task -> claim -> agent edits code -> runner tests -> PR. Repeat.

.DESCRIPTION
  The agent (default: Codex on the local Strata model) only edits files inside its sandbox. Everything that
  needs the real user environment -- Unity .meta generation, the context index, Unity tests, git push and
  the PR -- is done here, outside the sandbox. Failing tests are fed back to the agent for up to
  -MaxFixRounds extra rounds; if they still fail, the work is pushed as a draft PR and the task is marked
  blocked (claim kept) for a human.

  Run it in a dedicated clone that no one has open in the Unity Editor, at a short path, e.g.
    git clone <repo> C:\dev\<name>-agent ;  cd C:\dev\<name>-agent ;  tools\setup.cmd ;  tools\loop.cmd

  Stop it gracefully: create Logs\loop.stop (tools\loop.cmd -Stop). It finishes the current task first.
  Log: Logs\loop.log. Every agent run is recorded in the private history (tools\team.cmd history).

.EXAMPLE
  tools\loop.cmd                         # run until stopped
  tools\loop.cmd -Once                   # one task, then exit (good first test)
  tools\loop.cmd -MaxTasks 5 -TestPlatform All
  tools\loop.cmd -AgentTimeoutMinutes 20  # stop an agent run that takes longer (default 30)
  tools\loop.cmd -Stop
#>
param(
    [int]$MaxTasks = 0,
    [int]$MaxFixRounds = 2,
    [ValidateSet('codex-local', 'codex', 'claude')][string]$Agent = 'codex-local',
    [ValidateSet('EditMode', 'PlayMode', 'All')][string]$TestPlatform = 'EditMode',
    [int]$IdleMinutes = 15,
    [int]$AgentTimeoutMinutes = 30,
    [switch]$Once,
    [switch]$NoPR,
    [switch]$Stop
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/team.ps1')
$Tools = $PSScriptRoot
$LogDir = Join-Path $script:RepoRoot 'Logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$StopFile = Join-Path $LogDir 'loop.stop'
$LoopLog = Join-Path $LogDir 'loop.log'

if ($Stop) { New-Item -ItemType File -Force -Path $StopFile | Out-Null; Write-Host "Stop requested ($StopFile). The loop exits after the current task."; exit 0 }
Remove-Item -LiteralPath $StopFile -ErrorAction SilentlyContinue

function Write-Log([string]$msg) {
    $line = '{0} {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $msg
    Write-Host $line
    [IO.File]::AppendAllText($LoopLog, "$line`n", $script:Utf8)
}

function Invoke-Tool([string]$Name, [scriptblock]$Block) {
    # Runs a tools/*.ps1 call in-process and returns its exit code without aborting the loop.
    # (A script block, not an argument array: array splatting would pass "-Agent" as a plain value.)
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    try { & $Block 2>&1 | ConvertTo-OutputLine | Write-Host; $code = $LASTEXITCODE }
    catch { Write-Log "  $Name failed: $($_.Exception.Message)"; $code = 1 }
    finally { $ErrorActionPreference = $prev }
    if ($null -eq $code) { $code = 0 }
    return $code
}

function Get-ToolPath([string]$Script) { Join-Path $Tools $Script }

function Invoke-AgentWithTimeout([string]$PromptText, [string]$TaskId) {
    # The agent runs as a child process so a model that goes in circles cannot stall the loop forever:
    # after -AgentTimeoutMinutes its whole process tree is killed and its run record is closed as a timeout.
    $pf = Join-Path ([IO.Path]::GetTempPath()) ("loop-prompt-" + [Guid]::NewGuid().ToString('N') + '.txt')
    [IO.File]::WriteAllText($pf, $PromptText, $script:Utf8)
    $shell = (Get-Process -Id $PID).Path
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$(Get-ToolPath 'agent.ps1')`" $Agent -PromptFile `"$pf`" -Task $TaskId"
    $p = Start-Process -FilePath $shell -ArgumentList $argLine -NoNewWindow -PassThru
    $null = $p.Handle   # keeps ExitCode readable after the process ends
    try {
        if ($p.WaitForExit($AgentTimeoutMinutes * 60 * 1000)) { return $p.ExitCode }
        Write-Log "  agent exceeded $AgentTimeoutMinutes min; stopping it"
        & taskkill.exe /PID $p.Id /T /F 2>&1 | Out-Null
        $rec = Get-ChildItem -Path (Join-Path (Get-HistoryRoot) 'runs') -Recurse -Filter "*-$Agent-$TaskId.md" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($rec -and (Select-String -LiteralPath $rec.FullName -Pattern '^finished:\s*$' -Quiet)) {
            Add-RunSection $rec.FullName 'Timeout' "Stopped by tools/loop.ps1 after $AgentTimeoutMinutes minutes."
            Complete-RunRecord $rec.FullName 124
            Publish-History "timeout $($rec.BaseName)"
        }
        return 124
    } finally { Remove-Item -LiteralPath $pf -ErrorAction SilentlyContinue }
}

function Test-StrataUp {
    $port = (Get-Content -LiteralPath (Join-Path $script:RepoRoot '.strata/launch.json') -Raw | ConvertFrom-Json).port
    try { return [bool](Invoke-RestMethod "http://127.0.0.1:$port/health" -TimeoutSec 10).loaded } catch { return $false }
}

function Confirm-Strata {
    if ($Agent -ne 'codex-local') { return $true }
    if (Test-StrataUp) { return $true }
    Write-Log 'Strata is not running; starting it (tools\strata.cmd up)'
    $null = Invoke-Tool 'strata up' { & (Get-ToolPath 'strata.ps1') up }
    return (Test-StrataUp)
}

function Get-Failures([string]$platform) {
    # Compact failure summary for the agent: compile errors and failing tests only, never whole logs
    $lines = New-Object System.Collections.Generic.List[string]
    $plats = if ($platform -eq 'All') { @('EditMode', 'PlayMode') } else { @($platform) }
    foreach ($pl in $plats) {
        $log = Join-Path $LogDir "UnityTest-$pl.log"
        if (Test-Path -LiteralPath $log) {
            Select-String -LiteralPath $log -Pattern 'error CS\d{4}' | Select-Object -ExpandProperty Line -Unique -First 20 | ForEach-Object { $lines.Add($_.Trim()) }
        }
        $xml = Join-Path $LogDir ("{0}-results.xml" -f $pl.ToLower())
        if (Test-Path -LiteralPath $xml) {
            $doc = [xml](Get-Content -LiteralPath $xml -Raw)
            foreach ($tc in ($doc.SelectNodes("//test-case[@result='Failed']") | Select-Object -First 20)) {
                $m = "$($tc.failure.message.'#cdata-section')".Trim()
                if ($m.Length -gt 300) { $m = $m.Substring(0, 300) + '...' }
                $lines.Add("FAILED $($tc.fullname): $m")
            }
        } elseif ($lines.Count -eq 0) {
            $lines.Add("No test results for $pl (Unity did not start or did not compile). See Logs\UnityTest-$pl.log")
        }
    }
    return ($lines -join "`n")
}

function Get-TaskPrompt($task) {
    $paths = if ($task.paths) { ($task.paths -join ', ') } else { '(not specified -- keep changes minimal)' }
    $refs = if ($task.strataRefs) { ($task.strataRefs -join ', ') } else { '(none)' }
    $acc = if ($task.acceptance) { ($task.acceptance | ForEach-Object { "- $_" }) -join "`n" } else { '- tests pass' }
    return @"
Task $($task.id): $($task.title)
Notes: $($task.notes)
Files/folders you may change: $paths
Context ids to read first (.strata/strata_index.json): $refs
Acceptance:
$acc

Rules for this run:
- Edit files only. Do NOT run tools\unity.*, Unity, git commit or git push: the runner outside your sandbox
  generates .meta files, updates the context index, runs the Unity tests and commits after you finish.
- Stay inside the listed paths. Add or update EditMode tests in Assets/Tests/EditMode for new behaviour.
- New C# files go under the folder of the matching .asmdef. Never create or edit .meta files.
- When done, reply with a short summary of what you changed.
"@
}

function Find-Gh {
    $c = Get-Command gh, gh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
    if (-not $c -and (Test-Path 'C:\Program Files\GitHub CLI\gh.exe')) { $c = 'C:\Program Files\GitHub CLI\gh.exe' }
    return $c
}

# ---------- preflight ----------
$cfg = Get-TeamConfig
$default = $cfg.defaultBranch
if (Invoke-Git status --porcelain) { throw 'Working tree is not clean. Run the loop in a dedicated clone (see Get-Help tools\loop.ps1).' }
if (Test-Path -LiteralPath (Join-Path $script:RepoRoot 'Temp/UnityLockfile')) { throw 'This project is open in the Unity Editor. Use a dedicated clone for the loop.' }
$user = Get-GitUser
Write-Log "Loop started by $($user.Name): agent=$Agent tests=$TestPlatform maxFixRounds=$MaxFixRounds"
$done = 0

while ($true) {
    if (Test-Path -LiteralPath $StopFile) { Write-Log 'Stop file found; exiting.'; break }
    if ($MaxTasks -gt 0 -and $done -ge $MaxTasks) { Write-Log "Reached -MaxTasks $MaxTasks; exiting."; break }

    if (-not (Confirm-Strata)) {
        Write-Log "Strata is not available; retrying in $IdleMinutes min."
        if ($Once) { break }
        Start-Sleep -Seconds ($IdleMinutes * 60); continue
    }

    # Fresh default branch
    $null = Invoke-Git switch -q $default -AllowFail
    $null = Invoke-Git pull -q --ff-only origin $default -AllowFail

    # Pick the highest-priority todo task that is not claimed and does not overlap a claim
    $claims = @(Get-RemoteClaims)
    $picked = $null
    foreach ($t in (Get-AllTasks | Where-Object { $_.status -eq 'todo' } | Sort-Object priority, id)) {
        if ($claims | Where-Object { $_.Task -eq $t.id }) { continue }
        if ($t.paths -and ($claims | Where-Object { $_.Paths -and (Test-PathOverlap @($t.paths) @($_.Paths)) })) { continue }
        $code = Invoke-Tool 'task claim' { & (Get-ToolPath 'task.ps1') claim $t.id -Agent $Agent }
        if ($code -eq 0 -and (Get-CurrentBranch) -like "task/$($t.id)*") { $picked = $t; break }
        $null = Invoke-Git switch -q $default -AllowFail
    }
    if (-not $picked) {
        Write-Log "No claimable task; sleeping $IdleMinutes min."
        if ($Once) { break }
        Start-Sleep -Seconds ($IdleMinutes * 60); continue
    }
    $task = Get-TaskById $picked.id
    $branch = Get-CurrentBranch
    Write-Log "Claimed $($task.id) '$($task.title)' on $branch"

    # Agent edits -> runner tests, with feedback rounds
    $prompt = Get-TaskPrompt $task
    $passed = $false
    for ($round = 0; $round -le $MaxFixRounds; $round++) {
        if (Test-Path -LiteralPath $StopFile) { break }
        Write-Log "  round $($round): running $Agent"
        $agentCode = Invoke-AgentWithTimeout $prompt $task.id
        if ($agentCode -ne 0) { Write-Log "  agent exited with $agentCode" }
        $null = Invoke-Tool 'unity refresh' { & (Get-ToolPath 'unity.ps1') refresh }   # .meta for new files (outside the sandbox)
        $null = Invoke-Tool 'context index' { & (Get-ToolPath 'strata-index.ps1') }
        $testCode = Invoke-Tool 'unity test' { & (Get-ToolPath 'unity.ps1') test $TestPlatform }
        if ($testCode -eq 0) { $passed = $true; Write-Log "  round $($round): tests passed"; break }
        $failures = Get-Failures $TestPlatform
        Write-Log "  round $($round): tests failed (exit $testCode)"
        $prompt = (Get-TaskPrompt $task) + "`n`nYour previous attempt failed the runner's Unity tests. Fix these problems:`n$failures"
    }

    # Commit what the agent produced; trailers (Task / Agent / Run-Record) come from the commit-msg hook
    $env:AGENT_NAME = $Agent; $env:AGENT_TASK = $task.id
    # The agent ran as a child process, so point the Run-Record trailer at its newest record ourselves
    $rec = Get-ChildItem -Path (Join-Path (Get-HistoryRoot) 'runs') -Recurse -Filter "*-$Agent-$($task.id).md" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($rec) { $env:AGENT_RUN_REF = "runs/$($rec.Directory.Name)/$($rec.Name)" }
    $null = Invoke-Git add -A
    $status = if ($passed) { 'implement' } else { 'WIP, tests failing' }
    $commit = Invoke-Git commit -q -m "task($($task.id)): $status -- $($task.title)" -AllowFail
    if ($LASTEXITCODE -ne 0) { Write-Log "  commit failed or nothing to commit: $($commit -join ' ')" }

    if ($passed) { $null = Invoke-Tool 'task done' { & (Get-ToolPath 'task.ps1') done $task.id } }
    else {
        $note = "loop: Unity tests still failing after $($MaxFixRounds + 1) rounds"
        $null = Invoke-Tool 'task block' { & (Get-ToolPath 'task.ps1') block $task.id -Note $note }
    }

    $push = Invoke-Git push -q -u origin $branch -AllowFail
    if ($LASTEXITCODE -ne 0) { Write-Log "  push failed: $($push -join ' ')" }
    elseif (-not $NoPR -and ($gh = Find-Gh)) {
        $runs = (Get-ChildItem -Path (Join-Path (Get-HistoryRoot) 'runs') -Recurse -Filter "*-$($task.id).md" -ErrorAction SilentlyContinue |
            ForEach-Object { "- history:runs/$($_.Directory.Name)/$($_.Name)" }) -join "`n"
        $body = "Task: $($task.id)`n`nAutomated by tools/loop.ps1 ($Agent) for $($user.Name).`nUnity $TestPlatform tests: $(if ($passed) { 'passed' } else { 'FAILING -- needs a human' })`n`nAgent runs (private history repo):`n$runs`n"
        $bodyFile = Join-Path ([IO.Path]::GetTempPath()) ("pr-" + $task.id + '.md')
        [IO.File]::WriteAllText($bodyFile, $body, $script:Utf8)
        $prArgs = @('pr', 'create', '--base', $default, '--head', $branch, '--title', "$($task.id): $($task.title)", '--body-file', $bodyFile)
        if (-not $passed) { $prArgs += '--draft' }
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $prUrl = & $gh @prArgs 2>&1 | ConvertTo-OutputLine | Select-Object -Last 1
        $ErrorActionPreference = $prev
        Remove-Item -LiteralPath $bodyFile -ErrorAction SilentlyContinue
        Write-Log "  PR: $prUrl"
    }
    Remove-Item Env:AGENT_NAME, Env:AGENT_TASK, Env:AGENT_RUN_FILE, Env:AGENT_RUN_REF -ErrorAction SilentlyContinue
    $done++
    Write-Log "Finished $($task.id): $(if ($passed) { 'ready for review' } else { 'blocked (draft PR)' })"
    if ($Once) { break }
}
$null = Invoke-Git switch -q $default -AllowFail
Write-Log "Loop ended after $done task(s)."

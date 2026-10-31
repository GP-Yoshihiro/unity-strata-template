<#
.SYNOPSIS
  Unattended development loop: pick a task -> claim -> agent edits code -> runner tests -> PR. Repeat.
  Once a day (and when the queue is empty) it also runs a self-improvement pass that turns what the loop
  learned into a draft PR (lessons, prompts, task splits) for a human to review.

.DESCRIPTION
  The agent (default: Codex on the local Strata model) only edits files inside its sandbox. Everything that
  needs the real user environment -- Unity .meta generation, the context index, Unity tests, git push and
  the PR -- is done here, outside the sandbox. Failing tests are fed back to the agent for up to
  -MaxFixRounds extra rounds; if they still fail, the work is pushed as a draft PR and the task is marked
  blocked (claim kept) for a human.

  Guard rails: changes outside the task's "paths" are reverted (and reported to the agent), the working tree
  is reset between tasks, agent runs and Unity runs have time limits (-AgentTimeoutMinutes,
  UNITY_TIMEOUT_MINUTES), and the loop only picks tasks that are on the default branch -- tasks proposed by
  the improvement pass become workable only after a human merges its PR.

  Getting better over time:
    - every task appends one metrics line (rounds, pass/fail, compiler error codes, scope violations,
      duration) to Logs/loop-metrics.jsonl in this clone
    - Docs/agent-lessons.md (L1 context, first part of every prompt) holds the project's known pitfalls
    - the improvement pass (-ImproveEveryHours, default 24; 0 = off) gives the agent those metrics plus
      Prompts/PROMPT_DAILY_IMPROVEMENT.md and opens a DRAFT PR with the report, new lessons, prompt fixes and
      task splits. Nothing it proposes is used by the loop until a human merges it.

  Run it in a dedicated clone that no one has open in the Unity Editor, at a short path, e.g.
    git clone <repo> C:\dev\<name>-agent ;  cd C:\dev\<name>-agent ;  git config core.hooksPath .githooks ;  tools\loop.cmd

  Stop it gracefully: create Logs\loop.stop (tools\loop.cmd -Stop). It finishes the current task first.
  Log: Logs\loop.log (what the loop did) and the agent output on screen.

.EXAMPLE
  tools\loop.cmd                         # run until stopped
  tools\loop.cmd -Once                   # one task, then exit (good first test)
  tools\loop.cmd -MaxTasks 5 -TestPlatform All
  tools\loop.cmd -AgentTimeoutMinutes 20  # stop an agent run that takes longer (default 30)
  tools\loop.cmd -ImproveNow -Once        # run only the self-improvement pass now
  tools\loop.cmd -Stop
#>
param(
    [int]$MaxTasks = 0,
    [int]$MaxFixRounds = 2,
    [ValidateSet('', 'codex-local', 'codex', 'claude', 'claude-local')][string]$Agent = '',   # default: team.config.json loopAgent, else codex-local
    [ValidateSet('EditMode', 'PlayMode', 'All')][string]$TestPlatform = 'EditMode',
    [int]$IdleMinutes = 15,
    [int]$AgentTimeoutMinutes = 30,
    [int]$ImproveEveryHours = 24,
    [switch]$ImproveNow,
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
$ImproveStamp = Join-Path $LogDir 'loop.last-improve'
$LessonsFile = Join-Path $script:RepoRoot 'Docs/agent-lessons.md'
if (-not $Agent) { $Agent = "$((Get-TeamConfig).loopAgent)"; if (-not $Agent) { $Agent = 'codex-local' } }
$ImprovePaths = @('Docs/agent-lessons.md', 'Prompts', '.strata/cache_config.json', 'Reports', 'Tasks/items')

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
    # after -AgentTimeoutMinutes its whole process tree is killed.
    $pf = Join-Path ([IO.Path]::GetTempPath()) ("loop-prompt-" + [Guid]::NewGuid().ToString('N') + '.txt')
    [IO.File]::WriteAllText($pf, $PromptText, $script:Utf8)
    $shell = (Get-Process -Id $PID).Path
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$(Get-ToolPath 'agent.ps1')`" $Agent -PromptFile `"$pf`" -Task $TaskId"
    $p = Start-Process -FilePath $shell -ArgumentList $argLine -NoNewWindow -PassThru
    $null = $p.Handle   # keeps ExitCode readable after the process ends
    try {
        if ($p.WaitForExit($AgentTimeoutMinutes * 60 * 1000)) { return $p.ExitCode }
        Write-Log "  agent exceeded $AgentTimeoutMinutes min; stopping it"
        Stop-ProcessTree $p
        return 124
    } finally { Remove-Item -LiteralPath $pf -ErrorAction SilentlyContinue }
}

function Test-StrataUp {
    $port = (Get-Content -LiteralPath (Join-Path $script:RepoRoot '.strata/launch.json') -Raw | ConvertFrom-Json).port
    try { return [bool](Invoke-RestMethod "http://127.0.0.1:$port/health" -TimeoutSec 10).loaded } catch { return $false }
}

function Confirm-Strata {
    if ($Agent -notin 'codex-local', 'claude-local') { return $true }
    if (Test-StrataUp) { return $true }
    Write-Log 'Strata is not running; starting it (tools\strata.cmd up)'
    $null = Invoke-Tool 'strata up' { & (Get-ToolPath 'strata.ps1') up }
    return (Test-StrataUp)
}

function Get-ChangedFiles {
    # Working-tree changes relative to HEAD (tracked and untracked), repo-relative with '/'
    Invoke-Git -c core.quotepath=false status --porcelain --untracked-files=all -AllowFail | Where-Object { $_.Length -gt 3 } | ForEach-Object {
        $f = $_.Substring(3)
        if ($f -match ' -> ') { $f = ($f -split ' -> ')[-1] }
        $f.Trim('"')
    }
}

function Undo-OutOfScope($Task) {
    # Reverts every change the agent made outside the task's paths; returns the reverted files.
    $paths = @($Task.paths | Where-Object { $_ })
    if (-not $paths) { return @() }
    $bad = @(Get-ChangedFiles | Where-Object { -not (Test-InTaskPaths $_ $paths $Task.id) })
    foreach ($f in $bad) {
        $tracked = Invoke-Git ls-files -- $f -AllowFail
        if ($tracked) { $null = Invoke-Git checkout -q HEAD -- $f -AllowFail }
        else { Remove-Item -LiteralPath (Join-Path $script:RepoRoot $f) -Force -Recurse -ErrorAction SilentlyContinue }
    }
    return $bad
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

function Get-Lessons {
    # Stable L1 prefix of every prompt (identical between cycles, so Strata's prompt cache can reuse it)
    if (-not (Test-Path -LiteralPath $LessonsFile)) { return '' }
    $t = [IO.File]::ReadAllText($LessonsFile, $script:Utf8)
    if ($t.Length -gt 6000) { $t = $t.Substring(0, 6000) + "`n... (truncated)" }
    return "Project lessons (Docs/agent-lessons.md) -- known pitfalls, follow them:`n$t`n`n"
}

function Get-TaskPrompt($task) {
    $paths = if ($task.paths) { ($task.paths -join ', ') } else { '(not specified -- keep changes minimal)' }
    $refs = if ($task.strataRefs) { ($task.strataRefs -join ', ') } else { '(none)' }
    $acc = if ($task.acceptance) { ($task.acceptance | ForEach-Object { "- $_" }) -join "`n" } else { '- tests pass' }
    return (Get-Lessons) + @"
Task $($task.id): $($task.title)
Notes: $($task.notes)
Files/folders you may change: $paths
Context ids to read first (.strata/strata_index.json): $refs
Acceptance:
$acc

Rules for this run:
- Edit files only. Do NOT run tools\unity.*, Unity, git commit or git push: the runner outside your sandbox
  generates .meta files, updates the context index, runs the Unity tests and commits after you finish.
- Stay inside the listed paths: the runner reverts changes anywhere else. Add or update EditMode tests in
  Assets/Tests/EditMode for new behaviour.
- New C# files go under the folder of the matching .asmdef. Never create or edit .meta files.
- When done, reply with a short summary of what you changed.
"@
}

# ---------- metrics (Logs/loop-metrics.jsonl, one JSON line per task) ----------

$MetricsFile = Join-Path $LogDir 'loop-metrics.jsonl'

function Add-LoopMetric([hashtable]$Data) {
    $Data['time'] = (Get-Date).ToString('o'); $Data['user'] = (Get-GitUser).Name; $Data['agent'] = $Agent
    $Data['machine'] = [Environment]::MachineName
    [IO.File]::AppendAllText($MetricsFile, (($Data | ConvertTo-Json -Compress -Depth 4) + "`n"), $script:Utf8)
}

function Get-MetricsSummary([int]$Days = 7) {
    $since = (Get-Date).AddDays(-$Days)
    if (-not (Test-Path -LiteralPath $MetricsFile)) { return "No loop metrics yet." }
    $rows = @(Get-Content -LiteralPath $MetricsFile -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } |
        Where-Object { $_.time -and ([datetime]$_.time) -ge $since -and $_.kind -eq 'task' })
    if (-not $rows) { return "No loop metrics in the last $Days days." }
    $passed = @($rows | Where-Object { $_.passed }).Count
    $codes = $rows | ForEach-Object { $_.csErrors } | Where-Object { $_ } | Group-Object | Sort-Object Count -Descending | Select-Object -First 10 |
        ForEach-Object { "$($_.Name) x$($_.Count)" }
    $lines = @(
        "Loop metrics, last $Days days: $($rows.Count) tasks, $passed finished with passing tests, $($rows.Count - $passed) blocked.",
        "Average rounds: $([math]::Round(($rows | Measure-Object -Property rounds -Average).Average, 2)); agent timeouts: $(($rows | Measure-Object -Property timeouts -Sum).Sum); files reverted for leaving the task paths: $(($rows | Measure-Object -Property outOfScope -Sum).Sum).",
        "Most frequent compiler errors: $(if ($codes) { $codes -join ', ' } else { 'none' })",
        'Per task (task, passed, rounds, minutes, errors):'
    )
    $lines += $rows | Select-Object -Last 30 | ForEach-Object { "- $($_.task) passed=$($_.passed) rounds=$($_.rounds) min=$($_.minutes) errors=$((@($_.csErrors) -join ' '))" }
    return ($lines -join "`n")
}

# ---------- git helpers ----------

function Find-Gh {
    $c = Get-Command gh, gh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
    if (-not $c -and (Test-Path 'C:\Program Files\GitHub CLI\gh.exe')) { $c = 'C:\Program Files\GitHub CLI\gh.exe' }
    return $c
}

function Reset-WorkingTree([string]$TaskId) {
    # Never carry one task's leftovers into the next. Anything uncommitted is saved as a patch first.
    if (-not (Get-ChangedFiles)) { return }
    $null = Invoke-Git add -A -AllowFail
    $patch = Join-Path $LogDir ("loop-unsaved-{0}-{1}.patch" -f $TaskId, (Get-Date).ToString('yyyyMMdd-HHmmss'))
    $diff = Invoke-Git diff --cached --binary -AllowFail
    [IO.File]::WriteAllText($patch, (($diff -join "`n") + "`n"), $script:Utf8)
    $null = Invoke-Git reset -q --hard HEAD -AllowFail
    $null = Invoke-Git clean -fdq -AllowFail   # no -x: keeps Library/ and other ignored caches
    Write-Log "  uncommitted changes saved to $patch and removed from the working tree"
}

function Submit-Work($task, [bool]$passed, [string]$runAgent, [switch]$AlwaysDraft, [string]$Extra) {
    # Commit, mark done/blocked, push, PR. Returns whether the work counts as finished (not when nothing was committed).
    $note = "loop: unfinished after $($MaxFixRounds + 1) round(s) -- tests failing or agent error; see the draft PR"
    if (-not (Get-ChangedFiles)) {
        $passed = $false; $note = 'loop: the agent made no changes'; Write-Log "  $note"
    } else {
        $null = Invoke-Git add -A
        $status = if ($passed) { 'implement' } else { 'WIP, tests failing' }
        $commit = Invoke-Git commit -q -m "task($($task.id)): $status -- $($task.title)" -m "Task: $($task.id)" -m "Agent: $runAgent" -AllowFail
        if ($LASTEXITCODE -ne 0) {
            # e.g. the pre-commit hook refused (.meta, big file, stale index): the work is NOT on the branch
            Write-Log "  commit failed: $($commit -join ' ')"
            $passed = $false; $note = 'loop: commit refused by the pre-commit checks; the work is saved as a patch in the loop clone Logs/'
        }
    }
    Reset-WorkingTree $task.id   # keep a patch of anything left, never leak it into task done/block or the next task

    if ($passed) { $null = Invoke-Tool 'task done' { & (Get-ToolPath 'task.ps1') done $task.id } }
    else { $null = Invoke-Tool 'task block' { & (Get-ToolPath 'task.ps1') block $task.id -Note $note } }

    $branch = Get-CurrentBranch
    $push = Invoke-Git push -q -u origin $branch -AllowFail
    if ($LASTEXITCODE -ne 0) { Write-Log "  push failed: $($push -join ' ')" }
    elseif (-not $NoPR -and ($gh = Find-Gh)) {
        $result = if ($AlwaysDraft) { "Result: $(if ($passed) { 'agent finished' } else { "unfinished -- $note" })" } else { "Unity $TestPlatform tests: $(if ($passed) { 'passed' } else { "FAILING -- needs a human ($note)" })" }
        $body = "Task: $($task.id)`n`nAutomated by tools/loop.ps1 ($runAgent) for $((Get-GitUser).Name).`n$result`n$Extra`n"
        $bodyFile = Join-Path ([IO.Path]::GetTempPath()) ("pr-" + $task.id + '.md')
        [IO.File]::WriteAllText($bodyFile, $body, $script:Utf8)
        $prArgs = @('pr', 'create', '--base', $default, '--head', $branch, '--title', "$($task.id): $($task.title)", '--body-file', $bodyFile)
        if (-not $passed -or $AlwaysDraft) { $prArgs += '--draft' }
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $prUrl = & $gh @prArgs 2>&1 | ConvertTo-OutputLine | Select-Object -Last 1
        $ErrorActionPreference = $prev
        Remove-Item -LiteralPath $bodyFile -ErrorAction SilentlyContinue
        Write-Log "  PR: $prUrl"
    }
    return $passed
}

# ---------- self-improvement pass ----------

function Test-ImproveDue([switch]$Idle) {
    if ($ImproveNow) { return $true }
    if ($ImproveEveryHours -le 0) { return $false }
    if (-not (Test-Path -LiteralPath $ImproveStamp)) {
        # First start of this clone: begin the clock instead of improving before any work was done
        [IO.File]::WriteAllText($ImproveStamp, (Get-Date).ToString('o'), $script:Utf8); return $false
    }
    $last = [datetime](Get-Content -LiteralPath $ImproveStamp -Raw).Trim()
    $hours = ((Get-Date) - $last).TotalHours
    # An empty queue is a good moment too (the pass proposes task splits), but not more than every 6 hours
    return ($hours -ge $ImproveEveryHours) -or ($Idle -and $hours -ge [math]::Min(6, $ImproveEveryHours))
}

function Invoke-ImprovementPass {
    [IO.File]::WriteAllText($ImproveStamp, (Get-Date).ToString('o'), $script:Utf8)   # also on failure: no retry storm
    $title = "Daily improvement $((Get-Date).ToString('yyyy-MM-dd'))"
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $id = & (Get-ToolPath 'task.ps1') new $title -Paths ($ImprovePaths -join ',') -Priority 1 6>$null | Select-Object -Last 1
    $ErrorActionPreference = $prev
    if ("$id" -notmatch '^T-\d{6}-[0-9a-f]{4}$') { Write-Log "Improvement pass: could not create its task ($id)"; return }
    $code = Invoke-Tool 'task claim' { & (Get-ToolPath 'task.ps1') claim $id -Agent $Agent }
    if ($code -ne 0 -or (Get-CurrentBranch) -notlike "task/$id*") {
        Write-Log "Improvement pass: claim of $id failed"
        Remove-Item -LiteralPath (Join-Path (Get-TaskDir) "$id.json") -ErrorAction SilentlyContinue
        $null = Invoke-Git switch -q $default -AllowFail
        return
    }
    $task = Get-TaskById $id
    Write-Log "Improvement pass $id on $(Get-CurrentBranch)"
    $instructions = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'Prompts/PROMPT_DAILY_IMPROVEMENT.md'), $script:Utf8)
    $recent = if (Test-Path -LiteralPath $LoopLog) { (Get-Content -LiteralPath $LoopLog -Tail 60) -join "`n" } else { '' }
    $prompt = (Get-Lessons) + @"
Task $($id): $title -- self-improvement pass of the unattended loop.
Files/folders you may change: $($ImprovePaths -join ', ')  (everything else is reverted by the runner)

Follow the instructions below, with these adjustments for this sandboxed run:
- You cannot run Unity, git or tools\task.cmd. The runner already collected the
  data you need (below). Create new tasks by writing Tasks/items/T-<yyMMdd>-<4 hex>.json files as described in
  Tasks/README.md (status "todo", precise "paths", "strataRefs", "acceptance").
- Write the report to Reports/daily_report_$((Get-Date).ToString('yyyyMMdd')).md.
- Turn repeated failures into short, concrete rules in Docs/agent-lessons.md (one line each, newest first,
  drop rules that no longer apply; keep the file under 80 lines). This file is prepended to every agent prompt.
- Change Prompts/ or .strata/cache_config.json only when the data shows a clear benefit; explain why in the report.
- Never modify tasks that are claimed (see "Active claims" below).

=== Instructions (Prompts/PROMPT_DAILY_IMPROVEMENT.md) ===
$instructions

=== Data collected by the runner ===
$(Get-MetricsSummary 7)

Active claims: $((@(Get-RemoteClaims) | ForEach-Object { "$($_.Task) ($($_.State), $($_.User))" }) -join '; ')
Open tasks: $((@(Get-AllTasks | Where-Object { $_.status -in 'todo', 'blocked' }) | ForEach-Object { "$($_.id) [$($_.status)] $($_.title)" }) -join '; ')

Recent loop log:
$recent
"@
    $agentCode = Invoke-AgentWithTimeout $prompt $id
    if ($agentCode -ne 0) { Write-Log "  improvement agent exited with $agentCode" }
    $reverted = @(Undo-OutOfScope $task)
    if ($reverted) { Write-Log "  reverted out-of-scope changes: $($reverted -join ', ')" }
    $null = Invoke-Tool 'context index' { & (Get-ToolPath 'strata-index.ps1') }
    # Self-modification is always reviewed by a human: draft PR, and the loop ignores it until merged
    $ok = Submit-Work $task ($agentCode -eq 0) $Agent -AlwaysDraft -Extra 'Self-improvement pass: review the report, lessons, prompt changes and proposed tasks; merge only what you agree with.'
    Add-LoopMetric @{ kind = 'improve'; task = $id; passed = $ok; outOfScope = $reverted.Count }
    $null = Invoke-Git switch -q $default -AllowFail
}

# ---------- preflight ----------
$cfg = Get-TeamConfig
$default = $cfg.defaultBranch
if (Invoke-Git status --porcelain) { throw 'Working tree is not clean. Run the loop in a dedicated clone (see Get-Help tools\loop.ps1).' }
if (Test-Path -LiteralPath (Join-Path $script:RepoRoot 'Temp/UnityLockfile')) { throw 'This project is open in the Unity Editor. Use a dedicated clone for the loop.' }
$user = Get-GitUser
Write-Log "Loop started by $($user.Name): agent=$Agent tests=$TestPlatform maxFixRounds=$MaxFixRounds improveEvery=${ImproveEveryHours}h"
$done = 0

while ($true) {
    if (Test-Path -LiteralPath $StopFile) { Write-Log 'Stop file found; exiting.'; break }
    if ($MaxTasks -gt 0 -and $done -ge $MaxTasks) { Write-Log "Reached -MaxTasks $MaxTasks; exiting."; break }

    if (-not (Confirm-Strata)) {
        Write-Log "Strata is not available; retrying in $IdleMinutes min."
        if ($Once) { break }
        Start-Sleep -Seconds ($IdleMinutes * 60); continue
    }

    # Fresh default branch (tasks are only picked from here, i.e. after a human merged them)
    $null = Invoke-Git switch -q $default -AllowFail
    $null = Invoke-Git pull -q --ff-only origin $default -AllowFail

    if (Test-ImproveDue) {
        Invoke-ImprovementPass
        if ($ImproveNow) { break }
        continue
    }

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
        if (Test-ImproveDue -Idle) { Invoke-ImprovementPass; continue }
        Write-Log "No claimable task; sleeping $IdleMinutes min."
        if ($Once) { break }
        Start-Sleep -Seconds ($IdleMinutes * 60); continue
    }
    $task = Get-TaskById $picked.id
    $branch = Get-CurrentBranch
    $started = Get-Date
    Write-Log "Claimed $($task.id) '$($task.title)' on $branch"
    if (-not $task.paths) { Write-Log '  warning: task has no "paths"; changes cannot be scope-checked' }

    # Agent edits -> runner tests, with feedback rounds
    $prompt = Get-TaskPrompt $task
    $passed = $false; $rounds = 0; $timeouts = 0; $outOfScope = 0
    $csErrors = New-Object System.Collections.Generic.List[string]
    for ($round = 0; $round -le $MaxFixRounds; $round++) {
        if (Test-Path -LiteralPath $StopFile) { break }
        $rounds = $round + 1
        Write-Log "  round $($round): running $Agent"
        $agentCode = Invoke-AgentWithTimeout $prompt $task.id
        if ($agentCode -eq 124) { $timeouts++ }
        if ($agentCode -ne 0) { Write-Log "  agent exited with $agentCode" }
        $reverted = @(Undo-OutOfScope $task)
        $outOfScope += $reverted.Count
        if ($reverted) { Write-Log "  reverted changes outside the task paths: $($reverted -join ', ')" }
        $null = Invoke-Tool 'unity refresh' { & (Get-ToolPath 'unity.ps1') refresh }   # .meta for new files (outside the sandbox)
        $null = Invoke-Tool 'context index' { & (Get-ToolPath 'strata-index.ps1') }
        $testCode = Invoke-Tool 'unity test' { & (Get-ToolPath 'unity.ps1') test $TestPlatform }
        if ($testCode -eq 0) { $passed = $true; Write-Log "  round $($round): tests passed"; break }
        $failures = Get-Failures $TestPlatform
        [regex]::Matches($failures, 'error (CS\d{4})') | ForEach-Object { $csErrors.Add($_.Groups[1].Value) }
        Write-Log "  round $($round): tests failed (exit $testCode)"
        $scopeNote = if ($reverted) { "`nThe runner reverted your changes to these files because they are outside the task paths: $($reverted -join ', ')" } else { '' }
        $prompt = (Get-TaskPrompt $task) + "`n`nYour previous attempt failed the runner's Unity tests. Fix these problems:`n$failures$scopeNote"
    }

    $passed = Submit-Work $task $passed $Agent
    Add-LoopMetric @{ kind = 'task'; task = $task.id; passed = $passed; rounds = $rounds; timeouts = $timeouts; outOfScope = $outOfScope
        minutes = [math]::Round(((Get-Date) - $started).TotalMinutes, 1); csErrors = @($csErrors | Select-Object -Unique); tests = $TestPlatform }
    $done++
    Write-Log "Finished $($task.id): $(if ($passed) { 'ready for review' } else { 'blocked (draft PR)' })"
    if ($Once) { break }
}
$null = Invoke-Git switch -q $default -AllowFail
Write-Log "Loop ended after $done task(s)."

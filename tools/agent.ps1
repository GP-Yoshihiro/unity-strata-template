<#
.SYNOPSIS
  Run an AI agent on a task and record who ran it, which agent/model, the exact instructions and the
  outcome in History/runs/ (one file per run, committed with the work).

.EXAMPLE
  tools\agent.cmd codex-local "Prompts/unity_csharp_coder.md に従って T-261031-0001 を実装して"
  tools\agent.cmd codex -Task T-261031-0001 "..."          # cloud Codex
  tools\agent.cmd claude "..."                             # Claude Code (claude -p)
  tools\agent.cmd strata "Summarise Logs/UnityTest-EditMode.log"   # single local-model answer

  The task id defaults to the one in the current branch name (task/<id>-...).
  Inside the run, AGENT_RUN_FILE / AGENT_NAME / AGENT_TASK are set, so:
    - commits get "Task:", "Agent:" and "Run-Record:" trailers (.githooks/commit-msg)
    - work delegated with tools\strata.cmd ask is appended to the same record
#>
param(
    [Parameter(Mandatory = $true, Position = 0)][ValidateSet('codex', 'codex-local', 'claude', 'strata')][string]$Agent,
    [Parameter(Mandatory = $true, Position = 1)][string]$Prompt,
    [string]$Task,
    [switch]$NoRecord
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/team.ps1')

if (-not $Task) { $Task = Get-TaskIdFromBranch (Get-CurrentBranch) }

function Find-Exe([string[]]$names, [string]$fallback) {
    $c = Get-Command $names -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
    if (-not $c -and $fallback -and (Test-Path -LiteralPath $fallback)) { $c = $fallback }
    return $c
}

# Context handed to every agent: who it works for and which task, so its commits and notes stay attributable.
$header = "You are working in a shared team repository. Follow AGENTS.md."
if ($Task) { $header += " Current task: $Task (Tasks/items/$Task.json). Only touch the paths listed there." }
$fullPrompt = "$header`n`n$Prompt"

switch ($Agent) {
    'codex' {
        $exe = Find-Exe @('codex.cmd', 'codex') (Join-Path "$env:APPDATA" 'npm\codex.cmd')
        if (-not $exe) { throw 'Codex CLI not found. Install: npm.cmd install -g @openai/codex' }
        $cmd = { & $exe exec $fullPrompt }; $model = 'codex (cloud default)'
    }
    'codex-local' {
        $cmd = { & (Join-Path $PSScriptRoot 'codex-local.ps1') exec $fullPrompt }
        $model = (Get-Content (Join-Path $PSScriptRoot 'templates/codex-local.config.toml') | Select-String '^model\s*=\s*"(.+)"').Matches[0].Groups[1].Value
    }
    'claude' {
        $exe = Find-Exe @('claude.cmd', 'claude.exe', 'claude') $null
        if (-not $exe) { throw 'Claude Code CLI (claude) not found on PATH.' }
        $cmd = { & $exe -p $fullPrompt }; $model = 'claude (default)'
    }
    'strata' {
        $cmd = { & (Join-Path $PSScriptRoot 'strata.ps1') ask $fullPrompt }
        $model = 'strata local'
    }
}

$record = $null
if (-not $NoRecord) {
    $record = New-RunRecord -Agent $Agent -Model $model -TaskId $Task -Prompt $Prompt
    $env:AGENT_RUN_FILE = $record
    Write-Host "Recording run: $record"
}
$env:AGENT_NAME = $Agent
$env:AGENT_TASK = $Task

$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
$output = & $cmd 2>&1 | ForEach-Object { $line = "$_"; Write-Host $line; $line }
$code = $LASTEXITCODE
$ErrorActionPreference = $prev
if ($null -eq $code) { $code = 0 }

if ($record) {
    Add-RunSection $record 'Result (tail)' (($output | Select-Object -Last 80) -join "`n") 6000
    Complete-RunRecord $record $code
    Write-Host "Run recorded: $record (commit it with the work)"
}
exit $code

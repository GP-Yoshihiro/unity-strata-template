<#
.SYNOPSIS
  Run an AI agent on a task and record who ran it, which agent/model, the exact instructions and the
  outcome in the private history repo (team.config.json: historyRepo, cloned at .history/).
  The record is pushed when the run starts (so teammates see it live) and again when it ends.

.EXAMPLE
  tools\agent.cmd codex-local "Implement T-261031-0001 following Prompts/unity_csharp_coder.md"
  tools\agent.cmd codex -Task T-261031-0001 "..."          # cloud Codex
  tools\agent.cmd claude "..."                             # Claude Code (claude -p)
  tools\agent.cmd strata "Summarise Logs/UnityTest-EditMode.log"   # single local-model answer

  The task id defaults to the one in the current branch name (task/<id>-...).
  Inside the run, AGENT_RUN_FILE / AGENT_RUN_REF / AGENT_NAME / AGENT_TASK are set, so:
    - commits get "Task:", "Agent:" and "Run-Record:" trailers (.githooks/commit-msg)
    - work delegated with tools\strata.cmd ask is appended to the same record
#>
param(
    [Parameter(Mandatory = $true, Position = 0)][ValidateSet('codex', 'codex-local', 'claude', 'strata')][string]$Agent,
    [Parameter(Position = 1)][string]$Prompt,
    [string]$PromptFile,   # UTF-8 file instead of -Prompt (used by tools/loop.ps1 for multi-line prompts)
    [string]$Task,
    [switch]$NoRecord
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/team.ps1')
if ($PromptFile) { $Prompt = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $PromptFile).Path, $script:Utf8) }
if (-not $Prompt) { throw 'Give the instructions: tools\agent.cmd <agent> "prompt"  (or -PromptFile <utf8 file>)' }

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

# The CLIs read the prompt from a UTF-8 file on stdin (see Invoke-WithPromptFile): multi-line and
# Japanese prompts survive Windows PowerShell 5.1 and the codex.cmd / claude.cmd batch shims intact.
$promptFile = Join-Path ([IO.Path]::GetTempPath()) ("agent-prompt-" + [Guid]::NewGuid().ToString('N') + '.txt')
[IO.File]::WriteAllText($promptFile, $fullPrompt, (New-Object Text.UTF8Encoding $false))
switch ($Agent) {
    'codex' {
        $exe = Find-Exe @('codex.cmd', 'codex') (Join-Path "$env:APPDATA" 'npm\codex.cmd')
        if (-not $exe) { throw 'Codex CLI not found. Install: npm.cmd install -g @openai/codex' }
        # --sandbox: without it an untrusted checkout falls back to read-only and the agent cannot edit
        $cmd = { Invoke-WithPromptFile $exe @('exec', '--sandbox', 'workspace-write', '-') $promptFile }; $model = 'codex (cloud default)'
    }
    'codex-local' {
        $cmd = { & (Join-Path $PSScriptRoot 'codex-local.ps1') -PromptFile $promptFile exec - }
        $model = (Get-Content (Join-Path $PSScriptRoot 'templates/codex-local.config.toml') | Select-String '^model\s*=\s*"(.+)"').Matches[0].Groups[1].Value
    }
    'claude' {
        $exe = Find-Exe @('claude.cmd', 'claude.exe', 'claude') $null
        if (-not $exe) { throw 'Claude Code CLI (claude) not found on PATH.' }
        # Headless (-p) runs cannot answer permission prompts: allow file edits; shell commands stay limited to
        # .claude/settings.json allow rules, and its deny rules (.history, .meta, force push) still apply.
        $cmd = { Invoke-WithPromptFile $exe @('-p', '--permission-mode', 'acceptEdits') $promptFile }; $model = 'claude (default)'
    }
    'strata' {
        $cmd = { & (Join-Path $PSScriptRoot 'strata.ps1') ask $fullPrompt }
        $model = 'strata local'
    }
}

$record = $null
if (-not $NoRecord) {
    $record = New-RunRecord -Agent $Agent -Model $model -TaskId $Task -Prompt $Prompt
    $env:AGENT_RUN_FILE = $record.Path   # absolute; tools\strata.ps1 ask appends delegated work here
    $env:AGENT_RUN_REF = $record.Ref     # repo-relative id used in the Run-Record commit trailer
    Publish-History "start $($record.Id)"
    Write-Host "Recording run: history:$($record.Ref)"
}
$env:AGENT_NAME = $Agent
$env:AGENT_TASK = $Task

$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
# The CLIs write UTF-8; without this Windows PowerShell 5.1 decodes their output with the OEM code page
$prevEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
try {
    $output = & $cmd 2>&1 | ConvertTo-OutputLine | ForEach-Object { Write-Host $_; $_ }
    $code = $LASTEXITCODE
} finally {
    [Console]::OutputEncoding = $prevEnc
    $ErrorActionPreference = $prev
}
if ($null -eq $code) { $code = 0 }
Remove-Item -LiteralPath $promptFile -ErrorAction SilentlyContinue

if ($record) {
    Add-RunSection $record.Path 'Result (tail)' (($output | Select-Object -Last 80) -join "`n") 6000
    Complete-RunRecord $record.Path $code
    Publish-History "end $($record.Id) exit=$code"
    Write-Host "Run recorded: history:$($record.Ref)"
}
exit $code

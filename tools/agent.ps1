<#
.SYNOPSIS
  Run one AI agent with a prompt, the same way for every agent (used by tools/loop.ps1).

.EXAMPLE
  tools\agent.cmd claude "Implement T-261031-0001 following Prompts/unity_csharp_coder.md"   # Claude Code (claude -p)
  tools\agent.cmd codex "..."                              # Codex (cloud)
  tools\agent.cmd codex-local "..."                        # Codex on the local Strata model
  tools\agent.cmd claude-local "..."                       # Claude Code on the local Strata model (experimental)
  tools\agent.cmd strata "Summarise Logs/UnityTest-EditMode.log"   # one local-model answer

  The task id defaults to the one in the current branch name (task/<id>-...).
#>
param(
    [Parameter(Mandatory = $true, Position = 0)][ValidateSet('codex', 'codex-local', 'claude', 'claude-local', 'strata')][string]$Agent,
    [Parameter(Position = 1)][string]$Prompt,
    [string]$PromptFile,   # UTF-8 file instead of -Prompt (used by tools/loop.ps1 for multi-line prompts)
    [string]$Task
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

# Context handed to every agent: the shared rules and the claimed task's scope
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
        $cmd = { Invoke-WithPromptFile $exe @('exec', '--sandbox', 'workspace-write', '-') $promptFile }
    }
    'codex-local' {
        $cmd = { & (Join-Path $PSScriptRoot 'codex-local.ps1') -PromptFile $promptFile exec - }
    }
    'claude' {
        $exe = Find-Exe @('claude.cmd', 'claude.exe', 'claude') $null
        if (-not $exe) { throw 'Claude Code CLI (claude) not found on PATH.' }
        # Headless (-p) runs cannot answer permission prompts: allow file edits; shell commands stay limited to
        # .claude/settings.json allow rules, and its deny rules (.meta, force push, --no-verify) still apply.
        $cmd = { Invoke-WithPromptFile $exe @('-p', '--permission-mode', 'acceptEdits') $promptFile }
    }
    'claude-local' {
        # Claude Code against Strata's Anthropic-compatible API: no cloud tokens. Experimental -- small local
        # models handle Claude Code's long tool prompts less reliably than the cloud models.
        $exe = Find-Exe @('claude.cmd', 'claude.exe', 'claude') $null
        if (-not $exe) { throw 'Claude Code CLI (claude) not found on PATH.' }
        $launch = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.strata/launch.json') -Raw | ConvertFrom-Json
        $base = "http://127.0.0.1:$(if ($launch.port) { $launch.port } else { 8080 })"
        try { $localModel = (Invoke-RestMethod "$base/v1/models" -TimeoutSec 10).data[0].id } catch { throw "Strata is not running at $base (tools\strata.cmd up)." }
        $env:ANTHROPIC_BASE_URL = $base
        $env:ANTHROPIC_AUTH_TOKEN = if ($env:STRATA_API_KEY) { $env:STRATA_API_KEY } else { 'strata-local' }
        $env:ANTHROPIC_MODEL = $localModel
        $env:ANTHROPIC_DEFAULT_HAIKU_MODEL = $localModel; $env:ANTHROPIC_SMALL_FAST_MODEL = $localModel
        $env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'
        $cmd = { Invoke-WithPromptFile $exe @('-p', '--permission-mode', 'acceptEdits') $promptFile }
    }
    'strata' {
        $cmd = { & (Join-Path $PSScriptRoot 'strata.ps1') ask $fullPrompt }
    }
}

$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
# The CLIs write UTF-8; without this Windows PowerShell 5.1 decodes their output with the OEM code page
$prevEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
try {
    & $cmd 2>&1 | ConvertTo-OutputLine | ForEach-Object { Write-Host $_ }
    $code = $LASTEXITCODE
} finally {
    [Console]::OutputEncoding = $prevEnc
    $ErrorActionPreference = $prev
}
if ($null -eq $code) { $code = 0 }
Remove-Item -LiteralPath $promptFile -ErrorAction SilentlyContinue
exit $code

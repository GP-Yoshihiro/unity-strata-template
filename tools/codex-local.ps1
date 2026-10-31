<#
.SYNOPSIS
  Run Codex on the local Strata model (start it first: tools\strata.cmd up).

.DESCRIPTION
  Uses <repo>/.codex-local as CODEX_HOME so the Codex desktop app's plugins and MCP servers in ~/.codex
  do not fill the local model's context window. The config is generated from
  tools/templates/codex-local.config.toml plus a trust entry for this checkout's absolute path
  (trust is per machine, so it is never committed).

.EXAMPLE
  tools\codex-local.cmd                                  # interactive
  tools\codex-local.cmd exec "task"                      # one-shot (single-line ASCII-safe prompt)
  tools\codex-local.cmd -PromptFile prompt.txt exec -    # one-shot, multi-line / Japanese prompt from a UTF-8 file
#>
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'lib/team.ps1')

$CodexArgs = @($args)
$PromptFile = $null
if ($CodexArgs.Count -ge 2 -and $CodexArgs[0] -eq '-PromptFile') {
    $PromptFile = (Resolve-Path -LiteralPath $CodexArgs[1]).Path
    $CodexArgs = @($CodexArgs | Select-Object -Skip 2)
}
$CodexHome = Join-Path $RepoRoot '.codex-local'
New-Item -ItemType Directory -Force -Path $CodexHome | Out-Null

$template = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'templates/codex-local.config.toml') -Raw
$trustKey = $RepoRoot.Replace("'", "''")
$config = $template.TrimEnd() + "`n`n[projects.'$trustKey']`ntrust_level = `"trusted`"`n"
[IO.File]::WriteAllText((Join-Path $CodexHome 'config.toml'), $config, (New-Object Text.UTF8Encoding $false))

if (-not $env:STRATA_API_KEY) { $env:STRATA_API_KEY = 'strata-local' }
$env:CODEX_HOME = $CodexHome

$codex = Get-Command codex.cmd, codex -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
if (-not $codex -and $env:APPDATA -and (Test-Path (Join-Path $env:APPDATA 'npm\codex.cmd'))) { $codex = Join-Path $env:APPDATA 'npm\codex.cmd' }
if (-not $codex) { throw 'Codex CLI not found. Install: npm.cmd install -g @openai/codex' }

Push-Location $RepoRoot
$ErrorActionPreference = 'Continue'   # Codex reports progress on stderr
try {
    if ($PromptFile) { Invoke-WithPromptFile $codex $CodexArgs $PromptFile }
    else { & $codex @CodexArgs }
    exit $LASTEXITCODE
} finally { Pop-Location }

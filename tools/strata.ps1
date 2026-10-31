<#
.SYNOPSIS
  Run the Strata local model server (https://github.com/Niko1221/Strata) with this project's settings.

.DESCRIPTION
  The Strata Terminal is located per machine (PATH, then its default install folders), and the model
  settings come from .strata/launch.json, so every machine starts the same model.

.EXAMPLE
  ./tools/strata.ps1 install    # print the official install command (Strata is not installed by this script)
  ./tools/strata.ps1 version    # installed Strata Terminal version
  ./tools/strata.ps1 plan       # show downloads / memory for .strata/launch.json; changes nothing
  ./tools/strata.ps1 up         # download if needed and start in the background
  ./tools/strata.ps1 status     # running model and address
  ./tools/strata.ps1 health     # GET /health and /v1/models
  ./tools/strata.ps1 check      # `strata connect codex --check`: one prompt + one tool call the way Codex sends them
  ./tools/strata.ps1 stop
  ./tools/strata.ps1 <anything else>   # passed through to strata
#>
param(
    [Parameter(Position = 0)][string]$Command = 'status',
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$OnWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows
$Launch = Get-Content -LiteralPath (Join-Path $RepoRoot '.strata/launch.json') -Raw | ConvertFrom-Json

function Find-Strata {
    if ($env:STRATA_EXE -and (Test-Path -LiteralPath $env:STRATA_EXE)) { return $env:STRATA_EXE }
    foreach ($name in @('strata.cmd', 'strata')) {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    }
    $candidates = if ($OnWindows) {
        @((Join-Path $env:LOCALAPPDATA 'Strata\terminal\current\bin\strata.cmd'))
    } else {
        @((Join-Path $HOME '.local/bin/strata'))
    }
    if ($env:STRATA_DATA_DIR) { $candidates = @((Join-Path $env:STRATA_DATA_DIR 'terminal/current/bin/strata.cmd')) + $candidates }
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    return $null
}

$installHelp = if ($OnWindows) {
    'irm https://github.com/Niko1221/Strata/releases/latest/download/install.ps1 | iex'
} else {
    'curl -fsSL https://github.com/Niko1221/Strata/releases/latest/download/install.sh -o install.sh && sh install.sh'
}
if ($Command -eq 'install') { Write-Output $installHelp; exit 0 }

$Strata = Find-Strata
if (-not $Strata) { throw "Strata Terminal not found. Install it (official installer):`n  $installHelp`nor set STRATA_EXE to strata(.cmd)." }

$modelArgs = @('--family', $Launch.family, '--model', $Launch.model, '--context', $Launch.context,
    '--vision', $Launch.vision, '--access', $Launch.access, '--port', [string]$Launch.port)
$base = "http://127.0.0.1:$($Launch.port)"

switch ($Command) {
    'version' { & $Strata --version }
    'plan' { & $Strata launch --plan @modelArgs @Rest }
    'up' { & $Strata launch @modelArgs --yes --no-tui @Rest }
    'status' { & $Strata launch --status @Rest }
    'stop' { & $Strata launch --stop @Rest }
    'check' { & $Strata connect codex --check @Rest }
    'health' {
        try {
            Invoke-RestMethod "$base/health" | ConvertTo-Json -Compress
            (Invoke-RestMethod "$base/v1/models").data | ForEach-Object { "model: $($_.id)" }
        } catch { Write-Error "Strata server not reachable at $base ($($_.Exception.Message)). Start it with: tools\strata.cmd up"; exit 1 }
    }
    default { & $Strata $Command @Rest }
}
exit $LASTEXITCODE

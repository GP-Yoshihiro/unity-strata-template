<#
.SYNOPSIS
  Operate the Strata local model server (https://github.com/Niko1221/Strata) from PowerShell,
  and let Codex / Claude Code delegate sub-tasks to it.

.DESCRIPTION
  The Strata Terminal is located per machine (STRATA_EXE, PATH, then its default install folders) and the
  model settings come from .strata/launch.json, so every machine and every teammate starts the same model.
  No web UI is needed: everything below runs in PowerShell (or cmd via tools\strata.cmd).

.EXAMPLE
  tools\strata.cmd install     # print the official install command (this script never installs Strata)
  tools\strata.cmd version     # installed Strata Terminal version
  tools\strata.cmd plan        # downloads / memory for .strata/launch.json; changes nothing
  tools\strata.cmd up          # download if needed and start in the background
  tools\strata.cmd status      # running model and address
  tools\strata.cmd health      # GET /health and /v1/models
  tools\strata.cmd monitor     # live terminal monitor (speed, VRAM, requests); q to quit
  tools\strata.cmd logs        # engine log (add --follow to tail)
  tools\strata.cmd check       # one prompt + one tool call the way Codex sends them
  tools\strata.cmd stop        # unload the model and free memory
  tools\strata.cmd ask "Summarise these errors" -File Logs\UnityTest-EditMode.log
  Get-Content diff.txt | tools\strata.ps1 ask "Review this diff for Unity pitfalls"
  tools\strata.cmd <anything else>   # passed through to strata
#>
param(
    [Parameter(Position = 0)][string]$Command = 'status',
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest,
    [Parameter(ValueFromPipeline = $true)][string]$InputLine
)
begin {
    $piped = New-Object System.Collections.Generic.List[string]
}
process {
    if ($null -ne $InputLine) { $piped.Add($InputLine) }
}
end {
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$OnWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows
$Launch = Get-Content -LiteralPath (Join-Path $RepoRoot '.strata/launch.json') -Raw | ConvertFrom-Json
$base = "http://127.0.0.1:$($Launch.port)"

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

# Sends one chat request to the local model. Used by Codex / Claude Code to delegate cheap, bulky work
# (log triage, summaries, first drafts) without spending cloud tokens. Prompt = args + -File contents + pipeline.
function Invoke-StrataAsk([string[]]$AskArgs, [string[]]$PipedLines) {
    $files = @(); $words = @(); $maxTokens = 2048; $system = 'You are a precise assistant for a Unity C# project. Answer concisely. Output code as git-style diffs when changing code.'
    for ($i = 0; $i -lt $AskArgs.Count; $i++) {
        switch -Regex ($AskArgs[$i]) {
            '^-File$' { $files += $AskArgs[++$i]; continue }
            '^-MaxTokens$' { $maxTokens = [int]$AskArgs[++$i]; continue }
            '^-System$' { $system = $AskArgs[++$i]; continue }
            default { $words += $AskArgs[$i] }
        }
    }
    $prompt = ($words -join ' ').Trim()
    foreach ($f in $files) {
        $p = if ([IO.Path]::IsPathRooted($f)) { $f } else { Join-Path (Get-Location) $f }
        $prompt += "`n`n--- $f ---`n" + [IO.File]::ReadAllText($p)
    }
    if ($PipedLines.Count -gt 0) { $prompt += "`n`n--- stdin ---`n" + ($PipedLines -join "`n") }
    if (-not $prompt) { throw 'Usage: tools\strata.cmd ask "question" [-File path]... [-MaxTokens n]' }

    $model = (Invoke-RestMethod "$base/v1/models" -TimeoutSec 10).data[0].id
    $body = @{ model = $model; max_tokens = $maxTokens; messages = @(@{ role = 'system'; content = $system }, @{ role = 'user'; content = $prompt }) } | ConvertTo-Json -Depth 5
    $headers = @{}
    if ($env:STRATA_API_KEY -and $env:STRATA_API_KEY -ne 'strata-local') { $headers['Authorization'] = "Bearer $env:STRATA_API_KEY" }
    $resp = Invoke-WebRequest -UseBasicParsing -Method Post -Uri "$base/v1/chat/completions" -Headers $headers `
        -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 1800
    # Decode explicitly: Windows PowerShell 5.1 guesses the wrong charset for UTF-8 JSON
    $json = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray()) | ConvertFrom-Json
    $answer = $json.choices[0].message.content

    # Recorded under the calling agent run (tools\agent.cmd sets AGENT_RUN_FILE), so delegated work is visible in History/.
    if ($env:AGENT_RUN_FILE -and $env:AGENT_NAME -ne 'strata') {
        . (Join-Path $PSScriptRoot 'lib/team.ps1')
        $label = (($words -join ' ') -split "`r?`n")[0]
        if ($label.Length -gt 80) { $label = $label.Substring(0, 80) + '...' }
        Add-RunSection $env:AGENT_RUN_FILE "Delegated to Strata ($model): $label" $answer 2000
    }
    return $answer
}

$installHelp = if ($OnWindows) {
    'irm https://github.com/Niko1221/Strata/releases/latest/download/install.ps1 | iex'
} else {
    'curl -fsSL https://github.com/Niko1221/Strata/releases/latest/download/install.sh -o install.sh && sh install.sh'
}
if ($Command -eq 'install') { Write-Output $installHelp; exit 0 }
if ($Command -eq 'ask') {
    try { Invoke-StrataAsk @($Rest) $piped.ToArray(); exit 0 }
    catch { [Console]::Error.WriteLine("strata ask failed: $($_.Exception.Message). Is the server up? tools\strata.cmd health"); exit 1 }
}

$Strata = Find-Strata
if (-not $Strata) { throw "Strata Terminal not found. Install it (official installer):`n  $installHelp`nor set STRATA_EXE to strata(.cmd)." }

$modelArgs = @('--family', $Launch.family, '--model', $Launch.model, '--context', $Launch.context,
    '--vision', $Launch.vision, '--access', $Launch.access, '--port', [string]$Launch.port)

switch ($Command) {
    'version' { & $Strata --version }
    'where' { Write-Output $Strata }
    'plan' { & $Strata launch --plan @modelArgs @Rest }
    'up' { & $Strata launch @modelArgs --yes --no-tui @Rest }
    'status' { & $Strata launch --status @Rest }
    'stop' { & $Strata launch --stop @Rest }
    'monitor' { & $Strata monitor --url $base @Rest }
    'check' { & $Strata connect codex --check @Rest }
    'health' {
        try {
            Invoke-RestMethod "$base/health" -TimeoutSec 10 | ConvertTo-Json -Compress
            (Invoke-RestMethod "$base/v1/models" -TimeoutSec 10).data | ForEach-Object { "model: $($_.id)" }
        } catch { [Console]::Error.WriteLine("Strata server not reachable at $base ($($_.Exception.Message)). Start it with: tools\strata.cmd up"); exit 1 }
    }
    default { & $Strata $Command @Rest }
}
exit $LASTEXITCODE
}

<#
.SYNOPSIS
  Run Unity for this project in batch mode, with the editor located by find-unity.ps1.

.EXAMPLE
  ./tools/unity.ps1 path                         # print resolved editor
  ./tools/unity.ps1 test                         # EditMode tests (default)
  ./tools/unity.ps1 test PlayMode
  ./tools/unity.ps1 test All
  ./tools/unity.ps1 refresh                      # import assets / generate .meta files
  ./tools/unity.ps1 exec Game.Editor.BatchEntry.MoveAsset -from Assets/A.cs -to Assets/B/A.cs
  ./tools/unity.ps1 open                         # open the project in the Editor GUI

  Exit codes: 0 ok, 2 tests failed, other = Unity/setup error. Logs go to Logs/.
#>
param(
    [Parameter(Position = 0)][ValidateSet('path', 'test', 'refresh', 'exec', 'open')][string]$Command = 'test',
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$LogDir = Join-Path $RepoRoot 'Logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$Unity = & (Join-Path $PSScriptRoot 'find-unity.ps1')
if (-not $Unity) { exit 1 }
if ($Command -eq 'path') { Write-Output $Unity; exit 0 }

$OnWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows
if ($OnWindows -and $RepoRoot.Length -gt 120) {
    Write-Warning "Project path is $($RepoRoot.Length) chars long. Unity may silently fail on Windows with deep paths -- clone to a short path such as C:\dev\<name>."
}
if (Test-Path -LiteralPath (Join-Path $RepoRoot 'Temp/UnityLockfile')) {
    Write-Warning 'Temp/UnityLockfile exists: the project may already be open in an Editor. Batch mode will fail if it is.'
}

function Quote([string]$a) { if ($a -match '[\s"]') { '"' + ($a -replace '"', '\"') + '"' } else { $a } }

function Invoke-Unity([string[]]$UnityArgs, [switch]$NoWait) {
    $all = @('-projectPath', $RepoRoot) + $UnityArgs
    Write-Host "> $Unity $($all -join ' ')"
    # Start-Process is required: Unity is a GUI-subsystem exe, so '&' would not wait for it on Windows.
    $p = Start-Process -FilePath $Unity -ArgumentList (($all | ForEach-Object { Quote $_ }) -join ' ') -PassThru -NoNewWindow -Wait:(-not $NoWait)
    if ($NoWait) { return 0 }
    return $p.ExitCode
}

function Show-TestSummary([string]$xml) {
    if (-not (Test-Path -LiteralPath $xml)) { Write-Warning "No result file: $xml"; return }
    $run = ([xml](Get-Content -LiteralPath $xml -Raw)).'test-run'
    Write-Host ("[{0}] total={1} passed={2} failed={3} skipped={4}" -f $run.result, $run.total, $run.passed, $run.failed, $run.skipped)
    foreach ($tc in $run.SelectNodes("//test-case[@result='Failed']")) {
        Write-Host "  FAILED $($tc.fullname)" -ForegroundColor Red
        if ($tc.failure.message) { Write-Host "    $($tc.failure.message.'#cdata-section'.Trim())" }
    }
}

switch ($Command) {
    'test' {
        $requested = if ($Rest) { $Rest[0] } else { 'EditMode' }
        $platforms = if ($requested -eq 'All') { @('EditMode', 'PlayMode') } else { @($requested) }
        $worst = 0
        foreach ($pl in $platforms) {
            $xml = Join-Path $LogDir ("{0}-results.xml" -f $pl.ToLower())
            $log = Join-Path $LogDir "UnityTest-$pl.log"
            Remove-Item -LiteralPath $xml -ErrorAction SilentlyContinue
            $code = Invoke-Unity @('-batchmode', '-nographics', '-runTests', '-testPlatform', $pl, '-testResults', $xml, '-logFile', $log)
            Show-TestSummary $xml
            Write-Host "$pl exit code $code (log: Logs/UnityTest-$pl.log)"
            if ($code -gt $worst) { $worst = $code }
        }
        exit $worst
    }
    'refresh' {
        exit (Invoke-Unity @('-batchmode', '-nographics', '-quit', '-executeMethod', 'Game.Editor.BatchEntry.Refresh', '-logFile', (Join-Path $LogDir 'UnityRefresh.log')))
    }
    'exec' {
        if (-not $Rest) { throw 'Usage: unity.ps1 exec <Namespace.Class.Method> [args...]' }
        $method = $Rest[0]
        $extra = @($Rest | Select-Object -Skip 1)
        exit (Invoke-Unity (@('-batchmode', '-nographics', '-quit', '-executeMethod', $method, '-logFile', (Join-Path $LogDir 'UnityExec.log')) + $extra))
    }
    'open' {
        Invoke-Unity @() -NoWait | Out-Null
    }
}

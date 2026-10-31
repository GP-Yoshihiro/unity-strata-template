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
  ./tools/unity.ps1 install                      # install ProjectVersion.txt's editor with the Unity Hub CLI
  ./tools/unity.ps1 install 6000.6.7f1 --module windows-il2cpp   # extra args go to the Hub CLI
  ./tools/unity.ps1 upgrade 6000.7.1f1           # install + open the project once with that editor (on a task branch!)
  ./tools/unity.ps1 packages add com.unity.inputsystem,com.unity.cinemachine   # Unity picks the right versions

  Exit codes: 0 ok, 2 tests failed, 124 timed out, other = Unity/setup error. Logs go to Logs/.
  UNITY_TIMEOUT_MINUTES (default 60, 0 = no limit) stops a hung batch run so unattended loops keep going.
#>
param(
    [Parameter(Position = 0)][ValidateSet('path', 'test', 'refresh', 'exec', 'open', 'install', 'upgrade', 'packages')][string]$Command = 'test',
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'lib/team.ps1')   # Stop-ProcessTree
$LogDir = Join-Path $RepoRoot 'Logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$FindUnity = Join-Path $PSScriptRoot 'find-unity.ps1'
$OnWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows
$TimeoutMinutes = if ($env:UNITY_TIMEOUT_MINUTES) { [int]$env:UNITY_TIMEOUT_MINUTES } else { 60 }

function Quote([string]$a) { if ($a -match '[\s"]') { '"' + ($a -replace '"', '\"') + '"' } else { $a } }

function Start-Waited([string]$Exe, [string[]]$ArgList, [int]$Minutes) {
    # Start-Process -Wait would also wait for every child process (Unity leaves Unity.Licensing.Client and
    # shader compilers running for a while), which can hang a batch run. Wait for Unity itself instead.
    $p = Start-Process -FilePath $Exe -ArgumentList (($ArgList | ForEach-Object { Quote $_ }) -join ' ') -PassThru -NoNewWindow
    $null = $p.Handle   # keeps ExitCode readable after the process ends
    if ($Minutes -gt 0) {
        if (-not $p.WaitForExit($Minutes * 60 * 1000)) {
            Write-Warning "$(Split-Path -Leaf $Exe) did not finish in $Minutes min (UNITY_TIMEOUT_MINUTES); stopping it."
            Stop-ProcessTree $p
            return 124
        }
    } else { $p.WaitForExit() }
    return $p.ExitCode
}

function Get-ProjectVersionInfo {
    $text = Get-Content -LiteralPath (Join-Path $RepoRoot 'ProjectSettings/ProjectVersion.txt') -Raw
    $m = [regex]::Match($text, 'm_EditorVersionWithRevision:\s*(\S+)\s*\(([0-9a-f]+)\)')
    if ($m.Success) { return [pscustomobject]@{ Version = $m.Groups[1].Value; Changeset = $m.Groups[2].Value } }
    return [pscustomobject]@{ Version = [regex]::Match($text, 'm_EditorVersion:\s*(\S+)').Groups[1].Value; Changeset = $null }
}

function Install-Editor([string]$Ver, [string]$Changeset, [string[]]$Extra) {
    # Unity Hub CLI: https://docs.unity3d.com/hub/manual/HubCLI.html  (Windows/macOS need the extra "--")
    $existing = $null
    try { $existing = & $FindUnity -Version $Ver -Strict 3>$null } catch { }
    if ($existing) { Write-Host "Unity $Ver is already installed: $existing"; return 0 }
    $hub = & $FindUnity -Hub
    $hubArgs = @()
    if ($OnWindows -or $IsMacOS) { $hubArgs += '--' }
    $hubArgs += @('--headless', 'install', '--version', $Ver)
    if ($Changeset) { $hubArgs += @('--changeset', $Changeset) }
    $hubArgs += @($Extra | Where-Object { $_ })
    Write-Host "> $hub $($hubArgs -join ' ')"
    Write-Host 'Downloading and installing the editor (several GB; this can take a while)...'
    $code = Start-Waited $hub $hubArgs 0
    try { $path = & $FindUnity -Version $Ver -Strict 3>$null } catch { $path = $null }
    if (-not $path) { Write-Warning "Unity Hub exit code $code, and Unity $Ver is still not found. Install it from the Hub GUI or https://unity.com/releases/editor/archive"; return 1 }
    Write-Host "Installed: $path"
    Write-Host 'Batch mode needs an activated licence on this machine: sign in to Unity Hub once (Personal) or activate a serial.'
    return 0
}

switch ($Command) {
    'install' {
        $info = Get-ProjectVersionInfo
        $ver = if ($Rest -and $Rest[0] -notlike '-*') { $Rest[0] } else { $info.Version }
        $extra = @($Rest | Where-Object { $_ -ne $ver })
        # The project's changeset only when the caller did not pass --changeset (Hub rejects it twice)
        $changeset = if ($ver -eq $info.Version -and $extra -notcontains '--changeset') { $info.Changeset } else { $null }
        exit (Install-Editor $ver $changeset $extra)
    }
    'upgrade' {
        if (-not $Rest) { throw 'Usage: unity.ps1 upgrade <version>   (e.g. 6000.6.8f1; run it on a claimed task branch whose paths include ProjectSettings/ and Packages/)' }
        $ver = $Rest[0]
        $from = (Get-ProjectVersionInfo).Version
        if ((Install-Editor $ver $null @($Rest | Select-Object -Skip 1)) -ne 0) { exit 1 }
        $editor = & $FindUnity -Version $ver -Strict
        Write-Host "Opening the project once with $ver (was $from) so Unity upgrades ProjectSettings/ and Packages/ ..."
        $log = Join-Path $LogDir 'UnityUpgrade.log'
        $code = Start-Waited $editor @('-projectPath', $RepoRoot, '-batchmode', '-nographics', '-quit', '-logFile', $log) $TimeoutMinutes
        $now = (Get-ProjectVersionInfo).Version
        Write-Host "Exit code $code; ProjectVersion.txt now says $now (log: Logs/UnityUpgrade.log)"
        if ($code -ne 0 -or $now -ne $ver) { exit 1 }
        Write-Host 'Next: tools\unity.cmd test All, review `git diff ProjectSettings Packages`, then commit and open a PR. Teammates run tools\unity.cmd install after it merges.'
        exit 0
    }
}

$Unity = & $FindUnity
if (-not $Unity) { exit 1 }
if ($Command -eq 'path') { Write-Output $Unity; exit 0 }

if ($OnWindows -and $RepoRoot.Length -gt 120) {
    Write-Warning "Project path is $($RepoRoot.Length) chars long. Unity may silently fail on Windows with deep paths -- clone to a short path such as C:\dev\<name>."
}
if (Test-Path -LiteralPath (Join-Path $RepoRoot 'Temp/UnityLockfile')) {
    Write-Warning 'Temp/UnityLockfile exists: the project may already be open in an Editor. Batch mode will fail if it is.'
}

function Invoke-Unity([string[]]$UnityArgs, [switch]$NoWait) {
    $all = @('-projectPath', $RepoRoot) + $UnityArgs
    Write-Host "> $Unity $($all -join ' ')"
    if ($NoWait) {
        # Unity is a GUI-subsystem exe on Windows, so Start-Process (not '&') is used either way.
        Start-Process -FilePath $Unity -ArgumentList (($all | ForEach-Object { Quote $_ }) -join ' ') | Out-Null
        return 0
    }
    return (Start-Waited $Unity $all $TimeoutMinutes)
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
            # No result file means Unity never ran the tests (licence, compile or start-up problem): not a pass
            if ($code -eq 0 -and -not (Test-Path -LiteralPath $xml)) { $code = 1 }
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
    'packages' {
        if (-not $Rest -or $Rest[0] -ne 'add' -or $Rest.Count -lt 2) { throw 'Usage: unity.ps1 packages add <id>[,<id>...]' }
        $ids = (@($Rest | Select-Object -Skip 1) -join ',') -replace '\s', ''
        # No -quit: the Package Manager request is asynchronous; BatchEntry.AddPackages exits when it completes
        exit (Invoke-Unity @('-batchmode', '-nographics', '-executeMethod', 'Game.Editor.BatchEntry.AddPackages', '-packages', $ids, '-logFile', (Join-Path $LogDir 'UnityPackages.log')))
    }
}

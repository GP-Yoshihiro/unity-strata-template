<#
.SYNOPSIS
  Resolve the Unity Editor executable for this project on the current machine.
  Works on Windows PowerShell 5.1 and PowerShell 7 (Windows / macOS / Linux).

.DESCRIPTION
  Resolution order (first hit wins):
    1. -UnityPath argument
    2. $env:UNITY_EDITOR_PATH
    3. .unity-path.local in the repo root (gitignored, one line; relative paths resolve from the repo root)
    4. Installed editors matching ProjectSettings/ProjectVersion.txt exactly, searched in:
         - $env:UNITY_EDITORS_DIR (extra roots, separated by ';' on Windows or ':' elsewhere)
         - <repo>/../UnityEditors, <repo>/.unity-editors          (portable, repo-relative)
         - Unity Hub default install dir and Hub "secondaryInstallPath"
         - Editors registered manually in Unity Hub (editors*.json)
    5. A NEWER patch of the same major.minor (warning) -- disabled by -Strict. Older editors and other
       major/minor versions are never picked silently: opening the project with them would downgrade or
       upgrade it for the whole team. Use `tools/unity.* install` or `tools/unity.* upgrade <version>`.
    6. 'Unity' / 'Unity.exe' on PATH

  -Version <v> looks for that version instead of ProjectVersion.txt (used by `unity.ps1 upgrade`).
  -Hub prints the Unity Hub executable (UNITY_HUB_PATH, default install folders, PATH) for CLI installs.

.EXAMPLE
  ./tools/find-unity.ps1            # prints the editor path
  ./tools/find-unity.ps1 -List      # lists every editor found
  ./tools/find-unity.ps1 -Hub       # Unity Hub executable (for headless installs)
#>
[CmdletBinding()]
param(
    [string]$UnityPath,
    [string]$Version,
    [switch]$Strict,
    [switch]$List,
    [switch]$Hub
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot

$OnWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows
$OnMac = (-not $OnWindows) -and $IsMacOS

# Inside an agent sandbox (e.g. Codex on Windows) reading the user's profile can fail with
# "Access is denied"; treat that location as absent instead of aborting the whole search.
function Test-PathSafe([string]$LiteralPath, [string]$PathType = 'Any') {
    try { return [bool](Test-Path -LiteralPath $LiteralPath -PathType $PathType -ErrorAction Stop) } catch { return $false }
}

function Resolve-FromRepo([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return $null }
    $p = [Environment]::ExpandEnvironmentVariables($p.Trim().Trim('"'))
    if ($p.StartsWith('~')) { $p = Join-Path $HOME $p.Substring(1).TrimStart('/', '\') }
    if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path $RepoRoot $p }
    # A path to the editor folder / .app is accepted too
    if (Test-PathSafe -LiteralPath $p -PathType Container) {
        foreach ($rel in (Get-ExeRelPaths)) {
            $c = Join-Path $p $rel
            if (Test-PathSafe -LiteralPath $c -PathType Leaf) { return (Resolve-Path -LiteralPath $c).Path }
        }
        return $null
    }
    if (Test-PathSafe -LiteralPath $p -PathType Leaf) { return (Resolve-Path -LiteralPath $p).Path }
    return $null
}

# Executable location relative to a "<root>/<version>/" directory (also tried relative to the folder itself)
function Get-ExeRelPaths {
    if ($OnWindows) { return @('Editor\Unity.exe', 'Unity.exe') }
    if ($OnMac) { return @('Unity.app/Contents/MacOS/Unity', 'Contents/MacOS/Unity') }
    return @('Editor/Unity', 'Unity')
}

function Get-ProjectVersion {
    if ($Version) { return $Version }
    $f = Join-Path $RepoRoot 'ProjectSettings/ProjectVersion.txt'
    if (-not (Test-PathSafe -LiteralPath $f)) { return $null }
    $m = Select-String -LiteralPath $f -Pattern '^m_EditorVersion:\s*(\S+)' | Select-Object -First 1
    if ($m) { return $m.Matches[0].Groups[1].Value }
    return $null
}

# Sortable key for versions like 6000.2.11f1
function Get-VersionKey([string]$v) {
    $m = [regex]::Match($v, '^(\d+)\.(\d+)\.(\d+)([a-z]+)?(\d+)?')
    if (-not $m.Success) { return '0' }
    $build = if ($m.Groups[5].Success) { [int]$m.Groups[5].Value } else { 0 }
    return '{0:D6}.{1:D4}.{2:D4}{3}{4:D4}' -f [int]$m.Groups[1].Value, [int]$m.Groups[2].Value, [int]$m.Groups[3].Value, $m.Groups[4].Value, $build
}

function Get-HubConfigDir {
    if ($OnWindows) { return Join-Path $env:APPDATA 'UnityHub' }
    if ($OnMac) { return Join-Path $HOME 'Library/Application Support/UnityHub' }
    return Join-Path $HOME '.config/UnityHub'
}

function Get-EditorRoots {
    $roots = New-Object System.Collections.Generic.List[string]
    $sep = if ($OnWindows) { ';' } else { ':' }
    if ($env:UNITY_EDITORS_DIR) { $env:UNITY_EDITORS_DIR.Split($sep) | Where-Object { $_ } | ForEach-Object { $roots.Add($_) } }
    $roots.Add((Join-Path (Split-Path -Parent $RepoRoot) 'UnityEditors'))
    $roots.Add((Join-Path $RepoRoot '.unity-editors'))
    if ($OnWindows) {
        foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432) | Where-Object { $_ } | Select-Object -Unique) {
            $roots.Add((Join-Path $pf 'Unity\Hub\Editor'))
        }
    } elseif ($OnMac) {
        $roots.Add('/Applications/Unity/Hub/Editor')
    } else {
        $roots.Add((Join-Path $HOME 'Unity/Hub/Editor'))
    }
    $secondary = Join-Path (Get-HubConfigDir) 'secondaryInstallPath.json'
    if (Test-PathSafe -LiteralPath $secondary) {
        try {
            $s = Get-Content -LiteralPath $secondary -Raw | ConvertFrom-Json
            if ($s -is [string] -and $s.Trim()) { $roots.Add($s.Trim()) }
        } catch { Write-Verbose "secondaryInstallPath.json unreadable: $_" }
    }
    return $roots | Select-Object -Unique
}

function Get-InstalledEditors {
    $found = @{}
    foreach ($root in (Get-EditorRoots)) {
        if (-not (Test-PathSafe -LiteralPath $root -PathType Container)) { continue }
        foreach ($dir in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            foreach ($rel in (Get-ExeRelPaths)) {
                $exe = Join-Path $dir.FullName $rel
                if (Test-PathSafe -LiteralPath $exe -PathType Leaf) { $found[$exe] = $dir.Name; break }
            }
        }
    }
    # Editors added via Hub's "Locate" button
    $hubDir = Get-HubConfigDir
    foreach ($json in @('editors-v2.json', 'editors.json')) {
        $f = Join-Path $hubDir $json
        if (-not (Test-PathSafe -LiteralPath $f)) { continue }
        try { $text = Get-Content -LiteralPath $f -Raw -ErrorAction Stop } catch { continue }
        $pattern = if ($OnWindows) { '"([^"]+?Unity\.exe)"' } else { '"([^"]+?/Unity)"' }
        foreach ($m in [regex]::Matches($text, $pattern)) {
            $exe = $m.Groups[1].Value -replace '\\\\', '\'
            if (-not (Test-PathSafe -LiteralPath $exe -PathType Leaf)) { continue }
            $ver = [regex]::Match($exe, '\d+\.\d+\.\d+[a-z]+\d+').Value
            if ($ver) { $found[$exe] = $ver }
        }
    }
    return $found.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Version = $_.Value; Path = $_.Key; Key = (Get-VersionKey $_.Value) } } |
        Sort-Object Key -Descending
}

function Find-UnityHub {
    if ($env:UNITY_HUB_PATH -and (Test-PathSafe -LiteralPath $env:UNITY_HUB_PATH -PathType Leaf)) { return $env:UNITY_HUB_PATH }
    $candidates = if ($OnWindows) {
        @((Join-Path "$env:ProgramFiles" 'Unity Hub\Unity Hub.exe'), (Join-Path "$env:LOCALAPPDATA" 'Programs\Unity Hub\Unity Hub.exe'))
    } elseif ($OnMac) {
        @('/Applications/Unity Hub.app/Contents/MacOS/Unity Hub', (Join-Path $HOME 'Applications/Unity Hub.app/Contents/MacOS/Unity Hub'))
    } else {
        @('/usr/bin/unityhub', '/opt/unityhub/unityhub', (Join-Path $HOME 'Applications/Unity Hub.AppImage'), (Join-Path $HOME 'Applications/UnityHub.AppImage'))
    }
    foreach ($c in $candidates) { if (Test-PathSafe -LiteralPath $c -PathType Leaf) { return $c } }
    $cmd = Get-Command 'unityhub', 'Unity Hub' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    throw 'Unity Hub not found. Install it from https://unity.com/download (or set UNITY_HUB_PATH).'
}

if ($Hub) { Write-Output (Find-UnityHub); return }

if ($List) {
    Write-Host "Project version: $(Get-ProjectVersion)"
    Get-InstalledEditors | Format-Table Version, Path -AutoSize | Out-String | Write-Host
    return
}

# 1-3: explicit locations
foreach ($candidate in @(
        @{ Src = '-UnityPath'; Val = $UnityPath },
        @{ Src = 'UNITY_EDITOR_PATH'; Val = $env:UNITY_EDITOR_PATH },
        @{ Src = '.unity-path.local'; Val = $(if (Test-PathSafe -LiteralPath (Join-Path $RepoRoot '.unity-path.local')) { (Get-Content -LiteralPath (Join-Path $RepoRoot '.unity-path.local') | Where-Object { $_ -and -not $_.StartsWith('#') } | Select-Object -First 1) }) })) {
    if (-not $candidate.Val) { continue }
    if ($Version -and $candidate.Src -ne '-UnityPath') { continue }   # an explicit -Version must not be overridden by the usual editor
    $r = Resolve-FromRepo $candidate.Val
    if ($r) { Write-Verbose "Unity from $($candidate.Src)"; Write-Output $r; return }
    Write-Warning "$($candidate.Src) is set but no Unity executable was found at '$($candidate.Val)'"
}

# 4-5: installed editors
$want = Get-ProjectVersion
$editors = @(Get-InstalledEditors)
if ($want) {
    $exact = $editors | Where-Object { $_.Version -eq $want } | Select-Object -First 1
    if ($exact) { Write-Output $exact.Path; return }
}
if (-not $Strict -and $editors.Count -gt 0) {
    $pick = $null
    if ($want) {
        # Only a newer patch of the same major.minor: anything else would silently up/downgrade the project
        $mm = ($want -split '\.')[0..1] -join '.'
        $wantKey = Get-VersionKey $want
        $pick = $editors | Where-Object { $_.Version.StartsWith("$mm.") -and $_.Key -gt $wantKey } | Select-Object -Last 1
    } else {
        $pick = $editors | Select-Object -First 1
    }
    if ($pick) {
        Write-Warning "Unity $want not installed; using $($pick.Version) (same major.minor). Install $want (tools\unity.cmd install) to stay on the team's version."
        Write-Output $pick.Path
        return
    }
    $have = ($editors | ForEach-Object { $_.Version }) -join ', '
    throw "Unity $want is not installed (found: $have). Install it: tools\unity.cmd install   -- or move the project to another version on purpose: tools\unity.cmd upgrade <version>"
}

# 6: PATH (not for an explicit -Version: the editor on PATH may be any version)
foreach ($name in $(if ($Version) { @() } else { @('Unity', 'Unity.exe') })) {
    $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { Write-Output $cmd.Source; return }
}

throw "Unity Editor $want not found. Install it with Unity Hub, or set UNITY_EDITOR_PATH / create .unity-path.local (see README)."

<#
.SYNOPSIS
  Per-machine setup after cloning. Safe to re-run.
  - checks git / git-lfs, enables LFS hooks for this repo
  - locates the Unity Editor and registers UnityYAMLMerge as a merge driver (repo-local git config)
  - syncs the shared agent skill (.agents/skills -> .claude/skills)
  - rebuilds the Strata index
#>
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $RepoRoot
try {
    Write-Host '== git'
    git --version
    git lfs version
    if ($LASTEXITCODE -ne 0) { throw 'git-lfs is not installed: https://git-lfs.com' }
    git lfs install --local | Out-Null
    git lfs pull

    Write-Host '== Unity'
    & (Join-Path $PSScriptRoot 'find-unity.ps1') -List
    $unity = & (Join-Path $PSScriptRoot 'find-unity.ps1')
    Write-Host "Using: $unity"

    $editorDir = Split-Path -Parent $unity
    $yamlMerge = @(
        (Join-Path $editorDir 'Data/Tools/UnityYAMLMerge.exe'),
        (Join-Path $editorDir 'Data/Tools/UnityYAMLMerge'),
        (Join-Path $editorDir '../Resources/Tools/UnityYAMLMerge')
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($yamlMerge) {
        $yamlMerge = (Resolve-Path -LiteralPath $yamlMerge).Path.Replace('\', '/')
        git config --local merge.unityyamlmerge.name 'Unity SmartMerge'
        git config --local merge.unityyamlmerge.driver "'$yamlMerge' merge -p %O %B %A %A"
        git config --local merge.unityyamlmerge.recursive binary
        Write-Host "UnityYAMLMerge registered: $yamlMerge"
    } else {
        Write-Warning 'UnityYAMLMerge not found; scene/prefab conflicts will use the default text merge.'
    }

    Write-Host '== agent skills'
    $src = Join-Path $RepoRoot '.agents/skills'
    $dst = Join-Path $RepoRoot '.claude/skills'
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force
    Write-Host "Synced $src -> $dst"

    Write-Host '== strata'
    & (Join-Path $PSScriptRoot 'strata-index.ps1')

    Write-Host "`nSetup complete. Try: tools\unity.cmd test EditMode"
} finally { Pop-Location }

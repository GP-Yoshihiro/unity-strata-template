<#
.SYNOPSIS
  Build or verify .strata/strata_index.json (the codebase context map).

.DESCRIPTION
  If `strata-cli` is on PATH it is used (`strata-cli index` / `strata-cli verify`).
  Otherwise a built-in indexer produces a compatible map: one entry per file with its
  cache layer (from .strata/cache_config.json), content hash, assembly, namespace and
  declared types. Each type gets a stable reference id "cs:<Namespace>.<Type>" that tasks
  and prompts can cite instead of pasting code.

.EXAMPLE
  ./tools/strata-index.ps1            # rebuild the index
  ./tools/strata-index.ps1 -Verify    # exit 1 if the index is stale (use before commit / in CI)
  ./tools/strata-index.ps1 -Builtin   # force the built-in indexer even if strata-cli exists
#>
param([switch]$Verify, [switch]$Builtin)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Config = Get-Content -LiteralPath (Join-Path $RepoRoot '.strata/cache_config.json') -Raw | ConvertFrom-Json
$OutPath = Join-Path $RepoRoot $Config.index.out

$cli = Get-Command 'strata-cli' -ErrorAction SilentlyContinue
if ($cli -and -not $Builtin) {
    Push-Location $RepoRoot
    try {
        if ($Verify) { & $cli.Source verify; exit $LASTEXITCODE }
        foreach ($root in $Config.index.roots) {
            & $cli.Source index --path "$root/" --out $Config.index.out
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        }
        exit 0
    } finally { Pop-Location }
}

function ConvertTo-GlobRegex([string]$glob) {
    $sb = New-Object System.Text.StringBuilder '^'
    for ($i = 0; $i -lt $glob.Length; $i++) {
        $c = $glob[$i]
        if ($c -eq '*' -and $i + 1 -lt $glob.Length -and $glob[$i + 1] -eq '*') {
            if ($i + 2 -lt $glob.Length -and $glob[$i + 2] -eq '/') { [void]$sb.Append('(.*/)?'); $i += 2 }
            else { [void]$sb.Append('.*'); $i++ }
        } elseif ($c -eq '*') { [void]$sb.Append('[^/]*') }
        elseif ($c -eq '?') { [void]$sb.Append('[^/]') }
        else { [void]$sb.Append([regex]::Escape([string]$c)) }
    }
    return [regex]($sb.Append('$').ToString())
}

$layerRules = foreach ($layer in $Config.layers) {
    [pscustomobject]@{ Id = $layer.id; Patterns = @($layer.include | Where-Object { $_ -notlike 'git:*' } | ForEach-Object { ConvertTo-GlobRegex $_ }) }
}
function Get-Layer([string]$rel) {
    foreach ($l in $layerRules) { foreach ($p in $l.Patterns) { if ($p.IsMatch($rel)) { return $l.Id } } }
    return 'L3'
}

$sha = [Security.Cryptography.SHA256]::Create()
function Get-Hash([byte[]]$bytes) { ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').Substring(0, 16).ToLower() }

# Map each directory to the asmdef that owns it
$asmdefs = @{}
foreach ($root in $Config.index.roots) {
    $abs = Join-Path $RepoRoot $root
    if (-not (Test-Path -LiteralPath $abs)) { continue }
    Get-ChildItem -LiteralPath $abs -Recurse -Filter *.asmdef | ForEach-Object {
        $asmdefs[$_.DirectoryName] = (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).name
    }
}
function Get-Assembly([string]$dir) {
    while ($dir -and $dir.Length -ge $RepoRoot.Length) {
        if ($asmdefs.ContainsKey($dir)) { return $asmdefs[$dir] }
        $dir = Split-Path -Parent $dir
    }
    return 'Assembly-CSharp'
}

$typeRegex = [regex]'(?m)^\s*(?:\[[^\]]*\]\s*)*(?:(?:public|internal|private|protected|static|sealed|abstract|partial|readonly|ref|unsafe|new)\s+)*(class|struct|interface|enum|record)\s+([A-Za-z_][A-Za-z0-9_]*)'
$nsRegex = [regex]'(?m)^\s*namespace\s+([A-Za-z0-9_.]+)'

$files = New-Object System.Collections.Generic.List[object]
$symbols = New-Object System.Collections.Generic.List[object]
foreach ($root in $Config.index.roots) {
    $abs = Join-Path $RepoRoot $root
    if (-not (Test-Path -LiteralPath $abs)) { continue }
    $items = Get-ChildItem -LiteralPath $abs -Recurse -File | Where-Object { $Config.index.extensions -contains $_.Extension }
    foreach ($f in $items) {
        $rel = $f.FullName.Substring($RepoRoot.Length + 1).Replace('\', '/')
        $bytes = [IO.File]::ReadAllBytes($f.FullName)
        $text = [Text.Encoding]::UTF8.GetString($bytes)
        $entry = [ordered]@{
            path     = $rel
            layer    = Get-Layer $rel
            hash     = Get-Hash ([Text.Encoding]::UTF8.GetBytes($text.Replace("`r`n", "`n")))
            assembly = Get-Assembly $f.DirectoryName
        }
        if ($f.Extension -eq '.cs') {
            $ns = $nsRegex.Match($text)
            $entry.namespace = if ($ns.Success) { $ns.Groups[1].Value } else { '' }
            $types = @($typeRegex.Matches($text) | ForEach-Object { $_.Groups[2].Value } | Select-Object -Unique)
            $entry.types = $types
            foreach ($t in $types) {
                $full = if ($entry.namespace) { "$($entry.namespace).$t" } else { $t }
                $symbols.Add([ordered]@{ id = "cs:$full"; path = $rel; layer = $entry.layer })
            }
        }
        $files.Add($entry)
    }
}

$sortedFiles = @($files | Sort-Object { $_.path })
$sortedSymbols = @($symbols | Sort-Object { $_.id })
$index = [ordered]@{
    schema      = 'strata-index/builtin-1'
    generator   = 'tools/strata-index.ps1'
    contentHash = Get-Hash ([Text.Encoding]::UTF8.GetBytes((($sortedFiles | ForEach-Object { "$($_.path):$($_.hash)" }) -join "`n")))
}
# One entry per line: diff-friendly and identical between Windows PowerShell 5.1 and PowerShell 7
function Join-JsonLines($items) { (@($items | ForEach-Object { '    ' + ($_ | ConvertTo-Json -Compress -Depth 4) }) -join ",`n") }
$json = "{`n" +
    (@($index.Keys | ForEach-Object { '  "{0}": "{1}"' -f $_, $index[$_] }) -join ",`n") + ",`n" +
    "  `"files`": [`n$(Join-JsonLines $sortedFiles)`n  ],`n" +
    "  `"symbols`": [`n$(Join-JsonLines $sortedSymbols)`n  ]`n}`n"

if ($Verify) {
    if (-not (Test-Path -LiteralPath $OutPath)) { Write-Host 'strata index missing -- run tools/strata-index.ps1'; exit 1 }
    $current = (Get-Content -LiteralPath $OutPath -Raw | ConvertFrom-Json).contentHash
    if ($current -ne $index.contentHash) { Write-Host 'strata index is STALE -- run tools/strata-index.ps1'; exit 1 }
    Write-Host "strata index OK ($($sortedFiles.Count) files, $($sortedSymbols.Count) symbols)"
    exit 0
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutPath) | Out-Null
[IO.File]::WriteAllText($OutPath, $json, (New-Object Text.UTF8Encoding $false))
Write-Host "Wrote $($Config.index.out): $($sortedFiles.Count) files, $($sortedSymbols.Count) symbols"

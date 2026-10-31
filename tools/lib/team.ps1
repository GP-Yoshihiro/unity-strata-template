# Shared helpers for tools/task.ps1, tools/agent.ps1, tools/team.ps1 and tools/strata.ps1.
# Dot-source it:  . (Join-Path $PSScriptRoot 'lib/team.ps1')
# Windows PowerShell 5.1 compatible.

$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # tools/lib -> repo root
$script:Utf8 = New-Object Text.UTF8Encoding $false

function Invoke-Git {
    # Runs git in the repo root; returns output lines, throws on failure unless -AllowFail is among the args.
    # No param block on purpose: git flags such as -q / --format=... must reach git untouched.
    $AllowFail = $args -contains '-AllowFail'
    $GitArgs = @($args | Where-Object { $_ -ne '-AllowFail' })
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & git -C $script:RepoRoot @GitArgs 2>&1
    $ErrorActionPreference = $prev
    if ($LASTEXITCODE -ne 0 -and -not $AllowFail) { throw "git $($GitArgs -join ' ') failed:`n$($out | Out-String)" }
    return $out | ForEach-Object { "$_" }
}

function Get-GitUser {
    $name = (& git -C $script:RepoRoot config user.name) 2>$null
    $mail = (& git -C $script:RepoRoot config user.email) 2>$null
    if (-not $name) { throw 'git user.name is not set. Run: git config user.name "<your name>"' }
    return [pscustomobject]@{ Name = "$name"; Email = "$mail"; Slug = ("$name" -replace '[^A-Za-z0-9_-]', '').ToLower() }
}

function Get-CurrentBranch { (Invoke-Git rev-parse --abbrev-ref HEAD | Select-Object -First 1) }

function Get-TaskIdFromBranch([string]$branch) {
    $m = [regex]::Match($branch, '^task/(T-[0-9]{6}-[0-9a-f]{4})')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Write-TextFile([string]$path, [string]$text) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    [IO.File]::WriteAllText($path, $text.Replace("`r`n", "`n"), $script:Utf8)
}

function ConvertTo-PrettyJson($obj) {
    # Stable 2-space JSON regardless of PowerShell edition (5.1 indents oddly).
    $raw = $obj | ConvertTo-Json -Depth 10
    $lines = $raw -split "`r?`n"
    $sb = New-Object Text.StringBuilder
    $depth = 0
    foreach ($line in $lines) {
        $t = $line.Trim()
        if ($t -match '^[\]\}]') { $depth-- }
        [void]$sb.Append(('  ' * [math]::Max($depth, 0)) + ($t -replace '":\s+', '": ') + "`n")
        if ($t -match '[\[\{]$') { $depth++ }
    }
    return $sb.ToString()
}

# ---------- Agent run history (History/runs) ----------
# One Markdown file per run, so concurrent runs by different people never touch the same file.

function New-RunRecord {
    param([string]$Agent, [string]$Model, [string]$TaskId, [string]$Prompt)
    $user = Get-GitUser
    $now = Get-Date
    $branch = Get-CurrentBranch
    if (-not $TaskId) { $TaskId = Get-TaskIdFromBranch $branch }
    $id = '{0}-{1}-{2}' -f $now.ToString('yyyyMMdd-HHmmss'), $user.Slug, $Agent
    if ($TaskId) { $id += "-$TaskId" }
    $rel = 'History/runs/{0}/{1}.md' -f $now.ToString('yyyy-MM'), $id
    $base = (Invoke-Git rev-parse --short HEAD -AllowFail | Select-Object -First 1)
    $text = @"
---
run: $id
user: $($user.Name)
agent: $Agent
model: $Model
task: $TaskId
branch: $branch
base_commit: $base
started: $($now.ToString('o'))
finished:
exit_code:
---

## Prompt

``````text
$Prompt
``````

"@
    Write-TextFile (Join-Path $script:RepoRoot $rel) ($text.TrimEnd() + "`n`n")
    return $rel
}

function Add-RunSection([string]$RelPath, [string]$Title, [string]$Body, [int]$MaxChars = 4000) {
    if (-not $RelPath) { return }
    $path = Join-Path $script:RepoRoot $RelPath
    if (-not (Test-Path -LiteralPath $path)) { return }
    if ($Body.Length -gt $MaxChars) { $Body = $Body.Substring(0, $MaxChars) + "`n... (truncated, $($Body.Length) chars)" }
    $add = "## $Title`n`n``````text`n$Body`n```````n`n"
    [IO.File]::AppendAllText($path, $add, $script:Utf8)
}

function Complete-RunRecord([string]$RelPath, [int]$ExitCode) {
    $path = Join-Path $script:RepoRoot $RelPath
    $text = [IO.File]::ReadAllText($path, $script:Utf8)
    $text = $text -replace '(?m)^finished:.*$', "finished: $((Get-Date).ToString('o'))"
    $text = $text -replace '(?m)^exit_code:.*$', "exit_code: $ExitCode"
    $changed = Invoke-Git status --porcelain --untracked-files=all -AllowFail | Where-Object { $_ -notmatch 'History/runs/' } | ForEach-Object { "- $($_.Substring(3))" }
    if ($changed) { $text += "## Files changed in working tree`n`n$($changed -join "`n")`n`n" }
    [IO.File]::WriteAllText($path, $text, $script:Utf8)
}

# ---------- Tasks (Tasks/items/*.json) ----------

function Get-TaskDir { Join-Path $script:RepoRoot 'Tasks/items' }

function Get-AllTasks {
    $dir = Get-TaskDir
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    Get-ChildItem -LiteralPath $dir -Filter 'T-*.json' | ForEach-Object {
        $t = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $t | Add-Member -NotePropertyName _path -NotePropertyValue $_.FullName -Force
        $t
    }
}

function Get-TaskById([string]$Id) {
    $p = Join-Path (Get-TaskDir) "$Id.json"
    if (-not (Test-Path -LiteralPath $p)) { throw "Task $Id not found (Tasks/items/$Id.json)" }
    $t = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
    $t | Add-Member -NotePropertyName _path -NotePropertyValue $p -Force
    return $t
}

function Save-Task($Task) {
    $path = $Task._path
    $copy = $Task | Select-Object * -ExcludeProperty _path
    Write-TextFile $path (ConvertTo-PrettyJson $copy)
}

# ---------- Claims (refs/claims/<task-id> on origin) ----------
# Creating a ref with `git push` is atomic on the server: if someone else already pushed the same
# claim ref, our push is rejected. That makes it a lock that needs no merge and no shared file.

function Get-RemoteClaims {
    $lines = Invoke-Git ls-remote origin 'refs/claims/*' -AllowFail
    $claims = @()
    foreach ($l in $lines) {
        $parts = $l -split '\s+'
        if ($parts.Count -lt 2 -or $parts[1] -notlike 'refs/claims/*') { continue }
        $taskId = $parts[1].Substring('refs/claims/'.Length)
        $null = Invoke-Git fetch -q origin "+$($parts[1]):refs/remotes/claims/$taskId" -AllowFail
        $msg = (Invoke-Git log -1 --format=%B "refs/remotes/claims/$taskId" -AllowFail) -join "`n"
        $info = $null
        try { $info = ($msg.Substring($msg.IndexOf('{')) | ConvertFrom-Json) } catch { }
        $claims += [pscustomobject]@{ Task = $taskId; User = $info.user; Agent = $info.agent; Since = $info.claimed; Paths = @($info.paths); Branch = $info.branch }
    }
    return $claims
}

function Test-PathOverlap([string[]]$A, [string[]]$B) {
    # Glob prefixes overlap when one is a prefix of the other after stripping wildcards.
    foreach ($a in $A) {
        foreach ($b in $B) {
            $pa = ($a -replace '\*.*$', '').TrimEnd('/')
            $pb = ($b -replace '\*.*$', '').TrimEnd('/')
            if (-not $pa -or -not $pb) { return $true }
            if ($pa.StartsWith($pb) -or $pb.StartsWith($pa)) { return "$a <-> $b" }
        }
    }
    return $false
}

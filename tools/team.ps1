<#
.SYNOPSIS
  Team overview: who is working on what, which files are locked, and what instructions agents were given.

.EXAMPLE
  tools\team.cmd status                       # claims, open tasks, LFS locks, recent runs
  tools\team.cmd history                      # all agent runs (newest first)
  tools\team.cmd history -User GP-Yoshihiro -Agent codex-local -Days 7
  tools\team.cmd history -Task T-261031-0001
  tools\team.cmd run <path-or-run-id>         # print one run record (prompt + result)
#>
param(
    [Parameter(Position = 0)][ValidateSet('status', 'history', 'run')][string]$Command = 'status',
    [Parameter(Position = 1)][string]$Arg,
    [string]$User,
    [string]$Agent,
    [string]$Task,
    [int]$Days = 0,
    [int]$Limit = 30
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/team.ps1')

function ConvertFrom-RunText([string[]]$lines, [string]$file) {
    $meta = @{}
    foreach ($l in ($lines | Select-Object -First 14)) { $m = [regex]::Match($l, '^(\w+):\s*(.*)$'); if ($m.Success) { $meta[$m.Groups[1].Value] = $m.Groups[2].Value } }
    # First prompt line: line 17 of the record written by New-RunRecord (front matter, heading, fence)
    $promptLine = "$($lines | Select-Object -Skip 16 -First 1)"
    $exit = $meta['exit_code']
    if (-not $exit -and -not $meta['finished']) { $exit = 'running' }
    [pscustomobject]@{
        Started = $meta['started']; User = $meta['user']; Agent = $meta['agent']; Task = $meta['task']
        Exit = $exit; Prompt = if ($promptLine.Length -gt 60) { $promptLine.Substring(0, 60) + '...' } else { $promptLine }
        File = $file
    }
}

# All runs of the whole team: the private history repo is pulled first, so runs started on other
# machines (including ones still running) show up immediately.
function Get-Runs {
    $root = Sync-History
    $dir = Join-Path $root 'runs'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    Get-ChildItem -LiteralPath $dir -Recurse -Filter '*.md' | ForEach-Object {
        ConvertFrom-RunText (Get-Content -LiteralPath $_.FullName -Encoding UTF8) $_.FullName.Substring($root.Length + 1).Replace('\', '/')
    } | Sort-Object Started -Descending
}

switch ($Command) {
    'status' {
        Write-Host "== Branch: $(Get-CurrentBranch)   You: $((Get-GitUser).Name)"
        Write-Host "`n== Active claims (refs/claims on origin)"
        $claims = @(Get-RemoteClaims)
        if ($claims) { $claims | Format-Table Task, User, Agent, Since, @{ n = 'Paths'; e = { $_.Paths -join ', ' } } -AutoSize | Out-String -Width 200 | Write-Host }
        else { Write-Host '  (none)' }

        Write-Host "== Open tasks"
        & (Join-Path $PSScriptRoot 'task.ps1') list

        Write-Host "== LFS file locks (binary assets)"
        $locks = Invoke-Git lfs locks -AllowFail
        if ($LASTEXITCODE -eq 0 -and $locks) { $locks | ForEach-Object { "  $_" } | Write-Host } else { Write-Host '  (none, or the remote has no LFS locking API)' }

        Write-Host "`n== Recent agent runs"
        Get-Runs | Select-Object -First 10 | Format-Table Started, User, Agent, Task, Exit, Prompt -AutoSize | Out-String -Width 220 | Write-Host
    }
    'history' {
        $runs = Get-Runs
        if ($User) { $runs = $runs | Where-Object { $_.User -like "*$User*" } }
        if ($Agent) { $runs = $runs | Where-Object { $_.Agent -eq $Agent } }
        if ($Task) { $runs = $runs | Where-Object { $_.Task -eq $Task } }
        if ($Days -gt 0) { $since = (Get-Date).AddDays(-$Days); $runs = $runs | Where-Object { [datetime]$_.Started -ge $since } }
        $runs | Select-Object -First $Limit | Format-Table Started, User, Agent, Task, Exit, Prompt, File -AutoSize | Out-String -Width 260 | Write-Host
        if ($Task) {
            Write-Host "== Commits for $Task"
            Invoke-Git log --all --format='  %h %ad %an  %s' --date=short "--grep=Task: $Task" -AllowFail | Write-Host
        }
    }
    'run' {
        if (-not $Arg) { throw 'Usage: tools\team.cmd run <runs/...md | run id | history:runs/...md>' }
        $root = Sync-History
        $path = Join-Path $root ($Arg -replace '^history:', '')
        if (-not (Test-Path -LiteralPath $path)) {
            $hit = Get-ChildItem -LiteralPath (Join-Path $root 'runs') -Recurse -Filter "*$Arg*.md" -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $hit) { throw "Run $Arg not found." }
            $path = $hit.FullName
        }
        Get-Content -LiteralPath $path -Encoding UTF8 | Write-Host
    }
}

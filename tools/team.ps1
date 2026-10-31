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

function Get-Runs {
    $dir = Join-Path $script:RepoRoot 'History/runs'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    Get-ChildItem -LiteralPath $dir -Recurse -Filter '*.md' | ForEach-Object {
        $head = Get-Content -LiteralPath $_.FullName -TotalCount 14 -Encoding UTF8
        $meta = @{}
        foreach ($l in $head) { $m = [regex]::Match($l, '^(\w+):\s*(.*)$'); if ($m.Success) { $meta[$m.Groups[1].Value] = $m.Groups[2].Value } }
        # First prompt line: line 17 of the record written by New-RunRecord (front matter, heading, fence)
        $promptLine = "$(Get-Content -LiteralPath $_.FullName -Encoding UTF8 | Select-Object -Skip 16 -First 1)"
        [pscustomobject]@{
            Started = $meta['started']; User = $meta['user']; Agent = $meta['agent']; Task = $meta['task']
            Exit = $meta['exit_code']; Prompt = if ($promptLine.Length -gt 60) { $promptLine.Substring(0, 60) + '...' } else { $promptLine }
            File = $_.FullName.Substring($script:RepoRoot.Length + 1).Replace('\', '/')
        }
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
        $locks = & git -C $script:RepoRoot lfs locks 2>$null
        if ($LASTEXITCODE -eq 0 -and $locks) { $locks | ForEach-Object { "  $_" } | Write-Host } else { Write-Host '  (none or LFS locking unavailable)' }

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
        if (-not $Arg) { throw 'Usage: tools\team.cmd run <History/runs/...md | run id>' }
        $path = Join-Path $script:RepoRoot $Arg
        if (-not (Test-Path -LiteralPath $path)) {
            $hit = Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'History/runs') -Recurse -Filter "*$Arg*.md" | Select-Object -First 1
            if (-not $hit) { throw "Run $Arg not found." }
            $path = $hit.FullName
        }
        Get-Content -LiteralPath $path -Encoding UTF8 | Write-Host
    }
}

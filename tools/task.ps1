<#
.SYNOPSIS
  Team task board stored in git: one file per task (Tasks/items/<id>.json) plus an atomic claim ref per
  task on origin (refs/claims/<id>), so several people and agents can work in parallel without clashing.

.EXAMPLE
  tools\task.cmd list                                   # board + who holds which claim
  tools\task.cmd new "Player jump" -Paths Assets/Scripts/Runtime/Player -Priority 2
  tools\task.cmd claim T-261031-a1b2 -Agent codex       # lock it, create branch task/<id>
  tools\task.cmd claim T-261031-a1b2 -Worktree          # ...in its own worktree (parallel agents on one PC)
  tools\task.cmd show T-261031-a1b2                     # task, claim, runs and commits
  tools\task.cmd done T-261031-a1b2                     # mark done on the task branch, release the claim
  tools\task.cmd release T-261031-a1b2                  # give it up without finishing
#>
param(
    [Parameter(Position = 0)][ValidateSet('list', 'new', 'claim', 'release', 'done', 'show')][string]$Command = 'list',
    [Parameter(Position = 1)][string]$Arg,
    [string[]]$Paths,
    [int]$Priority = 3,
    [string[]]$Refs,
    [string[]]$Accept,
    [ValidateSet('human', 'claude', 'codex', 'codex-local', 'strata')][string]$Agent = 'human',
    [switch]$Worktree,
    [switch]$Force,
    [switch]$All
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/team.ps1')

function Get-DefaultBranch {
    $ref = Invoke-Git symbolic-ref --quiet refs/remotes/origin/HEAD -AllowFail | Select-Object -First 1
    if ($ref -and $ref -like 'refs/remotes/origin/*') { return $ref.Substring('refs/remotes/origin/'.Length) }
    return 'main'
}

switch ($Command) {
    'list' {
        $claims = @(Get-RemoteClaims)
        $rows = foreach ($t in (Get-AllTasks | Sort-Object priority, id)) {
            if (-not $All -and $t.status -eq 'done') { continue }
            $c = $claims | Where-Object { $_.Task -eq $t.id } | Select-Object -First 1
            [pscustomobject]@{
                Id = $t.id; Status = if ($c -and $t.status -eq 'todo') { 'doing' } else { $t.status }; P = $t.priority
                Owner = if ($c) { "$($c.User) ($($c.Agent))" } else { '' }; Title = $t.title
            }
        }
        if ($rows) { $rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host } else { Write-Host 'No open tasks.' }
        $orphans = $claims | Where-Object { -not (Test-Path (Join-Path (Get-TaskDir) "$($_.Task).json")) }
        foreach ($o in $orphans) { Write-Host "claim without a task file on this branch: $($o.Task) by $($o.User) -- pull the latest default branch" }
    }

    'new' {
        if (-not $Arg) { throw 'Usage: tools\task.cmd new "title" [-Paths ...] [-Priority n] [-Refs cs:...] [-Accept "..."]' }
        $user = Get-GitUser
        $id = 'T-{0}-{1}' -f (Get-Date).ToString('yyMMdd'), ([Guid]::NewGuid().ToString('N').Substring(0, 4))
        $task = [pscustomobject]@{
            id = $id; title = $Arg; status = 'todo'; priority = $Priority
            paths = @($Paths | Where-Object { $_ }); strataRefs = @($Refs | Where-Object { $_ })
            acceptance = if ($Accept) { @($Accept) } else { @('tools/unity.cmd test EditMode exits 0', 'tools/strata-index.cmd -Verify exits 0') }
            createdBy = $user.Name; createdAt = (Get-Date).ToString('o')
            assignee = $null; agent = $null; branch = $null; completedAt = $null; notes = ''
            _path = Join-Path (Get-TaskDir) "$id.json"
        }
        Save-Task $task
        Write-Host "Created Tasks/items/$id.json -- commit it (and push / open a PR) so the team can see it."
        Write-Output $id
    }

    'claim' {
        $task = Get-TaskById $Arg
        if ($task.status -eq 'done') { throw "$Arg is already done." }
        $user = Get-GitUser
        $null = Invoke-Git fetch -q origin
        $claims = @(Get-RemoteClaims)
        $mine = $claims | Where-Object { $_.Task -eq $Arg }
        if ($mine) { throw "$Arg is already claimed by $($mine.User) ($($mine.Agent)) since $($mine.Since)." }

        $claimPaths = if ($Paths) { @($Paths) } else { @($task.paths) }
        foreach ($c in $claims) {
            $hit = if ($claimPaths.Count -and $c.Paths.Count) { Test-PathOverlap $claimPaths $c.Paths } else { $false }
            if ($hit) {
                $msg = "Paths overlap with $($c.Task) held by $($c.User) ($($c.Agent)): $hit"
                if ($Force) { Write-Warning "$msg -- continuing because of -Force" } else { throw "$msg. Coordinate first, narrow -Paths, or use -Force." }
            }
        }

        $slug = ($task.title -replace '[^A-Za-z0-9]+', '-').Trim('-').ToLower()
        if ($slug.Length -gt 30) { $slug = $slug.Substring(0, 30).Trim('-') }
        $branch = if ($slug) { "task/$Arg-$slug" } else { "task/$Arg" }
        $info = [ordered]@{ task = $Arg; user = $user.Name; agent = $Agent; claimed = (Get-Date).ToString('o'); branch = $branch; paths = $claimPaths }

        # The claim is a commit with an empty tree whose message carries the claim; pushing it creates
        # refs/claims/<id>. If someone else created that ref first, the push is rejected -> nobody double-claims.
        $emptyTree = '4b825dc642cb6eb9a060e54bf8d69288fbee4904'
        $claimCommit = ($info | ConvertTo-Json -Compress) | & git -C $script:RepoRoot commit-tree $emptyTree -F -
        if ($LASTEXITCODE -ne 0) { throw 'git commit-tree failed' }
        $push = Invoke-Git push origin "$($claimCommit):refs/claims/$Arg" -AllowFail
        if ($LASTEXITCODE -ne 0) { throw "Could not claim $Arg (someone may have claimed it a moment ago):`n$($push -join "`n")" }

        $default = Get-DefaultBranch
        if ($Worktree) {
            $wtRoot = Join-Path (Split-Path -Parent $script:RepoRoot) ((Split-Path -Leaf $script:RepoRoot) + '.wt')
            $wt = Join-Path $wtRoot $Arg
            $null = Invoke-Git worktree add -b $branch $wt "origin/$default"
            $target = $wt
        } else {
            $dirty = Invoke-Git status --porcelain
            if ($dirty) { Write-Warning 'Working tree has uncommitted changes; they will come along to the task branch.' }
            $null = Invoke-Git switch -c $branch "origin/$default"
            $target = $script:RepoRoot
        }

        # Record the assignment on the task branch; it reaches the default branch with the PR.
        $taskFile = Join-Path $target "Tasks/items/$Arg.json"
        $t = Get-Content -LiteralPath $taskFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $t.status = 'doing'; $t.assignee = $user.Name; $t.agent = $Agent; $t.branch = $branch
        if ($Paths) { $t.paths = @($Paths) }
        $t | Add-Member -NotePropertyName _path -NotePropertyValue $taskFile -Force
        Save-Task $t
        # git prints CRLF warnings on stderr; under Windows PowerShell 5.1 that must not abort the script
        $ErrorActionPreference = 'Continue'
        & git -C $target add -- "Tasks/items/$Arg.json" 2>&1 | Out-Null
        & git -C $target commit -q -m "task($Arg): start -- $($task.title)" -m "Task: $Arg" 2>&1 | Write-Host
        $ErrorActionPreference = 'Stop'
        Write-Host "Claimed $Arg for $($user.Name) ($Agent). Branch: $branch"
        if ($Worktree) { Write-Host "Worktree: $target" }
    }

    'release' {
        $user = Get-GitUser
        $c = Get-RemoteClaims | Where-Object { $_.Task -eq $Arg } | Select-Object -First 1
        if (-not $c) { Write-Host "$Arg has no claim."; return }
        if ($c.User -ne $user.Name -and -not $Force) { throw "$Arg is claimed by $($c.User); use -Force to release someone else's claim (tell them first)." }
        $null = Invoke-Git push origin ":refs/claims/$Arg"
        Write-Host "Released claim on $Arg."
    }

    'done' {
        $t = Get-TaskById $Arg
        $t.status = 'done'; $t.completedAt = (Get-Date).ToString('o')
        Save-Task $t
        $null = Invoke-Git add -- "Tasks/items/$Arg.json"
        $null = Invoke-Git commit -q -m "task($Arg): done -- $($t.title)" -m "Task: $Arg"
        $c = Get-RemoteClaims | Where-Object { $_.Task -eq $Arg }
        if ($c) { $null = Invoke-Git push origin ":refs/claims/$Arg" }
        Write-Host "$Arg marked done and claim released. Push the branch and open a PR:"
        Write-Host "  git push -u origin $(Get-CurrentBranch)"
    }

    'show' {
        $t = Get-TaskById $Arg
        $t | Select-Object * -ExcludeProperty _path | Format-List | Out-String -Width 200 | Write-Host
        $c = Get-RemoteClaims | Where-Object { $_.Task -eq $Arg }
        if ($c) { Write-Host "Claim: $($c.User) ($($c.Agent)) since $($c.Since) on $($c.Branch); paths: $($c.Paths -join ', ')" }
        Write-Host "`nAgent runs:"
        $historyRoot = Sync-History
        Get-ChildItem -Path (Join-Path $historyRoot 'runs') -Recurse -Filter "*-$Arg.md" -ErrorAction SilentlyContinue |
            ForEach-Object { '  history:' + $_.FullName.Substring($historyRoot.Length + 1).Replace('\', '/') } | Write-Host
        Write-Host "`nCommits:"
        Invoke-Git log --all --format='  %h %ad %an  %s' --date=short "--grep=Task: $Arg" -AllowFail | Write-Host
    }
}

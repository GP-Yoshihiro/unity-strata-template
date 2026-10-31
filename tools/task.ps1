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
  tools\task.cmd done T-261031-a1b2                     # mark done on the task branch; claim -> "review"
  tools\task.cmd release T-261031-a1b2                  # give it up without finishing
  tools\task.cmd block T-261031-a1b2 -Note "why"        # keep the claim but flag it for a human

  Claim lifecycle: claim (doing) -> done (review) -> PR merged or closed -> the release-claims GitHub
  workflow deletes refs/claims/<id>. The claim is held until the PR is resolved, so nobody re-takes a task
  whose finished work is still waiting for review.
#>
param(
    [Parameter(Position = 0)][ValidateSet('list', 'new', 'claim', 'release', 'done', 'block', 'show')][string]$Command = 'list',
    [Parameter(Position = 1)][string]$Arg,
    [string[]]$Paths,
    [int]$Priority = 3,
    [string[]]$Refs,
    [string[]]$Accept,
    [ValidateSet('human', 'claude', 'codex', 'codex-local', 'strata')][string]$Agent = 'human',
    [switch]$Worktree,
    [string]$Note,
    [switch]$Force,
    [switch]$All
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/team.ps1')

# Via tools\task.cmd (powershell -File) "a,b" arrives as one string: accept commas as separators
$Paths = @($Paths | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Refs = @($Refs | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

function Get-DefaultBranch {
    $ref = Invoke-Git symbolic-ref --quiet refs/remotes/origin/HEAD -AllowFail | Select-Object -First 1
    if ($ref -and $ref -like 'refs/remotes/origin/*') { return $ref.Substring('refs/remotes/origin/'.Length) }
    return 'main'
}

switch ($Command) {
    'list' {
        $claims = @(Get-RemoteClaims)
        $staleHours = [double](Get-TeamConfig).staleClaimHours
        $rows = foreach ($t in (Get-AllTasks | Sort-Object priority, id)) {
            if (-not $All -and $t.status -eq 'done') { continue }
            $c = $claims | Where-Object { $_.Task -eq $t.id } | Select-Object -First 1
            # A live claim is the truth for in-flight work (the task file on this branch may still say todo)
            $state = if ($c) { $c.State } else { $t.status }
            if ($c -and $c.State -eq 'doing' -and $staleHours -gt 0 -and $c.Since) {
                # "doing" for longer than staleClaimHours: a crashed loop or a forgotten claim -- ask its owner
                try { $age = ((Get-Date) - [datetime]$c.Since).TotalHours; if ($age -ge $staleHours) { $state = "doing (stale {0:N0}h)" -f $age } } catch { }
            }
            [pscustomobject]@{
                Id = $t.id; Status = $state; P = $t.priority
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
        $info = [ordered]@{ task = $Arg; user = $user.Name; agent = $Agent; claimed = (Get-Date).ToString('o'); state = 'doing'; branch = $branch; paths = $claimPaths }
        $push = Publish-Claim $Arg $info
        if (-not $push.Ok) { throw "Could not claim $Arg (someone may have claimed it a moment ago):`n$($push.Output)" }

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

    { $_ -in 'done', 'block' } {
        # The claim is NOT released here: the task file says "done" only on this branch until the PR merges,
        # so releasing now would let someone re-take finished work. The release-claims workflow deletes the
        # claim when the PR is merged or closed. "block" keeps the claim and flags it for a human.
        $user = Get-GitUser
        $c = Get-RemoteClaims | Where-Object { $_.Task -eq $Arg } | Select-Object -First 1
        if ($c -and $c.User -ne $user.Name -and -not $Force) { throw "$Arg is claimed by $($c.User), not you." }
        $t = Get-TaskById $Arg
        if ($Command -eq 'done') { $t.status = 'done'; $t.completedAt = (Get-Date).ToString('o') }
        else { $t.status = 'blocked'; if ($Note) { $t.notes = $Note } }
        Save-Task $t
        $null = Invoke-Git add -- "Tasks/items/$Arg.json"
        $null = Invoke-Git commit -q -m "task($Arg): $($t.status) -- $($t.title)" -m "Task: $Arg"
        if ($c) {
            $state = if ($Command -eq 'done') { 'review' } else { 'blocked' }
            $info = [ordered]@{ task = $Arg; user = $c.User; agent = $c.Agent; claimed = $c.Since; state = $state; branch = $c.Branch; paths = $c.Paths; updated = (Get-Date).ToString('o'); note = $Note }
            $r = Publish-Claim $Arg $info -Update
            if (-not $r.Ok) { Write-Warning "Could not update the claim state: $($r.Output)" }
        }
        Write-Host "$Arg is now '$($t.status)'; the claim stays until its PR is merged or closed. Push and open a PR:"
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

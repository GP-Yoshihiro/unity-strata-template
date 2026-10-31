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

function Test-SamePath([string]$A, [string]$B) {
    # Compares two directory paths on every OS. GetFullPath normalises '/' to '\' on Windows; on macOS/Linux
    # a backslash is an ordinary file-name character, so never rewrite '/' to '\' before calling it.
    if (-not $A -or -not $B) { return $false }
    $na = [IO.Path]::GetFullPath($A).TrimEnd('\', '/')
    $nb = [IO.Path]::GetFullPath($B).TrimEnd('\', '/')
    $onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows
    if ($onWindows) { return $na -ieq $nb }
    return $na -ceq $nb
}

function Stop-ProcessTree($Process) {
    # Kills a process and everything it started (Unity licensing client, shader compilers, agent CLIs).
    if (-not $Process -or $Process.HasExited) { return }
    $onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows
    if ($onWindows) { & taskkill.exe /PID $Process.Id /T /F 2>&1 | Out-Null; return }
    try { $Process.Kill($true) } catch { try { $Process.Kill() } catch { } }   # Kill($true) = whole tree (.NET Core 3+)
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

function Invoke-WithPromptFile([string]$Exe, [string[]]$ExeArgs, [string]$PromptFile) {
    # Runs `<exe> <args> < <file>` through cmd.exe so the prompt reaches the CLI byte-for-byte as UTF-8.
    # (PowerShell 5.1 re-encodes piped text to native programs, and batch shims such as codex.cmd cut
    #  command-line arguments at newlines, so neither a pipe nor an argument is safe for multi-line prompts.)
    $quoted = @($ExeArgs | ForEach-Object { if ($_ -match '[\s"&|<>^]') { '"' + ($_ -replace '"', '""') + '"' } else { $_ } })
    $line = '"' + $Exe + '" ' + ($quoted -join ' ') + ' < "' + $PromptFile + '"'
    # CLIs print progress on stderr; under Windows PowerShell 5.1 that must not become a terminating error
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & cmd.exe /d /s /c "`"$line`"" 2>&1 | ConvertTo-OutputLine } finally { $ErrorActionPreference = $prev }
}

function ConvertTo-OutputLine {
    # stderr lines arrive as ErrorRecords; print their text, not "System.Management.Automation.RemoteException"
    process { if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" } }
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

# ---------- Team config (team.config.json) ----------

function Get-TeamConfig {
    $cfg = [pscustomobject]@{ historyRepo = ''; historyDir = '.history'; defaultBranch = 'main'; staleClaimHours = 24; mainAgent = 'claude'; loopAgent = 'codex-local' }
    $path = Join-Path $script:RepoRoot 'team.config.json'
    if (Test-Path -LiteralPath $path) {
        $file = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $file.PSObject.Properties) { $cfg | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force }
    }
    return $cfg
}

# ---------- Agent run history (private history repo) ----------
# Prompts and results can contain things the public template repo must not publish, so run records live
# in a separate private repository (team.config.json: historyRepo), cloned to <main checkout>/.history.
# One Markdown file per run, so concurrent runs by different people never touch the same file.

function Invoke-GitIn([string]$Dir) {
    $gitArgs = @($args)
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & git -C $Dir @gitArgs 2>&1
    $ErrorActionPreference = $prev
    return $out | ForEach-Object { "$_" }
}

function Get-HistoryRoot {
    # Shared by all worktrees: resolved against the main checkout (parent of the common .git dir)
    $common = Invoke-Git rev-parse --path-format=absolute --git-common-dir -AllowFail | Select-Object -First 1
    $mainRoot = if ($common -and (Test-Path -LiteralPath $common)) { Split-Path -Parent $common } else { $script:RepoRoot }
    return Join-Path $mainRoot (Get-TeamConfig).historyDir
}

function Protect-PrivateFolder([string]$Dir) {
    # Hidden folder, never part of the project's git (.gitignore + pre-commit), synced only to the private repo.
    # Windows: keeps your normal (inherited) permissions -- tools you start, including sandboxed app terminals,
    # still need them -- and adds a deny rule for Codex's sandbox group so autonomous agents can neither read
    # past prompts nor rewrite the record. (Removing inheritance instead locks out restricted app tokens.)
    $item = Get-Item -LiteralPath $Dir -Force
    $onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows
    if (-not $onWindows) { & chmod 700 $Dir; return }
    if (-not ($item.Attributes -band [IO.FileAttributes]::Hidden)) {
        $item.Attributes = $item.Attributes -bor [IO.FileAttributes]::Hidden
    }
    $group = "$env:COMPUTERNAME\CodexSandboxUsers"
    try { $null = ([Security.Principal.NTAccount]$group).Translate([Security.Principal.SecurityIdentifier]) } catch { return }  # no Codex sandbox on this PC
    $acl = Get-Acl -LiteralPath $Dir
    $denied = $acl.Access | Where-Object { $_.AccessControlType -eq 'Deny' -and $_.IdentityReference.Value -like '*CodexSandboxUsers' }
    if (-not $denied) {
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        & icacls.exe $Dir /deny "$($group):(OI)(CI)F" /Q 2>&1 | Out-Null
        $ErrorActionPreference = $prev
        if ($LASTEXITCODE -ne 0) { Write-Warning "Could not add the agent-sandbox deny rule on $Dir (icacls exit $LASTEXITCODE)." }
    }
}

function Test-HistoryRepo([string]$Dir) {
    # True only when $Dir is the top of its own git repository. Without this check, a history folder git cannot
    # read would make `git -C <dir>` fall through to the project repo and commit there.
    if (-not (Test-Path -LiteralPath (Join-Path $Dir '.git'))) { return $false }
    $top = Invoke-GitIn $Dir rev-parse --show-toplevel | Select-Object -First 1
    if ($LASTEXITCODE -ne 0 -or -not $top) { return $false }
    return (Test-SamePath $top $Dir)
}

function Sync-History {
    # Create the hidden private history folder; clone/update the private history repo into it when
    # team.config.json names one you can access, otherwise keep records local only.
    $cfg = Get-TeamConfig
    $dir = Get-HistoryRoot
    $isRepo = Test-HistoryRepo $dir
    if ($cfg.historyRepo -and -not $isRepo -and (Test-Path -LiteralPath (Join-Path $dir '.git'))) {
        Write-Warning "$dir\.git exists but git cannot use it (permissions?). History stays local until fixed: icacls `"$dir`" /reset /T"
    } elseif ($cfg.historyRepo -and -not $isRepo -and -not (Test-Path -LiteralPath (Join-Path $dir 'runs'))) {
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Force -Recurse }   # empty placeholder from an earlier offline run
        & git clone -q $cfg.historyRepo $dir 2>&1 | Out-Null
        $ErrorActionPreference = $prev
        if ($LASTEXITCODE -ne 0) { Write-Warning "History repo $($cfg.historyRepo) is not reachable (no access or offline). Run records stay local in $dir." }
    } elseif ($isRepo) {
        $null = Invoke-GitIn $dir pull -q --rebase --autostash
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $dir 'runs') | Out-Null
    Protect-PrivateFolder $dir
    return $dir
}

function Publish-History([string]$Message) {
    # Commit and push new/changed records; retries on concurrent pushes (each run is its own file, so rebase never conflicts).
    $cfg = Get-TeamConfig
    $dir = Get-HistoryRoot
    if (-not $cfg.historyRepo -or -not (Test-HistoryRepo $dir)) { return }
    $null = Invoke-GitIn $dir add -A
    $null = Invoke-GitIn $dir -c "user.name=$((Get-GitUser).Name)" -c "user.email=$((Get-GitUser).Email)" commit -q -m $Message
    for ($i = 0; $i -lt 3; $i++) {
        $null = Invoke-GitIn $dir push -q
        if ($LASTEXITCODE -eq 0) { return }
        $null = Invoke-GitIn $dir pull -q --rebase
    }
    Write-Warning "Could not push run history to $($cfg.historyRepo); it will go up with the next run."
}

function New-RunRecord {
    # Returns @{ Path = absolute file; Ref = 'runs/yyyy-MM/<id>.md' inside the history repo }
    param([string]$Agent, [string]$Model, [string]$TaskId, [string]$Prompt)
    $user = Get-GitUser
    $now = Get-Date
    $branch = Get-CurrentBranch
    if (-not $TaskId) { $TaskId = Get-TaskIdFromBranch $branch }
    $id = '{0}-{1}-{2}' -f $now.ToString('yyyyMMdd-HHmmss'), $user.Slug, $Agent
    if ($TaskId) { $id += "-$TaskId" }
    $rel = 'runs/{0}/{1}.md' -f $now.ToString('yyyy-MM'), $id
    $root = Sync-History
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
    $path = Join-Path $root $rel
    Write-TextFile $path ($text.TrimEnd() + "`n`n")
    return [pscustomobject]@{ Path = $path; Ref = $rel; Id = $id }
}

function Add-RunSection([string]$Path, [string]$Title, [string]$Body, [int]$MaxChars = 4000) {
    # Silently skipped when the record is not writable (e.g. called from inside an agent sandbox)
    try { if (-not $Path -or -not (Test-Path -LiteralPath $Path -ErrorAction Stop)) { return } } catch { return }
    if ($Body.Length -gt $MaxChars) { $Body = $Body.Substring(0, $MaxChars) + "`n... (truncated, $($Body.Length) chars)" }
    $add = "## $Title`n`n``````text`n$Body`n```````n`n"
    try { [IO.File]::AppendAllText($Path, $add, $script:Utf8) } catch { }
}

function Complete-RunRecord([string]$Path, [int]$ExitCode) {
    $text = [IO.File]::ReadAllText($Path, $script:Utf8)
    $text = $text -replace '(?m)^finished:.*$', "finished: $((Get-Date).ToString('o'))"
    $text = $text -replace '(?m)^exit_code:.*$', "exit_code: $ExitCode"
    $changed = Invoke-Git status --porcelain --untracked-files=all -AllowFail | ForEach-Object { "- $($_.Substring(3))" }
    if ($changed) { $text += "## Files changed in working tree`n`n$($changed -join "`n")`n`n" }
    [IO.File]::WriteAllText($Path, $text, $script:Utf8)
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
    # One fetch mirrors all claim refs (deleted claims are pruned), then each claim's JSON is read locally.
    $null = Invoke-Git fetch -q --prune origin '+refs/claims/*:refs/remotes/claims/*' -AllowFail
    $claims = @()
    $prevEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = $script:Utf8
    try {
        foreach ($ref in (Invoke-Git for-each-ref --format='%(refname)' refs/remotes/claims -AllowFail)) {
            if ($ref -notlike 'refs/remotes/claims/*') { continue }
            $taskId = $ref.Substring('refs/remotes/claims/'.Length)
            $msg = (Invoke-Git log -1 --format=%B $ref -AllowFail) -join "`n"
            $info = $null
            try { $info = ($msg.Substring($msg.IndexOf('{')) | ConvertFrom-Json) } catch { }
            $state = if ($info.state) { $info.state } else { 'doing' }
            $claims += [pscustomobject]@{ Task = $taskId; User = $info.user; Agent = $info.agent; Since = $info.claimed; State = $state; Paths = @($info.paths); Branch = $info.branch }
        }
    } finally { [Console]::OutputEncoding = $prevEnc }
    return $claims
}

function Publish-Claim([string]$TaskId, $Info, [switch]$Update) {
    # The claim is a commit with an empty tree whose message is the claim JSON, pushed as refs/claims/<id>.
    # Creating that ref is atomic on the server: if someone else created it first our push is rejected.
    # -Update replaces our own claim (state change), which needs a forced ref update.
    $file = Join-Path ([IO.Path]::GetTempPath()) ("claim-" + [Guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($file, ($Info | ConvertTo-Json -Compress), $script:Utf8)   # file, not a pipe: keeps non-ASCII names intact on PS 5.1
    try {
        $emptyTree = '4b825dc642cb6eb9a060e54bf8d69288fbee4904'
        $sha = Invoke-Git commit-tree $emptyTree -F $file | Select-Object -Last 1
    } finally { Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue }
    $refspec = "$($sha):refs/claims/$TaskId"
    if ($Update) { $refspec = "+$refspec" }
    $out = Invoke-Git push origin $refspec -AllowFail
    return [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Output = ($out -join "`n") }
}

function ConvertTo-PathRegex([string]$Glob) {
    # Task "paths" entry -> regex. "**" spans folders, "*" / "?" stay inside one folder. An entry without
    # wildcards also covers everything below it (a folder).
    $g = $Glob.Replace('\', '/').TrimEnd('/')
    $sb = New-Object Text.StringBuilder '^'
    for ($i = 0; $i -lt $g.Length; $i++) {
        $c = $g[$i]
        if ($c -eq '*' -and $i + 1 -lt $g.Length -and $g[$i + 1] -eq '*') {
            if ($i + 2 -lt $g.Length -and $g[$i + 2] -eq '/') { [void]$sb.Append('(.*/)?'); $i += 2 } else { [void]$sb.Append('.*'); $i++ }
        } elseif ($c -eq '*') { [void]$sb.Append('[^/]*') }
        elseif ($c -eq '?') { [void]$sb.Append('[^/]') }
        else { [void]$sb.Append([regex]::Escape([string]$c)) }
    }
    if ($g -notmatch '[\*\?]') { [void]$sb.Append('(/.*)?') }
    return [regex]($sb.Append('$').ToString())
}

function Test-InTaskPaths([string]$File, [string[]]$TaskPaths, [string]$TaskId) {
    # True when a changed file is allowed for the task: inside its paths, the .meta of such a file or of a
    # folder above one, the task's own file, or the generated context index.
    $f = $File.Replace('\', '/')
    if ($f -eq '.strata/strata_index.json' -or ($TaskId -and $f -eq "Tasks/items/$TaskId.json")) { return $true }
    $target = if ($f.EndsWith('.meta')) { $f.Substring(0, $f.Length - 5) } else { $f }
    foreach ($p in $TaskPaths) {
        if (-not $p) { continue }
        if ((ConvertTo-PathRegex $p).IsMatch($target)) { return $true }
        if ($f.EndsWith('.meta') -and $p.Replace('\', '/').StartsWith("$target/")) { return $true }   # folder .meta
    }
    return $false
}

function Get-PathSegments([string]$Glob) {
    # Folder segments before the first wildcard: "Assets/Scenes/*.unity" -> Assets, Scenes
    $segs = @()
    foreach ($s in ($Glob.Replace('\', '/') -split '/')) {
        if (-not $s) { continue }
        if ($s -match '[\*\?\[]') { break }
        $segs += $s
    }
    return , $segs
}

function Test-PathOverlap([string[]]$Mine, [string[]]$Theirs) {
    # Two globs overlap when one's fixed folder part is a whole-segment prefix of the other's
    # ("Assets/Player" vs "Assets/Player/Move.cs" overlap; "Assets/Player" vs "Assets/PlayerUI" do not).
    # Note: PowerShell variable names are case-insensitive, so loop variables must not reuse parameter names.
    foreach ($pathMine in $Mine) {
        foreach ($pathTheirs in $Theirs) {
            $sa = Get-PathSegments $pathMine
            $sb = Get-PathSegments $pathTheirs
            $n = [math]::Min($sa.Count, $sb.Count)
            $same = $true
            for ($i = 0; $i -lt $n; $i++) { if ($sa[$i] -ne $sb[$i]) { $same = $false; break } }
            if ($same) { return "$pathMine <-> $pathTheirs" }
        }
    }
    return $false
}

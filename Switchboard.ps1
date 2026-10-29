$ErrorActionPreference = "Stop"

# WSL distribution used by the launcher.
# Check available distributions with: wsl -l -q
$Distro = "Ubuntu"

# Folder holding the projects, relative to the WSL home directory. Projects sit
# one level inside it, which is what lets the CLAUDE.md and other Claude config
# kept in this folder apply to every project below it: Claude walks up from the
# working directory collecting instructions, and that walk reaches here from a
# project and from an agent worktree inside one alike.
$ProjectsRoot = "projects"

# Both settings above are defaults; Setup-Switchboard.bat writes this PC's own
# values to switchboard.local.json, which Import-LocalSettings reads at start.

# Config dirs whose usage refresh has already been attempted this run, so a
# signed-out or otherwise failing account is not retried on every redraw.
$script:UsageRefreshTried = @{}

function Import-LocalSettings {
    # The per-PC values live in a separate, git-ignored file so this script
    # stays identical to the repository on every PC and "git pull" never runs
    # into a local edit.
    $path = Join-Path $PSScriptRoot "switchboard.local.json"
    if (-not (Test-Path -LiteralPath $path)) {
        return
    }

    try {
        $settings = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    }
    catch {
        throw ("Could not read '{0}': {1} Run Setup-Switchboard.bat to write it again." -f $path, $_.Exception.Message)
    }

    if ($settings.Distro) {
        $script:Distro = [string]$settings.Distro
    }
    if ($settings.ProjectsRoot) {
        $script:ProjectsRoot = [string]$settings.ProjectsRoot
    }
}

function Get-WslHome {
    $output = @($null | & wsl.exe -d $Distro -- printenv HOME)
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        throw "Could not determine HOME in WSL distribution '$Distro' (exit code $exitCode)."
    }

    $wslHomeValue = (($output -join "`n").Trim())
    if ([string]::IsNullOrWhiteSpace($wslHomeValue)) {
        throw "WSL returned an empty HOME directory for '$Distro'."
    }

    return $wslHomeValue
}

function Ensure-WslDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Refusing to create an empty WSL path."
    }

    $null | & wsl.exe -d $Distro -- mkdir -p -- $Path
    if ($LASTEXITCODE -ne 0) {
        throw "Could not create WSL directory '$Path'."
    }
}

function Test-WslDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $null | & wsl.exe -d $Distro -- test -d $Path
    return ($LASTEXITCODE -eq 0)
}

function Invoke-WslNative {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock
    )

    # PowerShell promotes a native command's stderr text into a terminating
    # error whenever $ErrorActionPreference is "Stop" - even with output
    # streams redirected to $null. Several expected, non-exceptional outcomes
    # here (no git repo, a failed login, a merge that needs manual attention)
    # legitimately write to stderr, so this runs the call with that preference
    # relaxed; the caller still checks $LASTEXITCODE by hand afterward, same
    # as every other wsl.exe call in this script.
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $ScriptBlock
    }
    finally {
        $ErrorActionPreference = $previousEap
    }
}

function ConvertTo-NativeArgumentString {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Arguments
    )

    # Start-Process takes a single command line rather than an argv array, so
    # every value has to be quoted the way CommandLineToArgvW reads it back:
    # wrap anything containing whitespace or a quote, double the backslashes
    # that run into a quote, and escape the quote itself. Project paths with
    # spaces and the merge prompt both depend on this.
    $quoted = @()
    foreach ($argument in $Arguments) {
        $value = [string]$argument
        if ($value -eq "") {
            $quoted += '""'
            continue
        }
        if ($value -notmatch '[\s"]') {
            $quoted += $value
            continue
        }
        $escaped = [regex]::Replace($value, '(\\*)"', '$1$1\"')
        $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
        $quoted += '"' + $escaped + '"'
    }

    return ($quoted -join ' ')
}

function Start-WslInteractive {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$WslArguments
    )

    # Every interactive Claude session below is reached through menu functions
    # whose return value is captured ("$projectResult = Show-ProjectMenu ..."),
    # and in PowerShell that capture propagates all the way down the call
    # chain: a native command only inherits the console's stdout handle when
    # the enclosing pipeline's output is itself going to the console. Nested
    # under a capture, "& wsl.exe" gets a pipe for stdout while stdin and
    # stderr stay on the pty - Claude sees a non-TTY stdout, falls back to
    # non-interactive --print mode and dies with "Input must be provided
    # either through stdin or as a prompt argument when using --print".
    #
    # Start-Process bypasses PowerShell's native-command plumbing entirely:
    # with -NoNewWindow and no redirection the child inherits this console's
    # real handles no matter what the surrounding pipeline is doing, so all
    # three descriptors reach WSL as the pty. Verified with readlink on
    # /proc/self/fd inside the distro.
    $arguments = ConvertTo-NativeArgumentString -Arguments $WslArguments

    # Relaxed for the same reason Invoke-WslNative relaxes it: stderr text
    # from Claude is expected here and must not become a terminating error.
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $process = Start-Process -FilePath "wsl.exe" -ArgumentList $arguments `
            -NoNewWindow -Wait -PassThru
    }
    finally {
        $ErrorActionPreference = $previousEap
    }

    if (-not $process) {
        return 1
    }

    return [int]$process.ExitCode
}

function Read-MenuKey {
    # One keypress, no Enter needed. When input is redirected (scripted runs)
    # there is no console to read keys from, so fall back to a line read and
    # treat end-of-input as "quit" rather than failing on a null value.
    if ([Console]::IsInputRedirected) {
        $line = [Console]::In.ReadLine()
        if ($null -eq $line) {
            return "Q"
        }
        $line = $line.Trim()
        if (-not $line) {
            return "ENTER"
        }
        return $line.Substring(0, 1).ToUpperInvariant()
    }

    $keyInfo = [Console]::ReadKey($true)
    if ($keyInfo.Key -eq [ConsoleKey]::Enter) {
        return "ENTER"
    }
    if ($keyInfo.Key -eq [ConsoleKey]::Escape) {
        return "ESC"
    }
    if ([char]::IsControl($keyInfo.KeyChar)) {
        return ""
    }
    return ([string]$keyInfo.KeyChar).ToUpperInvariant()
}

function Read-PromptLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt
    )

    # Mirrors Read-MenuKey's handling of redirected input. Windows PowerShell's
    # Read-Host ignores a redirected stdin completely and hands back an empty
    # string, which would quietly turn every scripted answer into "cancel" -
    # safe, but untestable and misleading. Reading the stream directly keeps a
    # scripted run honest; end-of-input still comes back empty, which is the
    # answer every caller here treats as "do nothing".
    if ([Console]::IsInputRedirected) {
        Write-Host ("{0}: " -f $Prompt) -NoNewline
        $line = [Console]::In.ReadLine()
        Write-Host ""
        if ($null -eq $line) {
            return ""
        }
        return $line
    }

    return [string](Read-Host $Prompt)
}

function Read-ConfirmKey {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Question,

        [bool]$DefaultYes = $false
    )

    $hint = if ($DefaultYes) { "[Y/n]" } else { "[y/N]" }
    Write-Host ("{0} {1} " -f $Question, $hint) -NoNewline

    $key = Read-MenuKey
    $answer = $DefaultYes
    if ($key -eq "Y") {
        $answer = $true
    }
    elseif ($key -eq "N") {
        $answer = $false
    }

    if ($answer) { Write-Host "y" } else { Write-Host "n" }
    return $answer
}

function Wait-AnyKey {
    param([string]$Message = "Press any key to continue")

    Write-Host ""
    Write-Host ("{0}..." -f $Message) -ForegroundColor DarkGray
    [void](Read-MenuKey)
}

function Clear-HostSafe {
    # A plain "Clear-Host" calls [Console]::Clear(), which on Windows can
    # reallocate the console screen buffer. When that happens shortly before
    # this script spawns wsl.exe for an interactive Claude session, the child
    # process can inherit a stdout handle that no longer points at a real
    # console - Claude then can't detect a terminal and silently falls back
    # to non-interactive --print mode, which is what caused "Input must be
    # provided either through stdin or as a prompt argument when using
    # --print" right after "Open Claude Code console here" and would affect
    # "sign in to this account now" the same way. A VT clear-screen sequence
    # repaints the existing buffer instead of touching the underlying handle,
    # so it is safe to use right before launching an interactive WSL session.
    Write-Host -NoNewline "$([char]27)[2J$([char]27)[3J$([char]27)[H"
}

function Get-UsageBar {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Percent,

        [int]$Width = 10
    )

    # Plain ASCII: this launcher runs under Windows PowerShell with a legacy
    # OEM console code page, where block-drawing characters render as noise.
    $value = $Percent
    if ($value -lt 0) { $value = 0 }
    if ($value -gt 100) { $value = 100 }

    $filled = [int][Math]::Round(($value * $Width) / 100.0)
    if ($filled -eq 0 -and $value -gt 0) { $filled = 1 }
    if ($filled -gt $Width) { $filled = $Width }

    return ("[" + ("#" * $filled) + ("-" * ($Width - $filled)) + "]")
}

function Get-UsageColor {
    param([int]$Percent)

    if ($Percent -ge 80) { return "Red" }
    if ($Percent -ge 50) { return "Yellow" }
    return "Green"
}

function Get-EpochMs {
    $epoch = New-Object DateTime(1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc))
    return ((Get-Date).ToUniversalTime() - $epoch).TotalMilliseconds
}

function Format-UsageAge {
    param([double]$FetchedAtMs)

    if ($FetchedAtMs -le 0) {
        return ""
    }

    $ageMinutes = (Get-EpochMs) - $FetchedAtMs
    $ageMinutes = $ageMinutes / 60000.0
    if ($ageMinutes -lt 1) { return "just now" }
    if ($ageMinutes -lt 60) { return ("{0}m ago" -f [int]$ageMinutes) }
    if ($ageMinutes -lt 1440) { return ("{0}h ago" -f [int]($ageMinutes / 60)) }
    return ("{0}d ago" -f [int]($ageMinutes / 1440))
}

function Get-WslLeafName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $value = $Path.Trim().TrimEnd('/')
    if (-not $value) {
        return ""
    }

    $index = $value.LastIndexOf('/')
    if ($index -ge 0) {
        return $value.Substring($index + 1)
    }

    return $value
}

function Get-DirectoriesImmediatelyBelow {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    if (-not (Test-WslDirectory -Path $Root)) {
        return @()
    }

    # Do not use `find -printf "%f\n"` here.  Windows PowerShell -> wsl.exe
    # quoting can transform the backslash sequence and append a literal "n".
    # Request normal full paths and take the basename in PowerShell instead.
    $paths = @($null | & wsl.exe -d $Distro -- find $Root -mindepth 1 -maxdepth 1 -type d -print)
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        throw "Could not list directories below '$Root' (exit code $exitCode)."
    }

    $names = @()
    foreach ($path in $paths) {
        $text = ([string]$path).Trim()
        if ($text) {
            $leaf = Get-WslLeafName -Path $text
            if ($leaf) {
                $names += $leaf
            }
        }
    }

    return @($names | Sort-Object -Unique)
}

function Get-Projects {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WslHome
    )

    return @(Get-DirectoriesImmediatelyBelow -Root "$WslHome/$ProjectsRoot")
}

function Get-ClaudeProjectKey {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectPath
    )

    # Claude Code stores per-project state under "<config dir>/projects/<key>",
    # where <key> is the project's absolute path with every non-alphanumeric
    # character (including "/") turned into "-".
    return ($ProjectPath -replace '[^A-Za-z0-9]', '-')
}

function Test-PreviousClaudeSession {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigDir,

        [Parameter(Mandatory = $true)]
        [string]$ProjectPath
    )

    $sessionKey = Get-ClaudeProjectKey -ProjectPath $ProjectPath
    $sessionDir = "$ConfigDir/projects/$sessionKey"

    if (-not (Test-WslDirectory -Path $sessionDir)) {
        return $false
    }

    # Avoid passing a glob pattern (e.g. "*.jsonl") through wsl.exe: it is
    # relayed to a shell that would expand it against the wrong directory.
    # List plain files instead and filter the extension in PowerShell.
    $paths = @($null | & wsl.exe -d $Distro -- find $sessionDir -maxdepth 1 -type f -print)
    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    foreach ($path in $paths) {
        $text = ([string]$path).Trim()
        if ($text -like '*.jsonl') {
            return $true
        }
    }

    return $false
}

function Copy-ProjectMemory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigDir,

        [Parameter(Mandatory = $true)]
        [string]$FromPath,

        [Parameter(Mandatory = $true)]
        [string]$ToPath
    )

    # One-time snapshot, not a live sync: gives a brand-new agent worktree the
    # same accumulated project understanding the main project already has, at
    # the moment the worktree is created. Silently does nothing if the source
    # has no memory yet, or the destination already has some (never overwrite
    # an agent's own accumulated memory).
    $fromMemoryDir = "$ConfigDir/projects/$(Get-ClaudeProjectKey -ProjectPath $FromPath)/memory"
    $toMemoryDir = "$ConfigDir/projects/$(Get-ClaudeProjectKey -ProjectPath $ToPath)/memory"

    if (-not (Test-WslDirectory -Path $fromMemoryDir)) {
        return
    }
    if (Test-WslDirectory -Path $toMemoryDir) {
        $existing = @($null | & wsl.exe -d $Distro -- find $toMemoryDir -mindepth 1 -maxdepth 1 -print)
        if ($LASTEXITCODE -eq 0 -and $existing.Count -gt 0) {
            return
        }
    }

    Ensure-WslDirectory -Path $toMemoryDir
    $null | & wsl.exe -d $Distro -- cp -r -- "$fromMemoryDir/." "$toMemoryDir/"
    if ($LASTEXITCODE -ne 0) {
        throw "Could not copy project memory from '$fromMemoryDir' to '$toMemoryDir'."
    }
}

function Test-GitRepo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoPath
    )

    Invoke-WslNative { $null | & wsl.exe -d $Distro -- git -C $RepoPath rev-parse --is-inside-work-tree *> $null }
    return ($LASTEXITCODE -eq 0)
}

function Test-GitHasCommits {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoPath
    )

    # Agents are worktrees branched from HEAD, so a freshly "git init"-ed
    # repository has nothing to branch from until its first commit.
    Invoke-WslNative { $null | & wsl.exe -d $Distro -- git -C $RepoPath rev-parse -q --verify HEAD *> $null }
    return ($LASTEXITCODE -eq 0)
}

function Get-GitCurrentBranch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoPath
    )

    $output = @($null | & wsl.exe -d $Distro -- git -C $RepoPath rev-parse --abbrev-ref HEAD)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not determine the current branch for '$RepoPath'."
    }
    return (($output -join "`n").Trim())
}

function Get-AgentBranches {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HelperPath,

        [Parameter(Mandatory = $true)]
        [string]$RepoPath
    )

    $lines = @($null | & wsl.exe -d $Distro -- bash $HelperPath list $RepoPath)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not list agent branches for '$RepoPath'."
    }

    $branches = @()
    foreach ($line in $lines) {
        $text = ([string]$line).Trim()
        if (-not $text) {
            continue
        }
        $parts = $text -split '\|'
        if ($parts.Count -ne 4) {
            continue
        }
        $branches += [PSCustomObject]@{
            Name   = $parts[0]
            Branch = $parts[1]
            Locked = ($parts[2] -eq 'yes')
            Ahead  = [int]$parts[3]
        }
    }

    return @($branches)
}

function Get-ClaudeProfiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HelperPath,

        [Parameter(Mandatory = $true)]
        [string]$WslHome
    )

    # Identity and usage come straight out of each profile's own Claude config
    # files, so building this list costs one WSL call and no model calls -
    # "claude -p /usage" is only needed to refresh that cached data.
    $lines = @(Invoke-WslNative { $null | & wsl.exe -d $Distro -- bash $HelperPath accounts $WslHome })
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read the list of Claude accounts."
    }

    $profiles = @()
    foreach ($line in $lines) {
        $text = ([string]$line).Trim()
        if (-not $text) {
            continue
        }

        $parts = $text -split '\|'
        if ($parts.Count -lt 8) {
            continue
        }

        $profiles += [PSCustomObject]@{
            Name        = $parts[0]
            ConfigDir   = $parts[1]
            Email       = $parts[2]
            Org         = $parts[3]
            Plan        = $parts[4]
            SessionPct  = $(if ($parts[5] -match '^\d+$') { [int]$parts[5] } else { -1 })
            WeekPct     = $(if ($parts[6] -match '^\d+$') { [int]$parts[6] } else { -1 })
            FetchedAtMs = $(if ($parts[7] -match '^\d+$') { [double]$parts[7] } else { 0 })
            SignedIn    = ($parts.Count -ge 9 -and $parts[8] -eq "1")
            SeatTier    = $(if ($parts.Count -ge 10) { $parts[9] } else { "" })
            Expired     = ($parts.Count -ge 11 -and $parts[10] -eq "1")
            IsDefault   = ($parts[0] -eq "Default")
        }
    }

    return @($profiles)
}

function Copy-TextToWslFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    $lastSlash = $DestinationPath.LastIndexOf('/')
    if ($lastSlash -le 0) {
        throw "Invalid WSL destination path '$DestinationPath'."
    }

    $destinationDirectory = $DestinationPath.Substring(0, $lastSlash)
    Ensure-WslDirectory -Path $destinationDirectory

    $tempFile = [System.IO.Path]::GetTempFileName()
    try {
        # Linux shell/config files should use LF and no UTF-8 BOM.
        $normalized = $Text.Replace("`r`n", "`n")
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tempFile, $normalized, $utf8NoBom)

        # wsl.exe strips backslashes from arguments it relays to the Linux side
        # (they are consumed as shell escape characters), so a raw Windows path
        # like 'C:\Users\...' arrives at wslpath as 'C:UsersAppData...'.
        # Forward slashes survive the trip and wslpath accepts them fine.
        $tempFileForWsl = $tempFile -replace '\\', '/'
        $wslTempOutput = @($null | & wsl.exe -d $Distro -- wslpath -a -u $tempFileForWsl)
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0 -or $wslTempOutput.Count -eq 0) {
            throw "Could not translate temporary Windows path to WSL."
        }

        $wslTemp = (($wslTempOutput -join "`n").Trim())
        if ([string]::IsNullOrWhiteSpace($wslTemp)) {
            throw "wslpath returned an empty path for the temporary file."
        }

        $null | & wsl.exe -d $Distro -- cp -- $wslTemp $DestinationPath
        if ($LASTEXITCODE -ne 0) {
            throw "Could not copy temporary file to '$DestinationPath'."
        }
    }
    finally {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    }
}

function Install-WslShellRunner {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WslHome
    )

    $runnerPath = "$WslHome/.claude-launcher/run-in-login-shell.sh"

    # This helper is deliberately stored inside WSL.  Windows only passes normal
    # argv values to it; all shell quoting happens on the Linux side.  That avoids
    # the PowerShell -> wsl.exe -> bash -c quoting bugs that caused the earlier
    # blank error and the extra "n" in the project name.
    $runner = @'
#!/usr/bin/env bash
set -e
exec bash -ic 'exec "$@"' bash "$@"
'@

    Copy-TextToWslFile -Text $runner -DestinationPath $runnerPath
    $null | & wsl.exe -d $Distro -- chmod 700 -- $runnerPath
    if ($LASTEXITCODE -ne 0) {
        throw "Could not make '$runnerPath' executable."
    }

    return $runnerPath
}

function Install-WslLauncherHelper {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WslHome
    )

    $helperPath = "$WslHome/.claude-launcher/launcher-helper.sh"

    # Small bash helper for the parts that are native there: reading account
    # identity and cached usage out of Claude's own JSON, parsing
    # "git worktree list --porcelain", ahead-counts, and lock/remove/branch
    # delete. PowerShell only passes plain argv values to it, never a shell
    # string, so nothing here can reintroduce the quoting bugs documented
    # above.
    $helper = @'
#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: launcher-helper.sh <accounts|mark-onboarded|delete-profile|ensure-gitignore|new-project|list|cleanup> ..." >&2
    exit 2
}

# Reads one value out of a Claude JSON config, printing "" for anything
# missing (absent file, no jq, absent key) so callers always get a full row.
json_field() {
    local file="$1"
    local filter="$2"
    if [ ! -f "$file" ]; then
        printf ''
        return 0
    fi
    if ! command -v jq >/dev/null 2>&1; then
        printf ''
        return 0
    fi
    local value
    value="$(jq -r "($filter) // \"\" | tostring" "$file" 2>/dev/null)" || value=""
    if [ "$value" = "null" ]; then
        value=""
    fi
    printf '%s' "${value//|/ }"
}

# Prints 1 when a sign-in is dead: the access token has expired and so has the
# refresh token that would renew it. Claude then fails every request quietly
# while the credentials file - all "signed in" checks for - is still there,
# and the account's plan, tier and usage stop updating. Anything unreadable
# counts as not expired, so a missing jq never flags a working account.
sign_in_expired() {
    local creds="$1"
    local now access refresh
    now="$(date +%s%3N)"
    access="$(json_field "$creds" '.claudeAiOauth.expiresAt')"
    refresh="$(json_field "$creds" '.claudeAiOauth.refreshTokenExpiresAt')"
    if [[ "$access" =~ ^[0-9]+$ && "$refresh" =~ ^[0-9]+$ ]] \
        && [ "$access" -lt "$now" ] && [ "$refresh" -lt "$now" ]; then
        printf '1'
    else
        printf '0'
    fi
}

account_row() {
    local name="$1"
    local dir="$2"
    local config="$dir/.claude.json"
    local creds="$dir/.credentials.json"
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$name" \
        "$dir" \
        "$(json_field "$config" '.oauthAccount.emailAddress')" \
        "$(json_field "$config" '.oauthAccount.organizationName')" \
        "$(json_field "$creds" '.claudeAiOauth.subscriptionType')" \
        "$(json_field "$config" '.cachedUsageUtilization.utilization.five_hour.utilization')" \
        "$(json_field "$config" '.cachedUsageUtilization.utilization.seven_day.utilization')" \
        "$(json_field "$config" '.cachedUsageUtilization.fetchedAtMs')" \
        "$(if [ -s "$creds" ]; then echo 1; else echo 0; fi)" \
        "$(json_field "$config" '.oauthAccount.seatTier')" \
        "$(sign_in_expired "$creds")"
}

cmd="${1:-}"
[ -n "$cmd" ] || usage
shift

case "$cmd" in
    accounts)
        home="${1:-}"
        [ -n "$home" ] || usage
        account_row "Default" "$home/.claude"
        if [ -d "$home/.claude-profiles" ]; then
            for dir in "$home"/.claude-profiles/*; do
                [ -d "$dir" ] || continue
                account_row "$(basename "$dir")" "$dir"
            done
        fi
        ;;

    ensure-gitignore)
        repo="${1:-}"
        [ -n "$repo" ] || usage
        gi="$repo/.gitignore"
        if [ ! -f "$gi" ]; then
            printf '.claude/\n' > "$gi"
        elif ! grep -qxF '.claude/' "$gi"; then
            printf '.claude/\n' >> "$gi"
        fi
        ;;

    new-project)
        # A project the way the rest of this launcher expects one: a git
        # repository with at least one commit (agents are worktrees, and a
        # worktree needs a commit to branch from) and .claude/ ignored.
        # Everything is checked before anything is created, so a refusal
        # leaves nothing half-made behind.
        root="${1:-}"
        name="${2:-}"
        [ -n "$root" ] && [ -n "$name" ] || usage

        case "$name" in
            */*|*\\*|.*|"")
                echo "Refusing: '$name' is not a plain folder name." >&2
                exit 3
                ;;
        esac

        target="$root/$name"
        if [ -e "$target" ]; then
            echo "A folder named '$name' already exists." >&2
            exit 4
        fi
        if ! command -v git >/dev/null 2>&1; then
            echo "git is not installed in this WSL distribution." >&2
            exit 5
        fi
        # Read from "/" so the answer comes from the global config alone and
        # not from whatever repository the current directory happens to be in.
        if [ -z "$(git -C / config --get user.name)" ] || [ -z "$(git -C / config --get user.email)" ]; then
            echo "git has no name and email yet, so it cannot make the first commit. Set them in WSL:" >&2
            echo "  git config --global user.name \"Your Name\"" >&2
            echo "  git config --global user.email you@example.com" >&2
            exit 6
        fi

        mkdir -p -- "$target"
        git -C "$target" init -q
        printf '.claude/\n' > "$target/.gitignore"
        git -C "$target" add .gitignore
        git -C "$target" commit -q -m "Initial commit"
        ;;

    list)
        repo="${1:-}"
        [ -n "$repo" ] || usage
        # Without a commit there can be no worktrees yet, and the HEAD lookup
        # below would fail outright - which used to take the whole launcher
        # down when opening a freshly "git init"-ed project.
        git -C "$repo" rev-parse -q --verify HEAD >/dev/null || exit 0
        prefix="$repo/.claude/worktrees/"
        head="$(git -C "$repo" rev-parse --abbrev-ref HEAD)"

        # git worktree list --porcelain emits blank-line separated blocks:
        #   worktree <path>
        #   HEAD <sha>
        #   branch refs/heads/<name>   (or "detached")
        #   locked [<reason>]          (only present when locked)
        git -C "$repo" worktree list --porcelain | awk -v prefix="$prefix" '
            function flush() {
                if (path != "" && index(path, prefix) == 1) {
                    print path, branch, (locked ? "yes" : "no")
                }
                path = ""; branch = ""; locked = 0
            }
            /^$/ { flush(); next }
            /^worktree / { path = substr($0, 10) }
            /^branch /   { b = substr($0, 8); sub(/^refs\/heads\//, "", b); branch = b }
            /^locked/    { locked = 1 }
            END { flush() }
        ' | while IFS=' ' read -r path branch locked; do
            name="$(basename "$path")"
            ahead="$(git -C "$repo" rev-list --count "$head..$branch" 2>/dev/null || echo 0)"
            printf '%s|%s|%s|%s\n' "$name" "$branch" "$locked" "$ahead"
        done
        ;;

    cleanup)
        repo="${1:-}"
        name="${2:-}"
        [ -n "$repo" ] && [ -n "$name" ] || usage
        deleteBranch=0
        if [ "${3:-}" = "--delete-branch" ]; then
            deleteBranch=1
        fi

        path="$repo/.claude/worktrees/$name"
        branch="worktree-$name"

        git -C "$repo" worktree unlock -- "$path" 2>/dev/null || true
        git -C "$repo" worktree remove -- "$path"

        if [ "$deleteBranch" -eq 1 ]; then
            git -C "$repo" branch -D -- "$branch"
        fi
        ;;

    mark-onboarded)
        # A fresh CLAUDE_CONFIG_DIR has valid credentials but no
        # "hasCompletedOnboarding" flag, so Claude runs its first-run wizard -
        # which includes the "how do you want to log in" screen and reads as
        # though the account were not authorised at all. The account is fine;
        # only the flag is missing. Writing it here keeps every profile this
        # launcher creates from asking again.
        dir="${1:-}"
        version="${2:-}"
        [ -n "$dir" ] || usage
        config="$dir/.claude.json"

        [ -f "$config" ] || printf '{}' > "$config"

        # jq is the normal path; python3 is the fallback so a distro without
        # jq still gets a correctly merged file rather than a clobbered one.
        tmp="$config.tmp.$$"
        if command -v jq >/dev/null 2>&1; then
            jq --arg v "$version" \
                '.hasCompletedOnboarding = true
                 | if $v == "" then . else .lastOnboardingVersion = $v end' \
                "$config" > "$tmp" 2>/dev/null || { rm -f "$tmp"; exit 0; }
        elif command -v python3 >/dev/null 2>&1; then
            python3 - "$config" "$tmp" "$version" <<'PYEOF' || { rm -f "$tmp"; exit 0; }
import json, sys
src, dst, version = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src) as fh:
    data = json.load(fh)
data["hasCompletedOnboarding"] = True
if version:
    data["lastOnboardingVersion"] = version
with open(dst, "w") as fh:
    json.dump(data, fh, indent=2)
PYEOF
        else
            exit 0
        fi

        chmod --reference="$config" "$tmp" 2>/dev/null || chmod 600 "$tmp"
        mv -- "$tmp" "$config"
        ;;

    delete-profile)
        # Removing an account means deleting its isolated config directory.
        # The guards below matter more than the deletion itself: this runs
        # "rm -rf" against a path built from a name, so every way that name
        # could point somewhere else is closed off first, and the Default
        # account - the launcher's own ~/.claude, holding your settings,
        # project history and skills - is refused outright.
        home="${1:-}"
        name="${2:-}"
        safe="${3:-}"
        [ -n "$home" ] && [ -n "$name" ] || usage

        case "$name" in
            Default)
                echo "Refusing: the Default account cannot be deleted." >&2
                exit 3
                ;;
            */*|*\\*|.|..|"")
                echo "Refusing: '$name' is not a plain profile name." >&2
                exit 3
                ;;
        esac

        root="$home/.claude-profiles"
        target="$root/$name"

        if [ -L "$target" ]; then
            echo "Refusing: '$target' is a symlink." >&2
            exit 3
        fi
        if [ ! -d "$target" ]; then
            echo "No such profile directory: $target" >&2
            exit 4
        fi

        # Belt and braces: resolve both paths and require the profile to sit
        # directly inside .claude-profiles, so nothing that slipped past the
        # name check above can reach outside it.
        realRoot="$(cd "$root" && pwd -P)"
        realTarget="$(cd "$target" && pwd -P)"
        if [ "$realTarget" = "$realRoot" ] || [ "$(dirname "$realTarget")" != "$realRoot" ]; then
            echo "Refusing: '$target' resolves outside $root." >&2
            exit 3
        fi

        rm -rf -- "$realTarget"

        # The generated .code-workspace files name their account, so the ones
        # belonging to this profile would otherwise linger and reopen a config
        # directory that no longer exists.
        if [ -n "$safe" ] && [ -d "$home/.claude-launcher/workspaces" ]; then
            find "$home/.claude-launcher/workspaces" -maxdepth 1 -type f \
                -name "*--claude-$safe.code-workspace" -delete 2>/dev/null || true
        fi
        ;;

    *)
        usage
        ;;
esac
'@

    Copy-TextToWslFile -Text $helper -DestinationPath $helperPath
    $null | & wsl.exe -d $Distro -- chmod 700 -- $helperPath
    if ($LASTEXITCODE -ne 0) {
        throw "Could not make '$helperPath' executable."
    }

    # Leftover from the previous name of this helper.
    $null | & wsl.exe -d $Distro -- rm -f -- "$WslHome/.claude-launcher/agent-branches.sh"

    return $helperPath
}

function Set-ClaudeOnboarded {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HelperPath,

        [Parameter(Mandatory = $true)]
        [string]$RunnerPath,

        [Parameter(Mandatory = $true)]
        [string]$ConfigDir
    )

    # Credentials living in an isolated CLAUDE_CONFIG_DIR are enough to be
    # signed in, but not enough to skip Claude's first-run wizard: without
    # "hasCompletedOnboarding" it opens on the login-method screen, which
    # looks exactly like the account never having been authorised. Marking it
    # here - once per account selection, before anything is launched - is what
    # keeps every profile this launcher manages from asking again.
    #
    # Best effort on purpose: a failure here only brings the wizard back, so
    # it must never take the launcher down with it.
    $version = ""
    try {
        $versionOutput = @($null | & wsl.exe -d $Distro -- env "CLAUDE_CONFIG_DIR=$ConfigDir" `
                bash $RunnerPath claude --version 2>$null)
        if ($LASTEXITCODE -eq 0 -and $versionOutput.Count -gt 0) {
            $version = ([string]$versionOutput[0]).Trim().Split(" ")[0]
        }
    }
    catch {
        $version = ""
    }

    try {
        Invoke-WslNative {
            $null | & wsl.exe -d $Distro -- bash $HelperPath mark-onboarded $ConfigDir $version *> $null
        }
    }
    catch {
        # Ignore - see above.
    }
}

function Invoke-ClaudeLogin {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunnerPath,

        [Parameter(Mandatory = $true)]
        [string]$ConfigDir,

        [string]$Email = ""
    )

    Ensure-WslDirectory -Path $ConfigDir

    Write-Host ""
    Write-Host "Starting Claude login in WSL..." -ForegroundColor Cyan
    Write-Host "Finish the Anthropic login in your browser."
    Write-Host ""

    $wslArgs = @(
        "-d", $Distro,
        "--",
        "env", "CLAUDE_CONFIG_DIR=$ConfigDir",
        "bash", $RunnerPath,
        "claude", "auth", "login"
    )

    if (-not [string]::IsNullOrWhiteSpace($Email)) {
        $wslArgs += "--email"
        $wslArgs += $Email
    }

    # Interactive on purpose: this one needs the real console, since you may
    # have to answer prompts while finishing the login in the browser. Both
    # callers wrap this function in "[void](...)", which is a capture - see
    # Start-WslInteractive for why that has to stay off the native-command
    # path.
    $exitCode = Start-WslInteractive -WslArguments $wslArgs

    if ($exitCode -ne 0) {
        Write-Host ""
        Write-Host ("Claude login exited with code {0}." -f $exitCode) -ForegroundColor Yellow
        Write-Host "The profile was kept; you can retry login later."
        return $false
    }

    return $true
}

function Invoke-ClaudeUsageRefresh {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunnerPath,

        [Parameter(Mandatory = $true)]
        [string]$ConfigDir
    )

    # Asking Claude for "/usage" is what refreshes the utilization block this
    # launcher then reads straight out of the profile's own .claude.json, so
    # the output itself is discarded - capturing it also keeps a transient
    # spinner from being half-painted into this console. The detached stdin
    # matters here beyond type-ahead: Claude otherwise spends several seconds
    # waiting on input that is never coming.
    [void](Invoke-WslNative {
            $null | & wsl.exe -d $Distro -- env "CLAUDE_CONFIG_DIR=$ConfigDir" bash $RunnerPath `
                claude -p "/usage" --model claude-haiku-4-5-20251001 2>&1
        })

    return ($LASTEXITCODE -eq 0)
}

function Invoke-ClaudeAgentBootstrap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunnerPath,

        [Parameter(Mandatory = $true)]
        [string]$ConfigDir,

        [Parameter(Mandatory = $true)]
        [string]$RepoPath,

        [string]$AgentName = ""
    )

    # A cheap, tool-free reply is enough to make "claude -w" materialize the
    # worktree/branch; the real work happens once the user is actually in it.
    # "env --chdir" sets the Linux-side working directory directly - relying
    # on PowerShell's own cwd would not reach the WSL process at all.
    $wslArgs = @(
        "-d", $Distro,
        "--",
        "env", "--chdir=$RepoPath", "CLAUDE_CONFIG_DIR=$ConfigDir",
        "bash", $RunnerPath,
        "claude", "-p", "Reply with OK only, do not use any tools.",
        "--model", "claude-haiku-4-5-20251001",
        "-w"
    )
    if ($AgentName) {
        $wslArgs += $AgentName
    }

    Invoke-WslNative { $null | & wsl.exe @wslArgs *> $null }
    return ($LASTEXITCODE -eq 0)
}

function Invoke-ClaudeMergeSession {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunnerPath,

        [Parameter(Mandatory = $true)]
        [string]$ConfigDir,

        [Parameter(Mandatory = $true)]
        [string]$RepoPath,

        [Parameter(Mandatory = $true)]
        [string]$BaseBranch,

        [Parameter(Mandatory = $true)]
        [string]$AgentBranch
    )

    $prompt = "You are merging the branch '$AgentBranch' into '$BaseBranch' in the " +
        "repository at $RepoPath (already checked out on '$BaseBranch'). Steps: " +
        "1) Run git merge $AgentBranch. " +
        "2) If there are conflicts, resolve them by reading both sides' diffs and " +
        "commit messages to understand intent - do not guess blindly. " +
        "3) Run any existing build/lint/test commands you can find in this project " +
        "to sanity-check the result. " +
        "4) If anything is ambiguous, risky, or you are not confident the " +
        "resolution is correct, stop and ask me before proceeding. " +
        "5) Once merged and verified, give me a concise summary of what was merged " +
        "and any conflicts you resolved. " +
        "Do not delete the '$AgentBranch' branch or its worktree yourself - that is " +
        "handled separately after this session."

    Write-Host ""
    Write-Host ("Starting merge session for '{0}' -> '{1}'..." -f $AgentBranch, $BaseBranch) -ForegroundColor Cyan
    Write-Host ""

    # Interactive on purpose: this is a real Claude session you talk to, so it
    # needs the console's own stdin *and* stdout. Launched through
    # Start-WslInteractive rather than "& wsl.exe" because the caller captures
    # this function's return value ("$merged = Invoke-ClaudeMergeSession ..."),
    # which would otherwise put a pipe on claude's stdout and drop it into
    # --print mode.
    $exitCode = Start-WslInteractive -WslArguments @(
        "-d", $Distro,
        "--",
        "env", "--chdir=$RepoPath", "CLAUDE_CONFIG_DIR=$ConfigDir",
        "bash", $RunnerPath,
        "claude", "--", $prompt
    )
    return ($exitCode -eq 0)
}

function Invoke-ClaudeConsoleSession {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunnerPath,

        [Parameter(Mandatory = $true)]
        [string]$ConfigDir,

        [Parameter(Mandatory = $true)]
        [string]$FolderPath
    )

    Write-Host ""
    Write-Host ("Starting Claude Code console in '{0}'..." -f $FolderPath) -ForegroundColor Cyan
    Write-Host ""

    # Interactive on purpose, same as the merge session above: this is a real
    # Claude session you talk to directly in this console, no VS Code involved.
    # Launched through Start-WslInteractive - see the comment there for why
    # "& wsl.exe" cannot reach the console from this far down the menu chain.
    $exitCode = Start-WslInteractive -WslArguments @(
        "-d", $Distro,
        "--",
        "env", "--chdir=$FolderPath", "CLAUDE_CONFIG_DIR=$ConfigDir",
        "bash", $RunnerPath,
        "claude"
    )
    return ($exitCode -eq 0)
}

function New-ClaudeProfile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WslHome,

        [Parameter(Mandatory = $true)]
        [string]$RunnerPath
    )

    while ($true) {
        Clear-HostSafe
        Write-Host "Add Claude account" -ForegroundColor Cyan
        Write-Host "------------------"
        Write-Host ""
        Write-Host "This creates an isolated Claude Code config directory in WSL."
        Write-Host "Example profile names: personal-2, work, max-2"
        Write-Host ""

        $name = (Read-Host "Profile name (blank = cancel)").Trim()
        if (-not $name) {
            return $null
        }

        $name = $name -replace '\s+', '-'
        if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
            Write-Host ""
            Write-Host "Use letters, numbers, dots, underscores or dashes only." -ForegroundColor Yellow
            Wait-AnyKey -Message "Press any key to try again"
            continue
        }

        $configDir = "$WslHome/.claude-profiles/$name"
        if (Test-WslDirectory -Path $configDir) {
            Write-Host ""
            Write-Host "A profile with this name already exists." -ForegroundColor Yellow
            Wait-AnyKey -Message "Press any key to try again"
            continue
        }

        Ensure-WslDirectory -Path $configDir
        $null | & wsl.exe -d $Distro -- chmod 700 -- $configDir

        $email = (Read-Host "Anthropic email (optional; blank lets browser choose)").Trim()
        if (Read-ConfirmKey -Question "Sign in to this account now?" -DefaultYes $true) {
            [void](Invoke-ClaudeLogin -RunnerPath $RunnerPath -ConfigDir $configDir -Email $email)
        }

        return [PSCustomObject]@{
            Name      = $name
            ConfigDir = $configDir
            IsDefault = $false
        }
    }
}

function Write-ColoredText {
    param(
        [AllowEmptyString()]
        [string]$Text,

        [string]$Color = ""
    )

    # The console palette has no orange, so "Orange" is drawn with a
    # 256-colour VT code - the same VT support Clear-HostSafe relies on.
    # Redirected output gets the nearest palette colour instead of raw codes.
    if ($Color -eq "Orange") {
        if ([Console]::IsOutputRedirected) {
            Write-Host $Text -NoNewline -ForegroundColor DarkYellow
        }
        else {
            Write-Host ("{0}[38;5;208m{1}{0}[0m" -f [char]27, $Text) -NoNewline
        }
        return
    }

    if (-not $Color) {
        $Color = "DarkGray"
    }
    Write-Host $Text -NoNewline -ForegroundColor $Color
}

function Show-PagedMenu {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,

        [string]$Subtitle = "",

        [array]$Items = @(),

        # Extra single-key actions, as objects with Key and Label.
        [array]$Commands = @(),

        [string]$EmptyText = "(nothing here yet)",

        [int]$StartPage = 0
    )

    # Ten entries per page so every row has its own digit: 1-9 then 0.
    $pageSize = 10
    $page = $StartPage

    while ($true) {
        $pageCount = 1
        if ($Items.Count -gt 0) {
            $pageCount = [int][Math]::Ceiling($Items.Count / [double]$pageSize)
        }
        if ($page -ge $pageCount) { $page = 0 }
        if ($page -lt 0) { $page = $pageCount - 1 }

        $start = $page * $pageSize
        $end = [Math]::Min($start + $pageSize, $Items.Count)

        Clear-HostSafe
        Write-Host $Title -ForegroundColor Cyan
        Write-Host ("-" * $Title.Length) -ForegroundColor Cyan
        if ($Subtitle) {
            Write-Host $Subtitle -ForegroundColor DarkGray
        }
        Write-Host ""

        if ($Items.Count -eq 0) {
            Write-Host $EmptyText -ForegroundColor DarkGray
            Write-Host ""
        }

        for ($i = $start; $i -lt $end; $i++) {
            $item = $Items[$i]
            $keyLabel = [string]((($i - $start) + 1) % 10)

            Write-Host ("  [{0}] " -f $keyLabel) -NoNewline -ForegroundColor White
            Write-Host $item.Text

            if ($item.PSObject.Properties['Segments'] -and $item.Segments) {
                Write-Host "      " -NoNewline
                foreach ($segment in $item.Segments) {
                    Write-ColoredText -Text $segment.Text -Color $segment.Color
                }
                Write-Host ""
            }
        }

        Write-Host ""
        if ($pageCount -gt 1) {
            Write-Host ("  [ and ]  page {0} of {1}" -f ($page + 1), $pageCount) -ForegroundColor DarkGray
        }
        foreach ($command in $Commands) {
            Write-Host ("  [{0}] " -f $command.Key) -NoNewline -ForegroundColor White
            Write-Host $command.Label -ForegroundColor DarkGray
        }

        Write-Host ""
        Write-Host "  press a key" -ForegroundColor DarkGray

        $key = Read-MenuKey

        if ($key -eq "]") { $page++; continue }
        if ($key -eq "[") { $page--; continue }

        if ($key -eq "ENTER") {
            if ($end -gt $start) {
                return [PSCustomObject]@{ Kind = "Item"; Index = $start; Page = $page }
            }
            continue
        }

        if ($key -match '^[0-9]$') {
            $slot = [int]$key
            if ($slot -eq 0) { $slot = 10 }
            $index = $start + ($slot - 1)
            if ($index -lt $end) {
                return [PSCustomObject]@{ Kind = "Item"; Index = $index; Page = $page }
            }
            continue
        }

        foreach ($command in $Commands) {
            if ($key -eq ([string]$command.Key).ToUpperInvariant()) {
                return [PSCustomObject]@{ Kind = "Command"; Key = $key; Page = $page }
            }
        }
    }
}

function Show-Help {
    Clear-HostSafe
    Write-Host "Switchboard - quick guide" -ForegroundColor Cyan
    Write-Host "-------------------------" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "1. Pick a Claude account. Each has its own sign-in and settings in WSL;"
    Write-Host "   'Default' is ~/.claude. N adds an account, D deletes one, U refreshes usage."
    Write-Host ("2. Pick a project - every folder inside ~/{0}." -f $ProjectsRoot)
    Write-Host "   N on the projects screen creates a new one, ready for agents."
    Write-Host "3. In a project:"
    Write-Host "     Open a new agent         own git branch and folder, so agents work in parallel"
    Write-Host "     Resume an agent          reopen one in VS Code"
    Write-Host "     Merge / delete agents    Claude merges finished work back, or discard it"
    Write-Host "     Open the project itself  plain VS Code, no branch"
    Write-Host ""
    # Switchboard reads these straight from each account's own Claude files
    # (oauthAccount.seatTier, claudeAiOauth.subscriptionType, the cached usage
    # block); Claude Code is what refreshes them, as described here.
    Write-Host "Plan, tier and usage" -ForegroundColor Cyan
    Write-Host "  Shown as Claude Code last saved them for each account. Claude refetches the plan"
    Write-Host "  and tier when it renews an account's sign-in, and on start once they are over a"
    Write-Host "  day old. U starts Claude for every account, so it fetches fresh usage and brings"
    Write-Host "  an old tier up to date too. When a sign-in expires (shown in orange), all of this"
    Write-Host "  stays frozen until you select the account and sign in again."
    Write-Host ""
    Write-Host "If something is missing" -ForegroundColor Cyan
    Write-Host "  No projects listed         Press N on the projects screen, or clone a"
    Write-Host ("                             repository into ~/{0}." -f $ProjectsRoot)
    Write-Host "  No 'Open a new agent'      Agents need a git repository with a commit: 'git init'"
    Write-Host "                             and a first commit there, or start the project with N."
    Write-Host "  'not signed in'/'expired'  Select the account to sign in."
    Write-Host "  VS Code does not open      'code .' must work in WSL (needs VS Code's WSL extension)."
    Write-Host "  Wrong distribution/folder  Run Setup-Switchboard.bat."
    Wait-AnyKey -Message "Press any key to go back"
}

function New-Project {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WslHome,

        [Parameter(Mandatory = $true)]
        [string]$HelperPath
    )

    Write-Host ""
    $name = (Read-PromptLine -Prompt "New project name (blank = cancel)").Trim()
    if (-not $name) {
        return $null
    }

    $name = $name -replace '\s+', '-'
    if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        Write-Host ""
        Write-Host "Use letters, numbers, dots, underscores or dashes only." -ForegroundColor Yellow
        Wait-AnyKey -Message "Press any key to return to the menu"
        return $null
    }

    $output = @(Invoke-WslNative {
            $null | & wsl.exe -d $Distro -- bash $HelperPath new-project "$WslHome/$ProjectsRoot" $name 2>&1
        })

    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host ("Could not create project '{0}'." -f $name) -ForegroundColor Red
        foreach ($line in $output) {
            if (([string]$line).Trim()) {
                Write-Host ("  {0}" -f ([string]$line).Trim()) -ForegroundColor DarkGray
            }
        }
        Wait-AnyKey -Message "Press any key to return to the menu"
        return $null
    }

    Write-Host ""
    Write-Host ("Created ~/{0}/{1} - a git repository with a first commit, ready for agents." -f $ProjectsRoot, $name) -ForegroundColor Green
    Wait-AnyKey -Message "Press any key to open it"
    return $name
}

function Get-FriendlyTier {
    param([string]$SeatTier)

    if ([string]::IsNullOrWhiteSpace($SeatTier)) {
        return ""
    }

    # Title-case each underscore-separated word (e.g. "team_tier_1" ->
    # "Team Tier 1") instead of hardcoding a lookup table of known tier
    # names, so this keeps reading correctly if Anthropic adds new tiers.
    $words = $SeatTier -split '_' | ForEach-Object {
        if ($_.Length -eq 0) { $_ }
        elseif ($_ -match '^\d+$') { $_ }
        else { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1).ToLowerInvariant() }
    }
    return ($words -join ' ')
}

function New-AccountMenuItem {
    param(
        [Parameter(Mandatory = $true)]
        $Profile,

        [bool]$ShowUsage = $true
    )

    $text = [string]$Profile.Name
    if ($Profile.Email) {
        $text = "{0}  -  {1}" -f $Profile.Name, $Profile.Email
    }
    if ($Profile.Plan) {
        $text = "{0} ({1})" -f $text, $Profile.Plan
    }

    $segments = @()
    if (-not $Profile.SignedIn) {
        # No .credentials.json in this config dir, so Claude would come up signed
        # out - in the console and in the VS Code extension alike.
        $segments += [PSCustomObject]@{ Text = "not signed in - select to sign in now"; Color = "Yellow" }
        return [PSCustomObject]@{
            Text     = $text
            Segments = $segments
        }
    }

    if ($Profile.Expired) {
        # Whatever usage and tier are cached stopped updating when the
        # sign-in died, so showing them would only mislead.
        $segments += [PSCustomObject]@{ Text = "sign-in expired - select to sign in again"; Color = "Orange" }
        return [PSCustomObject]@{
            Text     = $text
            Segments = $segments
        }
    }

    if (-not $ShowUsage) {
        return [PSCustomObject]@{
            Text     = $text
            Segments = $segments
        }
    }

    if ($Profile.SessionPct -ge 0 -or $Profile.WeekPct -ge 0) {
        if ($Profile.SessionPct -ge 0) {
            $segments += [PSCustomObject]@{ Text = "session "; Color = "DarkGray" }
            $segments += [PSCustomObject]@{
                Text  = (Get-UsageBar -Percent $Profile.SessionPct)
                Color = (Get-UsageColor -Percent $Profile.SessionPct)
            }
            $segments += [PSCustomObject]@{ Text = ("{0,3}%   " -f $Profile.SessionPct); Color = "DarkGray" }
        }
        if ($Profile.WeekPct -ge 0) {
            $segments += [PSCustomObject]@{ Text = "week "; Color = "DarkGray" }
            $segments += [PSCustomObject]@{
                Text  = (Get-UsageBar -Percent $Profile.WeekPct)
                Color = (Get-UsageColor -Percent $Profile.WeekPct)
            }
            $segments += [PSCustomObject]@{ Text = ("{0,3}%" -f $Profile.WeekPct); Color = "DarkGray" }
        }

        $age = Format-UsageAge -FetchedAtMs $Profile.FetchedAtMs
        if ($age) {
            $segments += [PSCustomObject]@{ Text = ("   {0}" -f $age); Color = "DarkGray" }
        }
    }
    else {
        $segments += [PSCustomObject]@{ Text = "no usage data yet - press U to refresh"; Color = "DarkGray" }
    }

    # Seat tier (e.g. "Team Standard", "Team Tier 1") - read straight out of
    # the profile's own cached oauth account info, same as everything else
    # above, so it is always current as of this run with no extra network
    # call.
    $tier = Get-FriendlyTier -SeatTier ([string]$Profile.SeatTier)
    if ($tier) {
        $segments += [PSCustomObject]@{ Text = ("  |  {0}" -f $tier); Color = "Magenta" }
    }

    return [PSCustomObject]@{
        Text     = $text
        Segments = $segments
    }
}

function Update-StaleUsage {
    param(
        [Parameter(Mandatory = $true)]
        [array]$Profiles,

        [Parameter(Mandatory = $true)]
        [string]$RunnerPath,

        [switch]$Force
    )

    # Claude keeps this utilization block fresh on its own while an account is
    # in use, so a refresh is only worth its few seconds when the cached data
    # is actually old. Accounts that fail once are not retried for the rest of
    # this run, so a signed-out profile cannot stall every menu redraw.
    $staleAfterMs = 15 * 60 * 1000
    $nowMs = Get-EpochMs
    $refreshed = $false

    foreach ($profileEntry in $Profiles) {
        $configDir = [string]$profileEntry.ConfigDir

        # Not even U helps here: without a working sign-in the refresh can
        # only fail, after a few seconds of trying, on every redraw.
        if (-not $profileEntry.SignedIn -or $profileEntry.Expired) {
            continue
        }

        if (-not $Force) {
            if ($script:UsageRefreshTried.ContainsKey($configDir)) {
                continue
            }
            if ($profileEntry.FetchedAtMs -gt 0 -and ($nowMs - $profileEntry.FetchedAtMs) -lt $staleAfterMs) {
                continue
            }
        }

        $script:UsageRefreshTried[$configDir] = $true
        Write-Host ("Refreshing usage for '{0}'..." -f $profileEntry.Name) -ForegroundColor DarkGray
        [void](Invoke-ClaudeUsageRefresh -RunnerPath $RunnerPath -ConfigDir $configDir)
        $refreshed = $true
    }

    return $refreshed
}

function Remove-ClaudeProfile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WslHome,

        [Parameter(Mandatory = $true)]
        [string]$HelperPath,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Profiles
    )

    # The Default account is this launcher's own ~/.claude - settings, project
    # history, skills, the lot - so it is never offered for deletion here. The
    # helper refuses it a second time on the WSL side.
    $deletable = @($Profiles | Where-Object { -not $_.IsDefault })
    if ($deletable.Count -eq 0) {
        Write-Host ""
        Write-Host "Only the Default account exists, and it cannot be deleted." -ForegroundColor Yellow
        Wait-AnyKey -Message "Press any key to return to the menu"
        return $null
    }

    $items = @()
    foreach ($entry in $deletable) {
        $detail = if ($entry.Email) { [string]$entry.Email } else { "not signed in" }
        $items += [PSCustomObject]@{
            Text     = [string]$entry.Name
            Segments = @([PSCustomObject]@{ Text = $detail; Color = "DarkGray" })
        }
    }

    $result = Show-PagedMenu -Title "Delete an Anthropic account" `
        -Subtitle "Removes the account's local config directory in WSL." `
        -Items $items `
        -Commands @([PSCustomObject]@{ Key = "B"; Label = "back, delete nothing" })

    if ($result.Kind -ne "Item") {
        return $null
    }

    $target = $deletable[$result.Index]
    $targetName = [string]$target.Name

    $heading = "Delete account '{0}'" -f $targetName

    Clear-HostSafe
    Write-Host $heading -ForegroundColor Red
    Write-Host ("-" * $heading.Length) -ForegroundColor Red
    Write-Host ""
    if ($target.Email) {
        Write-Host ("  signed in as   {0}" -f $target.Email)
    }
    Write-Host ("  config dir     {0}" -f $target.ConfigDir)
    Write-Host ""
    Write-Host "That directory holds this account's credentials, settings, project"
    Write-Host "history and session transcripts. The VS Code workspace files this"
    Write-Host "launcher generated for the account are removed with it."
    Write-Host ""
    Write-Host "Your Anthropic account itself is not touched - this only signs it"
    Write-Host "out of this machine. [N] on the accounts menu adds it back."
    Write-Host ""
    Write-Host "This cannot be undone." -ForegroundColor Yellow
    Write-Host ""

    $typed = Read-PromptLine -Prompt ("Type {0} to confirm (blank = cancel)" -f $targetName)
    if ($null -eq $typed) {
        $typed = ""
    }
    $typed = $typed.Trim()

    if (-not $typed) {
        Write-Host ""
        Write-Host "Cancelled - nothing was deleted." -ForegroundColor DarkGray
        Wait-AnyKey -Message "Press any key to return to the menu"
        return $null
    }

    # Ordinal, case-sensitive: an account named "work" and one named "Work"
    # are two different directories, and this is the last thing standing
    # between a keypress and an irreversible delete.
    if (-not [string]::Equals($typed, $targetName, [StringComparison]::Ordinal)) {
        Write-Host ""
        Write-Host ("That does not match '{0}' - nothing was deleted." -f $targetName) -ForegroundColor Yellow
        Wait-AnyKey -Message "Press any key to return to the menu"
        return $null
    }

    $configDir = [string]$target.ConfigDir
    $safeName = Get-SafeFilePart -Value $targetName

    Write-Host ""
    Write-Host ("Deleting '{0}'..." -f $targetName) -ForegroundColor Cyan

    $output = @(Invoke-WslNative {
            $null | & wsl.exe -d $Distro -- bash $HelperPath delete-profile $WslHome $targetName $safeName 2>&1
        })

    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host ("Could not delete '{0}' (exit code {1})." -f $targetName, $LASTEXITCODE) -ForegroundColor Red
        foreach ($line in $output) {
            if (([string]$line).Trim()) {
                Write-Host ("  {0}" -f ([string]$line).Trim()) -ForegroundColor DarkGray
            }
        }
        Wait-AnyKey -Message "Press any key to return to the menu"
        return $null
    }

    Write-Host ("Deleted account '{0}'." -f $targetName) -ForegroundColor Green
    Wait-AnyKey -Message "Press any key to return to the menu"
    return $configDir
}

function Show-AccountMenu {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WslHome,

        [Parameter(Mandatory = $true)]
        [string]$RunnerPath,

        [Parameter(Mandatory = $true)]
        [string]$HelperPath,

        # When false, skips the "claude -p /usage" refresh call for every
        # account (the slow part of opening this menu) and leaves usage/tier
        # off each row, so the menu appears as soon as the profiles are read
        # from disk. Pressing "U" always fetches on demand regardless.
        [bool]$LoadUsageInfo = $true
    )

    $page = 0
    $showUsage = $LoadUsageInfo

    while ($true) {
        $profiles = @(Get-ClaudeProfiles -HelperPath $HelperPath -WslHome $WslHome)

        if ($showUsage) {
            if (Update-StaleUsage -Profiles $profiles -RunnerPath $RunnerPath) {
                $profiles = @(Get-ClaudeProfiles -HelperPath $HelperPath -WslHome $WslHome)
            }
        }

        $items = @()
        foreach ($profileEntry in $profiles) {
            $items += (New-AccountMenuItem -Profile $profileEntry -ShowUsage $showUsage)
        }

        $commands = @(
            [PSCustomObject]@{ Key = "N"; Label = "add / sign in another Anthropic account" },
            [PSCustomObject]@{ Key = "D"; Label = "delete an Anthropic account" },
            [PSCustomObject]@{ Key = "U"; Label = "refresh usage now" },
            [PSCustomObject]@{ Key = "H"; Label = "help" },
            [PSCustomObject]@{ Key = "Q"; Label = "quit" }
        )

        $result = Show-PagedMenu -Title "Claude accounts" -Items $items -Commands $commands `
            -EmptyText "No Claude accounts found." -StartPage $page
        $page = $result.Page

        if ($result.Kind -eq "Item") {
            $selected = $profiles[$result.Index]
            if (-not $selected.SignedIn) {
                # Opening VS Code now would hand the extension a config dir with no
                # credentials in it, and Claude would open asking to log in.
                Write-Host ""
                Write-Host ("Account '{0}' is not signed in yet." -f $selected.Name) -ForegroundColor Yellow
                if (Read-ConfirmKey -Question "Sign in to it now?" -DefaultYes $true) {
                    [void](Invoke-ClaudeLogin -RunnerPath $RunnerPath -ConfigDir ([string]$selected.ConfigDir))
                    $script:UsageRefreshTried.Remove([string]$selected.ConfigDir)
                }
                continue
            }
            if ($selected.Expired) {
                # Signing in again writes fresh credentials into the same
                # config dir, so the account keeps its settings and history;
                # the known email steers the browser to the right account.
                Write-Host ""
                Write-ColoredText -Text ("The sign-in for '{0}' has expired." -f $selected.Name) -Color "Orange"
                Write-Host ""
                if (Read-ConfirmKey -Question "Sign in to it again now?" -DefaultYes $true) {
                    [void](Invoke-ClaudeLogin -RunnerPath $RunnerPath -ConfigDir ([string]$selected.ConfigDir) `
                            -Email ([string]$selected.Email))
                    $script:UsageRefreshTried.Remove([string]$selected.ConfigDir)
                }
                continue
            }
            return $selected
        }

        if ($result.Key -eq "Q") {
            return "__QUIT__"
        }

        if ($result.Key -eq "N") {
            $newProfile = New-ClaudeProfile -WslHome $WslHome -RunnerPath $RunnerPath
            if ($null -ne $newProfile) {
                $script:UsageRefreshTried.Remove([string]$newProfile.ConfigDir)
            }
            continue
        }

        if ($result.Key -eq "D") {
            $removed = Remove-ClaudeProfile -WslHome $WslHome -HelperPath $HelperPath -Profiles $profiles
            if ($removed) {
                $script:UsageRefreshTried.Remove([string]$removed)
            }
            continue
        }

        if ($result.Key -eq "U") {
            $showUsage = $true
            [void](Update-StaleUsage -Profiles $profiles -RunnerPath $RunnerPath -Force)
            continue
        }

        if ($result.Key -eq "H") {
            Show-Help
            continue
        }
    }
}

function Get-SafeFilePart {
    param([string]$Value)

    $safe = $Value -replace '[^A-Za-z0-9._-]', '_'
    if (-not $safe) {
        return "item"
    }
    return $safe
}

function New-ClaudeWorkspace {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WslHome,

        [Parameter(Mandatory = $true)]
        [string]$ProjectName,

        [Parameter(Mandatory = $true)]
        $Profile,

        [bool]$ContinueSession = $false,

        # Opens this exact folder instead of the project's own folder - used
        # for agent-branch worktrees, which live elsewhere on disk.
        [string]$FolderPath = "",

        # Distinguishes an agent-branch workspace file from the plain-project
        # one and from other agents of the same project, so they don't clobber
        # each other's .code-workspace file.
        [string]$AgentName = ""
    )

    $projectPath = if ($FolderPath) { $FolderPath } else { "$WslHome/$ProjectsRoot/$ProjectName" }
    $safeProject = Get-SafeFilePart -Value $ProjectName
    $safeProfile = Get-SafeFilePart -Value ([string]$Profile.Name)
    $workspaceFileName = if ($AgentName) {
        "$safeProject--agent-$(Get-SafeFilePart -Value $AgentName)--claude-$safeProfile.code-workspace"
    } else {
        "$safeProject--claude-$safeProfile.code-workspace"
    }
    $workspacePath = "$WslHome/.claude-launcher/workspaces/$workspaceFileName"

    $workspace = [ordered]@{
        folders = @(
            [ordered]@{
                path = $projectPath
            }
        )
        settings = [ordered]@{
            "terminal.integrated.env.linux" = [ordered]@{
                CLAUDE_CONFIG_DIR = [string]$Profile.ConfigDir
            }
            "claudeCode.environmentVariables" = @(
                [ordered]@{
                    name  = "CLAUDE_CONFIG_DIR"
                    value = [string]$Profile.ConfigDir
                }
            )
        }
    }

    if ($ContinueSession) {
        # Resumes the most recent Claude conversation for this folder as soon
        # as the workspace opens. VS Code will ask once per workspace to allow
        # automatic tasks; approving it lets this run without a further prompt
        # on later launches.
        $workspace["tasks"] = [ordered]@{
            version = "2.0.0"
            tasks   = @(
                [ordered]@{
                    label        = "Resume Claude session"
                    type         = "shell"
                    command      = "claude --continue"
                    presentation = [ordered]@{
                        reveal = "always"
                        panel  = "dedicated"
                    }
                    runOptions   = [ordered]@{
                        runOn = "folderOpen"
                    }
                }
            )
        }
    }

    $json = $workspace | ConvertTo-Json -Depth 8
    Copy-TextToWslFile -Text $json -DestinationPath $workspacePath
    return $workspacePath
}

function Open-ClaudeWorkspace {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunnerPath,

        [Parameter(Mandatory = $true)]
        [string]$WorkspacePath,

        [Parameter(Mandatory = $true)]
        [string]$ConfigDir
    )

    # Resolve `code` inside the same interactive WSL shell where it normally works.
    # CLAUDE_CONFIG_DIR is also placed on the VS Code launch process; the workspace
    # file independently configures both integrated terminals and Claude extension.
    $null | & wsl.exe -d $Distro -- env "CLAUDE_CONFIG_DIR=$ConfigDir" bash $RunnerPath code --new-window $WorkspacePath
    return ($LASTEXITCODE -eq 0)
}

function Open-AgentWorkspace {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WslHome,

        [Parameter(Mandatory = $true)]
        [string]$RunnerPath,

        [Parameter(Mandatory = $true)]
        [string]$Project,

        [Parameter(Mandatory = $true)]
        [string]$FolderPath,

        [string]$AgentName = "",

        [Parameter(Mandatory = $true)]
        $Profile,

        # A freshly created agent worktree already has a trivial session
        # transcript, left behind by the "claude -w" bootstrap ping that
        # materialized it - Test-PreviousClaudeSession would find that and
        # ask "Continue previous session?", which would be misleading right
        # after creation. Set by the "new agent" call site only.
        [bool]$SkipContinueCheck = $false
    )

    $continueSession = $false
    if (-not $SkipContinueCheck -and (Test-PreviousClaudeSession -ConfigDir ([string]$Profile.ConfigDir) -ProjectPath $FolderPath)) {
        Write-Host ""
        $subject = if ($AgentName) { "agent '$AgentName'" } else { "'$Project'" }
        $continueSession = Read-ConfirmKey -Question ("A previous Claude session was found for {0}. Continue it?" -f $subject)
    }

    $workspacePath = New-ClaudeWorkspace -WslHome $WslHome -ProjectName $Project -Profile $Profile `
        -ContinueSession $continueSession -FolderPath $FolderPath -AgentName $AgentName

    Write-Host ""
    $openLabel = if ($AgentName) { "agent '$AgentName' for '$Project'" } else { "'$Project'" }
    Write-Host ("Opening {0} with Claude account '{1}'..." -f $openLabel, $Profile.Name) -ForegroundColor Green

    $opened = Open-ClaudeWorkspace -RunnerPath $RunnerPath -WorkspacePath $workspacePath -ConfigDir ([string]$Profile.ConfigDir)
    if (-not $opened) {
        Write-Host ""
        Write-Host "VS Code could not be opened from WSL." -ForegroundColor Red
        Write-Host "Inside WSL, verify that this command works:"
        Write-Host "  code ."
        Wait-AnyKey -Message "Press any key to return to the menu"
        return
    }

    exit 0
}

function New-AgentMenuItem {
    param(
        [Parameter(Mandatory = $true)]
        $Branch,

        [bool]$Selected = $false,

        [bool]$ShowSelection = $false
    )

    $text = [string]$Branch.Name
    if ($ShowSelection) {
        $marker = if ($Selected) { "[x]" } else { "[ ]" }
        $text = "{0} {1}" -f $marker, $Branch.Name
    }

    $state = if ($Branch.Locked) { "in use" } else { "idle" }
    $commits = if ($Branch.Ahead -eq 1) { "1 new commit" } else { "{0} new commits" -f $Branch.Ahead }

    $color = "DarkGray"
    if ($Branch.Ahead -gt 0) {
        $color = "Yellow"
    }

    return [PSCustomObject]@{
        Text     = $text
        Segments = @([PSCustomObject]@{ Text = ("{0}, {1}" -f $state, $commits); Color = $color })
    }
}

function Invoke-AgentCleanupMenu {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunnerPath,

        [Parameter(Mandatory = $true)]
        [string]$HelperPath,

        [Parameter(Mandatory = $true)]
        [string]$RepoPath,

        [Parameter(Mandatory = $true)]
        [string]$Project,

        [Parameter(Mandatory = $true)]
        $Profile
    )

    $selected = @{}
    $page = 0

    while ($true) {
        $branches = @(Get-AgentBranches -HelperPath $HelperPath -RepoPath $RepoPath)
        if ($branches.Count -eq 0) {
            return
        }

        $items = @()
        foreach ($branch in $branches) {
            $items += (New-AgentMenuItem -Branch $branch -Selected ($selected.ContainsKey($branch.Name)) -ShowSelection $true)
        }

        $commands = @(
            [PSCustomObject]@{ Key = "A"; Label = "select / clear all" },
            [PSCustomObject]@{ Key = "M"; Label = "merge selected into the base branch (via Claude)" },
            [PSCustomObject]@{ Key = "D"; Label = "delete selected permanently" },
            [PSCustomObject]@{ Key = "B"; Label = "back" }
        )

        $result = Show-PagedMenu -Title "Merge / delete agents" `
            -Subtitle ("{0}  -  account {1}   (press a number to select)" -f $Project, $Profile.Name) `
            -Items $items -Commands $commands -StartPage $page
        $page = $result.Page

        if ($result.Kind -eq "Item") {
            $name = [string]$branches[$result.Index].Name
            if ($selected.ContainsKey($name)) {
                $selected.Remove($name)
            }
            else {
                $selected[$name] = $true
            }
            continue
        }

        if ($result.Key -eq "B") {
            return
        }

        if ($result.Key -eq "A") {
            if ($selected.Count -eq $branches.Count) {
                $selected = @{}
            }
            else {
                foreach ($branch in $branches) {
                    $selected[[string]$branch.Name] = $true
                }
            }
            continue
        }

        $chosen = @($branches | Where-Object { $selected.ContainsKey([string]$_.Name) })
        if ($chosen.Count -eq 0) {
            Write-Host ""
            Write-Host "Select at least one agent first." -ForegroundColor Yellow
            Wait-AnyKey
            continue
        }

        if ($result.Key -eq "D") {
            foreach ($branch in $chosen) {
                Write-Host ""
                $question = "Discard '{0}'? This permanently deletes unmerged work." -f $branch.Name
                if (Read-ConfirmKey -Question $question) {
                    $null | & wsl.exe -d $Distro -- bash $HelperPath cleanup $RepoPath $branch.Name --delete-branch
                }
            }
            $selected = @{}
            Wait-AnyKey
            continue
        }

        if ($result.Key -eq "M") {
            $baseBranch = Get-GitCurrentBranch -RepoPath $RepoPath

            # One at a time: merging several branches at once makes it much
            # harder to tell which one caused a given conflict.
            foreach ($branch in $chosen) {
                if ($branch.Ahead -eq 0) {
                    Write-Host ""
                    Write-Host ("'{0}' has no new commits - nothing to merge." -f $branch.Name) -ForegroundColor Yellow
                    if (Read-ConfirmKey -Question "Delete it instead?") {
                        $null | & wsl.exe -d $Distro -- bash $HelperPath cleanup $RepoPath $branch.Name --delete-branch
                    }
                    continue
                }

                $merged = Invoke-ClaudeMergeSession -RunnerPath $RunnerPath -ConfigDir ([string]$Profile.ConfigDir) `
                    -RepoPath $RepoPath -BaseBranch $baseBranch -AgentBranch $branch.Branch

                Write-Host ""
                if (-not $merged) {
                    Write-Host ("The merge session for '{0}' exited with an error." -f $branch.Name) -ForegroundColor Yellow
                }

                $question = "Remove '{0}' and its worktree now?" -f $branch.Name
                if (Read-ConfirmKey -Question $question) {
                    $null | & wsl.exe -d $Distro -- bash $HelperPath cleanup $RepoPath $branch.Name --delete-branch
                }
            }

            $selected = @{}
            Wait-AnyKey
            continue
        }
    }
}

function Invoke-ProjectMenu {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WslHome,

        [Parameter(Mandatory = $true)]
        [string]$RunnerPath,

        [Parameter(Mandatory = $true)]
        [string]$HelperPath,

        [Parameter(Mandatory = $true)]
        [string]$Project,

        [Parameter(Mandatory = $true)]
        $Profile
    )

    $repoPath = "$WslHome/$ProjectsRoot/$Project"
    $page = 0

    while ($true) {
        $isGitRepo = Test-GitRepo -RepoPath $repoPath
        $hasCommits = $false
        $agentBranches = @()
        if ($isGitRepo) {
            $null | & wsl.exe -d $Distro -- bash $HelperPath ensure-gitignore $repoPath
            $hasCommits = Test-GitHasCommits -RepoPath $repoPath
            if ($hasCommits) {
                $agentBranches = @(Get-AgentBranches -HelperPath $HelperPath -RepoPath $repoPath)
            }
        }

        $actions = @()
        $items = @()

        if ($isGitRepo -and $hasCommits) {
            $actions += "new"
            $items += [PSCustomObject]@{
                Text     = "Open a new agent"
                Segments = @([PSCustomObject]@{ Text = "its own branch and worktree"; Color = "DarkGray" })
            }

            if ($agentBranches.Count -gt 0) {
                $actions += "resume"
                $items += [PSCustomObject]@{
                    Text     = "Resume an agent"
                    Segments = @([PSCustomObject]@{
                            Text  = ("{0} open" -f $agentBranches.Count)
                            Color = "DarkGray"
                        })
                }

                $actions += "cleanup"
                $items += [PSCustomObject]@{
                    Text     = "Merge / delete agents"
                    Segments = @([PSCustomObject]@{ Text = "fold finished work back, or discard it"; Color = "DarkGray" })
                }
            }
        }

        $actions += "plain"
        $items += [PSCustomObject]@{
            Text     = "Open the project itself"
            Segments = @([PSCustomObject]@{ Text = "no branch, no worktree"; Color = "DarkGray" })
        }

        $subtitle = "account {0}" -f $Profile.Name
        if (-not $isGitRepo) {
            $subtitle = "{0}   (not a git repository - agents need git, see H on the projects screen)" -f $subtitle
        }
        elseif (-not $hasCommits) {
            $subtitle = "{0}   (no commits yet - agents need at least one)" -f $subtitle
        }

        $commands = @(
            [PSCustomObject]@{ Key = "B"; Label = "back to projects" },
            [PSCustomObject]@{ Key = "Q"; Label = "quit" }
        )

        $result = Show-PagedMenu -Title $Project -Subtitle $subtitle -Items $items -Commands $commands -StartPage $page
        $page = $result.Page

        if ($result.Kind -eq "Command") {
            if ($result.Key -eq "Q") { return "__QUIT__" }
            if ($result.Key -eq "B") { return $null }
            continue
        }

        $action = $actions[$result.Index]

        if ($action -eq "plain") {
            Open-AgentWorkspace -WslHome $WslHome -RunnerPath $RunnerPath -Project $Project `
                -FolderPath $repoPath -AgentName "" -Profile $Profile
            continue
        }

        if ($action -eq "new") {
            Write-Host ""
            $label = (Read-Host "Name for this agent (Enter = pick one for me)").Trim()

            Write-Host ""
            Write-Host "Creating agent..." -ForegroundColor Cyan

            $beforeNames = @((Get-AgentBranches -HelperPath $HelperPath -RepoPath $repoPath) | ForEach-Object { $_.Name })
            $created = Invoke-ClaudeAgentBootstrap -RunnerPath $RunnerPath -ConfigDir ([string]$Profile.ConfigDir) `
                -RepoPath $repoPath -AgentName $label
            if (-not $created) {
                Write-Host ""
                Write-Host "Could not create the agent." -ForegroundColor Red
                Wait-AnyKey -Message "Press any key to return to the menu"
                continue
            }

            $afterList = @(Get-AgentBranches -HelperPath $HelperPath -RepoPath $repoPath)
            $newEntry = $afterList | Where-Object { $beforeNames -notcontains $_.Name } | Select-Object -First 1
            if (-not $newEntry -and $label) {
                $newEntry = $afterList | Where-Object { $_.Name -eq $label } | Select-Object -First 1
            }
            if (-not $newEntry) {
                Write-Host ""
                Write-Host "Could not find the new agent after creating it." -ForegroundColor Red
                Wait-AnyKey -Message "Press any key to return to the menu"
                continue
            }

            $agentPath = "$repoPath/.claude/worktrees/$($newEntry.Name)"
            Copy-ProjectMemory -ConfigDir ([string]$Profile.ConfigDir) -FromPath $repoPath -ToPath $agentPath

            Open-AgentWorkspace -WslHome $WslHome -RunnerPath $RunnerPath -Project $Project `
                -FolderPath $agentPath -AgentName $newEntry.Name -Profile $Profile -SkipContinueCheck $true
            continue
        }

        if ($action -eq "resume") {
            $resumeItems = @()
            foreach ($branch in $agentBranches) {
                $resumeItems += (New-AgentMenuItem -Branch $branch)
            }

            $resumeCommands = @([PSCustomObject]@{ Key = "B"; Label = "back" })
            $resumeResult = Show-PagedMenu -Title "Resume an agent" `
                -Subtitle ("{0}  -  account {1}" -f $Project, $Profile.Name) `
                -Items $resumeItems -Commands $resumeCommands

            if ($resumeResult.Kind -ne "Item") {
                continue
            }

            $entry = $agentBranches[$resumeResult.Index]
            Open-AgentWorkspace -WslHome $WslHome -RunnerPath $RunnerPath -Project $Project `
                -FolderPath "$repoPath/.claude/worktrees/$($entry.Name)" -AgentName $entry.Name -Profile $Profile
            continue
        }

        if ($action -eq "cleanup") {
            Invoke-AgentCleanupMenu -RunnerPath $RunnerPath -HelperPath $HelperPath -RepoPath $repoPath `
                -Project $Project -Profile $Profile
            continue
        }
    }
}

function Show-ProjectMenu {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WslHome,

        [Parameter(Mandatory = $true)]
        [string]$RunnerPath,

        [Parameter(Mandatory = $true)]
        [string]$HelperPath,

        [Parameter(Mandatory = $true)]
        $Profile
    )

    $page = 0

    while ($true) {
        $projects = @(Get-Projects -WslHome $WslHome)

        $items = @()
        foreach ($project in $projects) {
            $items += [PSCustomObject]@{ Text = [string]$project }
        }

        $commands = @(
            [PSCustomObject]@{ Key = "N"; Label = "new project (git repository, ready for agents)" },
            [PSCustomObject]@{ Key = "O"; Label = "open base folder in VS Code, no project" },
            [PSCustomObject]@{ Key = "C"; Label = "open Claude Code console in base folder" },
            [PSCustomObject]@{ Key = "R"; Label = "refresh" },
            [PSCustomObject]@{ Key = "H"; Label = "help" },
            [PSCustomObject]@{ Key = "B"; Label = "back to accounts" },
            [PSCustomObject]@{ Key = "Q"; Label = "quit" }
        )

        $result = Show-PagedMenu -Title "Projects" `
            -Subtitle ("account {0}   -   ~/{1}" -f $Profile.Name, $ProjectsRoot) `
            -Items $items -Commands $commands -StartPage $page `
            -EmptyText ("No project folders in ~/{0} yet - press N to create one." -f $ProjectsRoot)
        $page = $result.Page

        if ($result.Kind -eq "Command") {
            if ($result.Key -eq "Q") { return "__QUIT__" }
            if ($result.Key -eq "B") { return $null }
            if ($result.Key -eq "H") {
                Show-Help
                continue
            }
            # Straight into the new project's own menu, since opening it is
            # nearly always the next thing wanted.
            if ($result.Key -eq "N") {
                $newProject = New-Project -WslHome $WslHome -HelperPath $HelperPath
                if ($newProject) {
                    $projectResult = Invoke-ProjectMenu -WslHome $WslHome -RunnerPath $RunnerPath -HelperPath $HelperPath `
                        -Project $newProject -Profile $Profile
                    if ($projectResult -is [string] -and $projectResult -eq "__QUIT__") {
                        return "__QUIT__"
                    }
                }
                continue
            }
            # Straight at the base folder. The old "Base folder (no project)"
            # screen existed only to ask which of these two you wanted, so the
            # key now answers that up front and the extra menu is gone.
            if ($result.Key -eq "O") {
                Open-AgentWorkspace -WslHome $WslHome -RunnerPath $RunnerPath `
                    -Project (Get-WslLeafName -Path $ProjectsRoot) `
                    -FolderPath "$WslHome/$ProjectsRoot" -AgentName "" -Profile $Profile
                continue
            }
            if ($result.Key -eq "C") {
                [void](Invoke-ClaudeConsoleSession -RunnerPath $RunnerPath `
                        -ConfigDir ([string]$Profile.ConfigDir) `
                        -FolderPath "$WslHome/$ProjectsRoot")
                Wait-AnyKey -Message "Press any key to return to the menu"
                continue
            }
            continue
        }

        $projectResult = Invoke-ProjectMenu -WslHome $WslHome -RunnerPath $RunnerPath -HelperPath $HelperPath `
            -Project ([string]$projects[$result.Index]) -Profile $Profile

        if ($projectResult -is [string] -and $projectResult -eq "__QUIT__") {
            return "__QUIT__"
        }
    }
}

try {
    Import-LocalSettings
    $wslHome = Get-WslHome
    $runnerPath = Install-WslShellRunner -WslHome $wslHome
    $helperPath = Install-WslLauncherHelper -WslHome $wslHome

    Clear-HostSafe
    Write-Host "Switchboard" -ForegroundColor Cyan
    Write-Host "-----------"
    Write-Host ""
    $loadUsageInfo = Read-ConfirmKey -Question "Load Anthropic account usage/tier info?" -DefaultYes $true
    if (-not $loadUsageInfo) {
        Write-Host "Skipping the usage/tier refresh - accounts will load faster (press U in that menu to fetch it on demand)." -ForegroundColor DarkGray
    }

    # Account first, then project, then agent: which Anthropic account you are
    # working as is the thing that decides everything below it.
    while ($true) {
        $profile = Show-AccountMenu -WslHome $wslHome -RunnerPath $runnerPath -HelperPath $helperPath -LoadUsageInfo $loadUsageInfo
        if ($profile -is [string] -and $profile -eq "__QUIT__") {
            exit 0
        }

        # Done here rather than at each launch site so the console session, the
        # VS Code workspace, the agent bootstrap and the merge session all get
        # the same already-onboarded config dir.
        Set-ClaudeOnboarded -HelperPath $helperPath -RunnerPath $runnerPath -ConfigDir ([string]$profile.ConfigDir)

        $projectResult = Show-ProjectMenu -WslHome $wslHome -RunnerPath $runnerPath -HelperPath $helperPath -Profile $profile
        if ($projectResult -is [string] -and $projectResult -eq "__QUIT__") {
            exit 0
        }
    }
}
catch {
    $message = [string]$_.Exception.Message
    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = (($_ | Out-String).Trim())
    }
    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = "Unknown launcher error."
    }

    Write-Host ""
    Write-Host ("Error: {0}" -f $message) -ForegroundColor Red

    if ($_.InvocationInfo -and $_.InvocationInfo.ScriptLineNumber) {
        Write-Host ("PowerShell line: {0}" -f $_.InvocationInfo.ScriptLineNumber) -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "WSL distribution configured in this launcher:"
    Write-Host ("  {0}" -f $Distro)
    Write-Host "Available distributions:"
    $null | & wsl.exe -l -q
    Write-Host ""
    Write-Host "Run Setup-Switchboard.bat to choose the distribution and projects folder."
    Write-Host ""
    Wait-AnyKey -Message "Press any key to close"
    exit 1
}

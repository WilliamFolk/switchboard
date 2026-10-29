$ErrorActionPreference = "Stop"

# One-time setup for Switchboard on a new PC. It checks the tools Switchboard
# requires, asks for this PC's WSL distribution and projects folder, saves
# both to switchboard.local.json (git-ignored, read by Switchboard.ps1 at
# start), and recreates the shortcut, whose paths are absolute and so break
# as soon as this folder moves. Nothing is touched until the summary at the
# end is confirmed.

$SwitchboardPath = Join-Path $PSScriptRoot "Switchboard.ps1"
$LauncherPath = Join-Path $PSScriptRoot "Switchboard.bat"
$LocalSettingsPath = Join-Path $PSScriptRoot "switchboard.local.json"
$IconPath = Join-Path $PSScriptRoot "icon\switchboard-3_cropped.ico"

# Plain names only, which also keeps each value safe to write into JSON
# without escaping. The projects folder additionally stays free of spaces:
# every Switchboard call hands it to wsl.exe, which relays it through a Linux
# shell, and that is where unusual paths go wrong first.
$DistroNamePattern = '^[A-Za-z0-9._-]+$'
$ProjectsRootPattern = '^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$'

# What Switchboard needs, each checked the way Switchboard reaches it. Claude
# and VS Code are started through an interactive bash (its
# run-in-login-shell.sh), so they count when ~/.bashrc puts them on PATH; jq
# and git are called from plain non-interactive shells, so they have to be on
# the default PATH. The WSL extension lives on the Windows side. "Why" is
# shown when a check fails.
$RequiredTools = @(
    [PSCustomObject]@{
        Name        = "claude"
        Kind        = "command"
        Interactive = $true
        Version     = $true
        Why         = @(
            "Switchboard requires Claude Code: every session, sign-in and agent runs",
            "through it. It has to be installed inside this WSL distribution - Claude",
            "Code installed on Windows does not count."
        )
    },
    [PSCustomObject]@{
        Name        = "jq"
        Kind        = "command"
        Interactive = $false
        Version     = $true
        Why         = @(
            "Switchboard requires jq to read each account's email, plan and usage.",
            "Without it the account list shows names only."
        )
    },
    [PSCustomObject]@{
        Name        = "git"
        Kind        = "command"
        Interactive = $false
        Version     = $true
        Why         = @(
            "Switchboard requires git for agents (each on its own branch and worktree)",
            "and for merging them back. Without it only 'Open the project itself' works."
        )
    },
    [PSCustomObject]@{
        Name        = "git user"
        Kind        = "git-identity"
        Interactive = $false
        Version     = $false
        Why         = @(
            "Switchboard requires a git name and email: new projects start with a",
            "commit, and agents and merges make commits too. Set them in this",
            "distribution with: git config --global user.name / user.email"
        )
    },
    [PSCustomObject]@{
        Name        = "code"
        Kind        = "command"
        Interactive = $true
        Version     = $false
        Why         = @(
            "Switchboard requires the VS Code 'code' command to open projects and",
            "agents. It comes from VS Code installed on Windows."
        )
    },
    [PSCustomObject]@{
        Name        = "wsl ext"
        Kind        = "vscode-wsl-extension"
        Interactive = $false
        Version     = $false
        Why         = @(
            "Switchboard requires the WSL extension in VS Code",
            "(ms-vscode-remote.remote-wsl). Without it 'code' hands Linux paths to",
            "the Windows editor, which cannot open them."
        )
    }
)

function Read-Answer {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt
    )

    # Read-Host ignores a redirected stdin under Windows PowerShell, so a
    # scripted run reads the stream directly, as Switchboard.ps1 does. Running
    # out of input stops here rather than quietly accepting every default.
    if ([Console]::IsInputRedirected) {
        Write-Host ("{0}: " -f $Prompt) -NoNewline
        $line = [Console]::In.ReadLine()
        if ($null -eq $line) {
            Write-Host ""
            Write-Host "Input ended - nothing was changed." -ForegroundColor Yellow
            exit 1
        }
        Write-Host $line
        return $line.Trim()
    }

    return ([string](Read-Host $Prompt)).Trim()
}

function Read-YesNo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Question,

        [bool]$DefaultYes = $true
    )

    $hint = if ($DefaultYes) { "[Y/n]" } else { "[y/N]" }
    while ($true) {
        $answer = Read-Answer -Prompt ("{0} {1}" -f $Question, $hint)
        if (-not $answer) { return $DefaultYes }
        if ($answer -match '^(y|yes)$') { return $true }
        if ($answer -match '^(n|no)$') { return $false }
    }
}

function Wait-BeforeClose {
    # Started from Setup-Switchboard.bat, the console closes as soon as this
    # script exits and would take the last messages with it.
    if (-not [Console]::IsInputRedirected) {
        Write-Host ""
        [void](Read-Host "Press Enter to close")
    }
}

function Invoke-Wsl {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    # Same reasoning as Invoke-WslNative in Switchboard.ps1: with
    # $ErrorActionPreference at "Stop", Windows PowerShell turns any stderr
    # line from a native command into a terminating error, and a distribution
    # that is missing a file or still booting legitimately writes some.
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = @($null | & wsl.exe @Arguments 2>$null)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousEap
    }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Lines    = @($lines | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    }
}

function Get-WslDistributions {
    # The registry is where WSL itself keeps this list. Reading it avoids
    # "wsl -l", whose UTF-16 output Windows PowerShell decodes with a NUL
    # between every letter, and it also says which one is the WSL default.
    $lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (-not (Test-Path -LiteralPath $lxss)) {
        return @()
    }

    $defaultId = [string](Get-ItemProperty -LiteralPath $lxss).DefaultDistribution
    $distros = @()
    foreach ($key in (Get-ChildItem -LiteralPath $lxss)) {
        $name = [string](Get-ItemProperty -LiteralPath $key.PSPath).DistributionName
        if ($name) {
            $distros += [PSCustomObject]@{
                Name      = $name
                IsDefault = ($key.PSChildName -eq $defaultId)
            }
        }
    }

    return @($distros | Sort-Object Name)
}

function Get-WslRelease {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Distro
    )

    # The distribution name ("Ubuntu") often says nothing about the release
    # inside it, so ask the distribution itself.
    $result = Invoke-Wsl -Arguments @("-d", $Distro, "--", "cat", "/etc/os-release")
    if ($result.ExitCode -ne 0) {
        return ""
    }

    foreach ($line in $result.Lines) {
        if ($line -match '^PRETTY_NAME="?([^"]*)"?$') {
            return $Matches[1]
        }
    }
    return ""
}

function Get-WslHome {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Distro
    )

    $result = Invoke-Wsl -Arguments @("-d", $Distro, "--", "printenv", "HOME")
    if ($result.ExitCode -ne 0 -or $result.Lines.Count -eq 0) {
        throw ("Could not start '{0}'. Open it once from the Start menu so it can finish its first-run setup, then run this again." -f $Distro)
    }
    return $result.Lines[0]
}

function Test-WslDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Distro,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return ((Invoke-Wsl -Arguments @("-d", $Distro, "--", "test", "-d", $Path)).ExitCode -eq 0)
}

function Test-VsCodeWslExtension {
    # Asked of VS Code on Windows, where its extensions live. Its own list is
    # used rather than the extensions folder, which keeps an uninstalled
    # extension's files around until VS Code next cleans up.
    $code = Get-Command "code.cmd" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $code) {
        return [PSCustomObject]@{ Status = "MISSING"; Detail = "VS Code not found on Windows" }
    }

    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $extensions = @(& $code.Source --list-extensions 2>$null | ForEach-Object { ([string]$_).Trim() })
    }
    finally {
        $ErrorActionPreference = $previousEap
    }

    if ($extensions -contains "ms-vscode-remote.remote-wsl") {
        return [PSCustomObject]@{ Status = "OK"; Detail = "ms-vscode-remote.remote-wsl" }
    }
    return [PSCustomObject]@{ Status = "MISSING"; Detail = "not installed in VS Code" }
}

function Test-RequiredTool {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Distro,

        [Parameter(Mandatory = $true)]
        $Tool
    )

    if ($Tool.Kind -eq "vscode-wsl-extension") {
        return Test-VsCodeWslExtension
    }

    # Read from "/" so the identity comes from the global config alone, not
    # from whatever repository wsl.exe's starting directory happens to be in.
    if ($Tool.Kind -eq "git-identity") {
        $command = "git -C / config --get user.name && git -C / config --get user.email"
    }
    else {
        $command = "command -v {0}" -f $Tool.Name
        # "code --version" is left out on purpose: from WSL it starts the
        # Windows editor's own runtime, which is slow and proves nothing more
        # than finding the command does.
        if ($Tool.Version) {
            $command += " && {0} --version" -f $Tool.Name
        }
    }

    # --exec skips the Linux shell that wsl.exe otherwise relays commands
    # through, so this command string reaches bash exactly as written and is
    # expanded there, with that bash's own PATH. The marker line separates the
    # answer from anything a .bashrc prints on the way in.
    $flag = if ($Tool.Interactive) { "-ic" } else { "-c" }
    $result = Invoke-Wsl -Arguments @("-d", $Distro, "--exec", "bash", $flag, ("echo SWITCHBOARD-CHECK; " + $command))
    $marker = [array]::IndexOf($result.Lines, "SWITCHBOARD-CHECK")
    $answer = @()
    if ($marker -ge 0) {
        $answer = @($result.Lines | Select-Object -Skip ($marker + 1))
    }

    if ($Tool.Kind -eq "git-identity") {
        if ($result.ExitCode -eq 0 -and $answer.Count -ge 2) {
            return [PSCustomObject]@{ Status = "OK"; Detail = ("{0} <{1}>" -f $answer[0], $answer[1]) }
        }
        return [PSCustomObject]@{ Status = "MISSING"; Detail = "no git user.name / user.email set" }
    }

    if ($answer.Count -eq 0) {
        return [PSCustomObject]@{ Status = "MISSING"; Detail = "not found" }
    }
    if ($result.ExitCode -ne 0) {
        return [PSCustomObject]@{
            Status = "BROKEN"
            Detail = ("found at {0}, but '{1} --version' did not run" -f $answer[0], $Tool.Name)
        }
    }
    if ($Tool.Version -and $answer.Count -ge 2) {
        return [PSCustomObject]@{ Status = "OK"; Detail = $answer[1] }
    }
    return [PSCustomObject]@{ Status = "OK"; Detail = $answer[0] }
}

function Show-RequiredTools {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Distro
    )

    # Reports only - installing is left to the user. Returns the names of the
    # checks that failed so the summary can repeat them.
    Write-Host ""
    Write-Host ("Checking what Switchboard requires in {0}..." -f $Distro) -ForegroundColor DarkGray
    Write-Host ""

    $missing = @()
    foreach ($tool in $RequiredTools) {
        $check = Test-RequiredTool -Distro $Distro -Tool $tool
        if ($check.Status -eq "OK") {
            Write-Host "  [  OK   ] " -NoNewline -ForegroundColor Green
            Write-Host ("{0,-9}" -f $tool.Name) -NoNewline
            Write-Host $check.Detail -ForegroundColor DarkGray
            continue
        }

        $missing += $tool.Name
        Write-Host ("  [{0,-7}] " -f $check.Status) -NoNewline -ForegroundColor Red
        Write-Host ("{0,-9}" -f $tool.Name) -NoNewline
        Write-Host $check.Detail -ForegroundColor Red
        foreach ($line in $tool.Why) {
            Write-Host ("                     {0}" -f $line) -ForegroundColor Yellow
        }
    }

    Write-Host ""
    if ($missing.Count -eq 0) {
        Write-Host "Everything Switchboard requires is in place." -ForegroundColor Green
    }
    else {
        Write-Host "Switchboard requires everything marked above. Setup can still finish, but" -ForegroundColor Yellow
        Write-Host "Switchboard will not work fully until it is in place." -ForegroundColor Yellow
    }

    return @($missing)
}

function Get-ScriptSetting {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $pattern = '(?m)^\$' + $Name + '\s*=\s*"([^"\r\n]*)"'
    $found = [regex]::Matches($Text, $pattern)
    if ($found.Count -ne 1) {
        throw ('Switchboard.ps1 should set ${0} exactly once at the start of a line, but does so {1} times.' -f $Name, $found.Count)
    }
    return $found[0].Groups[1].Value
}

function Read-ProjectsRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WslHome,

        [string]$Default = ""
    )

    while ($true) {
        $prompt = if ($Default) { "Folder (Enter = {0})" -f $Default } else { "Folder" }
        $answer = Read-Answer -Prompt $prompt
        if (-not $answer) {
            $answer = $Default
        }
        if (-not $answer) {
            continue
        }

        # Accept the forms people naturally type - "~/x", "$HOME/x", the full
        # /home/<user>/x - and keep the part below home, which is how
        # Switchboard.ps1 uses it ("$WslHome/$ProjectsRoot").
        $value = $answer -replace '\\', '/'
        if ($value -eq '~' -or $value -eq '$HOME' -or $value.TrimEnd('/') -eq $WslHome) {
            $value = ""
        }
        elseif ($value.StartsWith('~/')) {
            $value = $value.Substring(2)
        }
        elseif ($value.StartsWith('$HOME/')) {
            $value = $value.Substring(6)
        }
        elseif ($value.StartsWith($WslHome + '/')) {
            $value = $value.Substring($WslHome.Length + 1)
        }
        elseif ($value.StartsWith('/')) {
            Write-Host ("Switchboard looks for projects inside your WSL home, so the folder has to be under {0}." -f $WslHome) -ForegroundColor Yellow
            continue
        }
        $value = $value.Trim('/')

        if (-not $value) {
            Write-Host "Pick a folder below your home, not the home folder itself - every folder in it would show up as a project." -ForegroundColor Yellow
            continue
        }

        $segments = $value -split '/'
        if ($value -notmatch $ProjectsRootPattern -or $segments -contains '.' -or $segments -contains '..') {
            Write-Host "Use letters, numbers, dots, underscores, dashes and / only - no spaces, no '..'." -ForegroundColor Yellow
            continue
        }

        return $value
    }
}

function Format-Change {
    param(
        [string]$Old,
        [string]$New
    )

    if ($Old -ceq $New) {
        return "   (unchanged)"
    }
    return ("   (was: {0})" -f $Old)
}

function New-SwitchboardShortcut {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    # Same shape as the original shortcut: cmd.exe running Switchboard.bat, so
    # the PowerShell flags stay defined in one place. The doubled quotes are
    # what "cmd /c" needs to keep the path intact when it holds spaces or
    # characters like "&" - it strips the outer pair and runs the rest.
    # Removed first so nothing from an old shortcut (such as an icon path
    # into a folder that no longer exists) carries over.
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force
    }

    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($Path)
    $link.TargetPath = $env:ComSpec
    $link.Arguments = '/c ""' + $LauncherPath + '""'
    $link.WorkingDirectory = $PSScriptRoot
    $link.WindowStyle = 1
    $link.Description = "Switchboard"
    if (Test-Path -LiteralPath $IconPath) {
        $link.IconLocation = "$IconPath,0"
    }
    $link.Save()
}

try {
    foreach ($required in @($SwitchboardPath, $LauncherPath)) {
        if (-not (Test-Path -LiteralPath $required)) {
            throw ("{0} was not found. Keep this script in the Switchboard folder." -f $required)
        }
    }

    # Current values: Switchboard.ps1's defaults, overridden by this PC's own
    # settings file when one exists - the same order Switchboard reads them in.
    $scriptText = [System.IO.File]::ReadAllText($SwitchboardPath)
    $currentDistro = Get-ScriptSetting -Text $scriptText -Name "Distro"
    $currentRoot = Get-ScriptSetting -Text $scriptText -Name "ProjectsRoot"
    $existingJson = ""
    if (Test-Path -LiteralPath $LocalSettingsPath) {
        $existingJson = [System.IO.File]::ReadAllText($LocalSettingsPath)
        try {
            $existing = $existingJson | ConvertFrom-Json
            if ($existing.Distro) { $currentDistro = [string]$existing.Distro }
            if ($existing.ProjectsRoot) { $currentRoot = [string]$existing.ProjectsRoot }
        }
        catch {
            Write-Host ("{0} could not be read - it will be written again." -f $LocalSettingsPath) -ForegroundColor Yellow
        }
    }

    Write-Host "Switchboard setup" -ForegroundColor Cyan
    Write-Host "-----------------" -ForegroundColor Cyan
    Write-Host "Nothing is changed until you confirm at the end." -ForegroundColor DarkGray
    Write-Host ""

    # --- Step 1: distribution ------------------------------------------------

    Write-Host "Step 1 of 3 - WSL distribution" -ForegroundColor Cyan
    Write-Host "Checking installed distributions (stopped ones start for a moment)..." -ForegroundColor DarkGray

    $installed = @(Get-WslDistributions)
    $candidates = @($installed | Where-Object { $_.Name -match '^Ubuntu' })
    if ($candidates.Count -eq 0) {
        $candidates = @($installed | Where-Object { $_.Name -notmatch '^docker-desktop' })
        if ($candidates.Count -gt 0) {
            Write-Host "No Ubuntu distribution found - listing the other installed ones." -ForegroundColor Yellow
        }
    }
    if ($candidates.Count -eq 0) {
        throw "No WSL distribution is installed. Install Ubuntu with 'wsl --install -d Ubuntu', open it once to create your Linux user, then run this again."
    }

    $rows = @()
    foreach ($candidate in $candidates) {
        $rows += [PSCustomObject]@{
            Name      = $candidate.Name
            IsDefault = $candidate.IsDefault
            Release   = (Get-WslRelease -Distro $candidate.Name)
        }
    }

    # Preselect what Switchboard already uses, else the WSL default.
    $defaultIndex = -1
    for ($i = 0; $i -lt $rows.Count; $i++) {
        if ($rows[$i].Name -eq $currentDistro) { $defaultIndex = $i }
    }
    if ($defaultIndex -lt 0) {
        for ($i = 0; $i -lt $rows.Count; $i++) {
            if ($rows[$i].IsDefault) { $defaultIndex = $i }
        }
    }
    if ($defaultIndex -lt 0) { $defaultIndex = 0 }

    Write-Host ""
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $row = $rows[$i]
        $release = if ($row.Release) { $row.Release } else { "(did not respond)" }
        $notes = @()
        if ($row.Name -eq $currentDistro) { $notes += "used by Switchboard now" }
        if ($row.IsDefault) { $notes += "WSL default" }

        Write-Host ("  [{0}] " -f ($i + 1)) -NoNewline -ForegroundColor White
        Write-Host ("{0,-16} {1,-22}" -f $row.Name, $release) -NoNewline
        Write-Host (" {0}" -f ($notes -join ", ")) -ForegroundColor DarkGray
    }
    Write-Host ""

    $chosen = $null
    while (-not $chosen) {
        $answer = Read-Answer -Prompt ("Choose 1-{0} (Enter = {1}, Q = quit)" -f $rows.Count, ($defaultIndex + 1))
        if (-not $answer) {
            $chosen = $rows[$defaultIndex]
        }
        elseif ($answer -match '^[qQ]$') {
            Write-Host "Nothing was changed."
            Wait-BeforeClose
            exit 0
        }
        elseif ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le $rows.Count) {
            $chosen = $rows[[int]$answer - 1]
        }
        else {
            Write-Host "Type a number from the list." -ForegroundColor Yellow
        }
    }

    $distro = [string]$chosen.Name
    if ($distro -notmatch $DistroNamePattern) {
        throw ("'{0}' is not a name Switchboard can use. Pick another distribution or rename this one." -f $distro)
    }

    $wslHome = Get-WslHome -Distro $distro
    $missingTools = @(Show-RequiredTools -Distro $distro)

    # --- Step 2: projects folder ---------------------------------------------

    Write-Host ""
    Write-Host "Step 2 of 3 - Projects folder" -ForegroundColor Cyan
    Write-Host "Switchboard lists every folder directly inside this one as a project."
    Write-Host ("Give it as a path inside your WSL home ({0}), e.g. projects or projects/work" -f $wslHome)
    Write-Host ""

    $root = Read-ProjectsRoot -WslHome $wslHome -Default $currentRoot
    $rootPath = "$wslHome/$root"

    $createRoot = $false
    if (Test-WslDirectory -Distro $distro -Path $rootPath) {
        $listing = Invoke-Wsl -Arguments @("-d", $distro, "--", "find", $rootPath, "-mindepth", "1", "-maxdepth", "1", "-type", "d", "-print")
        Write-Host ("Found ~/{0} with {1} folder(s) in it." -f $root, $listing.Lines.Count) -ForegroundColor Green
    }
    else {
        Write-Host ("~/{0} does not exist yet in {1}." -f $root, $distro) -ForegroundColor Yellow
        $createRoot = Read-YesNo -Question "Create it when applying?" -DefaultYes $true
    }

    # --- Step 3: shortcut ----------------------------------------------------

    Write-Host ""
    Write-Host "Step 3 of 3 - Shortcut" -ForegroundColor Cyan
    Write-Host "Switchboard.lnk in this folder is recreated so it points here."
    $shortcuts = @(Join-Path $PSScriptRoot "Switchboard.lnk")
    if (Read-YesNo -Question "Also put a Switchboard shortcut on your Desktop?" -DefaultYes $true) {
        $shortcuts += Join-Path ([Environment]::GetFolderPath("Desktop")) "Switchboard.lnk"
    }
    if (-not (Test-Path -LiteralPath $IconPath)) {
        Write-Host ("Icon not found at {0} - the shortcut will get the default icon." -f $IconPath) -ForegroundColor Yellow
    }

    # --- Confirm and apply ---------------------------------------------------

    Write-Host ""
    Write-Host "Ready to apply" -ForegroundColor Cyan
    Write-Host "--------------" -ForegroundColor Cyan
    Write-Host ("  Distribution     {0}{1}" -f $distro, (Format-Change -Old $currentDistro -New $distro))
    if ($missingTools.Count -gt 0) {
        Write-Host ("  Still missing    {0}   (Switchboard requires them)" -f ($missingTools -join ", ")) -ForegroundColor Yellow
    }
    Write-Host ("  Projects folder  ~/{0}{1}" -f $root, (Format-Change -Old $currentRoot -New $root))
    if ($createRoot) {
        Write-Host "                   (will be created)"
    }
    Write-Host ("  Saved to         {0}" -f $LocalSettingsPath)
    for ($i = 0; $i -lt $shortcuts.Count; $i++) {
        $label = if ($i -eq 0) { "  Shortcut         " } else { "                   " }
        Write-Host ("{0}{1}" -f $label, $shortcuts[$i])
    }
    Write-Host ""

    if (-not (Read-YesNo -Question "Apply these changes?" -DefaultYes $true)) {
        Write-Host "Nothing was changed."
        Wait-BeforeClose
        exit 0
    }

    Write-Host ""
    if ($createRoot) {
        $made = Invoke-Wsl -Arguments @("-d", $distro, "--", "mkdir", "-p", "--", $rootPath)
        if ($made.ExitCode -ne 0) {
            throw ("Could not create {0} in {1}." -f $rootPath, $distro)
        }
        Write-Host ("Created ~/{0}" -f $root) -ForegroundColor Green
    }

    # Both values were validated against plain-character patterns above, so
    # they go into the JSON as they are, with nothing to escape.
    $settingsJson = "{`n  `"Distro`": `"$distro`",`n  `"ProjectsRoot`": `"$root`"`n}`n"
    if ($settingsJson -cne $existingJson) {
        [System.IO.File]::WriteAllText($LocalSettingsPath, $settingsJson, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host ("Saved {0}" -f $LocalSettingsPath) -ForegroundColor Green
    }
    else {
        Write-Host ("{0} already had these settings" -f $LocalSettingsPath) -ForegroundColor Green
    }

    foreach ($shortcut in $shortcuts) {
        New-SwitchboardShortcut -Path $shortcut
        Write-Host ("Created {0}" -f $shortcut) -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "Done. Start Switchboard from the shortcut." -ForegroundColor Cyan
    if ($missingTools.Count -gt 0) {
        Write-Host ("Switchboard still requires: {0} - see the check above." -f ($missingTools -join ", ")) -ForegroundColor Yellow
    }
    Wait-BeforeClose
}
catch {
    Write-Host ""
    Write-Host ("Error: {0}" -f $_.Exception.Message) -ForegroundColor Red
    if ($_.InvocationInfo -and $_.InvocationInfo.ScriptLineNumber) {
        Write-Host ("PowerShell line: {0}" -f $_.InvocationInfo.ScriptLineNumber) -ForegroundColor DarkGray
    }
    Wait-BeforeClose
    exit 1
}

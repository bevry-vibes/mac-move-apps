#Requires -Version 7.6
<#
.SYNOPSIS
    mac-move-apps - move macOS .app bundles to external storage and back, keeping them launchable via symlinks.

.DESCRIPTION
    Single command wrapping the full app-relocation workflow:

      move <app> [destination]   Copy the .app bundle to external storage with ditto,
                                 replace the original with a symlink, clear quarantine,
                                 ad-hoc re-sign, and re-register with LaunchServices.
                                 When the destination is omitted, the command asks
                                 where the app should go, offering mounted volumes.
      restore                    Move every externally-stored app back to the internal disk.
      list                       Show installed apps categorised by how safe they are to move.
      status                     Show apps already moved to external storage.
      refresh <app>              Re-register an app with LaunchServices and refresh
                                 Dock, Finder, and Spotlight; -ForceRepair also
                                 clears xattrs and re-signs.

    Apps are searched for in /Applications and ~/Applications.

    Exit codes: 0 = success, 1 = failure, 2 = usage error.

.EXAMPLE
    pwsh -File ./mac-move-apps.ps1 move 'Visual Studio Code'

    Asks where the app should go, offering mounted volumes.

.EXAMPLE
    pwsh -File ./mac-move-apps.ps1 move Motrix /Volumes/Scratchpad/Applications

.EXAMPLE
    pwsh -File ./mac-move-apps.ps1 list

.EXAMPLE
    pwsh -File ./mac-move-apps.ps1 status

.EXAMPLE
    pwsh -File ./mac-move-apps.ps1 restore -DryRun

.EXAMPLE
    pwsh -File ./mac-move-apps.ps1 refresh IINA -ForceRepair
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string]$Command,
    [Parameter(Position = 1)] [string]$AppName,
    [Parameter(Position = 2)] [string]$Destination,
    [switch]$Force,
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$ForceRepair
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$LASTEXITCODE = 0

$LsRegister = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
$SearchDirs = @('/Applications', "$HOME/Applications")

# Common short names people type instead of the canonical bundle name.
$AppAliases = @{
    'code'      = 'Visual Studio Code'
    'vs code'   = 'Visual Studio Code'
    'vscode'    = 'Visual Studio Code'
    'chrome'    = 'Google Chrome'
    'edge'      = 'Microsoft Edge'
    'iina'      = 'IINA'
    'iterm'     = 'iTerm'
    'iterm2'    = 'iTerm'
    'karabiner' = 'Karabiner-Elements'
}

# Curated move-safety tiers: pure GUI apps survive relocation cleanly; apps with
# privileged helpers, system extensions, virtualisation, or deep system integration do not.
$MoveTiers = [ordered]@{
    safe = @(
        'Android Studio', 'Audacity', 'Blender', 'Brave Browser', 'ChatGPT', 'DBeaver',
        'draw.io', 'FreeCAD', 'GIMP', 'Google Chrome', 'Hidden Bar', 'IINA', 'Inkscape',
        'KeyCastr', 'LocalSend', 'Microsoft Edge', 'MongoDB Compass', 'Motrix',
        'Pearcleaner', 'Telegram', 'Tor Browser', 'Visual Studio Code'
    )
    caution = @(
        'Android File Transfer', 'Hammerspoon', 'iTerm', 'Karabiner-Elements',
        'Karabiner-EventViewer', 'Microsoft Excel', 'Microsoft PowerPoint',
        'Microsoft Word', 'Ollama'
    )
    avoid = @(
        'Docker', 'ExpressVPN', 'iMovie', 'lghub', 'OrbStack', 'Parallels Desktop',
        'Safari', 'Tailscale', 'VMware Fusion', 'Xcode'
    )
}

function Write-Info    { param([string]$Message) Write-Host "$($PSStyle.Foreground.BrightBlue)info $Message$($PSStyle.Reset)" }
function Write-Caution { param([string]$Message) Write-Host "$($PSStyle.Foreground.Yellow)warn $Message$($PSStyle.Reset)" }
function Write-Failure { param([string]$Message) Write-Host "$($PSStyle.Foreground.Red)fail $Message$($PSStyle.Reset)" }
function Write-Preview { param([string]$Message) Write-Host "$($PSStyle.Foreground.BrightMagenta)dry  $Message$($PSStyle.Reset)" }

function Invoke-Tool {
    # Run a native tool with stderr captured into the returned output.
    # Throws on a non-zero exit unless -Tolerant.
    param(
        [Parameter(Mandatory)] [string]$Name,
        [string[]]$ToolArgs = @(),
        [switch]$Tolerant
    )
    $output = & $Name @ToolArgs 2>&1
    if ($LASTEXITCODE -ne 0 -and -not $Tolerant) {
        throw "$Name $($ToolArgs -join ' ') failed with exit $LASTEXITCODE`: $(($output | Out-String).Trim())"
    }
    return $output
}

function Resolve-AppName {
    # Map a short name to its canonical bundle name and ensure the .app suffix.
    param([Parameter(Mandatory)] [string]$Name)
    $canonical = $AppAliases[$Name] ?? $Name
    return $canonical.EndsWith('.app') ? $canonical : "$canonical.app"
}

function Resolve-AppBundle {
    # Locate an app bundle by name in the search dirs, or accept a direct path.
    param([Parameter(Mandatory)] [string]$AppFile)
    if ($AppFile -match '/') {
        return (Test-Path -LiteralPath $AppFile) ? (Get-Item -LiteralPath $AppFile).FullName : $null
    }
    foreach ($dir in $SearchDirs) {
        $candidate = Join-Path $dir $AppFile
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Get-InstalledApp {
    # Bundle names sitting in the search dirs; apps already symlinked elsewhere are skipped.
    foreach ($dir in $SearchDirs) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        Get-ChildItem -LiteralPath $dir -Filter *.app -Directory | Where-Object { -not $_.LinkType } |
            ForEach-Object { $_.Name -replace '\.app$', '' }
    }
}

function Get-MovedApp {
    # Apps replaced by symlinks into /Volumes - i.e. apps this tool has moved.
    # Target is a scalar string on some hosts and an array on others, hence the @() wrap.
    foreach ($dir in $SearchDirs) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        Get-ChildItem -LiteralPath $dir -Filter *.app | ForEach-Object {
            if ($_.LinkType -ne 'SymbolicLink' -or -not $_.Target) { return }
            $target = @($_.Target)[0]
            if ($target -notlike '/Volumes/*') { return }
            [pscustomobject]@{ Name = $_.Name -replace '\.app$', ''; LinkPath = $_.FullName; Target = $target }
        }
    }
}

function Get-ExternalVolume {
    # Mounted volumes under /Volumes that are real df mount points - the startup
    # volume's /Volumes entry fails the mount-point check, external drives pass it.
    foreach ($entry in Get-ChildItem -LiteralPath '/Volumes' -Directory) {
        $row = df -H $entry.FullName | Select-Object -Skip 1
        if (-not $row) { continue }
        $parts = $row -split '\s+'
        if ($parts.Count -lt 9) { continue }
        $mount = ($parts[8..($parts.Count - 1)] -join ' ').Trim()
        if ($mount -ne $entry.FullName) { continue }
        [pscustomobject]@{ Name = $entry.Name; Mount = $mount; Size = $parts[1]; Free = $parts[3] }
    }
}

function Read-Destination {
    # Ask where the app should go: pick a mounted volume (apps land in its
    # Applications dir) or type any destination path.
    if ([Console]::IsInputRedirected) {
        Write-Failure 'no destination given and stdin is not interactive - pass the destination path as an argument.'
        exit 2
    }
    $volumes = @(Get-ExternalVolume)
    Write-Host ''
    Write-Host 'Where should the app go?'
    for ($i = 0; $i -lt $volumes.Count; $i++) {
        Write-Host "  $($i + 1). $($volumes[$i].Mount)  ($($volumes[$i].Size) total, $($volumes[$i].Free) free)"
    }
    if ($volumes.Count -gt 0) { Write-Host '' }
    $suffix = ($volumes.Count -eq 1) ? ' [1]' : ''
    $answer = (Read-Host "Volume number or destination path$suffix").Trim()
    if (-not $answer -and $volumes.Count -eq 1) { $answer = '1' }
    if ($answer -match '^\d+$') {
        $index = [int]$answer - 1
        if ($index -lt 0 -or $index -ge $volumes.Count) {
            Write-Failure "no volume numbered $answer."
            exit 2
        }
        return Join-Path $volumes[$index].Mount 'Applications'
    }
    if (-not $answer) {
        Write-Failure 'no destination provided.'
        exit 2
    }
    return $answer
}

function Show-Usage {
    @'
Usage: pwsh -File ./mac-move-apps.ps1 <command> [arguments] [options]

Commands:
  move <app> [destination]  Move an app bundle to external storage and symlink
                            it back. Asks where the app should go when the
                            destination is omitted. The app is a name (aliases
                            supported, .app suffix optional) or a bundle path.
  restore                   Move every externally-stored app back to the internal disk.
  list                      Show installed apps categorised by move safety.
  status                    Show apps already moved to external storage.
  refresh <app>             Refresh LaunchServices, Dock, Finder, and Spotlight
                            for a moved app.

Options:
  -Force        move: overwrite an existing app at the destination.
  -DryRun       restore: preview what would move, change nothing.
  -Yes          restore: skip the confirmation prompt.
  -ForceRepair  refresh: also clear xattrs and re-sign the app.

Examples:
  pwsh -File ./mac-move-apps.ps1 move 'Visual Studio Code'
  pwsh -File ./mac-move-apps.ps1 move Motrix /Volumes/Scratchpad/Applications
  pwsh -File ./mac-move-apps.ps1 restore -DryRun
  pwsh -File ./mac-move-apps.ps1 refresh IINA -ForceRepair

Apps are searched for in /Applications and ~/Applications.
Exit codes: 0 = success, 1 = failure, 2 = usage error.
'@ | Write-Host
    exit 2
}

function Show-MovableList {
    $installed = @(Get-InstalledApp)
    $sections = [ordered]@{
        safe    = 'Safe to move - pure GUI apps, no system extensions'
        caution = 'Move with caution - test after moving'
        avoid   = 'Do not move - system extensions, virtualisation, VPNs, deep system integration'
    }
    $colors = @{
        safe    = $PSStyle.Foreground.Green
        caution = $PSStyle.Foreground.Yellow
        avoid   = $PSStyle.Foreground.Red
    }
    foreach ($tier in $sections.Keys) {
        Write-Host ''
        Write-Host "$($colors[$tier])$($sections[$tier])$($PSStyle.Reset)"
        $hits = @($MoveTiers[$tier] | Where-Object { $installed -contains $_ })
        if ($hits.Count -eq 0) {
            Write-Host '  (none installed)'
        } else {
            foreach ($app in $hits) { Write-Host "  - $app" }
        }
    }
    Write-Host ''
    Write-Host 'Unlisted apps: use your judgement - anything with privileged helpers,'
    Write-Host 'system extensions, or an updater that checks its own path stays put.'
}

function Show-Status {
    $moved = @(Get-MovedApp)
    if ($moved.Count -eq 0) {
        Write-Info 'no apps are symlinked to external storage - everything is on the internal disk.'
        return
    }
    $moved | Format-Table Name, LinkPath, Target -AutoSize | Out-String | Write-Host
    Write-Info "$($moved.Count) app(s) living on external storage."
}

function Invoke-Move {
    if (-not $AppName) { Show-Usage }
    $appFile = Resolve-AppName $AppName
    $src = Resolve-AppBundle $appFile
    if (-not $src) {
        Write-Failure "app not found in $($SearchDirs -join ' or '): $appFile"
        exit 1
    }
    $item = Get-Item -LiteralPath $src
    if ($item.LinkType -eq 'SymbolicLink') {
        Write-Caution "$appFile is already a symlink to $(@($item.Target)[0]) - nothing to move."
        exit 1
    }

    # a running app cannot be moved safely
    $null = pgrep -f "$src/"
    if ($LASTEXITCODE -eq 0) {
        Write-Failure "$appFile is running - quit it completely before moving."
        exit 1
    }

    $destDir = if ($Destination) { $Destination } else { Read-Destination }
    $destParent = Split-Path $destDir -Parent
    if (-not (Test-Path -LiteralPath $destParent)) {
        Write-Failure "destination drive is not mounted: $destParent"
        exit 1
    }
    $null = New-Item -ItemType Directory -Path $destDir -Force
    $dst = Join-Path $destDir $appFile

    if (Test-Path -LiteralPath $dst) {
        if ($Force) {
            Write-Caution "destination exists, overwriting: $dst"
            Remove-Item -LiteralPath $dst -Recurse -Force
        } else {
            Write-Failure "destination already exists: $dst (re-run with -Force to overwrite)"
            exit 1
        }
    }

    Write-Info "moving $src"
    Write-Info "   to $dst"
    Write-Info "symlink back at $src"

    # ditto preserves bundle structure, metadata, extended attributes, and forks
    Write-Info 'copying the bundle with ditto...'
    try {
        Invoke-Tool ditto @($src, $dst)
    } catch {
        Write-Failure "ditto copy failed: $_"
        exit 1
    }

    Write-Info 'removing the original...'
    try {
        Invoke-Tool rm @('-rf', $src)
    } catch {
        Write-Caution 'plain removal failed - retrying with sudo (password may be asked)...'
        try {
            Invoke-Tool sudo @('rm', '-rf', $src)
        } catch {
            Write-Failure "could not remove the original: $_"
            $null = Invoke-Tool rm @('-rf', $dst) -Tolerant
            Write-Caution "rolled back the copy at $dst"
            exit 1
        }
    }

    $null = New-Item -ItemType SymbolicLink -Path $src -Target $dst

    # clear quarantine and re-sign so Gatekeeper accepts the relocated bundle
    Write-Info 'clearing extended attributes and re-signing...'
    $null = Invoke-Tool xattr @('-cr', $dst) -Tolerant
    $null = Invoke-Tool codesign @('--force', '--deep', '--sign', '-', $dst) -Tolerant

    Write-Info 're-registering with LaunchServices...'
    $null = Invoke-Tool $LsRegister @('-f', $dst) -Tolerant

    Write-Info "moved $appFile to $dst"
    Write-Host ''
    Write-Host 'Next steps:'
    Write-Host "  - refresh caches:  pwsh -File ./mac-move-apps.ps1 refresh $appFile"
    Write-Host '  - undo everything: pwsh -File ./mac-move-apps.ps1 restore'
}

function Invoke-Restore {
    $moved = @(Get-MovedApp)
    if ($moved.Count -eq 0) {
        Write-Info 'no apps are symlinked to external storage - nothing to restore.'
        return
    }
    $moved | Format-Table Name, Target -AutoSize | Out-String | Write-Host

    if ($DryRun) {
        Write-Preview "would restore $($moved.Count) app(s) - dry run, nothing was moved."
        return
    }
    if (-not $Yes) {
        if ([Console]::IsInputRedirected) {
            Write-Failure 'stdin is not interactive - re-run with -Yes to restore without a prompt.'
            exit 2
        }
        $answer = (Read-Host "Restore these $($moved.Count) app(s) to the internal disk? [y/N]").Trim()
        if ($answer -notmatch '^[Yy]') {
            Write-Info 'cancelled.'
            return
        }
    }

    $restored = 0
    $failed = 0
    foreach ($app in $moved) {
        Write-Host -NoNewline "  restoring $($app.Name)... "
        if (-not (Test-Path -LiteralPath $app.Target)) {
            Write-Host 'missing source'
            $failed++
            continue
        }
        try {
            Remove-Item -LiteralPath $app.LinkPath
            Invoke-Tool mv @($app.Target, $app.LinkPath)
            Write-Host 'done'
            $restored++
        } catch {
            Write-Host 'failed'
            Write-Caution "  could not restore $($app.Name): $_"
            # relink so the external copy stays reachable
            if (-not (Test-Path -LiteralPath $app.LinkPath)) {
                $null = New-Item -ItemType SymbolicLink -Path $app.LinkPath -Target $app.Target
            }
            $failed++
        }
    }

    Write-Host ''
    if ($restored -gt 0) {
        Write-Info "restored $restored app(s), failed $failed."
        Write-Info 'refreshing LaunchServices, Dock, and Finder...'
        $null = Invoke-Tool $LsRegister @('-kill', '-r', '-domain', 'local', '-domain', 'system', '-domain', 'user') -Tolerant
        $null = Invoke-Tool killall @('Dock') -Tolerant
        $null = Invoke-Tool killall @('Finder') -Tolerant
    } else {
        Write-Failure "restored 0 app(s), failed $failed."
        exit 1
    }
}

function Invoke-Refresh {
    if (-not $AppName) { Show-Usage }
    $appFile = Resolve-AppName $AppName
    $path = Resolve-AppBundle $appFile
    if (-not $path) {
        Write-Failure "app not found in $($SearchDirs -join ' or '): $appFile"
        exit 1
    }
    $item = Get-Item -LiteralPath $path
    $realPath = ($item.LinkType -eq 'SymbolicLink' -and $item.Target) ? @($item.Target)[0] : $item.FullName
    Write-Info "refreshing $appFile at $realPath"

    Write-Info 're-registering with LaunchServices...'
    $null = Invoke-Tool $LsRegister @('-f', $realPath) -Tolerant

    if ($ForceRepair) {
        Write-Info 'clearing extended attributes and re-signing...'
        $null = Invoke-Tool xattr @('-cr', $realPath) -Tolerant
        $null = Invoke-Tool codesign @('--force', '--deep', '--sign', '-', $realPath) -Tolerant
    }

    Write-Info 'refreshing Dock, Finder, and Spotlight...'
    $null = Invoke-Tool killall @('Dock') -Tolerant
    $null = Invoke-Tool killall @('Finder') -Tolerant
    $null = Invoke-Tool mdimport @($realPath) -Tolerant

    Write-Info "refreshed $appFile - try launching it from Spotlight or the Dock."
}

if (-not $IsMacOS) {
    Write-Failure 'mac-move-apps only runs on macOS.'
    exit 1
}

switch ($Command) {
    'move'    { Invoke-Move }
    'restore' { Invoke-Restore }
    'list'    { Show-MovableList }
    'status'  { Show-Status }
    'refresh' { Invoke-Refresh }
    'help'    { Show-Usage }
    default {
        if ($Command) { Write-Failure "unknown command '$Command'." }
        Show-Usage
    }
}
exit 0

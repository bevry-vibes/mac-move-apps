#Requires -Version 7.6
<#
.SYNOPSIS
    mac-move-apps - move macOS .app bundles to external storage and back, keeping them launchable via symlinks.

.DESCRIPTION
    Single command wrapping the full app-relocation workflow:

      move [app] [destination]   Copy the .app bundle to external storage with ditto,
                                 replace the original with a symlink, clear quarantine,
                                 ad-hoc re-sign, and re-register with LaunchServices.
                                 The app's ~/Library footprint (Application Support,
                                 Caches, Logs, WebKit, HTTPStorages, Saved Application
                                 State) moves to the volume's 'App Library' folder too,
                                 symlinked back. With no app given, an interactive
                                 multiselect lists every installed app. When the
                                 destination is omitted, the command asks where the
                                 app should go, offering mounted volumes.
      restore                    Move every externally-stored app - and its ~/Library
                                 entries - back to the internal disk.
      list                       Show installed apps categorised by how safe they are to move.
      status                     Show apps already moved to external storage.
      refresh <app>              Re-register an app with LaunchServices and refresh
                                 Dock, Finder, and Spotlight; -ForceRepair also
                                 clears xattrs and re-signs.

    The move-safety tiers are enforced, not advisory: apps on the caution or avoid
    lists are locked in the multiselect and refused by direct move.

    Apps are searched for in /Applications and ~/Applications.

    Exit codes: 0 = success, 1 = failure, 2 = usage error.

.EXAMPLE
    pwsh -File ./mac-move-apps.ps1 move

    Multiselect across every installed app, then asks where the apps should go.

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

# Curated move-safety tiers, audited against the apps installed on this machine.
# These are enforced, not advisory: caution and avoid apps cannot be moved.
#   avoid   - installs drivers, system/network extensions, root helpers, or launchd
#             services; or patches the system (Apple pro media apps included).
#   caution - relies on integration that references its install path or keys
#             permissions to it (browser native messaging, accessibility/TCC grants,
#             driver installers, App Store Apple apps, terminals).
#   safe    - self-contained GUI apps with no system integration.
$MoveTiers = [ordered]@{
    safe = @(
        '0 A.D.', 'Aural', 'Amazon Kindle', 'Android Studio', 'AnythingLLM', 'Audacity',
        'balenaEtcher', 'Beeper Desktop', 'Bible', 'Blender', 'Brave Browser', 'BusyCal',
        'BusyContacts', 'Byword', 'calibre', 'ChatGPT', 'Claude', 'DBeaver', 'Discord',
        'draw.io', 'Duplicate File Finder', 'eero', 'Endel', 'Firefox', 'Flighty',
        'FreeCAD', 'GIMP', 'GitHub Copilot', 'GitHub Desktop', 'GoPro Player',
        'Google Chrome', 'Hidden Bar', 'IINA', 'Inkscape', 'Jellyfin', 'Kagi Search',
        'Kamusku', 'KeepingYouAwake', 'KeyCastr', 'keyviz', 'Lapce', 'Libation',
        'LocalSend', 'Microsoft Edge', 'MongoDB Compass', 'Motrix', 'Numi',
        'ONLYOFFICE', 'Open WebUI', 'OpenAudible', 'Orion', 'PDFgear', 'Pearcleaner',
        'Plex', 'Plexamp', 'Prologue', 'Proton Meet', 'Readest', 'Revu',
        'Script Debugger', 'Shazam', 'Shop', 'Shortcut Remote', 'Signal', 'Sketch',
        'Sorted³', 'SpotiFLAC-Next', 'SQLiteo', 'Super Productivity', 'Telegram',
        'Thunderbird', 'Tor Browser', 'Vivaldi', 'Visual Studio Code', 'Waterfox',
        'WhatsApp', 'ZCode', 'Zed'
    )
    caution = @(
        '1Password', 'Alfred 5', 'Android File Transfer', 'Elgato Camera Hub',
        'Elgato Capture Device Utility', 'Elgato Control Center', 'Elgato Stream Deck',
        'Elgato Studio', 'Ghostty', 'Hammerspoon', 'iTerm', 'Karabiner-EventViewer',
        'Keynote', 'LG Screen Manager', 'Microsoft Excel', 'Microsoft PowerPoint',
        'Microsoft Word', 'Numbers', 'OBS', 'Ollama', 'Pages', 'QuickLook Video',
        'Routine Screenshot', 'Swish', 'Toggle Office Lights', 'UI Browser', 'Vidimote',
        'Wox', 'zoom.us'
    )
    avoid = @(
        'Adguard', 'Audio Hijack', 'Backblaze', 'BackblazeRestore', 'Compressor',
        'DaVinci Resolve', 'Docker', 'ExpressVPN', 'Final Cut Pro', 'iMovie',
        'Karabiner-Elements', 'lghub', 'Loopback', 'OpenCore-Patcher', 'OrbStack',
        'Parallels Desktop', 'Plex Media Server', 'RustDesk', 'Safari', 'SoundSource',
        'Syncthing', 'Tailscale', 'VMware Fusion', 'Xcode'
    )
}

function Get-MoveTier {
    # Look up an app's safety tier: safe | caution | avoid, or unlisted when unknown.
    param([Parameter(Mandatory)] [string]$Name)
    foreach ($tier in $MoveTiers.Keys) {
        if ($MoveTiers[$tier] -contains $Name) { return $tier }
    }
    return 'unlisted'
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
  move [app] [destination]  Move an app bundle and its ~/Library footprint
                            (Application Support, Caches, Logs, WebKit,
                            HTTPStorages, Saved Application State) to external
                            storage, symlinking both back. With no app, an
                            interactive multiselect lists every installed app.
                            Asks where the app(s) should go when the destination
                            is omitted. The app is a name (aliases supported,
                            .app suffix optional) or a bundle path. Caution and
                            avoid list apps are locked in the multiselect and
                            refused when named.
  restore                   Move every externally-stored app - and its ~/Library
                            entries - back to the internal disk.
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
  pwsh -File ./mac-move-apps.ps1 move
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
    Write-Host 'Caution and avoid apps cannot be moved; safe apps are recommended.'
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

function Read-MultiChoice {
    # Arrow-key multiselect over Options (Name, Note, Locked), following the input
    # pattern of bevry-vibes menu.ps1: typed key comparisons, Ctrl+C captured as an
    # ordinary key, in-place redraw, console state restored in finally. Locked
    # entries render dimmed and can be neither focused nor toggled. Returns the
    # chosen names (empty = confirmed nothing), or $null when cancelled/aborted.
    param(
        [Parameter(Mandatory)] [pscustomobject[]]$Options,
        [string]$Title = 'Select'
    )
    if ([Console]::IsInputRedirected) { throw 'Read-MultiChoice requires an interactive console' }
    $focusIndex = @(for ($i = 0; $i -lt $Options.Count; $i++) { if (-not $Options[$i].Locked) { $i } })
    $chosen = [System.Collections.Generic.HashSet[int]]::new()
    $cursor = 0
    $top = 0
    $visible = [Math]::Min($Options.Count, 12)
    $lastCount = 0
    $firstDraw = $true
    $esc = [char]27
    $reset = $PSStyle.Reset
    $dim = $PSStyle.Dim
    $green = $PSStyle.Foreground.Green
    $bold = $PSStyle.Bold
    $previousTreatControlC = [Console]::TreatControlCAsInput

    Write-Host ''
    Write-Host "$bold$Title$reset"
    Write-Host 'up/down or j/k move · space toggle · a all · n none · enter confirm · q or esc cancel'
    Write-Host 'Locked entries (caution / do-not-move) cannot be selected.'

    try {
        [Console]::TreatControlCAsInput = $true
        # CursorVisible's getter throws on macOS, so save nothing and just restore
        [Console]::CursorVisible = $false
        while ($true) {
            if ($cursor -lt $top) { $top = $cursor }
            if ($cursor -ge $top + $visible) { $top = $cursor - $visible + 1 }
            if ($Options.Count -gt $visible) { $top = [Math]::Min($top, $Options.Count - $visible) }
            $lines = @()
            if ($top -gt 0) { $lines += "$dim  …$reset" }
            for ($i = $top; $i -lt [Math]::Min($top + $visible, $Options.Count); $i++) {
                $opt = $Options[$i]
                if ($opt.Locked) {
                    $lines += "$dim  [locked] $($opt.Name) - $($opt.Note)$reset"
                } else {
                    $box = $chosen.Contains($i) ? "$green[x]$reset" : '[ ]'
                    $arrow = ($focusIndex[$cursor] -eq $i) ? "$bold>$reset " : '  '
                    $lines += "$arrow$box $($opt.Name)$dim $($opt.Note)$reset"
                }
            }
            if ($top + $visible -lt $Options.Count) { $lines += "$dim  …$reset" }
            if (-not $firstDraw) { [Console]::Write("$esc[$($lastCount)A") }
            $firstDraw = $false
            foreach ($line in $lines) { [Console]::Write("$line$esc[K`r`n") }
            $lastCount = $lines.Count

            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::Enter) { break }
            if ($key.Key -eq [ConsoleKey]::Escape) { return $null }
            if ($key.Key -eq [ConsoleKey]::C -and ($key.Modifiers -band [ConsoleModifiers]::Control)) { return $null }
            if ($key.Key -eq [ConsoleKey]::UpArrow) {
                $cursor = ($cursor - 1 + $focusIndex.Count) % $focusIndex.Count
            } elseif ($key.Key -eq [ConsoleKey]::DownArrow) {
                $cursor = ($cursor + 1) % $focusIndex.Count
            } elseif ($key.Key -eq [ConsoleKey]::Home) {
                $cursor = 0
            } elseif ($key.Key -eq [ConsoleKey]::End) {
                $cursor = $focusIndex.Count - 1
            } elseif ($key.Key -eq [ConsoleKey]::Spacebar) {
                $i = $focusIndex[$cursor]
                if ($chosen.Contains($i)) { [void]$chosen.Remove($i) } else { [void]$chosen.Add($i) }
            } else {
                $c = [char]$key.KeyChar
                if ($c -eq 'j') { $cursor = ($cursor + 1) % $focusIndex.Count }
                elseif ($c -eq 'k') { $cursor = ($cursor - 1 + $focusIndex.Count) % $focusIndex.Count }
                elseif ($c -eq 'a' -or $c -eq 'A') { foreach ($i in $focusIndex) { [void]$chosen.Add($i) } }
                elseif ($c -eq 'n' -or $c -eq 'N') { $chosen.Clear() }
                elseif ($c -eq 'q' -or $c -eq 'Q') { return $null }
            }
        }
    } finally {
        [Console]::TreatControlCAsInput = $previousTreatControlC
        # best-effort: some terminals reject the restore once the picker is over
        try { [Console]::CursorVisible = $true } catch { Write-Host '' }
    }
    # the comma prevents PowerShell unrolling an empty selection into $null
    $names = @($focusIndex | Where-Object { $chosen.Contains($_) } | ForEach-Object { $Options[$_].Name })
    return , $names
}

function Test-AppReadyToMove {
    # Refuse already-symlinked and running apps. Reports the reason itself.
    param([Parameter(Mandatory)] [string]$Src)
    $item = Get-Item -LiteralPath $Src
    if ($item.LinkType -eq 'SymbolicLink') {
        Write-Caution "$(Split-Path $Src -Leaf) is already a symlink to $(@($item.Target)[0]) - nothing to move."
        return $false
    }
    $null = pgrep -f "$Src/"
    if ($LASTEXITCODE -eq 0) {
        Write-Caution "$(Split-Path $Src -Leaf) is running - quit it completely before moving."
        return $false
    }
    return $true
}

function Get-AppBundleIdentifier {
    # Read CFBundleIdentifier from an app bundle's Info.plist; '' when unreadable.
    param([Parameter(Mandatory)] [string]$BundlePath)
    $plist = Join-Path $BundlePath 'Contents/Info.plist'
    if (-not (Test-Path -LiteralPath $plist)) { return '' }
    $id = Invoke-Tool plutil @('-extract', 'CFBundleIdentifier', 'raw', '-o', '-', $plist) -Tolerant
    return "$id".Trim()
}

function Invoke-LibraryMove {
    # Relocate the app's ~/Library footprint - the big stuff: Application Support,
    # Caches, Logs, WebKit, HTTPStorages, Saved Application State - to LibRoot,
    # symlinking the original locations back. Preferences, Containers, and Group
    # Containers deliberately stay put: cfprefsd and sandbox path evaluation
    # misbehave through symlinks. Returns the number of entries moved.
    param(
        [Parameter(Mandatory)] [string]$AppName,
        [Parameter(Mandatory)] [string]$BundlePath,
        [Parameter(Mandatory)] [string]$LibRoot
    )
    $bundleId = Get-AppBundleIdentifier $BundlePath
    $relPaths = @("Application Support/$AppName", "Logs/$AppName")
    if ($bundleId) {
        $relPaths += @(
            "Application Support/$bundleId"
            "Caches/$bundleId"
            "Saved Application State/$bundleId.savedState"
            "WebKit/$bundleId"
            "HTTPStorages/$bundleId"
        )
    }
    $moved = 0
    foreach ($rel in ($relPaths | Select-Object -Unique)) {
        $libPath = Join-Path "$HOME/Library" $rel
        if (-not (Test-Path -LiteralPath $libPath)) { continue }
        if ((Get-Item -LiteralPath $libPath -Force).LinkType) { continue }
        $dest = Join-Path $LibRoot $rel
        $null = New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force
        Write-Info "moving ~/Library/$rel"
        try {
            Invoke-Tool ditto @($libPath, $dest)
            Invoke-Tool rm @('-rf', $libPath)
        } catch {
            Write-Caution "could not move ~/Library/${rel}: $_"
            $null = Invoke-Tool rm @('-rf', $dest) -Tolerant
            continue
        }
        $null = New-Item -ItemType SymbolicLink -Path $libPath -Target $dest
        $moved++
    }
    return $moved
}

function Invoke-LibraryRestore {
    # Reverse of Invoke-LibraryMove: walk the app's folder under the volume's
    # App Library root and move each entry back to its ~/Library location,
    # replacing the symlinks left there. Real entries at home are never clobbered.
    # Returns the number of entries restored.
    param(
        [Parameter(Mandatory)] [string]$AppName,
        [Parameter(Mandatory)] [string]$LibRoot
    )
    if (-not (Test-Path -LiteralPath $LibRoot)) { return 0 }
    $restored = 0
    foreach ($group in @(Get-ChildItem -LiteralPath $LibRoot -Directory)) {
        foreach ($item in @(Get-ChildItem -LiteralPath $group.FullName)) {
            $homePath = Join-Path "$HOME/Library/$($group.Name)" $item.Name
            $existing = Get-Item -LiteralPath $homePath -Force -ErrorAction SilentlyContinue
            if ($existing) {
                if ($existing.LinkType -eq 'SymbolicLink') {
                    Remove-Item -LiteralPath $homePath -Force
                } else {
                    Write-Caution "keeping ~/Library/$($group.Name)/$($item.Name) - a real entry replaced the symlink"
                    continue
                }
            }
            $null = New-Item -ItemType Directory -Path (Split-Path $homePath -Parent) -Force
            try {
                Invoke-Tool mv @($item.FullName, $homePath)
            } catch {
                Write-Caution "could not restore ~/Library/$($group.Name)/$($item.Name): $_"
                continue
            }
            $restored++
        }
        if (-not (Get-ChildItem -LiteralPath $group.FullName -Force)) { Remove-Item -LiteralPath $group.FullName -Force }
    }
    if (-not (Get-ChildItem -LiteralPath $LibRoot -Force)) { Remove-Item -LiteralPath $LibRoot -Force }
    return $restored
}

function Invoke-BundleMove {
    # Move one resolved, pre-checked bundle into DestDir and symlink it back.
    # Returns $true on success; reports its own failures.
    param(
        [Parameter(Mandatory)] [string]$Src,
        [Parameter(Mandatory)] [string]$DestDir
    )
    $appFile = Split-Path $Src -Leaf
    $destParent = Split-Path $DestDir -Parent
    if (-not (Test-Path -LiteralPath $destParent)) {
        Write-Failure "destination drive is not mounted: $destParent"
        return $false
    }
    $null = New-Item -ItemType Directory -Path $DestDir -Force
    $dst = Join-Path $DestDir $appFile

    if (Test-Path -LiteralPath $dst) {
        if ($Force) {
            Write-Caution "destination exists, overwriting: $dst"
            Remove-Item -LiteralPath $dst -Recurse -Force
        } else {
            Write-Failure "destination already exists: $dst (re-run with -Force to overwrite)"
            return $false
        }
    }

    Write-Info "moving $Src"
    Write-Info "   to $dst"
    Write-Info "symlink back at $Src"

    # ditto preserves bundle structure, metadata, extended attributes, and forks
    Write-Info 'copying the bundle with ditto...'
    try {
        Invoke-Tool ditto @($Src, $dst)
    } catch {
        Write-Failure "ditto copy failed: $_"
        return $false
    }

    Write-Info 'removing the original...'
    try {
        Invoke-Tool rm @('-rf', $Src)
    } catch {
        Write-Caution 'plain removal failed - retrying with sudo (password may be asked)...'
        try {
            Invoke-Tool sudo @('rm', '-rf', $Src)
        } catch {
            Write-Failure "could not remove the original: $_"
            $null = Invoke-Tool rm @('-rf', $dst) -Tolerant
            Write-Caution "rolled back the copy at $dst"
            return $false
        }
    }

    $null = New-Item -ItemType SymbolicLink -Path $Src -Target $dst

    # clear quarantine and re-sign so Gatekeeper accepts the relocated bundle
    Write-Info 'clearing extended attributes and re-signing...'
    $null = Invoke-Tool xattr @('-cr', $dst) -Tolerant
    $null = Invoke-Tool codesign @('--force', '--deep', '--sign', '-', $dst) -Tolerant

    Write-Info 're-registering with LaunchServices...'
    $null = Invoke-Tool $LsRegister @('-f', $dst) -Tolerant

    # relocate the app's ~/Library footprint next to the bundle on the volume
    $name = $appFile -replace '\.app$', ''
    $libRoot = Join-Path (Split-Path $DestDir -Parent) "App Library/$name"
    $libMoved = Invoke-LibraryMove -AppName $name -BundlePath $Src -LibRoot $libRoot

    Write-Info "moved $appFile to $dst$(($libMoved -gt 0) ? " (+$libMoved ~/Library entries)" : '')"
    return $true
}

function Invoke-MoveBatch {
    # move with no app given: multiselect across every installed app, then one
    # destination for all. Caution and avoid apps show up locked.
    if ([Console]::IsInputRedirected) {
        Write-Failure 'no app given and stdin is not interactive - pass an app name and destination, or run in a terminal.'
        exit 2
    }
    $installed = @(Get-InstalledApp)
    if ($installed.Count -eq 0) {
        Write-Info 'no installed apps found in the search dirs.'
        return
    }
    $tierOrder = @{ safe = 0; unlisted = 1; caution = 2; avoid = 3 }
    $rawOptions = foreach ($app in $installed) {
        $tier = Get-MoveTier $app
        [pscustomobject]@{
            Name   = $app
            Tier   = $tier
            Locked = $tier -in 'caution', 'avoid'
            Note   = switch ($tier) {
                'safe'    { 'safe' }
                'caution' { 'caution - locked' }
                'avoid'   { 'do not move - locked' }
                default   { 'unlisted' }
            }
        }
    }
    $options = @($rawOptions | Sort-Object { $tierOrder[$_.Tier] }, Name)
    if (-not ($options | Where-Object { -not $_.Locked })) {
        Write-Info 'every installed app is on the caution or do-not-move list - nothing can be moved.'
        return
    }

    $chosenNames = Read-MultiChoice -Options $options -Title 'Select apps to move'
    if ($null -eq $chosenNames) {
        Write-Info 'cancelled.'
        return
    }
    if ($chosenNames.Count -eq 0) {
        Write-Info 'nothing selected.'
        return
    }

    $destDir = if ($Destination) { $Destination } else { Read-Destination }
    $moved = 0
    $failed = 0
    $skipped = 0
    foreach ($name in $chosenNames) {
        $src = Resolve-AppBundle "$name.app"
        if (-not $src -or -not (Test-AppReadyToMove $src)) { $skipped++; continue }
        if (Invoke-BundleMove $src $destDir) { $moved++ } else { $failed++ }
    }

    Write-Host ''
    Write-Info "moved $moved app(s) to $destDir - skipped $skipped, failed $failed."
    if ($moved -gt 0) {
        Write-Host 'Next steps:'
        Write-Host '  - refresh caches:  pwsh -File ./mac-move-apps.ps1 refresh <app>'
        Write-Host '  - undo everything: pwsh -File ./mac-move-apps.ps1 restore'
    }
    if ($failed -gt 0 -and $moved -eq 0) { exit 1 }
}

function Invoke-Move {
    if (-not $AppName) { Invoke-MoveBatch; return }
    $appFile = Resolve-AppName $AppName
    $name = $appFile -replace '\.app$', ''
    $src = Resolve-AppBundle $appFile
    if (-not $src) {
        Write-Failure "app not found in $($SearchDirs -join ' or '): $appFile"
        exit 1
    }
    $tier = Get-MoveTier $name
    if ($tier -in 'caution', 'avoid') {
        Write-Failure "$name is on the $tier list - moving it is disabled."
        exit 1
    }
    if (-not (Test-AppReadyToMove $src)) { exit 1 }
    $destDir = if ($Destination) { $Destination } else { Read-Destination }
    if (-not (Invoke-BundleMove $src $destDir)) { exit 1 }
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
        $bundleOk = $false
        try {
            Remove-Item -LiteralPath $app.LinkPath
            Invoke-Tool mv @($app.Target, $app.LinkPath)
            $bundleOk = $true
        } catch {
            Write-Host 'failed'
            Write-Caution "  could not restore $($app.Name): $_"
            # relink so the external copy stays reachable
            if (-not (Test-Path -LiteralPath $app.LinkPath)) {
                $null = New-Item -ItemType SymbolicLink -Path $app.LinkPath -Target $app.Target
            }
            $failed++
        }
        if ($bundleOk) {
            # bring the app's ~/Library entries back from the volume's App Library;
            # a library failure never fails the restored bundle itself
            $libRoot = Join-Path (Split-Path (Split-Path $app.Target -Parent) -Parent) "App Library/$($app.Name)"
            $libRestored = 0
            try {
                $libRestored = Invoke-LibraryRestore -AppName $app.Name -LibRoot $libRoot
            } catch {
                Write-Caution "  could not restore ~/Library entries for $($app.Name): $_"
            }
            Write-Host "done$(($libRestored -gt 0) ? " (+$libRestored ~/Library entries)" : '')"
            $restored++
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

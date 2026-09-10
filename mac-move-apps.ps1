#!/usr/bin/env pwsh
#Requires -Version 7.6
<#
.SYNOPSIS
    mac-move-apps - move macOS .app bundles to external storage and back, keeping them launchable via symlinks.

.DESCRIPTION
    Single command wrapping the full app-relocation workflow:

      move [app] [destination]   Copy the .app bundle to external storage (a
                                 full-fidelity copy that preserves the app's
                                 signature and metadata), replace the original with
                                 a symlink, clear macOS's quarantine flag if present,
                                 keep the app's original signature (re-signing
                                 locally only when the copy broke it), and
                                 re-register the app with macOS.
                                 The app's ~/Library footprint (Application Support,
                                 Caches, Logs, WebKit, HTTPStorages, Saved Application
                                 State) moves to the volume's 'App Library' folder too,
                                 symlinked back. When both a local and a volume copy
                                 of an entry exist, the live/newer copy is kept
                                 automatically only when clearly safe (identical
                                 snapshots or a clearly staler leftover); two divergent
                                 copies stop that entry and ask which to keep.
                                 With no app given, a full-height
                                 interactive multiselect lists every installed app
                                 with tier colours, sizes, the paths a move would
                                 relocate, and a live selected-total footer.
                                 When the destination is omitted, the command asks
                                 where the app should go, offering mounted volumes.
      restore [app]              Move every externally-stored app - or just the named
                                 one - and its ~/Library entries back to the internal
                                 disk. Entries where real data reappeared at home
                                 resolve the same two-copy conflict: identical or
                                 clearly staler copies resolve automatically
                                 (recoverably), divergent copies ask which to keep.
      list                       Show installed apps categorised by how safe they
                                 are to move, with sizes and totals.
      status                     Show apps already moved to external storage.
      doctor                     Audit moved apps for partial or broken relocations
                                 (data left behind, dangling links, volume orphans,
                                 locked-tier apps like the Mozilla family), then fix
                                 each in the direction you choose: complete moves
                                 remaining local data to the volume, revert moves
                                 the app back to the internal disk.
      refresh <app>              Re-register an app with LaunchServices and refresh
                                 Dock, Finder, and Spotlight; -ForceRepair also
                                 clears quarantine and re-signs the app only when
                                 its signature is broken.

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
    pwsh -File ./mac-move-apps.ps1 doctor

    Reports every inconsistent moved app and asks per app: complete, revert, or skip.

.EXAMPLE
    pwsh -File ./mac-move-apps.ps1 doctor -Direction revert

    Brings every problem app back to the internal disk without asking.

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
    [switch]$ForceRepair,
    [ValidateSet('', 'complete', 'revert')][string]$Direction = ''
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
#             services; or patches the system (Apple pro media apps included); or
#             known-broken when moved (Orion fails to work at all from a volume).
#   caution - relies on integration that references its install path or keys
#             permissions to it (browser native messaging, accessibility/TCC grants,
#             driver installers, App Store Apple apps, terminals, and the Mozilla
#             family - Firefox, Thunderbird, Waterfox - whose profiles are keyed
#             to the install path, so relocation looks like a fresh install).
#   safe    - self-contained GUI apps with no system integration.
$MoveTiers = [ordered]@{
    safe = @(
        '0 A.D.', 'ABDownloadManager', 'Actions', 'Amazon Kindle', 'Android Studio',
        'AnythingLLM', 'Aural', 'Audacity', 'balenaEtcher', 'Beeper Desktop', 'Bible',
        'Blender', 'Brave Browser', 'BusyCal', 'BusyContacts', 'Byword', 'calibre',
        'ChatGPT', 'Claude', 'DBeaver', 'Discord', 'draw.io', 'Duplicate File Finder',
        'eero', 'Endel', 'Flighty', 'FreeCAD', 'GIMP', 'GitHub Copilot',
        'GitHub Desktop', 'GoPro Player', 'Google Chrome', 'Hidden Bar', 'IINA',
        'Insta360 Studio', 'Inkscape', 'Jellyfin', 'Kagi Search', 'Kamusku',
        'KeepingYouAwake', 'KeyCastr', 'keyviz', 'Lapce', 'Libation', 'LocalSend',
        'Menu Bar Controller for Sonos 2', 'Meta', 'Microsoft Edge', 'Mole',
        'MongoDB Compass', 'Motrix', 'mux', 'Numi', 'ONLYOFFICE', 'Open WebUI',
        'OpenAudible', 'Openscreen', 'PDFgear', 'Pearcleaner', 'Plezy',
        'Plex', 'Plexamp', 'Prologue', 'Proton Mail Uninstaller', 'Proton Meet',
        'Quiet', 'Radix', 'Readest', 'Revu', 'Script Debugger', 'Shazam', 'Shop',
        'Shortcut Remote', 'Signal', 'Sketch', 'Sorted³', 'SpotiFLAC-Next',
        'SQLiteo', 'Super Productivity', 'Telegram', 'Tolaria',
        'tribler-8.4.3-arm', 'Tor Browser', 'Vivaldi', 'Visual Studio Code',
        'WhatsApp', 'ZCode', 'Zed'
    )
    caution = @(
        '1Password', 'Alfred 5', 'Android File Transfer', 'Choosy', 'Data Jar',
        'Elgato Camera Hub', 'Elgato Capture Device Utility', 'Elgato Control Center',
        'Elgato Stream Deck', 'Elgato Studio', 'Firefox', 'Ghostty', 'Hammerspoon',
        'iTerm', 'Karabiner-EventViewer', 'Keynote', 'LG Screen Manager',
        'Microsoft Excel', 'Microsoft PowerPoint', 'Microsoft Word', 'Numbers',
        'OBS', 'Ollama', 'Pages', 'QuickLook Video', 'Routine Screenshot', 'Swish',
        'TestFlight', 'Thunderbird', 'Toggle Office Lights', 'UI Browser',
        'Vidimote', 'Waterfox', 'Wox', 'zoom.us'
    )
    avoid = @(
        'Adguard', 'Audio Hijack', 'Backblaze', 'BackblazeRestore', 'Compressor',
        'Compressor Creator Studio', 'DaVinci Resolve', 'Docker', 'ExpressVPN',
        'Final Cut Pro', 'iMovie', 'Karabiner-Elements', 'lghub', 'Loopback',
        'OpenCore-Patcher', 'OrbStack', 'Orion', 'Parallels Desktop', 'Plex Media Server',
        'RustDesk', 'Safari', 'SoundSource', 'Syncthing', 'Tailscale',
        'VMware Fusion', 'Xcode'
    )
}

# Terminal colour per tier, shared by the multiselect and the list output.
$TierColors = @{
    safe     = $PSStyle.Foreground.Green
    caution  = $PSStyle.Foreground.Yellow
    avoid    = $PSStyle.Foreground.Red
    unlisted = $PSStyle.Foreground.Cyan
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

function Write-RemovableVolumeNote {
    # Printed after library data lands on an external volume: macOS gates app
    # access to removable volumes behind a TCC permission, so the first launch
    # may prompt (or fail with EPERM until granted).
    Write-Info 'app data now lives on a removable volume - on first launch macOS may ask for "Removable Volumes" access: allow it (System Settings > Privacy & Security > Files & Folders)'
}

function Invoke-Tool {
    # Run a native tool with stderr captured into the returned output.
    # Throws on a non-zero exit unless -Tolerant.
    param(
        [Parameter(Mandatory)] [string]$Name,
        [string[]]$ToolArgs = @(),
        [switch]$Tolerant
    )
    $output = $null
    try {
        $output = & $Name @ToolArgs 2>&1
    } catch {
        # the tool itself was missing (e.g. a moved system binary), not a tool failure
        if ($Tolerant) { return $null }
        throw "could not run $Name`: $_"
    }
    if ($LASTEXITCODE -ne 0 -and -not $Tolerant) {
        throw "$Name $($ToolArgs -join ' ') failed with exit $LASTEXITCODE`: $(($output | Out-String).Trim())"
    }
    return $output
}

function Invoke-Trash {
    # Move paths to the macOS Trash with the built-in /usr/bin/trash (TRASH(8)).
    # Internal-disk paths are effectively a rename, Finder-style collision
    # naming applies, and the item stays recoverable until the Trash is emptied.
    # Returns $true only when every path left its original location. Deletions
    # of original user data go through here, never plain rm: a trashed item can
    # be pulled back out.
    param([Parameter(Mandatory)] [string[]]$Paths)
    if (-not (Test-Path -LiteralPath '/usr/bin/trash')) {
        Write-Caution "could not move to the Trash: /usr/bin/trash is not available: $($Paths -join ', ')"
        return $false
    }
    $trashArgs = @('-s') + $Paths
    $output = & /usr/bin/trash @trashArgs 2>&1
    $failed = @($Paths | Where-Object { Test-Path -LiteralPath $_ })
    if ($failed.Count -gt 0) {
        $reason = (($output | Out-String).Trim() -replace '\s+', ' ')
        Write-Caution "could not move to the Trash: $($failed -join ', ')$(($reason) ? " ($reason)" : '')"
        return $false
    }
    return $true
}

function Resolve-AppName {
    # Map a short name to its canonical bundle name and ensure the .app suffix.
    param([Parameter(Mandatory)] [string]$Name)
    $canonical = $AppAliases[$Name] ?? $Name
    return $canonical.EndsWith('.app') ? $canonical : "$canonical.app"
}

function Resolve-AppBundle {
    # Locate an app bundle by name in the search dirs, or accept a direct path
    # (~ and relative paths expanded for the direct-path form).
    param([Parameter(Mandatory)] [string]$AppFile)
    if ($AppFile -match '/') {
        $AppFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($AppFile)
        return (Test-Path -LiteralPath $AppFile) ? (Get-Item -LiteralPath $AppFile).FullName : $null
    }
    foreach ($dir in $SearchDirs) {
        $candidate = Join-Path $dir $AppFile
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Get-InstalledApp {
    # Bundles sitting in the search dirs; apps already symlinked elsewhere are skipped.
    foreach ($dir in $SearchDirs) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        Get-ChildItem -LiteralPath $dir -Filter *.app -Directory | Where-Object { -not $_.LinkType } |
            ForEach-Object { [pscustomobject]@{ Name = $_.Name -replace '\.app$', ''; Path = $_.FullName } }
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
  restore [app]             Move every externally-stored app - or just the named
                            one - and its ~/Library entries back to the internal
                            disk. Entries where real data reappeared at home
                            resolve the same two-copy conflict: identical or
                            clearly staler copies resolve automatically
                            (recoverably), divergent copies ask.
  list                      Show installed apps categorised by move safety.
  status                    Show apps already moved to external storage.
  refresh <app>             Refresh the app's macOS registration, Dock, Finder,
                            and Spotlight for a moved app.
  doctor                    Audit moved apps for partial or broken relocations,
                            then fix each in the direction you choose:
                            complete = move remaining local data to the volume,
                            revert = move the app back to the internal disk.

Options:
  -Force        move: overwrite an existing app at the destination.
  -DryRun       restore: preview what would move, change nothing.
  -Yes          restore: skip the confirmation prompt.
  -ForceRepair  refresh: also clear quarantine and re-sign the app when its
                signature is broken (a valid original signature is kept intact).
  -Direction    doctor: 'complete' or 'revert' - apply to every problem app
                without asking.

Examples:
  pwsh -File ./mac-move-apps.ps1 move
  pwsh -File ./mac-move-apps.ps1 move 'Visual Studio Code'
  pwsh -File ./mac-move-apps.ps1 move Motrix /Volumes/Scratchpad/Applications
  pwsh -File ./mac-move-apps.ps1 restore -DryRun
  pwsh -File ./mac-move-apps.ps1 doctor
  pwsh -File ./mac-move-apps.ps1 doctor -Direction revert
  pwsh -File ./mac-move-apps.ps1 refresh IINA -ForceRepair

Apps are searched for in /Applications and ~/Applications.
Exit codes: 0 = success, 1 = failure, 2 = usage error.
'@ | Write-Host
    exit 2
}

function Show-MovableList {
    Write-Info 'measuring apps...'
    $apps = @(Get-AppInventory)
    if ($apps.Count -eq 0) {
        Write-Info 'no installed apps found in the search dirs.'
        return
    }
    $sections = [ordered]@{
        safe     = 'Safe to move - pure GUI apps, no system extensions'
        caution  = 'Move with caution - locked (integration keys to the install path)'
        avoid    = 'Do not move - locked (drivers, extensions, root helpers, launchd services)'
        unlisted = 'Unclassified - review before moving'
    }
    $grandKb = 0
    $grandCount = 0
    foreach ($tier in $sections.Keys) {
        Write-Host ''
        Write-Host "$($TierColors[$tier])$($sections[$tier])$($PSStyle.Reset)"
        $hits = @($apps | Where-Object Tier -eq $tier)
        if ($hits.Count -eq 0) {
            Write-Host '  (none installed)'
            continue
        }
        $sectionKb = 0
        foreach ($app in $hits) {
            Write-Host "  $($TierColors[$tier])- $($app.Name)$($PSStyle.Reset)$($PSStyle.Dim)  $(Format-Size $app.SizeKb)$($PSStyle.Reset)"
            $sectionKb += $app.SizeKb
        }
        Write-Host "$($PSStyle.Dim)  section: $($hits.Count) app(s), $(Format-Size $sectionKb)$($PSStyle.Reset)"
        if ($tier -in 'safe', 'unlisted') { $grandKb += $sectionKb; $grandCount += $hits.Count }
    }
    Write-Host ''
    Write-Host "$($PSStyle.Bold)selectable (safe + unclassified): $grandCount app(s), $(Format-Size $grandKb)$($PSStyle.Reset)"
    Write-Host 'Caution and avoid apps are locked and cannot be moved; safe apps are recommended.'
    Write-Host 'Unclassified apps: review before moving - anything with privileged helpers,'
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
    # Full-height arrow-key multiselect, following the input pattern of
    # bevry-vibes menu.ps1: typed key comparisons, Ctrl+C captured as an ordinary
    # key, in-place redraw, console state restored in finally. Each entry renders
    # as a tier-coloured headline (name, size, status) with the paths a move
    # would relocate listed dimly underneath; locked entries stay single-line.
    # The footer's selected count and total update on every toggle. Returns the
    # chosen names (empty = confirmed nothing), or $null when cancelled/aborted.
    param(
        [Parameter(Mandatory)] [pscustomobject[]]$Options,
        [string]$Title = 'Select'
    )
    if ([Console]::IsInputRedirected) { throw 'Read-MultiChoice requires an interactive console' }
    $focusIndex = @(for ($i = 0; $i -lt $Options.Count; $i++) { if (-not $Options[$i].Locked) { $i } })
    if ($focusIndex.Count -eq 0) { return , @() }
    $chosen = [System.Collections.Generic.HashSet[int]]::new()
    $cursor = 0
    $top = 0
    $maxPathLines = 4
    $esc = [char]27
    $reset = $PSStyle.Reset
    $dim = $PSStyle.Dim
    $green = $PSStyle.Foreground.Green
    $bold = $PSStyle.Bold
    $previousTreatControlC = [Console]::TreatControlCAsInput

    $lineCount = {
        # headline + path preview lines (+ an overflow line) per entry
        param([pscustomobject]$Opt)
        if ($Opt.Locked) { return 1 }
        $pathLines = [Math]::Min($Opt.Paths.Count, $maxPathLines)
        $more = ($Opt.Paths.Count -gt $maxPathLines) ? 1 : 0
        return 1 + $pathLines + $more
    }

    $headerLines = 3   # blank + title + locked note, written once below
    Write-Host ''
    Write-Host "$bold$Title$reset"
    Write-Host "$dim locked entries (caution / do-not-move) cannot be selected.$reset"

    $shown = @()
    $lastDrawn = 0
    $firstDraw = $true
    try {
        [Console]::TreatControlCAsInput = $true
        # CursorVisible's getter throws on macOS, so save nothing and just restore
        [Console]::CursorVisible = $false
        while ($true) {
            # fill the window: header + footer + a one-line breathing margin
            $budget = [Math]::Max([Console]::WindowHeight - $headerLines - 3, 3)
            if ($focusIndex[$cursor] -lt $top) { $top = $focusIndex[$cursor] }

            foreach ($attempt in @($top, $focusIndex[$cursor])) {
                $shown = @()
                $lines = 0
                for ($i = $attempt; $i -lt $Options.Count; $i++) {
                    $count = & $lineCount $Options[$i]
                    if ($lines + $count -gt $budget -and $shown.Count -gt 0) { break }
                    $shown += $i
                    $lines += [Math]::Min($count, $budget - $lines)
                }
                if ($shown -contains $focusIndex[$cursor]) { $top = $attempt; break }
                # the focused entry fell outside the window - restart from it
            }

            # footer: controls + live totals over the current selection
            $selectedKb = 0
            foreach ($i in $chosen) { $selectedKb += $Options[$i].SizeKb }
            $footer = @(
                "$dim up/down or j/k move · space toggle · a all · n none · enter confirm · q or esc cancel$reset"
                "$bold$($chosen.Count) selected · $(Format-Size $selectedKb) will be moved$reset"
            )

            $out = @()
            foreach ($i in $shown) {
                $opt = $Options[$i]
                $color = $TierColors[$opt.Tier]
                if ($opt.Locked) {
                    $out += "$dim  [locked] $($opt.Name)$reset$dim  $(Format-Size $opt.SizeKb)  $($opt.Note)$reset"
                    continue
                }
                $box = $chosen.Contains($i) ? "$green[x]$reset" : '[ ]'
                $arrow = ($focusIndex[$cursor] -eq $i) ? "$bold>$reset " : '  '
                $out += "$arrow$box $color$($opt.Name)$reset$dim  $(Format-Size $opt.SizeKb)  $($opt.Note)$reset"
                $paths = @($opt.Paths)
                $take = [Math]::Min($paths.Count, $maxPathLines)
                for ($p = 0; $p -lt $take -and $out.Count -lt $budget; $p++) {
                    $short = $paths[$p] -replace [regex]::Escape($HOME), '~'
                    $out += "$dim      $short$reset"
                }
                if ($paths.Count -gt $maxPathLines -and $out.Count -lt $budget) {
                    $out += "$dim      … +$($paths.Count - $maxPathLines) more$reset"
                }
            }

            $lastDrawn = $out.Count + $footer.Count
            if (-not $firstDraw) { [Console]::Write("$esc[$($lastDrawn)A") }
            $firstDraw = $false
            foreach ($line in $out + $footer) { [Console]::Write("$esc[2K$line`r`n") }

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

function Test-AppRunning {
    # True when a process runs from any of the given paths: apps launch as
    # "<bundle>/Contents/MacOS/<binary>", so the bundle path with a trailing
    # slash matches both symlink-launched and volume-launched processes.
    param([Parameter(Mandatory)] [string[]]$Paths)
    foreach ($path in $Paths) {
        $null = pgrep -f ([regex]::Escape("$path/"))
        if ($LASTEXITCODE -eq 0) { return $true }
    }
    return $false
}

function Test-AppReadyToMove {
    # Refuse already-symlinked and running apps. Reports the reason itself.
    param([Parameter(Mandatory)] [string]$Src)
    $item = Get-Item -LiteralPath $Src
    if ($item.LinkType -eq 'SymbolicLink') {
        Write-Caution "$(Split-Path $Src -Leaf) is already a symlink to $(@($item.Target)[0]) - nothing to move."
        return $false
    }
    if (Test-AppRunning @($Src)) {
        Write-Caution "$(Split-Path $Src -Leaf) is running - quit it completely before moving."
        return $false
    }
    return $true
}

function Get-AppBundleIdentifier {
    # Read CFBundleIdentifier from an app bundle's Info.plist; '' when unreadable
    # (no plist, or the read is denied). Direct native call so $LASTEXITCODE is
    # this scope's, not an inner function's.
    param([Parameter(Mandatory)] [string]$BundlePath)
    $plist = Join-Path $BundlePath 'Contents/Info.plist'
    if (-not (Test-Path -LiteralPath $plist)) { return '' }
    $id = plutil -extract CFBundleIdentifier raw -o - $plist 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
    return "$id".Trim()
}

# Port of Mozilla's vendored CityHash v1 (other-licenses/nsis/Contrib/CityHash/cityhash),
# compiled lazily by Get-MozillaInstallHash. Verified to reproduce the install hashes
# observed in this machine's Thunderbird profiles.ini.
$CityHashSource = @'
using System;
using System.Text;

public static class CityHash {
    const ulong K0 = 0xc3a5c85c97cb3127UL;
    const ulong K1 = 0xb492b66fbe98f273UL;
    const ulong K2 = 0x9ae16a3b2f90404fUL;
    const ulong K3 = 0xc949d7c7509e6557UL;
    const ulong KMul = 0x9ddfea08eb382d69UL;

    static ulong Load64(byte[] s, int i) { return BitConverter.ToUInt64(s, i); }
    static uint Load32(byte[] s, int i) { return BitConverter.ToUInt32(s, i); }
    static ulong Rotate(ulong val, int shift) {
        return shift == 0 ? val : ((val >> shift) | (val << (64 - shift)));
    }
    static ulong RotateByAtLeast1(ulong val, int shift) {
        return (val >> shift) | (val << (64 - shift));
    }
    static ulong ShiftMix(ulong val) { return val ^ (val >> 47); }
    static ulong HashLen16(ulong u, ulong v) {
        ulong a = (u ^ v) * KMul;
        a ^= a >> 47;
        ulong b = (v ^ a) * KMul;
        b ^= b >> 47;
        b *= KMul;
        return b;
    }
    static ulong HashLen0to16(byte[] s, int len) {
        if (len > 8) {
            ulong a = Load64(s, 0);
            ulong b = Load64(s, len - 8);
            return HashLen16(a, RotateByAtLeast1(b + (ulong)len, len)) ^ b;
        }
        if (len >= 4) {
            ulong a = Load32(s, 0);
            return HashLen16((ulong)len + (a << 3), Load32(s, len - 4));
        }
        if (len > 0) {
            ulong a = s[0];
            ulong b = s[len >> 1];
            ulong c = s[len - 1];
            ulong y = a + (b << 8);
            ulong z = (ulong)len + (c << 2);
            return ShiftMix(y * K2 ^ z * K3) * K2;
        }
        return K2;
    }
    static ulong HashLen17to32(byte[] s, int len) {
        ulong a = Load64(s, 0) * K1;
        ulong b = Load64(s, 8);
        ulong c = Load64(s, len - 8) * K2;
        ulong d = Load64(s, len - 16) * K0;
        return HashLen16(Rotate(a - b, 43) + Rotate(c, 30) + d,
                         a + Rotate(b ^ K3, 20) - c + (ulong)len);
    }
    static void WeakHashLen32WithSeeds(byte[] s, int off, ulong a, ulong b, out ulong first, out ulong second) {
        ulong w = Load64(s, off), x = Load64(s, off + 8), y = Load64(s, off + 16), z = Load64(s, off + 24);
        a += w;
        b = Rotate(b + a + z, 21);
        ulong c = a;
        a += x;
        a += y;
        b += Rotate(a, 44);
        first = a + z;
        second = b + c;
    }
    static ulong HashLen33to64(byte[] s, int len) {
        ulong z = Load64(s, 24);
        ulong a = Load64(s, 0) + ((ulong)len + Load64(s, len - 16)) * K0;
        ulong b = Rotate(a + z, 52);
        ulong c = Rotate(a, 37);
        a += Load64(s, 8);
        c += Rotate(a, 7);
        a += Load64(s, 16);
        ulong vf = a + z;
        ulong vs = b + Rotate(a, 31) + c;
        a = Load64(s, 16) + Load64(s, len - 32);
        z = Load64(s, len - 8);
        b = Rotate(a + z, 52);
        c = Rotate(a, 37);
        a += Load64(s, len - 24);
        c += Rotate(a, 7);
        a += Load64(s, len - 16);
        ulong wf = a + z;
        ulong ws = b + Rotate(a, 31) + c;
        ulong r = ShiftMix((vf + ws) * K2 + (wf + vs) * K0);
        return ShiftMix(r * K0 + vs) * K2;
    }
    public static ulong Hash64(byte[] s) {
        int len = s.Length;
        if (len <= 32) {
            if (len <= 16) return HashLen0to16(s, len);
            return HashLen17to32(s, len);
        }
        if (len <= 64) return HashLen33to64(s, len);
        ulong x = Load64(s, 0);
        ulong y = Load64(s, len - 16) ^ K1;
        ulong z = Load64(s, len - 56) ^ K0;
        ulong vFirst, vSecond, wFirst, wSecond;
        WeakHashLen32WithSeeds(s, len - 64, (ulong)len, y, out vFirst, out vSecond);
        WeakHashLen32WithSeeds(s, len - 32, (ulong)len * K1, K0, out wFirst, out wSecond);
        z += ShiftMix(vSecond) * K1;
        x = Rotate(z + x, 39) * K1;
        y = Rotate(y, 33) * K1;
        int remaining = (len - 1) & ~63;
        int off = 0;
        do {
            x = Rotate(x + y + vFirst + Load64(s, off + 16), 37) * K1;
            y = Rotate(y + vSecond + Load64(s, off + 48), 42) * K1;
            x ^= wSecond;
            y ^= vFirst;
            z = Rotate(z ^ wFirst, 33);
            ulong nvFirst, nvSecond, nwFirst, nwSecond;
            WeakHashLen32WithSeeds(s, off, vSecond * K1, x + wFirst, out nvFirst, out nvSecond);
            WeakHashLen32WithSeeds(s, off + 32, z + wSecond, y, out nwFirst, out nwSecond);
            vFirst = nvFirst; vSecond = nvSecond; wFirst = nwFirst; wSecond = nwSecond;
            ulong tmp = z; z = x; x = tmp;
            off += 64;
            remaining -= 64;
        } while (remaining != 0);
        return HashLen16(HashLen16(vFirst, wFirst) + ShiftMix(y) * K1 + z,
                         HashLen16(vSecond, wSecond) + x);
    }
    public static string InstallHash(string installDirPath) {
        // UTF-16 code units, native endianness - matches the char16_t bytes
        // Mozilla hashes (little-endian on Apple Silicon and Intel)
        return Hash64(Encoding.Unicode.GetBytes(installDirPath)).ToString("X");
    }
}
'@

function Get-MozillaInstallHash {
    # Mozilla's per-installation identifier: CityHash64 over the UTF-16LE bytes
    # of the bundle's Contents/MacOS directory path (nsXREDirProvider::GetInstallHash
    # + GetInstallHash in commonupdatedir.cpp), uppercase hex. This is the <hash>
    # in profiles.ini's [Install<hash>] sections, so a relocated bundle computes
    # a different hash and Mozilla apps treat it as a new installation.
    param([Parameter(Mandatory)] [string]$BundlePath)
    if (-not ('CityHash' -as [type])) {
        Add-Type -TypeDefinition $CityHashSource -Language CSharp
    }
    return [CityHash]::InstallHash((Join-Path $BundlePath 'Contents/MacOS'))
}

function Invoke-MozillaRepoint {
    # After a Mozilla-family app's bundle settles at a new physical path, make the
    # first launch from there keep the existing profile instead of creating a
    # fresh one: point the CURRENT install section's Default= at the profile the
    # app used before the move, in profiles.ini and its sibling installs.ini.
    # Gate: only apps that actually have a Mozilla-style profiles.ini are touched
    # (~/Library/<app>/profiles.ini or ~/Library/Application Support/<app>/profiles.ini).
    # The original is kept once as <ini>.bak-mac-move-apps. Returns $true when a
    # file was rewritten.
    param(
        [Parameter(Mandatory)] [string]$AppName,
        [Parameter(Mandatory)] [string]$BundlePath
    )
    $iniPath = @(
        (Join-Path "$HOME/Library" "$AppName/profiles.ini")
        (Join-Path "$HOME/Library/Application Support" "$AppName/profiles.ini")
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $iniPath) { return $false }   # not a Mozilla-style app - nothing to do

    $currentHash = Get-MozillaInstallHash $BundlePath
    $lines = [System.IO.File]::ReadAllLines($iniPath)
    $section = ''
    $installDefaults = @{}
    $profilePaths = @{}
    $defaultProfileFlag = ''
    foreach ($line in $lines) {
        if ($line -match '^\s*\[(.+)\]\s*$') { $section = $Matches[1]; continue }
        if ($line -notmatch '^\s*(\w+)\s*=\s*(.*?)\s*$') { continue }
        $key = $Matches[1]
        $value = $Matches[2]
        if ($section -like 'Install*' -and $key -eq 'Default') { $installDefaults[$section] = $value }
        if ($section -match '^Profile\d+$' -and $key -eq 'Path') { $profilePaths[$section] = $value }
        if ($section -match '^Profile\d+$' -and $key -eq 'Default' -and $value -eq '1') { $defaultProfileFlag = $section }
    }
    # pick the profile to repoint to: the existing profile another install used,
    # preferring the most recently modified; fall back to the [Profile*] marked default
    $iniDir = Split-Path $iniPath -Parent
    $best = ''
    $bestMtime = [datetime]::MinValue
    foreach ($entry in $installDefaults.GetEnumerator()) {
        if ($entry.Key -eq "Install$currentHash") { continue }
        $value = $entry.Value
        if (-not $value) { continue }
        $profileDir = $value.StartsWith('/') ? $value : (Join-Path $iniDir $value)
        if (-not (Test-Path -LiteralPath $profileDir)) { continue }
        $mtime = (Get-Item -LiteralPath $profileDir).LastWriteTime
        if ($mtime -gt $bestMtime) { $bestMtime = $mtime; $best = $value }
    }
    if (-not $best -and $defaultProfileFlag -and $profilePaths[$defaultProfileFlag]) {
        $candidate = $profilePaths[$defaultProfileFlag]
        $profileDir = $candidate.StartsWith('/') ? $candidate : (Join-Path $iniDir $candidate)
        if (Test-Path -LiteralPath $profileDir) { $best = $candidate }
    }
    if (-not $best) {
        Write-Caution "found $iniPath but no previous default profile to point at - leaving it alone."
        return $false
    }

    $targets = @($iniPath)
    $installsIni = Join-Path $iniDir 'installs.ini'
    if (Test-Path -LiteralPath $installsIni) { $targets += $installsIni }
    foreach ($file in $targets) {
        $bak = "$file.bak-mac-move-apps"
        if (-not (Test-Path -LiteralPath $bak)) { Copy-Item -LiteralPath $file -Destination $bak }
        $list = [System.Collections.Generic.List[string]]::new()
        foreach ($l in [System.IO.File]::ReadAllLines($file)) { $list.Add($l) }
        $sectionHeader = "Install$currentHash"
        $start = -1
        for ($i = 0; $i -lt $list.Count; $i++) {
            if ($list[$i] -match ('^\s*\[' + [regex]::Escape($sectionHeader) + '\]\s*$')) { $start = $i; break }
        }
        if ($start -ge 0) {
            # rewrite Default (and Locked) inside the existing section
            $end = $list.Count
            for ($i = $start + 1; $i -lt $list.Count; $i++) {
                if ($list[$i] -match '^\s*\[') { $end = $i; break }
            }
            $defaultIdx = -1
            $lockedIdx = -1
            for ($i = $start + 1; $i -lt $end; $i++) {
                if ($list[$i] -match '^\s*Default\s*=') { $defaultIdx = $i }
                if ($list[$i] -match '^\s*Locked\s*=') { $lockedIdx = $i }
            }
            if ($defaultIdx -ge 0) {
                $list[$defaultIdx] = "Default=$best"
            } else {
                $list.Insert($start + 1, "Default=$best")
                if ($lockedIdx -ge 0) { $lockedIdx++ }
            }
            if ($lockedIdx -lt 0) {
                $list.Insert($start + 2, 'Locked=1')
            }
        } else {
            # the app has not run from this path yet - create its section
            if ($list.Count -gt 0 -and $list[$list.Count - 1] -ne '') { $list.Add('') }
            $list.Add("[$sectionHeader]")
            $list.Add("Default=$best")
            $list.Add('Locked=1')
        }
        [System.IO.File]::WriteAllText($file, ($list -join "`n") + "`n", [System.Text.UTF8Encoding]::new($false))
        Write-Info "repointed [$sectionHeader] Default=$best in $(($file -replace [regex]::Escape($HOME), '~'))"
    }
    return $true
}

function Get-AppLibraryRelPath {
    # The ~/Library-relative paths this tool relocates for an app: the top-level
    # app-named dir (where Mozilla keeps Thunderbird's data), by bundle name, and
    # by bundle identifier when one exists. Pure derivation - existence is the
    # caller's concern - so the menu can show exactly what a move would relocate.
    param(
        [Parameter(Mandatory)] [string]$AppName,
        [string]$BundleId = ''
    )
    $rel = @($AppName, "Application Support/$AppName", "Logs/$AppName")
    if ($BundleId) {
        $rel += @(
            "Application Support/$BundleId"
            "Caches/$BundleId"
            "Saved Application State/$BundleId.savedState"
            "WebKit/$BundleId"
            "HTTPStorages/$BundleId"
        )
    }
    return $rel | Select-Object -Unique
}

function Get-AppRelocatable {
    # Everything a move would take off the internal disk for one app: the bundle
    # plus its still-local ~/Library entries (already-symlinked entries are
    # already on a volume and are skipped). The menu sizes and previews these.
    param([Parameter(Mandatory)] [string]$BundlePath)
    $name = (Split-Path $BundlePath -Leaf) -replace '\.app$', ''
    $paths = @($BundlePath)
    $bundleId = Get-AppBundleIdentifier $BundlePath
    foreach ($rel in (Get-AppLibraryRelPath -AppName $name -BundleId $bundleId)) {
        $libPath = Join-Path "$HOME/Library" $rel
        if (-not (Test-Path -LiteralPath $libPath)) { continue }
        if ((Get-Item -LiteralPath $libPath -Force).LinkType) { continue }
        $paths += $libPath
    }
    return $paths
}

function Format-Size {
    # Human-readable size from du's 1 KiB units, so the byte-constant thresholds
    # read as their KiB multiples: 1MB of KiB = 1 GiB, 1KB of KiB = 1 MiB.
    param([Parameter(Mandatory)] [long]$SizeKb)
    if ($SizeKb -ge 1MB) { return '{0:n1} GB' -f ($SizeKb / 1MB) }
    if ($SizeKb -ge 1KB) { return '{0:n1} MB' -f ($SizeKb / 1KB) }
    return "$SizeKb KB"
}

function Get-PathSizeKb {
    # Total du size in KiB across the given paths; unreadable paths count as 0
    # (du's stderr is suppressed, so callers treat 0 as 'unknown', never as
    # measured-empty). Metadata reads only - milliseconds even for multi-GB trees.
    param([Parameter(Mandatory)] [string[]]$Paths)
    $total = 0L
    foreach ($path in $Paths) {
        $first = & du -sk $path 2>$null | Select-Object -First 1
        if ("$first" -match '^(\d+)') { $total += [long]$Matches[1] }
    }
    return $total
}

function Show-TreeTime {
    # Human-readable 'last change' for a unix timestamp; 'unknown' when 0.
    param([Parameter(Mandatory)] [long]$Epoch)
    if ($Epoch -le 0) { return 'unknown' }
    return [DateTimeOffset]::FromUnixTimeSeconds($Epoch).LocalDateTime.ToString('yyyy-MM-dd HH:mm')
}

function Get-TreeInfo {
    # @{ SizeKb; NewestFileEpoch } for a directory tree - metadata reads only,
    # so it costs seconds even for very large data.
    param([Parameter(Mandatory)] [string]$Path)
    $epochs = & find @($Path, '-type', 'f', '-exec', 'stat', '-f', '%m', '{}', '+') 2>$null
    $newest = 0L
    foreach ($line in @($epochs)) {
        if ("$line" -match '^(\d+)$' -and [long]$Matches[1] -gt $newest) { $newest = [long]$Matches[1] }
    }
    return @{ SizeKb = (Get-PathSizeKb @($Path)); NewestFileEpoch = $newest }
}

function Resolve-DataConflict {
    # Both a local and a volume copy of one library entry exist. The local side
    # is the live one - these call sites only run while no symlink is in place,
    # so the app has been writing to the local copy. Decides which copy keeps:
    #   the local copy wins automatically only when clearly safe - both sides
    #   are the same snapshot (last changes within 5 minutes) or the volume
    #   copy is clearly staler (a day or more behind);
    #   anything else is divergent, and the choice belongs to the user: the
    #   volume copy hugely larger (the husk of an old failed removal), newer
    #   than the live side, or both sides recently active in different ways.
    #   Interactive runs choose local / volume / skip with sizes, last changes,
    #   and the live side shown; non-interactive runs are refused with the
    #   same summary. Returns 'local' | 'volume' | 'skip'.
    param(
        [Parameter(Mandatory)] [string]$LocalPath,
        [Parameter(Mandatory)] [string]$VolumePath,
        [Parameter(Mandatory)] [string]$Label
    )
    $local = Get-TreeInfo $LocalPath
    $volume = Get-TreeInfo $VolumePath
    $sameSnapshot = [Math]::Abs($local.NewestFileEpoch - $volume.NewestFileEpoch) -le 300
    $volumeStaler = ($local.NewestFileEpoch - $volume.NewestFileEpoch) -ge 86400
    $huskShaped = $volume.SizeKb -gt ($local.SizeKb * 5)
    $volumeNewer = ($volume.NewestFileEpoch -gt $local.NewestFileEpoch) -and -not $sameSnapshot
    if (-not $huskShaped -and -not $volumeNewer -and ($sameSnapshot -or $volumeStaler)) {
        Write-Caution "${Label}: two copies exist - keeping the local one (live, $(Format-Size $local.SizeKb), last change $(Show-TreeTime $local.NewestFileEpoch)); the volume copy ($(Format-Size $volume.SizeKb), last change $(Show-TreeTime $volume.NewestFileEpoch)) moves to the Trash - recoverable until the Trash is emptied."
        return 'local'
    }
    $summary = @(
        "${Label}: two different-looking copies exist - which one should keep?"
        "  local  - $(Format-Size $local.SizeKb), last change $(Show-TreeTime $local.NewestFileEpoch) (the app is currently using this one)"
        "  volume - $(Format-Size $volume.SizeKb), last change $(Show-TreeTime $volume.NewestFileEpoch)"
    ) -join "`n"
    if ([Console]::IsInputRedirected) {
        Write-Caution $summary
        Write-Caution "${Label}: left untouched - re-run in a terminal to choose."
        return 'skip'
    }
    Write-Host ''
    Write-Host $summary
    $answer = (Read-Host 'Keep which copy? local / volume / skip [l/v/s]').Trim().ToLower()
    return $answer -in 'l', 'local' ? 'local' : $answer -in 'v', 'volume' ? 'volume' : 'skip'
}

function Get-AppSize {
    # Parallel du over each app's relocatable paths; returns a name-to-KiB hashtable.
    # du reads only directory metadata, so even multi-GB bundles size in milliseconds.
    param([Parameter(Mandatory)] [pscustomobject[]]$Apps)
    if ($Apps.Count -eq 0) { return @{} }
    # $LASTEXITCODE is not populated inside -Parallel runspaces, so success is
    # judged from stdout alone: a bad path leaves du output empty (stderr suppressed)
    $rows = $Apps | ForEach-Object -Parallel {
        $kb = 0
        foreach ($path in $_.Paths) {
            $first = & du -sk $path 2>$null | Select-Object -First 1
            if ("$first" -match '^(\d+)') { $kb += [long]$Matches[1] }
        }
        [pscustomobject]@{ Name = $_.Name; SizeKb = $kb }
    } -ThrottleLimit 8
    $sizes = @{}
    foreach ($row in $rows) { $sizes[$row.Name] = $row.SizeKb }
    return $sizes
}

function Invoke-LibraryMove {
    # Relocate the app's ~/Library footprint - the big stuff: Application Support,
    # Caches, Logs, WebKit, HTTPStorages, Saved Application State - to LibRoot,
    # symlinking the original locations back. Preferences, Containers, and Group
    # Containers deliberately stay put: cfprefsd and sandbox path evaluation
    # misbehave through symlinks. Returns @{ Moved; Failed }.
    # Failure handling is stage-aware, because each stage leaves a different
    # state behind - the lesson of the Thunderbird data loss:
    #   copy  : the original is intact and the destination copy is partial
    #           rubble - the partial copy is trashed (a same-volume rename on
    #           the destination's own volume, so it stays recoverable) and no
    #           symlink steps are suggested: they would point at rubble.
    #   trash : the original is intact and the copy is complete - the copy is
    #           kept and the finish-by-hand steps are printed.
    #   link  : the copy is complete and the original is already in the Trash -
    #           only the symlink is missing.
    # No stage ever deletes a complete copy of the data.
    param(
        [Parameter(Mandatory)] [string]$AppName,
        [Parameter(Mandatory)] [string]$BundlePath,
        [Parameter(Mandatory)] [string]$LibRoot
    )
    $bundleId = Get-AppBundleIdentifier $BundlePath
    $relPaths = Get-AppLibraryRelPath -AppName $AppName -BundleId $bundleId
    $moved = 0
    $failed = 0
    foreach ($rel in ($relPaths | Select-Object -Unique)) {
        $libPath = Join-Path "$HOME/Library" $rel
        if (-not (Test-Path -LiteralPath $libPath)) { continue }
        if ((Get-Item -LiteralPath $libPath -Force).LinkType) { continue }
        $dest = Join-Path $LibRoot $rel
        # refuse destinations that overlap the source: trashing the source
        # would take a copy sitting inside it down too (reachable when the
        # destination root lives inside ~/Library/<app>)
        $ordinal = [System.StringComparison]::OrdinalIgnoreCase
        if ($dest.StartsWith("$libPath/", $ordinal) -or $libPath.StartsWith("$dest/", $ordinal)) {
            Write-Caution "~/Library/${rel}: the destination overlaps it - skipping."
            $failed++
            continue
        }
        try {
            $stage = 'copy'
            [void][System.IO.Directory]::CreateDirectory((Split-Path $dest -Parent))
            # a leftover at the destination would make ditto merge into it, so
            # stale files would survive a re-move - when both sides hold data,
            # Resolve-DataConflict decides which copy keeps (the live/newer one
            # wins automatically only when clearly safe; divergent copies ask)
            if (Test-Path -LiteralPath $dest) {
                $destItem = Get-Item -LiteralPath $dest -Force
                if ($destItem.LinkType) {
                    # a stale link - removing it never touches its target
                    Remove-Item -LiteralPath $dest -Force
                } else {
                    $verdict = Resolve-DataConflict -LocalPath $libPath -VolumePath $dest -Label "~/Library/$rel"
                    if ($verdict -eq 'skip') {
                        $failed++
                        continue
                    }
                    if ($verdict -eq 'volume') {
                        # the volume copy is the keeper: the local copy moves to
                        # the Trash and the link takes its place. Stage 'link':
                        # the surviving data is complete and local is in the
                        # Trash, so a failure here means only the link is missing.
                        if (-not (Invoke-Trash @($libPath))) {
                            Write-Caution "~/Library/${rel}: could not trash the local copy - nothing was changed, the volume copy is untouched."
                            $failed++
                            continue
                        }
                        $stage = 'link'
                        Invoke-Tool ln @('-s', $dest, $libPath)
                        Write-Info "~/Library/${rel}: keeping the volume copy - the local copy is in the Trash (recoverable until the Trash is emptied)."
                        $moved++
                        continue
                    }
                    if (-not (Invoke-Trash @($dest))) {
                        Write-Caution "~/Library/${rel}: could not clear the volume copy - skipping (the local copy is untouched)."
                        $failed++
                        continue
                    }
                }
            }
            Write-Info "moving ~/Library/$rel"
            Invoke-Tool ditto @($libPath, $dest)
            # trash the original - recoverable, and a rename rather than a
            # file-by-file walk, so nothing can race it mid-deletion; library
            # data is irreplaceable, so a failed trash NEVER falls back to rm
            $stage = 'trash'
            if (-not (Invoke-Trash @($libPath))) {
                Write-Caution 'first trash attempt failed - retrying once...'
                Start-Sleep -Seconds 1
                if (-not (Invoke-Trash @($libPath))) {
                    throw "could not move ~/Library/$rel to the Trash"
                }
            }
            $stage = 'link'
            Invoke-Tool ln @('-s', $dest, $libPath)
        } catch {
            $destTilde = $dest -replace [regex]::Escape($HOME), '~'
            switch ($stage) {
                'copy' {
                    # the original is intact - the partial copy has no value
                    Write-Caution "could not copy ~/Library/${rel}: $_"
                    if (-not (Test-Path -LiteralPath $dest)) {
                        Write-Caution 'the original is unchanged; nothing was copied.'
                    } elseif (Invoke-Trash @($dest)) {
                        Write-Caution "the original is unchanged; the incomplete copy at $destTilde was moved to the Trash."
                    } else {
                        Write-Caution "the original is unchanged; an incomplete copy remains at $destTilde - move it to the Trash by hand before re-running."
                    }
                }
                'trash' {
                    # the original is intact and the copy is complete - the
                    # manual steps below are safe to follow
                    Write-Caution "could not finish moving ~/Library/${rel}: $_"
                    Write-Caution "kept the complete copy at $destTilde - to finish by hand:"
                    Write-Caution "  move `"$libPath`" to the Trash, then: ln -s `"$dest`" `"$libPath`""
                }
                'link' {
                    # the copy is complete and the original is already in the
                    # Trash - only the link is missing
                    Write-Caution "could not symlink ~/Library/${rel}: $_"
                    Write-Caution "the data is safe at $destTilde and the original is in the Trash - finish by hand:"
                    Write-Caution "  ln -s `"$dest`" `"$libPath`"  (if `"$libPath`" reappeared, move it to the Trash first)"
                }
            }
            $failed++
            continue
        }
        $moved++
    }
    return @{ Moved = $moved; Failed = $failed }
}

function Invoke-LibraryRestore {
    # Reverse of Invoke-LibraryMove: walk the app's folder under the volume's
    # App Library root and bring each entry back to its ~/Library location,
    # replacing the symlinks left there: ditto home, then trash the volume
    # original (recoverable, and a same-volume rename on its own volume - macOS
    # keeps a per-volume .Trashes). The tree holds two shapes: a top-level
    # entry named after the app is the whole ~/Library/<app> dir (single level);
    # any other top-level dir is a group (Application Support, Caches, ...) whose
    # children map to ~/Library/<group>/<child>. Real entries at home are never
    # clobbered, and a failed copy clears only the partial copy this function
    # just started writing (home held only our symlink when the entry began), so
    # a re-run is never blocked by rubble. Returns the number of entries restored.
    param(
        [Parameter(Mandatory)] [string]$AppName,
        [Parameter(Mandatory)] [string]$LibRoot
    )
    if (-not (Test-Path -LiteralPath $LibRoot)) { return 0 }
    $restored = 0
    $restoreEntry = {
        param([string]$VolumeEntry, [string]$HomePath)
        $existing = Get-Item -LiteralPath $HomePath -Force -ErrorAction SilentlyContinue
        if ($existing) {
            if ($existing.LinkType -eq 'SymbolicLink') {
                Remove-Item -LiteralPath $HomePath -Force
            } else {
                # both sides hold data - decide which copy keeps (live/newer
                # wins automatically only when clearly safe; divergent copies
                # ask local / volume / skip)
                $label = $HomePath -replace [regex]::Escape($HOME), '~'
                $verdict = Resolve-DataConflict -LocalPath $HomePath -VolumePath $VolumeEntry -Label $label
                if ($verdict -eq 'skip') { return $false }
                if ($verdict -eq 'volume') {
                    # the volume copy wins: replace the local data with it
                    if (-not (Invoke-Trash @($HomePath))) {
                        Write-Caution "could not clear $label for the volume copy - both copies are untouched."
                        return $false
                    }
                    try {
                        Invoke-Tool ditto @($VolumeEntry, $HomePath)
                    } catch {
                        Write-Caution "could not restore ${label}: $_"
                        # clear the partial copy just started (home held nothing
                        # real once the local original was trashed) - the local
                        # original sits in the Trash and the volume copy is intact
                        $null = Invoke-Trash @($HomePath)
                        return $false
                    }
                    if (-not (Invoke-Trash @($VolumeEntry))) {
                        Write-Caution "restored $label, but the volume original could not be trashed - move it to the Trash by hand"
                    }
                    Write-Info "kept the volume copy for $label (the previous local copy is in the Trash, recoverable until the Trash is emptied)."
                    return $true
                }
                # verdict 'local': the home copy wins - the volume side retires
                if (-not (Invoke-Trash @($VolumeEntry))) {
                    Write-Caution "kept the local copy at $label - but the volume copy could not be trashed, so it stays on the volume"
                    return $false
                }
                Write-Info "kept the local copy for $label (the volume copy is in the Trash, recoverable until the Trash is emptied)."
                return $true
            }
        }
        $null = [System.IO.Directory]::CreateDirectory((Split-Path $HomePath -Parent))
        try {
            Invoke-Tool ditto @($VolumeEntry, $HomePath)
        } catch {
            Write-Caution "could not restore ${HomePath}: $_"
            # home held no real entry when this began, so any partial copy
            # there is ours - clear it, and the volume original is untouched
            $null = Invoke-Trash @($HomePath)
            return $false
        }
        if (-not (Invoke-Trash @($VolumeEntry))) {
            Write-Caution "restored $HomePath, but the volume original could not be trashed - move `"$VolumeEntry`" to the Trash by hand"
        }
        return $true
    }
    foreach ($top in @(Get-ChildItem -LiteralPath $LibRoot -Force)) {
        if (-not $top.PSIsContainer) { continue }
        if ($top.Name -eq $AppName) {
            if (& $restoreEntry $top.FullName (Join-Path "$HOME/Library" $top.Name)) { $restored++ }
            continue
        }
        foreach ($item in @(Get-ChildItem -LiteralPath $top.FullName -Force)) {
            if (-not $item.PSIsContainer) { continue }
            if (& $restoreEntry $item.FullName (Join-Path "$HOME/Library/$($top.Name)" $item.Name)) { $restored++ }
        }
        # drop the scaffold group dir when this tool emptied it (a .DS_Store
        # or other straggler keeps it alive - cosmetic either way)
        if (-not (Get-ChildItem -LiteralPath $top.FullName -Force -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $top.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not (Get-ChildItem -LiteralPath $LibRoot -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $LibRoot -Force -ErrorAction SilentlyContinue
    }
    return $restored
}

function Invoke-BundleMove {
    # Move one resolved, pre-checked bundle into DestDir and symlink it back.
    # Returns $true on success; reports its own failures.
    param(
        [Parameter(Mandatory)] [string]$Src,
        [Parameter(Mandatory)] [string]$DestDir
    )
    # expand ~ and relative destinations - native tools take them literally otherwise
    $DestDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DestDir)
    while ($DestDir.Length -gt 1 -and $DestDir.EndsWith('/')) { $DestDir = $DestDir.Substring(0, $DestDir.Length - 1) }
    $appFile = Split-Path $Src -Leaf
    $name = $appFile -replace '\.app$', ''

    $destParent = Split-Path $DestDir -Parent
    if (-not (Test-Path -LiteralPath $destParent)) {
        Write-Failure "destination drive is not mounted: $destParent"
        return $false
    }
    $dst = Join-Path $DestDir $appFile

    # refuse destinations that resolve onto the source - -Force would rm the app itself
    $ordinal = [System.StringComparison]::OrdinalIgnoreCase
    if ($dst.Equals($Src, $ordinal) -or
        $dst.StartsWith("$Src/", $ordinal) -or
        $Src.StartsWith("$DestDir/", $ordinal)) {
        Write-Failure "destination $DestDir overlaps the source $Src - refusing to move."
        return $false
    }
    # app data must never move into ~/Library: the library relocation would
    # then copy and trash trees inside other apps' footprints
    if ($DestDir.StartsWith("$HOME/Library/", $ordinal) -or $DestDir -eq "$HOME/Library") {
        Write-Failure "destination $DestDir is inside ~/Library - refusing to move apps there."
        return $false
    }

    # root-level destinations (a volume root itself) have no sibling spot for
    # the app's ~/Library data. Case-sensitive on purpose: -ceq, because a
    # lower-case '/volumes/...' path is a legitimate destination, not /Volumes
    $rootDest = ($destParent -ceq '/' -or $destParent -ceq '/Volumes')

    try {
        # .NET call: literal path creation, unlike New-Item's wildcard-mangled -Path
        [void][System.IO.Directory]::CreateDirectory($DestDir)
        if (Test-Path -LiteralPath $dst) {
            if ($Force) {
                Write-Caution "destination exists, overwriting: $dst"
                if (-not (Invoke-Trash @($dst))) {
                    # a bundle is re-downloadable, so an rm fallback is acceptable
                    Invoke-Tool rm @('-rf', $dst)
                }
            } else {
                Write-Failure "destination already exists: $dst (re-run with -Force to overwrite)"
                return $false
            }
        }

        # refuse moves that cannot fit: a mid-copy disk-full failure is the
        # classic way relocation tools lose data, and du + df are metadata
        # reads, so this costs milliseconds even for multi-GB apps
        $relocatable = @(Get-AppRelocatable $Src)
        $needKb = Get-PathSizeKb ($rootDest ? @($relocatable[0]) : $relocatable)
        $dfRow = (df -k $DestDir | Select-Object -Skip 1) -split '\s+'
        $freeKb = [long]$dfRow[3]
        $mount = ($dfRow[5..($dfRow.Count - 1)] -join ' ').Trim()
        if ($mount -eq '/' -or $mount -eq '/System/Volumes/Data') {
            Write-Caution "$DestDir is on the internal disk - the move frees no internal space."
        }
        if ($freeKb -lt [Math]::Ceiling($needKb * 1.05)) {
            Write-Failure "not enough space on ${DestDir}: $(Format-Size $needKb) to move, $(Format-Size $freeKb) free - nothing was copied."
            return $false
        }
    } catch {
        Write-Failure "cannot prepare the destination: $_"
        return $false
    }

    Write-Info "moving $Src"
    Write-Info "   to $dst"
    Write-Info "symlink back at $Src"

    # ditto preserves bundle structure, metadata, extended attributes, and forks
    Write-Info 'copying the bundle to the volume...'
    try {
        Invoke-Tool ditto @($Src, $dst)
    } catch {
        Write-Failure "could not copy the bundle to the volume: $_"
        # the partial copy is ours and the original is intact; trash it - on
        # the destination's own volume the Trash is a same-volume rename
        # (macOS keeps a per-volume .Trashes), so this stays cheap - with an
        # rm fallback, since a bundle is re-downloadable
        if (-not (Invoke-Trash @($dst))) {
            $null = Invoke-Tool rm @('-rf', $dst) -Tolerant
        }
        return $false
    }

    Write-Info 'removing the original (to the Trash)...'
    if (-not (Invoke-Trash @($Src))) {
        Write-Caution 'trash failed - falling back to a permanent delete (a bundle can always be re-downloaded; the volume copy is kept if this fails too)...'
        try {
            Invoke-Tool rm @('-rf', $Src)
        } catch {
            Write-Caution 'permanent delete failed - retrying with administrator privileges (password may be asked)...'
            try {
                Invoke-Tool sudo @('rm', '-rf', $Src)
            } catch {
                # the copy is never deleted here: a half-finished removal leaves
                # the original damaged and the copy as the only complete version
                Write-Failure "could not remove the original: $_"
                Write-Caution "kept the copy at $dst - move `"$Src`" to the Trash (or rm -rf it), then: ln -s `"$dst`" `"$Src`""
                return $false
            }
        }
    }

    # ln -s: literal names (bracket-safe), and it fails rather than overwrites
    Write-Info 'creating the symlink back...'
    try {
        Invoke-Tool ln @('-s', $dst, $Src)
    } catch {
        Write-Failure "could not symlink $Src to ${dst}: $_"
        Write-Caution "the bundle is safe at $dst - restore it manually with: ln -s `"$dst`" `"$Src`""
        return $false
    }

    # clear quarantine (only if ditto carried it over) and keep the ORIGINAL
    # signature: ad-hoc re-signing replaces the Developer ID and unbinds every
    # TCC permission the app had (removable volumes, screen capture, ...), so
    # it is strictly a fallback for a copy that actually broke the signature
    $null = Invoke-Tool xattr @('-d', 'com.apple.quarantine', $dst) -Tolerant
    $verifyOutput = codesign --verify $dst 2>&1
    if ($LASTEXITCODE -ne 0) {
        $reason = (($verifyOutput | Out-String).Trim() -replace '\s+', ' ')
        Write-Caution "the original signature did not survive the copy ($reason) - re-signing it locally instead; macOS will ask again for permissions this app already had (removable volumes, screen recording, ...)"
        try {
            Invoke-Tool codesign @('--force', '--deep', '--sign', '-', $dst)
        } catch {
            Write-Caution "re-sign failed - the app may not launch from the volume: $(($_.ToString()))"
        }
    }

    Write-Info 're-registering the app with macOS...'
    $null = Invoke-Tool $LsRegister @('-f', $dst) -Tolerant

    # Mozilla-family apps: repoint profiles.ini at the existing profile so the
    # first launch from the volume does not present a fresh install
    $null = Invoke-MozillaRepoint -AppName $name -BundlePath $dst

    # relocate the app's ~/Library footprint next to the bundle on the volume;
    # skipped for root-level destinations, which have no sensible sibling spot
    if (-not $rootDest) {
        $libRoot = Join-Path $destParent "App Library/$name"
        $libMoved = 0
        $libFailed = 0
        try {
            $libResult = Invoke-LibraryMove -AppName $name -BundlePath $Src -LibRoot $libRoot
            $libMoved = $libResult.Moved
            $libFailed = $libResult.Failed
        } catch {
            Write-Caution "library relocation failed for $name (the bundle move is unaffected): $_"
        }
        $suffix = (($libMoved -gt 0) ? " (+$libMoved ~/Library entries)" : '') + (($libFailed -gt 0) ? " ($libFailed library entries need attention - see warnings)" : '')
        Write-Info "moved $appFile to $dst$suffix"
        if ($libMoved -gt 0) { Write-RemovableVolumeNote }
    } else {
        Write-Info "moved $appFile to $dst (~/Library entries stay put - destination has no sibling dir)"
    }
    return $true
}

function Get-AppInventory {
    # Installed apps enriched with tier, relocatable paths, and sizes - the shared
    # base for the multiselect and the list output, sorted safe → unlisted →
    # caution → avoid, then by name. Empty when nothing is installed.
    # Group-Object keeps the first occurrence per name (search-dir order), so
    # the same bundle in /Applications and ~/Applications counts once
    $installed = @(Get-InstalledApp | Group-Object Name | ForEach-Object { $_.Group[0] })
    if ($installed.Count -eq 0) { return @() }
    $infos = foreach ($app in $installed) {
        [pscustomobject]@{ Name = $app.Name; Path = $app.Path; Paths = @(Get-AppRelocatable $app.Path) }
    }
    $sizes = Get-AppSize $infos
    $tierOrder = @{ safe = 0; unlisted = 1; caution = 2; avoid = 3 }
    $notes = @{ caution = 'caution - locked'; avoid = 'do not move - locked'; unlisted = 'unlisted - review'; safe = 'safe' }
    $rows = foreach ($info in $infos) {
        $tier = Get-MoveTier $info.Name
        [pscustomobject]@{
            Name   = $info.Name
            Path   = $info.Path
            Tier   = $tier
            Locked = $tier -in 'caution', 'avoid'
            Note   = $notes[$tier]
            Paths  = $info.Paths
            SizeKb = $sizes[$info.Name]
        }
    }
    return @($rows | Sort-Object { $tierOrder[$_.Tier] }, Name)
}

function Invoke-MoveBatch {
    # move with no app given: multiselect across every installed app, then one
    # destination for all. Caution and avoid apps show up locked.
    if ([Console]::IsInputRedirected) {
        Write-Failure 'no app given and stdin is not interactive - pass an app name and destination, or run in a terminal.'
        exit 2
    }
    Write-Info 'measuring apps...'
    $options = @(Get-AppInventory)
    if ($options.Count -eq 0) {
        Write-Info 'no installed apps found in the search dirs.'
        return
    }
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
    if ($failed -gt 0) { exit 1 }
}

function Invoke-Move {
    if (-not $AppName) { Invoke-MoveBatch; return }
    $appFile = Resolve-AppName $AppName
    # tier checks key off the bundle name, so a locked app named by path cannot slip past
    $name = (Split-Path $appFile -Leaf) -replace '\.app$', ''
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

function Restore-OneBundle {
    # Bring one moved bundle back to its home path: remove the home symlink,
    # ditto the volume bundle over, then trash the volume original (recoverable,
    # and a same-volume rename on the volume). On a copy failure the
    # half-written home copy is cleared and the home symlink is recreated, so
    # the volume copy stays reachable and nothing is lost. Prints the trailing
    # result word on failure; returns $true when the bundle is back home.
    param(
        [Parameter(Mandatory)] [string]$LinkPath,
        [Parameter(Mandatory)] [string]$TargetPath
    )
    try {
        # the symlink only - the caller verified the home path is still a link
        Remove-Item -LiteralPath $LinkPath
        Invoke-Tool ditto @($TargetPath, $LinkPath)
    } catch {
        Write-Host 'failed'
        Write-Caution "  could not restore the bundle: $_"
        $left = Get-Item -LiteralPath $LinkPath -Force -ErrorAction SilentlyContinue
        if ($left -and -not $left.LinkType) { $null = Invoke-Trash @($LinkPath) }
        if (-not (Test-Path -LiteralPath $LinkPath)) {
            $null = Invoke-Tool ln @('-s', $TargetPath, $LinkPath) -Tolerant
        }
        return $false
    }
    if (-not (Invoke-Trash @($TargetPath))) {
        Write-Caution "  the bundle is home, but the volume copy could not be trashed - move `"$TargetPath`" to the Trash by hand"
    }
    $null = Invoke-Tool $LsRegister @('-f', $LinkPath) -Tolerant
    return $true
}

function Restore-AppRegistration {
    # Rebuild macOS's app database so apps stay findable after a move or
    # restore, and restart Dock and Finder so they pick up the new locations.
    Write-Info 'refreshing the macOS app database, Dock, and Finder...'
    $null = Invoke-Tool $LsRegister @('-kill', '-r', '-domain', 'local', '-domain', 'system', '-domain', 'user') -Tolerant
    $null = Invoke-Tool killall @('Dock') -Tolerant
    $null = Invoke-Tool killall @('Finder') -Tolerant
}

function Restore-OneMovedApp {
    # Restore one moved app: bundle home, then its ~/Library entries, then the
    # Mozilla profile repoint. Prints its own progress; returns 'restored',
    # 'failed', or 'skipped'.
    param([Parameter(Mandatory)] [pscustomobject]$App)
    Write-Host -NoNewline "  restoring $($App.Name)... "
    if (-not (Test-Path -LiteralPath $App.Target)) {
        Write-Host 'missing source'
        return 'failed'
    }
    $linkItem = Get-Item -LiteralPath $App.LinkPath -Force -ErrorAction SilentlyContinue
    if (-not $linkItem -or $linkItem.LinkType -ne 'SymbolicLink') {
        Write-Host 'skipped - the home path is no longer a symlink (a real app may have replaced it)'
        return 'skipped'
    }
    if (Test-AppRunning @($App.LinkPath, $App.Target)) {
        Write-Host 'skipped - the app is running; quit it completely and re-run'
        return 'skipped'
    }
    # Restore-OneBundle prints the trailing 'failed' word itself; nothing
    # is ever deleted on failure - the volume copy stays reachable
    if (-not (Restore-OneBundle -LinkPath $App.LinkPath -TargetPath $App.Target)) {
        return 'failed'
    }
    # bring the app's ~/Library entries back from the volume's App Library;
    # a library failure never fails the restored bundle itself
    $libRoot = Join-Path (Split-Path (Split-Path $App.Target -Parent) -Parent) "App Library/$($App.Name)"
    $libRestored = 0
    try {
        $libRestored = Invoke-LibraryRestore -AppName $App.Name -LibRoot $libRoot
    } catch {
        Write-Caution "  could not restore ~/Library entries for $($App.Name): $_"
    }
    # the bundle lives at its home path again - repoint Mozilla profiles.ini
    # at the home install hash, or the next launch presents a fresh profile
    $null = Invoke-MozillaRepoint -AppName $App.Name -BundlePath $App.LinkPath
    Write-Host "done$(($libRestored -gt 0) ? " (+$libRestored ~/Library entries)" : '')"
    return 'restored'
}

function Get-HalfRestoredApp {
    # Detect a half-finished restore: the app's bundle is back home as a real
    # folder, but some of its ~/Library entries are still symlinks into a
    # volume's App Library (a restore that was interrupted partway, e.g. by a
    # permission denial). Returns the moved-app shape plus LibRoot, or $null.
    param([Parameter(Mandatory)] [string]$Name)
    $homeBundle = $null
    foreach ($dir in $SearchDirs) {
        $candidate = Join-Path $dir "$Name.app"
        if (Test-Path -LiteralPath $candidate) {
            $item = Get-Item -LiteralPath $candidate
            if (-not $item.LinkType) { $homeBundle = $item.FullName; break }
        }
    }
    if (-not $homeBundle) { return $null }
    $bundleId = Get-AppBundleIdentifier $homeBundle
    $libRoot = ''
    foreach ($rel in (Get-AppLibraryRelPath -AppName $Name -BundleId $bundleId)) {
        $homePath = Join-Path "$HOME/Library" $rel
        if (-not (Test-Path -LiteralPath $homePath)) { continue }
        $item = Get-Item -LiteralPath $homePath -Force
        if ($item.LinkType -ne 'SymbolicLink') { continue }
        $target = @($item.Target)[0]
        if ($target -notlike '/Volumes/*') { continue }
        $marker = "/App Library/$Name/"
        $cut = $target.IndexOf($marker, [System.StringComparison]::OrdinalIgnoreCase)
        if ($cut -lt 0) { continue }
        $libRoot = $target.Substring(0, $cut + $marker.Length - 1)
        break
    }
    if (-not $libRoot) { return $null }
    $volumeRoot = Split-Path (Split-Path $libRoot -Parent) -Parent
    return [pscustomobject]@{
        Name     = $Name
        LinkPath = $homeBundle
        Target   = Join-Path (Join-Path $volumeRoot 'Applications') "$Name.app"
        LibRoot  = $libRoot
    }
}

function Invoke-RestoreHalf {
    # Finish a half-restored app: bring the still-linked ~/Library entries
    # home and retire the leftover volume bundle copy.
    param([Parameter(Mandatory)] [pscustomobject]$Half)
    $name = $Half.Name
    if ($DryRun) {
        Write-Preview "would finish restoring $name from $(($Half.LibRoot -replace [regex]::Escape($HOME), '~')) - dry run, nothing was moved."
        return
    }
    if (-not $Yes) {
        if ([Console]::IsInputRedirected) {
            Write-Failure 'stdin is not interactive - re-run with -Yes to restore without a prompt.'
            exit 2
        }
        $answer = (Read-Host "Finish restoring $name to the internal disk? [y/N]").Trim()
        if ($answer -notmatch '^[Yy]') {
            Write-Info 'cancelled.'
            return
        }
    }
    $libRestored = 0
    try {
        $libRestored = Invoke-LibraryRestore -AppName $name -LibRoot $Half.LibRoot
    } catch {
        Write-Caution "could not read the volume copy of ${name}: $_"
    }
    if (Test-Path -LiteralPath $Half.Target) {
        if (Invoke-Trash @($Half.Target)) {
            Write-Info 'leftover volume copy of the app moved to the Trash.'
        } else {
            Write-Caution "could not trash the leftover volume copy - move it to the Trash by hand: $($Half.Target)"
        }
    }
    $null = Invoke-MozillaRepoint -AppName $name -BundlePath $Half.LinkPath
    Write-Host ''
    if ($libRestored -gt 0) {
        Write-Info "finished restoring $name - all of its data is on the internal disk now."
        Restore-AppRegistration
    } else {
        Write-Failure "nothing could be restored for $name - the volume data could not be read from this terminal. Run this command from a terminal that can access the volume (the one that did the original move)."
        exit 1
    }
}

function Invoke-RestoreOne {
    # restore <app>: bring one named app back to the internal disk - either a
    # currently-moved app, or a half-finished restore (bundle already home,
    # data still linked to the volume).
    $appFile = Resolve-AppName $AppName
    $name = (Split-Path $appFile -Leaf) -replace '\.app$', ''
    $app = @(Get-MovedApp) | Where-Object Name -eq $name | Select-Object -First 1
    if (-not $app) {
        $half = Get-HalfRestoredApp -Name $name
        if (-not $half) {
            Write-Failure "$name is not on external storage - nothing to restore (see status)."
            exit 1
        }
        Invoke-RestoreHalf -Half $half
        return
    }
    if ($DryRun) {
        Write-Preview "would restore $name from $($app.Target) - dry run, nothing was moved."
        return
    }
    if (-not $Yes) {
        if ([Console]::IsInputRedirected) {
            Write-Failure 'stdin is not interactive - re-run with -Yes to restore without a prompt.'
            exit 2
        }
        $answer = (Read-Host "Restore $name to the internal disk? [y/N]").Trim()
        if ($answer -notmatch '^[Yy]') {
            Write-Info 'cancelled.'
            return
        }
    }
    $verdict = Restore-OneMovedApp $app
    Write-Host ''
    if ($verdict -eq 'restored') {
        Write-Info "restored $name to the internal disk."
        Restore-AppRegistration
    } elseif ($verdict -eq 'failed') {
        Write-Failure "could not restore $name - nothing was lost, the volume copy is still in place."
        exit 1
    } else {
        Write-Info "$name was skipped - nothing was changed."
    }
}

function Invoke-Restore {
    if ($AppName) { Invoke-RestoreOne; return }
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
    $skipped = 0
    foreach ($app in $moved) {
        $verdict = Restore-OneMovedApp $app
        if ($verdict -eq 'restored') { $restored++ } elseif ($verdict -eq 'failed') { $failed++ } else { $skipped++ }
    }

    Write-Host ''
    if ($restored -gt 0) {
        Write-Info "restored $restored app(s), skipped $skipped, failed $failed."
        Restore-AppRegistration
    } else {
        Write-Failure "restored 0 app(s), skipped $skipped, failed $failed."
    }
    if ($failed -gt 0) { exit 1 }
}

function Get-MoveAudit {
    # Audit every moved app for partial or broken relocations and return one
    # record per problem app (healthy apps are omitted). A partial move is data
    # the current candidate set would relocate but that stayed local (typical
    # for apps moved before the candidate set grew, e.g. Mozilla's top-level
    # ~/Library/<app> dir); also caught: dangling bundle or library symlinks,
    # volume entries orphaned from their home link, and moved apps now on the
    # locked tiers (the Mozilla fresh-profile trap).
    $records = @()
    foreach ($app in @(Get-MovedApp)) {
        $name = $app.Name
        $problems = @()
        $partial = @()
        $orphans = @()
        $broken = @()
        try {
            $bundleOk = Test-Path -LiteralPath $app.Target
            if (-not $bundleOk) {
                $problems += "bundle target is missing: $($app.Target)"
            }
            $libRoot = Join-Path (Split-Path (Split-Path $app.Target -Parent) -Parent) "App Library/$name"

            # home side: candidates that stayed local, or link to nothing
            $bundleId = $bundleOk ? (Get-AppBundleIdentifier $app.Target) : ''
            foreach ($rel in (Get-AppLibraryRelPath -AppName $name -BundleId $bundleId)) {
                # $home is a read-only automatic variable - hence $homePath
                $homePath = Join-Path "$HOME/Library" $rel
                if (-not (Test-Path -LiteralPath $homePath)) { continue }
                $item = Get-Item -LiteralPath $homePath -Force
                if ($item.LinkType) {
                    $targetPath = @($item.Target)[0]
                    if (-not (Test-Path -LiteralPath $targetPath)) {
                        $broken += $homePath
                        $problems += "broken link (its target is gone): ~/Library/$rel"
                    }
                } else {
                    $partial += [pscustomobject]@{ Path = $homePath; SizeKb = (Get-PathSizeKb @($homePath)) }
                    $problems += "still local: ~/Library/$rel"
                }
            }

            # volume side: entries whose home path vanished entirely; a top-level
            # entry named after the app is a whole ~/Library/<app> dir, anything
            # else is a group whose children map to ~/Library/<group>/<child>
            foreach ($top in @(Get-ChildItem -LiteralPath $libRoot -Force -ErrorAction SilentlyContinue)) {
                if (-not $top.PSIsContainer) { continue }
                if ($top.Name -eq $name) {
                    $homePath = Join-Path "$HOME/Library" $top.Name
                    if (Test-Path -LiteralPath $homePath) { continue }
                    $orphans += [pscustomobject]@{ Home = $homePath; Volume = $top.FullName }
                    $problems += "on the volume without a home link: ~/Library/$($top.Name)"
                    continue
                }
                foreach ($entry in @(Get-ChildItem -LiteralPath $top.FullName -Force -ErrorAction SilentlyContinue)) {
                    if (-not $entry.PSIsContainer) { continue }
                    $homePath = Join-Path "$HOME/Library/$($top.Name)" $entry.Name
                    if (Test-Path -LiteralPath $homePath) { continue }
                    $orphans += [pscustomobject]@{ Home = $homePath; Volume = $entry.FullName }
                    $problems += "on the volume without a home link: ~/Library/$($top.Name)/$($entry.Name)"
                }
            }

            $tier = Get-MoveTier $name
            if ($tier -in 'caution', 'avoid') {
                $problems += "on the $tier list while moved - Mozilla apps pick their default profile by install path, so a volume-moved app starts fresh; revert fixes it automatically, and doctor's complete re-points the app's profiles.ini at the existing profile"
            }
        } catch {
            $problems += "audit failed (volume unreadable?): $_"
        }
        if ($problems.Count -gt 0) {
            $records += [pscustomobject]@{
                Name     = $name
                Link     = $app.LinkPath
                Target   = $app.Target
                LibRoot  = Join-Path (Split-Path (Split-Path $app.Target -Parent) -Parent) "App Library/$name"
                Problems = $problems
                Partial  = $partial
                Orphans  = $orphans
                Broken   = $broken
                Tier     = Get-MoveTier $name
            }
        }
    }
    # no comma-wrap: the caller collects with @(), and a comma here would nest
    return $records
}

function Invoke-Doctor {
    # Show every partial or broken relocation, then fix each app in the chosen
    # direction: complete moves the remaining local data to the volume and links
    # orphaned volume entries home; revert brings the bundle and every volume
    # entry back to the internal disk. Per-app prompt unless -Direction is given.
    if ($Direction -and $Direction -notin 'complete', 'revert') {
        Write-Failure "-Direction must be 'complete' or 'revert' (got '$Direction')."
        exit 2
    }
    $records = @(Get-MoveAudit)
    if ($records.Count -eq 0) {
        Write-Info 'all moved apps are consistent - nothing to fix.'
        return
    }

    foreach ($record in $records) {
        Write-Host ''
        Write-Host "$($PSStyle.Bold)$($record.Name)$($PSStyle.Reset)"
        foreach ($problem in $record.Problems) { Write-Host "  - $problem" }
        if ($record.Partial.Count -gt 0) {
            $sum = ($record.Partial | Measure-Object -Property SizeKb -Sum).Sum
            Write-Host "  completing would move $(Format-Size $sum) to the volume"
        }
        if ($record.Tier -in 'caution', 'avoid') {
            Write-Caution '  reverting restores the original install path and fixes profile selection;'
            Write-Caution '  completing re-points the app''s profiles.ini at its existing profile automatically.'
        }
    }

    if (-not $Direction -and [Console]::IsInputRedirected) {
        Write-Host ''
        Write-Failure 'fixes need a direction - re-run in a terminal, or pass -Direction complete or -Direction revert.'
        exit 2
    }

    $fixed = 0
    $skipped = 0
    $failedFixes = 0
    $bundlesReverted = 0
    foreach ($record in $records) {
        Write-Host ''
        $choice = $Direction
        if (-not $choice) {
            $answer = (Read-Host "$($record.Name): complete / revert / skip? [c/r/s]").Trim().ToLower()
            $choice = $answer -in 'c', 'complete' ? 'complete' : $answer -in 'r', 'revert' ? 'revert' : 'skip'
        }
        if ($choice -eq 'skip') {
            $skipped++
            continue
        }
        try {
            if ($choice -eq 'complete') {
                if (-not (Test-Path -LiteralPath $record.Target)) {
                    Write-Failure "$($record.Name): the bundle is gone from the volume - only revert (or reinstall) can fix this."
                    $skipped++
                    continue
                }
                if (Test-AppRunning @($record.Link, $record.Target)) {
                    Write-Caution "$($record.Name): the app is running (launched via the symlink or the volume) - quit it before completing."
                    $skipped++
                    continue
                }
                # refuse completions that cannot fit: a mid-copy disk-full
                # failure is the classic way relocation tools lose data
                if ($record.Partial.Count -gt 0) {
                    $needKb = ($record.Partial | Measure-Object -Property SizeKb -Sum).Sum
                    $dfRow = (df -k $record.Target | Select-Object -Skip 1) -split '\s+'
                    $freeKb = [long]$dfRow[3]
                    if ($freeKb -lt [Math]::Ceiling($needKb * 1.05)) {
                        Write-Caution "$($record.Name): not enough space on the volume to complete - $(Format-Size $needKb) to move, $(Format-Size $freeKb) free. Nothing was copied."
                        $skipped++
                        continue
                    }
                }
                $libMoved = 0
                $libFailed = 0
                if ($record.Partial.Count -gt 0) {
                    $libResult = Invoke-LibraryMove -AppName $record.Name -BundlePath $record.Target -LibRoot $record.LibRoot
                    $libMoved = $libResult.Moved
                    $libFailed = $libResult.Failed
                }
                foreach ($orphan in $record.Orphans) {
                    $null = [System.IO.Directory]::CreateDirectory((Split-Path $orphan.Home -Parent))
                    $null = Invoke-Tool ln @('-s', $orphan.Volume, $orphan.Home)
                    $libMoved++
                }
                # Mozilla-family apps: repoint profiles.ini at the existing profile so
                # the next launch from the volume keeps it instead of starting fresh
                $null = Invoke-MozillaRepoint -AppName $record.Name -BundlePath $record.Target
                if ($libFailed -gt 0) {
                    Write-Caution "$($record.Name): completed with $libFailed library failure(s) - see warnings above; no original data was deleted."
                } else {
                    Write-Info "$($record.Name): completed$(($libMoved -gt 0) ? " (+$libMoved ~/Library entries)" : '')."
                }
                if ($libMoved -gt 0) { Write-RemovableVolumeNote }
                $fixed++
            } else {
                # revert: bundle first, then library entries, then clean dangling links
                $linkItem = Get-Item -LiteralPath $record.Link -Force -ErrorAction SilentlyContinue
                if (-not $linkItem -or $linkItem.LinkType -ne 'SymbolicLink') {
                    Write-Failure "$($record.Name): the home path is no longer a symlink - skipping (a real app may have replaced it)."
                    $skipped++
                    continue
                }
                if (Test-AppRunning @($record.Link, $record.Target)) {
                    Write-Caution "$($record.Name): the app is running - quit it before reverting."
                    $skipped++
                    continue
                }
                if (Test-Path -LiteralPath $record.Target) {
                    if (Restore-OneBundle -LinkPath $record.Link -TargetPath $record.Target) {
                        $bundlesReverted++
                    } else {
                        $failedFixes++
                        continue
                    }
                } else {
                    Remove-Item -LiteralPath $record.Link
                    Write-Caution "$($record.Name): volume bundle was gone - removed the dangling symlink only."
                }
                foreach ($dangling in $record.Broken) { Remove-Item -LiteralPath $dangling -Force -ErrorAction SilentlyContinue }
                $libRestored = Invoke-LibraryRestore -AppName $record.Name -LibRoot $record.LibRoot
                # the bundle is back at its home path - repoint Mozilla profiles.ini
                # at the home install hash, so the next launch from /Applications
                # keeps the existing profile instead of starting fresh
                $null = Invoke-MozillaRepoint -AppName $record.Name -BundlePath $record.Link
                Write-Info "$($record.Name): reverted$(($libRestored -gt 0) ? " (+$libRestored ~/Library entries)" : '')."
                $fixed++
            }
        } catch {
            Write-Failure "$($record.Name): $choice failed - $_ (re-run doctor to retry once the cause above is resolved)."
            $failedFixes++
        }
    }

    if ($bundlesReverted -gt 0) {
        Write-Host ''
        Restore-AppRegistration
    }
    Write-Host ''
    Write-Info "doctored $fixed app(s), skipped $skipped, failed $failedFixes."
    if ($failedFixes -gt 0) { exit 1 }
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
    if ($item.LinkType -eq 'SymbolicLink' -and -not (Test-Path -LiteralPath $realPath)) {
        Write-Caution "the linked bundle is missing: $realPath - refresh cannot fix a broken move (try doctor)."
    }
    Write-Info "refreshing $appFile at $realPath"

    Write-Info 're-registering the app with macOS...'
    $null = Invoke-Tool $LsRegister @('-f', $realPath) -Tolerant

    if ($ForceRepair) {
        # same policy as move: keep a valid original signature; re-signing is
        # a fallback, because an ad-hoc signature unbinds existing TCC grants
        $null = Invoke-Tool xattr @('-d', 'com.apple.quarantine', $realPath) -Tolerant
        $verifyOutput = codesign --verify $realPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            $reason = (($verifyOutput | Out-String).Trim() -replace '\s+', ' ')
            Write-Caution "signature check failed ($reason) - re-signing it locally instead; macOS will ask again for permissions this app already had (removable volumes, screen recording, ...)"
            try {
                Invoke-Tool codesign @('--force', '--deep', '--sign', '-', $realPath)
            } catch {
                Write-Caution "re-sign failed: $(($_.ToString()))"
            }
        } else {
            Write-Info 'signature verified - kept intact.'
        }
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
    'doctor'  { Invoke-Doctor }
    'refresh' { Invoke-Refresh }
    'help'    { Show-Usage }
    default {
        if ($Command) { Write-Failure "unknown command '$Command'." }
        Show-Usage
    }
}
exit 0

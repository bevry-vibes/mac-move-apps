#!/usr/bin/env pwsh
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
                                 symlinked back. With no app given, a full-height
                                 interactive multiselect lists every installed app
                                 with tier colours, sizes, the paths a move would
                                 relocate, and a live selected-total footer.
                                 When the destination is omitted, the command asks
                                 where the app should go, offering mounted volumes.
      restore                    Move every externally-stored app - and its ~/Library
                                 entries - back to the internal disk.
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
#             services; or patches the system (Apple pro media apps included).
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
        'OpenAudible', 'Openscreen', 'Orion', 'PDFgear', 'Pearcleaner', 'Plezy',
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
        'OpenCore-Patcher', 'OrbStack', 'Parallels Desktop', 'Plex Media Server',
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
  restore                   Move every externally-stored app - and its ~/Library
                            entries - back to the internal disk.
  list                      Show installed apps categorised by move safety.
  status                    Show apps already moved to external storage.
  refresh <app>             Refresh LaunchServices, Dock, Finder, and Spotlight
                            for a moved app.
  doctor                    Audit moved apps for partial or broken relocations,
                            then fix each in the direction you choose:
                            complete = move remaining local data to the volume,
                            revert = move the app back to the internal disk.

Options:
  -Force        move: overwrite an existing app at the destination.
  -DryRun       restore: preview what would move, change nothing.
  -Yes          restore: skip the confirmation prompt.
  -ForceRepair  refresh: also clear xattrs and re-sign the app.
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

function Test-AppReadyToMove {
    # Refuse already-symlinked and running apps. Reports the reason itself.
    param([Parameter(Mandatory)] [string]$Src)
    $item = Get-Item -LiteralPath $Src
    if ($item.LinkType -eq 'SymbolicLink') {
        Write-Caution "$(Split-Path $Src -Leaf) is already a symlink to $(@($item.Target)[0]) - nothing to move."
        return $false
    }
    $null = pgrep -f ([regex]::Escape("$Src/"))
    if ($LASTEXITCODE -eq 0) {
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
    # When a source removal fails partway, the volume copy is KEPT - it may be
    # the only complete copy - and the entry counts as failed, with the manual
    # finish steps printed. The copy is never rolled back.
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
        try {
            [void][System.IO.Directory]::CreateDirectory((Split-Path $dest -Parent))
            Write-Info "moving ~/Library/$rel"
            Invoke-Tool ditto @($libPath, $dest)
            # a Finder window or editor can race rm by dropping fresh files
            # (.DS_Store) into the directory - "Directory not empty" - retry once
            try {
                Invoke-Tool rm @('-rf', $libPath)
            } catch {
                Write-Caution "first removal failed (close Finder windows/editors holding ~/Library/$rel) - retrying..."
                Start-Sleep -Seconds 1
                Invoke-Tool rm @('-rf', $libPath)
            }
            Invoke-Tool ln @('-s', $dest, $libPath)
        } catch {
            # never delete the copy here: after a partial source removal it may
            # be the only complete copy left
            Write-Caution "could not finish moving ~/Library/${rel}: $_"
            Write-Caution "kept the copy at $(($dest -replace [regex]::Escape($HOME), '~')) - to finish by hand once nothing holds the directory:"
            Write-Caution "  rm -rf `"$libPath`" && ln -s `"$dest`" `"$libPath`""
            $failed++
            continue
        }
        $moved++
    }
    return @{ Moved = $moved; Failed = $failed }
}

function Invoke-LibraryRestore {
    # Reverse of Invoke-LibraryMove: walk the app's folder under the volume's
    # App Library root and move each entry back to its ~/Library location,
    # replacing the symlinks left there. The tree holds two shapes: a top-level
    # entry named after the app is the whole ~/Library/<app> dir (single level);
    # any other top-level dir is a group (Application Support, Caches, ...) whose
    # children map to ~/Library/<group>/<child>. Real entries at home are never
    # clobbered. Returns the number of entries restored.
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
                Write-Caution "keeping $HomePath - a real entry replaced the link"
                return $false
            }
        }
        $null = [System.IO.Directory]::CreateDirectory((Split-Path $HomePath -Parent))
        try {
            Invoke-Tool mv @($VolumeEntry, $HomePath)
        } catch {
            Write-Caution "could not restore ${HomePath}: $_"
            return $false
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
        if (-not (Get-ChildItem -LiteralPath $top.FullName -Force)) { Remove-Item -LiteralPath $top.FullName -Force }
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
    # expand ~ and relative destinations - native tools take them literally otherwise
    $DestDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DestDir)
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

    try {
        # .NET call: literal path creation, unlike New-Item's wildcard-mangled -Path
        [void][System.IO.Directory]::CreateDirectory($DestDir)
        if (Test-Path -LiteralPath $dst) {
            if ($Force) {
                Write-Caution "destination exists, overwriting: $dst"
                Remove-Item -LiteralPath $dst -Recurse -Force
            } else {
                Write-Failure "destination already exists: $dst (re-run with -Force to overwrite)"
                return $false
            }
        }
    } catch {
        Write-Failure "cannot prepare the destination: $_"
        return $false
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
        $null = Invoke-Tool rm @('-rf', $dst) -Tolerant
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
            # the copy is never deleted here: a half-finished removal leaves the
            # original damaged and the copy as the only complete version
            Write-Failure "could not remove the original: $_"
            Write-Caution "kept the copy at $dst - once nothing holds the original, finish by hand:"
            Write-Caution "  rm -rf `"$Src`" && ln -s `"$dst`" `"$Src`""
            return $false
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

    # clear quarantine and re-sign so Gatekeeper accepts the relocated bundle
    Write-Info 'clearing extended attributes and re-signing...'
    $null = Invoke-Tool xattr @('-cr', $dst) -Tolerant
    $null = Invoke-Tool codesign @('--force', '--deep', '--sign', '-', $dst) -Tolerant

    Write-Info 're-registering with LaunchServices...'
    $null = Invoke-Tool $LsRegister @('-f', $dst) -Tolerant

    # Mozilla-family apps: repoint profiles.ini at the existing profile so the
    # first launch from the volume does not present a fresh install
    $null = Invoke-MozillaRepoint -AppName $name -BundlePath $dst

    # relocate the app's ~/Library footprint next to the bundle on the volume;
    # skipped for root-level destinations, which have no sensible sibling spot
    if ($destParent -ne '/' -and $destParent -ne '/Volumes') {
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
    } else {
        Write-Info "moved $appFile to $dst (~/Library entries stay put - destination has no sibling dir)"
    }
    return $true
}

function Get-AppInventory {
    # Installed apps enriched with tier, relocatable paths, and sizes - the shared
    # base for the multiselect and the list output, sorted safe → unlisted →
    # caution → avoid, then by name. Empty when nothing is installed.
    $installed = @(Get-InstalledApp)
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
    if ($failed -gt 0 -and $moved -eq 0) { exit 1 }
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
            if (-not (Test-Path -LiteralPath $homePath)) {
                $null = Invoke-Tool ln @('-s', $app.Target, $app.LinkPath) -Tolerant
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
                        $problems += "dangling link: ~/Library/$rel"
                    }
                } else {
                    $kb = 0
                    $first = & du -sk $homePath 2>$null | Select-Object -First 1
                    if ("$first" -match '^(\d+)') { $kb = [long]$Matches[1] }
                    $partial += [pscustomobject]@{ Path = $homePath; SizeKb = $kb }
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
        if ($choice -eq 'complete') {
            if (-not (Test-Path -LiteralPath $record.Target)) {
                Write-Failure "$($record.Name): the bundle is gone from the volume - only revert (or reinstall) can fix this."
                $skipped++
                continue
            }
            $running = $false
            foreach ($probe in @("$($record.Link)/", "$($record.Target)/")) {
                $null = pgrep -f ([regex]::Escape($probe))
                if ($LASTEXITCODE -eq 0) { $running = $true; break }
            }
            if ($running) {
                Write-Caution "$($record.Name): the app is running (launched via the symlink or the volume) - quit it before completing."
                $skipped++
                continue
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
                Write-Caution "$($record.Name): completed with $libFailed library failure(s) - see warnings above, nothing was deleted."
            } else {
                Write-Info "$($record.Name): completed$(($libMoved -gt 0) ? " (+$libMoved ~/Library entries)" : '')."
            }
            $fixed++
        } else {
            # revert: bundle first, then library entries, then clean dangling links
            if (Test-Path -LiteralPath $record.Target) {
                Remove-Item -LiteralPath $record.Link
                Invoke-Tool mv @($record.Target, $record.Link)
                $bundlesReverted++
            } else {
                Remove-Item -LiteralPath $record.Link
                Write-Caution "$($record.Name): volume bundle was gone - removed the dangling symlink only."
            }
            foreach ($dangling in $record.Broken) { Remove-Item -LiteralPath $dangling -Force }
            $libRestored = Invoke-LibraryRestore -AppName $record.Name -LibRoot $record.LibRoot
            Write-Info "$($record.Name): reverted$(($libRestored -gt 0) ? " (+$libRestored ~/Library entries)" : '')."
            $fixed++
        }
    }

    if ($bundlesReverted -gt 0) {
        Write-Host ''
        Write-Info 'refreshing LaunchServices, Dock, and Finder...'
        $null = Invoke-Tool $LsRegister @('-kill', '-r', '-domain', 'local', '-domain', 'system', '-domain', 'user') -Tolerant
        $null = Invoke-Tool killall @('Dock') -Tolerant
        $null = Invoke-Tool killall @('Finder') -Tolerant
    }
    Write-Host ''
    Write-Info "doctored $fixed app(s), skipped $skipped."
    if ($fixed -eq 0 -and $records.Count -gt 0) { exit 1 }
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
    'doctor'  { Invoke-Doctor }
    'refresh' { Invoke-Refresh }
    'help'    { Show-Usage }
    default {
        if ($Command) { Write-Failure "unknown command '$Command'." }
        Show-Usage
    }
}
exit 0

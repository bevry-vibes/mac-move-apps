# Mac Move Apps

Move macOS `.app` bundles to external storage and back, keeping them fully launchable via symlinks — for when the internal SSD is full but Launchpad, Spotlight, and the Dock should keep working as before.

One PowerShell command wraps the whole workflow. Derived from [cnshsliu/mac-move-apps](https://github.com/cnshsliu/mac-move-apps) (MIT), rewritten and modernised.

## Requirements

- macOS 12+
- [PowerShell 7.6+](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-macos) (`pwsh`) — the `#Requires -Version 7.6` guard fails fast on older hosts
- `ditto`, `xattr`, `codesign` — all built into macOS:
  - `ditto` — Apple's copy command. Chosen over Finder/`cp` because it preserves permissions, extended attributes, resource forks, and the app's embedded signature.
  - `xattr` — manages the extra file attributes macOS attaches; used to remove an app's quarantine flag (the "downloaded from the internet" marker).
  - `codesign` — checks (and if necessary repairs) an app's code signature, the developer's cryptographic proof of who built the app.
- Administrator password for the rare case where a bundle in `/Applications` refuses removal as your user (the tool asks via `sudo` then).

## Usage

```powershell
pwsh -File ./mac-move-apps.ps1 move                                # multiselect apps, then destination
pwsh -File ./mac-move-apps.ps1 move 'Visual Studio Code'                                # asks where the app should go
pwsh -File ./mac-move-apps.ps1 move Motrix /Volumes/Scratchpad/Applications             # destination given
pwsh -File ./mac-move-apps.ps1 list                                                     # what is safe to move
pwsh -File ./mac-move-apps.ps1 status                                                   # what has been moved
pwsh -File ./mac-move-apps.ps1 restore -DryRun                                          # preview moving everything back
pwsh -File ./mac-move-apps.ps1 restore Orion -Yes                                       # bring one app back
pwsh -File ./mac-move-apps.ps1 refresh IINA -ForceRepair                                # re-register a moved app
```

The script has a `pwsh` shebang — `chmod +x ./mac-move-apps.ps1` once, then `./mac-move-apps.ps1 move` works directly.

| Command | What it does |
| --- | --- |
| `move [app] [destination]` | Copies the app to the volume with `ditto` (Apple's copy command — preserves everything, signature included), replaces the original with a symlink, clears the quarantine flag, re-registers the app with macOS — keeping the app's original signature, and re-signing locally only if the copy actually broke it (a local re-sign discards the developer's identity and makes macOS forget the app's permissions, so it is a last resort) — and relocates the app's `~/Library` footprint (Application Support, Caches, Logs, WebKit, HTTPStorages, Saved Application State) to the volume's `App Library` folder, symlinking those back too. When both a local and a volume copy of an entry exist, size and last-change decide: identical or clearly staler volume copies are moved to the Trash with a note (local — the copy the app is actually using — keeps), while two divergent copies stop that entry and ask which to keep (local / volume / skip, or a summary refusal when non-interactive). With no app given, a full-height multiselect lists every installed app: tier-coloured rows (green = safe, yellow = caution, red = do-not-move, cyan = unclassified), each showing the app's size and the exact paths a move would relocate underneath, with a live selected-total footer. |
| `restore [app]` | Moves every externally-stored app (`restore`) or one named app (`restore Orion`) — and its `~/Library` entries — back to its original location on the internal disk. Running it again for an app whose restore was interrupted finishes the job (data still linked to the volume comes home, leftover volume copies are trashed). Entries where real data reappeared at home resolve the two-copy conflict instead of silently keeping local: identical or clearly staler copies resolve automatically (the loser goes to the Trash, recoverably), divergent copies ask which to keep. |
| `list` | Shows installed apps categorised by move safety, tier-coloured, with per-app sizes, section totals, and a movable grand total. |
| `status` | Shows apps already moved (symlinks targeting `/Volumes`). |
| `doctor` | Audits moved apps for partial or broken relocations — data left behind locally (e.g. apps moved before a `~/Library` location was covered, like Thunderbird's top-level dir), broken symlinks (links whose target is gone), volume entries orphaned from their home, and moved apps now on the locked tiers — then asks per app which direction to fix: `complete` (finish moving the remaining data to the volume) or `revert` (bring the app back to the internal disk). `-Direction complete|revert` skips the asking. |
| `refresh <app>` | Re-registers the app with macOS and refreshes Dock, Finder, and Spotlight for a moved app. |

Options: `-Force` (move: overwrite an existing target), `-DryRun` (restore: preview only), `-Yes` (restore: skip the prompt), `-ForceRepair` (refresh: clear the quarantine flag and repair the signature, but only when it is broken).

App names accept aliases (`vscode`, `chrome`, `iterm2`, …), an optional `.app` suffix, or a direct bundle path. Apps are searched in `/Applications` and `~/Applications`.

When `move` gets no destination it asks where the app should go, listing mounted volumes with size and free space — pick a number (apps land in that volume's `Applications` dir, their library data in the sibling `App Library` dir) or type any destination path. Apps whose drive is unmounted simply fail to launch until it is remounted.

The safety tiers are enforced, not advisory: apps on the caution and avoid lists are locked in the multiselect and refused by direct `move` (see the lists in the script to adjust the classifications). `Preferences`, `Containers`, and `Group Containers` never move — macOS's settings system and app sandboxing misbehave when those go through symlinks.

## What not to move

Adobe suites, Xcode, Parallels/VMware/OrbStack/Docker, VPNs (Tailscale, ExpressVPN), Orion (observed on this machine: it stops working entirely when moved, and had to be moved back), and anything with privileged helpers or system extensions — these integrate too deeply with the OS and break when relocated. The **Mozilla family (Firefox, Thunderbird, Waterfox)** is also locked: Mozilla apps pick their dedicated default profile by hashing the app's real install directory ([toolkit/profile docs](https://searchfox.org/mozilla-central/source/toolkit/profile/docs/index.md)), so an app moved to another volume comes up as a fresh install with an empty profile — even though the original launch path is symlinked, and even though the profile *data* itself is fine to relocate (profile paths are relative to `~/Library/<app>`, which may be a symlink). Nothing is lost: revert the app, or `doctor -Direction complete` — which now re-points the app's `profiles.ini` at its existing profile automatically (computing Mozilla's install hash exactly, verified against real Thunderbird hashes; the original file is kept as `.bak-mac-move-apps`). `list` categorises what you have installed. Large apps on a mechanical external HDD will also feel sluggish — prefer a fast SSD.

## How it works

1. `ditto` (Apple's copy command) copies the entire app, preserving permissions, metadata, extended attributes, resource forks, and the embedded signature.
2. The original is moved to the Trash (built-in `/usr/bin/trash` — recoverable until you empty it; apps can fall back to a permanent delete because they are re-downloadable, library data never does). If a removal cannot complete, the volume copy is always kept and the tool prints the exact steps to finish by hand — nothing is ever deleted to "roll back".
3. A symlink — a shortcut that macOS transparently follows — takes the original's place, so the system keeps seeing the app at its old path.
4. The app's `~/Library` footprint moves to `<volume>/App Library/<app name>/` with symlinks back at each original location.
5. The quarantine flag (macOS's "downloaded from the internet" marker) is cleared if present, then `codesign` verifies the signature — the developer's proof of who built the app. A valid original signature is kept as-is; only a broken one triggers a local re-sign as a fallback (with a warning that macOS will ask for the app's permissions again). App data relocated to a removable volume is additionally gated by macOS's *Removable Volumes* permission (Privacy & Security → Files & Folders) — the first launch of a moved app may prompt for it; allow it.
6. `lsregister` (the system's app-registration tool) tells macOS where the app now lives; `restore` rebuilds the whole app database and restarts Dock and Finder.

## Credits

Derived from [cnshsliu/mac-move-apps](https://github.com/cnshsliu/mac-move-apps), originally MIT licensed.

<!-- LICENSE/ -->

## License

Unless stated otherwise all works are:

- Copyright &copy; [Benjamin Lupton](https://balupton.com)

and licensed under:

- [Reciprocal Public License 1.5](http://spdx.org/licenses/RPL-1.5.html)

<!-- /LICENSE -->

# Mac Move Apps

Move macOS `.app` bundles to external storage and back, keeping them fully launchable via symlinks — for when the internal SSD is full but Launchpad, Spotlight, and the Dock should keep working as before.

One PowerShell command wraps the whole workflow. Derived from [cnshsliu/mac-move-apps](https://github.com/cnshsliu/mac-move-apps) (MIT), rewritten and modernised.

## Requirements

- macOS 12+
- [PowerShell 7.6+](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-macos) (`pwsh`) — the `#Requires -Version 7.6` guard fails fast on older hosts
- `ditto`, `xattr`, `codesign` — all built into macOS
- Admin rights when the app in `/Applications` needs `sudo` to remove

## Usage

```powershell
pwsh -File ./mac-move-apps.ps1 move                                # multiselect apps, then destination
pwsh -File ./mac-move-apps.ps1 move 'Visual Studio Code'                                # asks where the app should go
pwsh -File ./mac-move-apps.ps1 move Motrix /Volumes/Scratchpad/Applications             # destination given
pwsh -File ./mac-move-apps.ps1 list                                                     # what is safe to move
pwsh -File ./mac-move-apps.ps1 status                                                   # what has been moved
pwsh -File ./mac-move-apps.ps1 restore -DryRun                                          # preview moving everything back
pwsh -File ./mac-move-apps.ps1 refresh IINA -ForceRepair                                # re-register a moved app
```

| Command | What it does |
| --- | --- |
| `move [app] [destination]` | Copies the bundle with `ditto`, replaces the original with a symlink, clears quarantine, ad-hoc re-signs, re-registers with LaunchServices — and relocates the app's `~/Library` footprint (Application Support, Caches, Logs, WebKit, HTTPStorages, Saved Application State) to the volume's `App Library` folder, symlinking those back too. With no app given, an arrow-key multiselect lists every installed app. |
| `restore` | Moves every externally-stored app — and its `~/Library` entries — back to its original location on the internal disk. |
| `list` | Shows installed apps categorised by move safety. |
| `status` | Shows apps already moved (symlinks targeting `/Volumes`). |
| `refresh <app>` | Refreshes LaunchServices, Dock, Finder, and Spotlight for a moved app. |

Options: `-Force` (move: overwrite an existing target), `-DryRun` (restore: preview only), `-Yes` (restore: skip the prompt), `-ForceRepair` (refresh: also clear xattrs and re-sign).

App names accept aliases (`vscode`, `chrome`, `iterm2`, …), an optional `.app` suffix, or a direct bundle path. Apps are searched in `/Applications` and `~/Applications`.

When `move` gets no destination it asks where the app should go, listing mounted volumes with size and free space — pick a number (apps land in that volume's `Applications` dir, their library data in the sibling `App Library` dir) or type any destination path. Apps whose drive is unmounted simply fail to launch until it is remounted.

The safety tiers are enforced, not advisory: apps on the caution and avoid lists are locked in the multiselect and refused by direct `move` (see the lists in the script to adjust the classifications). `Preferences`, `Containers`, and `Group Containers` never move — `cfprefsd` and sandbox path evaluation misbehave through symlinks.

## What not to move

Adobe suites, Xcode, Parallels/VMware/OrbStack/Docker, VPNs (Tailscale, ExpressVPN), and anything with privileged helpers or system extensions — these integrate too deeply with the OS and break when relocated. `list` categorises what you have installed. Large apps on a mechanical external HDD will also feel sluggish — prefer a fast SSD.

## How it works

1. `ditto` copies the entire bundle, preserving metadata, extended attributes, and resource forks.
2. The original is removed (falling back to `sudo`, rolling back the copy if even that fails).
3. A symlink takes the original's place, so macOS keeps seeing the app at its old path.
4. The app's `~/Library` footprint moves to `<volume>/App Library/<app name>/` with symlinks back at each original location.
5. `xattr -cr` clears quarantine and `codesign` ad-hoc re-signs, so Gatekeeper accepts the relocated bundle.
6. `lsregister` re-registers the app; `restore` rebuilds LaunchServices and restarts Dock and Finder.

## Credits

Derived from [cnshsliu/mac-move-apps](https://github.com/cnshsliu/mac-move-apps), originally MIT licensed.

<!-- LICENSE/ -->

## License

Unless stated otherwise all works are:

- Copyright &copy; [Benjamin Lupton](https://balupton.com)

and licensed under:

- [Reciprocal Public License 1.5](http://spdx.org/licenses/RPL-1.5.html)

<!-- /LICENSE -->

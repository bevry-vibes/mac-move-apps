# mac-move-apps

[![macOS](https://img.shields.io/badge/macOS-12%2B-blue)](https://www.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Move macOS `.app` bundles to an external drive safely while keeping them fully functional via symlinks.

This tool is especially useful when your internal SSD is running out of space but you still want apps to appear in Launchpad, Spotlight, and the Dock normally.

## Features

- Move any app from `/Applications` or `~/Applications` to external storage
- Automatically creates a symlink back to the original location
- Supports both argument orders: `app-name path` or `path app-name`
- `--list`: Shows currently installed apps categorized by safety
- `--refresh`: Refresh LaunchServices, Dock, and Spotlight cache after moving
- `--force`: Overwrite existing target if needed
- Companion script `restoreapps.sh` to move everything back in one go
- Automatic fallback to `sudo` when deleting protected apps
- Common app name aliases supported (`VS Code`, `微信`, `iina`, etc.)

## Installation

```bash
# Clone the repository
git clone https://github.com/cnshsliu/mac-move-apps.git
cd mac-move-apps

# Make scripts executable
chmod +x moveapp.sh restoreapps.sh

# (Optional) Install to ~/bin
mkdir -p ~/bin
cp moveapp.sh restoreapps.sh ~/bin/
```

Or simply download the scripts directly and place them in your `PATH`.

## Usage

### Basic Move

```bash
# Recommended order
moveapp.sh "Visual Studio Code" /Volumes/MySSD/Applications

# Alternative order (path first)
moveapp.sh /Volumes/MySSD/Applications "Visual Studio Code"
```

### List Safe-to-Move Apps

```bash
moveapp.sh --list
```

This shows all installed apps categorized into:

- **Recommended** (pure GUI apps with no system extensions)
- **Caution** (may need testing after moving)
- **Not Recommended** (Adobe apps, virtualization software, VPNs, etc.)

### Refresh After Moving

```bash
moveapp.sh --refresh "Visual Studio Code"
```

Or with forced repair:

```bash
moveapp.sh --refresh "IINA" --force-repair
```

### Force Overwrite

```bash
moveapp.sh --force /Volumes/MySSD/Applications "SomeApp"
```

### Restore All Apps

```bash
restoreapps.sh --dry-run     # Preview what will be restored
restoreapps.sh               # Interactive restore
restoreapps.sh --yes         # Restore everything without confirmation
```

## Important Notes

### Apps That Should NOT Be Moved

- **Adobe Creative Cloud apps** (Audition, Premiere, Photoshop, etc.)
- **Xcode**
- **Parallels Desktop**, **VMware Fusion**, **OrbStack**, **Docker**
- **Tailscale**, **ExpressVPN**, **Clash Verge**
- **Karabiner-Elements**
- Any app that installs system extensions or privileged helpers

These apps have deep system integration and moving them often breaks functionality.

### Performance Considerations

Even if an app can be moved, running large apps (especially video/audio editors) from a mechanical external HDD will result in noticeable lag. Use a fast external SSD (Thunderbolt or USB 3.2+) for best results.

### Requirements

- macOS 12+
- `ditto`, `codesign`, `xattr` (all built-in)
- Admin rights (for moving apps out of `/Applications`)

## How It Works

1. `ditto` is used to copy the entire `.app` bundle (preserves metadata and extended attributes).
2. The original is removed (with `sudo` fallback if needed).
3. A symlink is created in the original location pointing to the external copy.
4. `lsregister` + Dock restart refreshes all system caches.

Because of the symlink, macOS, Spotlight, and Launchpad continue to see the app at its original path.

## License

MIT License — feel free to use, modify, and share.

## Contributing

Issues and pull requests are welcome! Especially for:

- Adding more app aliases
- Improving the safe-app detection logic
- Supporting more languages in output messages

---

Made for people who constantly fight with "Your disk is almost full" on modern Macs.
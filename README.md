# Mac Shield & Cleaner

A lightweight, native macOS SwiftUI utility combining a **Low-Latency Gaming & Streaming Network Shield**, a **System Data & Cache Cleaner**, and an **External Drive Cleaner** in one Universal macOS app (`arm64` + `x86_64`, macOS 13+).

---

## Features

### 1. Anti-Lag Shield
* **Gaming Mode:** Disables delayed TCP ACKs (`delayed_ack=0`), tunes tight 4 MB anti-bufferbloat buffers, enables QoS fast-path, prioritizes active games/emulators/launchers (`renice -20` & `taskpolicy`), and enables macOS Game Mode support.
* **Streaming & Media Mode:** Enables Gigabit TSO and large 32 MB dynamic TCP buffers for 4K streaming apps (`Stremio`, `Plex`, `IINA`, `VLC`) and streaming browser tabs.
* **Zero-Stutter System Guard:** Pauses Spotlight indexing (`mdutil -i off /`), pauses AWDL/AirDrop background scans (`awdl0`/`llw0`), flushes DNS cache, prevents sleep (`caffeinate -dimsu`), and auto-learns your router's real MAC address to lock your default gateway ARP entry (with automatic re-learning when switching networks).
* **Live Telemetry, Launch at Login & Auto-Restore:** Tracks live ping + rolling jitter/min/avg right in the UI and macOS Menu Bar, supports Launch at Login (`SMAppService`), remembers your settings across launches, includes an in-app GitHub update check, and snapshots your exact `sysctl` values on start so stopping the Shield or quitting the app restores your Mac's original defaults cleanly.

### 2. System Data & Cache Cleaner
* Cleans discardable caches without deleting cookies, logins, bookmarks, game saves, or projects:
  * App Caches (`~/Library/Caches`) — skips running apps automatically (with a one-click quit option)
  * Sandboxed Containers, Group Containers & Mail Downloads
  * Chromium/Firefox Browser Caches (all profiles)
  * CrossOver / Heroic / Wine Bottle temp files
  * Developer & Package Caches (`Homebrew`, `uv`, `npm`, `yarn`, `pnpm`, `go`, `pip`, `gradle`, `cargo`, `Xcode`)
  * **Heavy System Data Bloat:** Chrome On-Device AI Model (`OptGuideOnDeviceModel`), macOS 4K Aerial Wallpaper videos, Chrome code-sign clones, and old Discord update versions
  * Optional toggles for GPU Shader Caches, Trash, and Admin System-Wide Caches + APFS local snapshot thinning
* Includes a **System Data Space Inspector** to reveal the largest folders on disk in Finder.

### 3. External Drives Cleaner
* Automatically detects mounted writable external HDDs, SSDs, and USB drives in real time.
* Safely cleans `.Trashes`, `.TemporaryItems`, external `SteamLibrary` download/depot caches, and macOS `._*` AppleDouble / `.DS_Store` clutter (especially impactful on ExFAT drives) without ever touching user files, games, or archives. Top-level `Temp/` cleanup is an explicit opt-in toggle with confirmation.

---

## Install

### Option 1: Download Prebuilt Release (`.dmg` or `.zip`)
1. Download the latest **`.dmg`** or **`.zip`** from the [Releases](https://github.com/NightKnight24/mac-shield-cleaner/releases) page (Universal Binary for Apple Silicon & Intel, macOS 13+).
2. Move **`Mac Shield & Cleaner.app`** into `/Applications`.
3. On first launch (since open-source ad-hoc builds are not Apple-notarized), right-click the app → **Open**, or run:
   ```bash
   xattr -cr "/Applications/Mac Shield & Cleaner.app"
   ```

### Option 2: Build from Source

Requires **macOS 13+** and **Xcode Command Line Tools** (`xcode-select --install`).

```bash
git clone https://github.com/NightKnight24/mac-shield-cleaner.git
cd mac-shield-cleaner
chmod +x build.sh
./build.sh --install
```

This compiles a **Universal Binary** (`arm64` + `x86_64`), generates the app icon, signs it locally, and installs **`/Applications/Mac Shield & Cleaner.app`**.

To build only into `./build/` without installing:

```bash
./build.sh
```

---

## Permissions & Safety
* **Admin Prompts:** Anti-Lag Shield and System-Wide Snapshot cleaning use native macOS `osascript ... with administrator privileges` (supporting Touch ID / system password) only when triggered. No passwords are ever stored.
* **Never Follows Symlinks:** Cache and external drive cleaners never follow symlinks or touch user documents, logins, or installed games.

## License
MIT License — see [LICENSE](LICENSE).

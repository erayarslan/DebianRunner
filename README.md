# DebianRunner

Headless **Debian GNU/Linux 13 (trixie) minimal ARM64** userspace for iPhone and iPad. No jailbreak, no desktop bloat.

## Features

- **Debian 13 Minimal ARM64** — First-launch verified download of official Debian trixie minimal packages (Turkish HTTPS mirrors with `deb.debian.org` fallback).
- **Termius SSH Workflow** — No built-in WebView terminal; built-in OpenSSH (`sshd` on `127.0.0.1:2222` and Wi-Fi LAN) starts automatically with 1-tap **Open in Termius** handoff (`termius://`, `ssh://`, or Apple Shortcuts auto-connect), opt-in **Auto-Open Termius on Launch**, and background keep-alive.
- **APT, Services & Accounts** — Native **Packages** UI for `apt`/`dpkg`, built-in `systemctl`/`journalctl`/`loginctl` service manager (user & system `.service` units with auto-start/restart), and account creation with passwordless `sudo` enabled by default.
- **Apple Files & Task Manager** — Browse the Debian rootfs directly in Apple's **Files** app, configure guest CPU/memory, and monitor live processes.

## Build Unsigned IPA (No Mac Required)

1. Open **Actions → Build DebianRunner IPA** and click **Run workflow** (or push to `main` / tag `v*`).
2. Download the `DebianRunner-<run>` artifact (retained for 1 day).
3. Sideload `DebianRunner.ipa` with AltStore, SideStore, Sideloadly, TrollStore, or Xcode.

## Requirements & Docs

- **Requirements:** ARM64 iPhone/iPad, iOS/iPadOS 15.0+, 2 GB+ RAM, 1 GB+ free storage.
- **Docs:** [Getting Started](docs/GETTING_STARTED.md) · [Installation](docs/INSTALLATION.md) · [Building](docs/BUILDING.md) · [Troubleshooting](docs/TROUBLESHOOTING.md) · [Known Limitations](docs/KNOWN_LIMITATIONS.md)

## License

Maintained by **Eray Arslan ([erayarslan](https://github.com/erayarslan))**, forked from [LinuxRunner](https://github.com/mxhm11cr/LinuxRunner) / [iSH](https://github.com/ish-app/ish). GPL-3.0 — see [LICENSE.md](LICENSE.md) and [LICENSE.IOS](LICENSE.IOS).

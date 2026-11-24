# DebianRunner

Headless **Debian GNU/Linux 13 (trixie) minimal ARM64** userspace for iPhone and iPad. No jailbreak, no desktop bloat, optional JIT.

## Features

- **Debian 13 Minimal ARM64** — First-launch verified download of official Debian trixie minimal packages (Turkish HTTPS mirrors with `deb.debian.org` fallback).
- **Terminal** — Native bash shell with touch text selection, unwrapped multiline URL copy, clickable links, smooth scrolling, and a compact key bar.
- **Built-in SSH Server** — OpenSSH (`sshd` on port `2222`) installed and enabled by default with background keepalive support.
- **APT & Accounts** — Native **Packages** UI for `apt`/`dpkg` and account creation with passwordless `sudo` enabled by default.
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

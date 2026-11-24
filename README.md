<p align="center">
  <img src="assets/branding/linuxrunner-icon.png" alt="DebianRunner" width="144">
</p>
<h1 align="center">DebianRunner</h1>
<h2 align="center">Headless Debian Minimal ARM64 for iPhone and iPad</h2>
<p align="center">Debian GNU/Linux 13 (trixie) minimal ARM64 userspace · Terminal · Built-in SSH · APT · Apple Files</p>
<p align="center">
  <img src="assets/branding/version-badge.svg" alt="DebianRunner">
  <img src="assets/branding/platform-badge.svg" alt="iOS and iPadOS">
  <a href="LICENSE.md"><img src="assets/branding/license-badge.svg" alt="GPL-3.0-covered application"></a>
</p>
<p align="center">
  <a href="#getting-started">Get started</a> ·
  <a href="#build-free-unsigned-ipa-no-mac-required">Build IPA on GitHub Actions</a> ·
  <a href="docs/USER_GUIDE.md">User guide</a> ·
  <a href="docs/BUILDING.md">Build from source</a> ·
  <a href="docs/TROUBLESHOOTING.md">Help</a>
</p>

DebianRunner runs **Debian GNU/Linux 13 (trixie) minimal ARM64** userspace on iPhone and iPad through a custom ARM64 instruction interpreter, an optional JIT engine, and a Linux ABI compatibility layer.

**No jailbreak. No desktop bloat. JIT is optional.** DebianRunner executes headless ARM64 Linux userspace programs; it does not boot a Linux kernel, use a full-system virtual machine, or bundle X11/Wayland/GPU desktop stacks.

## Features

| Capability | What it provides |
| --- | --- |
| **Debian 13 Minimal ARM64** | First-launch on-device download of official Debian trixie minimal packages verified against Debian's signed `InRelease` and SHA-256 package index (`DebianSupport.bundle`). |
| **Interactive Terminal** | Native terminal with bash login shell, hardware keyboard support, custom font sharpness/size, and command launchers. |
| **APT Package Management** | Native **Packages** front end for Debian `apt`/`dpkg` (curated CLI tools, full APT search, simulated transaction review, and Repair Center). |
| **Built-in SSH Server** | OpenSSH server (`sshd` on port `2222`) installed and started by default for remote terminals, VS Code Remote-SSH, `scp`, `rsync`, and SFTP, with background keepalive support. |
| **CPU, Memory & Task Manager** | Configure guest CPU core count and visible memory, monitor or terminate live Linux processes, and clear finished items from the Home task list. |
| **Apple Files & Shared Folders** | Mount the Debian root filesystem directly in Apple's native **Files** app (**Locations → DebianRunner → Debian Minimal**), plus `/mnt/LinuxRunnerShared` (`~/Shared`), linked Files folders (`/mnt/<name>`), Linux user management, Bluetooth LE serial (`/dev/ttyBLE0-3`), and USB-MIDI serial adapters (`/dev/ttyMIDI0-3`). |
| **Debian Minimal Settings & Wipe** | Dedicated **Debian** tab for managing your Debian Minimal environment and cleanly wiping/reinstalling it from scratch whenever needed. |
| **Optional ARM64 JIT** | Interpreter by default; optional JIT when iOS permits executable memory (e.g., via StikDebug). |

## Supported Devices and Requirements

| | Minimum guidance | Recommended |
| --- | --- | --- |
| Device | ARM64 iPhone or iPad | iPhone 12 Pro or newer, or equivalent iPad |
| RAM | At least 2 GB | At least 4 GB |
| OS | iOS/iPadOS 15.0 deployment target | Recent iOS/iPadOS release |
| Free storage | At least 1 GB for Debian minimal base | 4+ GB when installing toolchains and packages |

## Getting Started

1. Download or build `DebianRunner.ipa` (no Mac required via GitHub Actions — see below) and sideload it with AltStore, SideStore, Sideloadly, TrollStore, or Xcode. [Installation details](docs/INSTALLATION.md)
2. Open DebianRunner. On first launch, the setup wizard downloads and verifies official Debian 13 (trixie) minimal ARM64 packages using Turkish HTTPS mirrors (`mirror.rabisu.com`, `ftp.linux.org.tr`) with automatic fallback to `deb.debian.org`, and configures `/etc/apt/sources.list` to use Turkey's `ftp.linux.org.tr` mirror by default.
3. Optionally create a regular Linux user (with or without `sudo`) or continue as `root`.
4. Tap **Open Terminal** on the Home screen to start a Debian bash session.

Try `cat /etc/os-release`, `uname -m`, and `apt-get update` in the terminal, or browse CLI tools in **Home → Packages**.

[Full setup walkthrough](docs/GETTING_STARTED.md)

## Build Free Unsigned IPA (No Mac Required)

This repository includes a GitHub Actions workflow ([`.github/workflows/build-ipa.yml`](.github/workflows/build-ipa.yml)) that builds and verifies an unsigned ARM64 `DebianRunner.ipa` on GitHub's hosted macOS Apple Silicon runners (`macos-15`):

1. Open **Actions → Build DebianRunner IPA** in this repository.
2. Click **Run workflow** (or push to `main` / push a `v*` tag for an automatic GitHub Release).
   - Optional inputs: `jit` (include optional ARM64 JIT translator), `diagnostic` (diagnostic build), and `bundle_id` (default `dev.debianrunner.app`).
3. Download the `DebianRunner-<run>` artifact containing `DebianRunner.ipa`, `DebianRunner.ipa.sha256`, and validation reports.
4. Sideload `DebianRunner.ipa` onto your iPhone or iPad using AltStore, SideStore, Sideloadly, or TrollStore.

See [Building](docs/BUILDING.md) for local macOS/Xcode build commands as well.

## Built-in SSH Server

DebianRunner installs and starts an **OpenSSH server** (`sshd` on TCP port `2222`) by default. Open **Home → SSH Server** (or **Debian → SSH Server**) to view the copyable `ssh` / `sftp` commands, toggle auto-start or root login, enable background execution for long-lived SSH sessions, and inspect SSH logs.

## CPU & Memory

Open **Home → CPU & Memory** (or **Settings → Performance → CPU & Memory**) to configure how many CPU cores and how much memory Debian programs see. Changes apply on the next app launch. Use **Home → Task Manager** to inspect live CPU, memory, and guest processes.

## Networking and Apple Files

Linux sockets use the host iOS network stack (`ip addr`, `ip link`, `ip route`, `ping`, `tracepath`). Browse the full Debian root filesystem directly inside Apple's native **Files** app (**Browse → Locations → DebianRunner → Debian Minimal**) when signed with an App Group, or use **Home → Files** (`On My iPhone → DebianRunner → Shared`, mapped to `/mnt/LinuxRunnerShared` and `~/Shared`) and linked external folders at `/mnt/<name>`.

[Files](docs/FILE_SHARING.md) · [Networking](docs/NETWORKING_AND_DISPLAYS.md)

## How DebianRunner Works

1. The ELF loader maps ARM64 Linux executables and shared libraries into guest address spaces.
2. The Asbestos interpreter executes ARM64 instructions; the optional JIT translates hot blocks when iOS grants executable memory.
3. The compatibility layer implements Linux syscalls, processes, threads, signals, memory mappings, pseudo-terminals, sockets, and `fakefs` root filesystems.
4. Debian minimal packages are verified via `DebianSupport.bundle`, assembled locally into a `fakefs` root, and managed through Debian's own `apt` and `dpkg`.

[Architecture](docs/ARCHITECTURE.md) · [Compatibility](docs/COMPATIBILITY.md) · [Known limitations](docs/KNOWN_LIMITATIONS.md) · [Performance](docs/PERFORMANCE.md)

## License and Acknowledgments

Maintained by **Eray Arslan ([erayarslan](https://github.com/erayarslan))**.

DebianRunner is a headless Debian minimal fork of [LinuxRunner](https://github.com/mxhm11cr/LinuxRunner) (by Leminos / `mxhm11cr`), which derives from [iSH](https://github.com/ish-app/ish) (by Theodore Dubois and contributors) through [ios-linuxkit](https://github.com/rcarmo/ios-linuxkit) (by Rui Carmo and contributors).

The combined application is GPL-3.0-covered. Preserve upstream contribution-specific terms, attribution, and the App Store terms in [LICENSE.md](LICENSE.md) and [LICENSE.IOS](LICENSE.IOS). [Third-party notices](THIRD_PARTY_NOTICES.md) · [Security](SECURITY.md) · [Contributing](CONTRIBUTING.md)

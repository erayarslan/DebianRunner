# Getting Started — Installing Debian Minimal

Installing the IPA installs DebianRunner. On first launch, DebianRunner downloads and verifies **Debian GNU/Linux 13 (trixie) minimal ARM64** packages inside the app.

## 1. Install DebianRunner

Install the built/signed IPA using AltStore, SideStore, Sideloadly, TrollStore, or Xcode. See [Installation](INSTALLATION.md). No jailbreak or JIT activation is required.

## 2. First Launch & Debian Minimal Setup

The app has three tabs: **Home**, **Environments**, and **Settings**.

When no Debian environment is installed yet, the setup wizard opens automatically (or tap **Install Debian Minimal** on Home):

1. Review the storage and download size on **Install Debian Minimal**. At least 1 GB of free storage is required.
2. Tap **Install Debian Minimal** and keep DebianRunner in the foreground.
   - DebianRunner downloads official Debian 13 (trixie) minimal `.deb` packages from `deb.debian.org`.
   - Every package is checked against the bundled `DebianSupport.bundle/manifest.json` (`manifest.sha256` and Debian's signed `InRelease`).
   - Verified packages are assembled locally into a root filesystem archive and imported into an isolated `fakefs` root.
3. On first launch, DebianRunner boots the newly installed Debian minimal runtime automatically (if another environment was already booted in the same app session, close and reopen DebianRunner when prompted).
4. On **Your Account**, create a regular Linux user (with optional `sudo` administrator access) or choose **Continue as root (Skip)**.
5. Tap **Open Terminal** to launch a Debian bash shell.

First-boot package configuration (`dpkg --configure -a` and CA trust-store generation) runs automatically via `/usr/lib/linuxrunner/initialize-debian.sh`. Managed package and account operations wait for it to finish cleanly.

## 3. Verify Your Environment

In the terminal, run:

```sh
cat /etc/os-release
uname -m
id
```

The architecture reports `aarch64`.

## 4. Install CLI Packages with APT

Use **Home → Packages** to browse curated CLI tools, search all Debian APT repositories, preview simulated APT transactions, and install, update, or remove packages.

Or use `apt` directly in the terminal:

```sh
apt-get update
apt-get install --no-install-recommends git nano curl
```

## 5. Enable Optional Headless Modes

Open **Home → Modes** (or **Settings → General → DebianRunner Modes**) to install and toggle:

- **Agent Mode**: Node.js, git, ripgrep, Python, and CLI coding agents (`claude`, `codex`, `opencode`).
- **SSH Mode**: OpenSSH server on port `2222` (non-root user login).
- **Liftoff**: HTTP server for `~/Sites` on port `8080` with Safari link and LAN QR code.
- **Pocket Cloud**: WebDAV file server for `~/Pocket Cloud` on port `8081`.

## 6. Manage Multiple Debian Environments

Open the **Environments** tab to view storage usage, create an additional fresh Debian minimal environment, select which environment boots on next launch (**Use on Next Launch**), or delete inactive environments.

A mounted environment cannot be deleted while running; switch to another environment, fully close and reopen DebianRunner, then delete the inactive one.

## 7. CPU, Memory, and Optional JIT

- **Home → CPU & Memory** configures guest CPU cores and memory limits (applies on next launch).
- **Home → Task Manager** shows live guest CPU, memory, and running processes.
- **Settings → Advanced → Developer Mode → Execution Engine / StikDebug** inspects interpreter/JIT status. JIT is optional.

# Getting Started — Installing Debian Minimal

Installing the IPA installs DebianRunner. On first launch, DebianRunner downloads and verifies **Debian GNU/Linux 13 (trixie) minimal ARM64** packages inside the app.

## 1. Install DebianRunner

Install the built/signed IPA using AltStore, SideStore, Sideloadly, TrollStore, or Xcode. See [Installation](INSTALLATION.md). No jailbreak is required.

## 2. First Launch & Debian Minimal Setup

The app has three tabs: **Home**, **Debian**, and **Settings**.

When no Debian environment is installed yet, the setup wizard opens automatically (or tap **Install Debian Minimal** on Home):

1. Review the storage and download size on **Install Debian Minimal**. At least 1 GB of free storage is required.
2. Tap **Install Debian Minimal** and keep DebianRunner in the foreground.
   - DebianRunner downloads official Debian 13 (trixie) minimal `.deb` packages from Turkish HTTPS mirrors (`mirror.rabisu.com`, `ftp.linux.org.tr`) with automatic fallback to `deb.debian.org`, and defaults APT to `ftp.linux.org.tr`.
   - Every package is checked against the bundled `DebianSupport.bundle/manifest.json` (`manifest.sha256` and Debian's signed `InRelease`).
   - Verified packages are assembled locally into a root filesystem archive and imported into an isolated `fakefs` root.
3. On first launch, DebianRunner boots the newly installed Debian minimal runtime automatically (if another environment was already booted in the same app session, close and reopen DebianRunner when prompted).
4. On **Your Account**, create a regular Linux user (with passwordless `sudo` administrator access enabled by default) or choose **Continue as root (Skip)**.
5. Tap **Open in Termius** (or open **Home → Termius & SSH**) to connect to your Debian shell at `127.0.0.1:2222`.

First-boot package configuration (`dpkg --configure -a` and CA trust-store generation) runs automatically via `/usr/lib/linuxrunner/initialize-debian.sh`. Managed package and account operations wait for it to finish cleanly.

## 3. Connect with Termius

DebianRunner runs completely headlessly without an embedded WebView terminal. Instead, it installs `openssh-server` automatically, starts `sshd` on port `2222`, and hands off shell sessions to **Termius** on iPhone/iPad (with background keep-alive enabled automatically before switching apps):

1. Install [Termius](https://apps.apple.com/app/id549039908) from the App Store and add a host pointing to `127.0.0.1`, port `2222`, with your Debian username and password (or SSH key).
2. Tap **Open in Termius** from **Home**, **Debian**, or **Termius & SSH** to start `sshd`, enable background keep-alive, and switch directly to Termius.
3. For 1-tap auto-connect straight into your saved Debian host, create an Apple Shortcut using Termius's **Connect to a host** action, select **Apple Shortcut** in **Termius & SSH → Redirect Mode**, and optionally turn on **Auto-Open Termius on Launch** (also available in **Settings → General**).

Inside your Termius SSH session, verify your environment:

```sh
cat /etc/os-release
uname -m
id
```

The architecture reports `aarch64`.

## 4. Install CLI Packages with APT

Use **Home → Packages** to browse curated CLI tools, search all Debian APT repositories, preview simulated APT transactions, and install, update, or remove packages headlessly with live log output.

Or use `apt` directly over SSH in Termius:

```sh
apt-get update
apt-get install --no-install-recommends git nano curl
```

## 5. LAN SSH & SFTP Access

Open **Home → Termius & SSH** (or **Debian → Termius & SSH**) to:

- Copy the ready-to-run local (`127.0.0.1:2222`) or Wi-Fi LAN `ssh -p 2222 <user>@<iPhone-IP>` and `sftp -P 2222 <user>@<iPhone-IP>` commands.
- Start, stop, or restart `sshd`, toggle **Start SSH Automatically on Launch**, or enable **Allow Root Login**.
- Configure **Redirect Mode** (`Termius App`, `SSH Link`, or `Apple Shortcut`) and **Auto-Open Termius on Launch**.
- Manage **Keep Linux Running in Background** so SSH sessions stay alive while using Termius or locking your screen.

## 6. Manage or Wipe Debian Minimal

Open the **Debian** tab to inspect Debian Minimal status and storage usage, access SSH Server, APT packages, Linux users, and Apple Files settings, or tap **Wipe Debian Minimal…** to cleanly erase and reinstall Debian Minimal from scratch.

Finished or paused entries in the Home **Tasks** list can be removed individually or cleared all at once with **Clear**.

## 7. CPU and Memory

- **Home → CPU & Memory** configures guest CPU cores and memory limits (applies on next launch).
- **Home → Task Manager** shows live guest CPU, memory, and running processes.

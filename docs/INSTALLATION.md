# Install DebianRunner

Installing the IPA installs DebianRunner. On first launch, DebianRunner downloads and verifies **Debian GNU/Linux 13 (trixie) minimal ARM64** packages inside the app. No jailbreak or JIT activation is required.

## Requirements

- ARM64 iPhone or iPad (minimum deployment target iOS/iPadOS 15.0; tested primarily on recent releases).
- At least 1 GB of free device storage for Debian minimal (4+ GB recommended when installing development toolchains).
- Network access on first launch to download verified official Debian packages from `deb.debian.org`.

## Install and Open

1. Download `DebianRunner.ipa` from a GitHub Actions workflow artifact or GitHub Release (no Mac required — see [Building](BUILDING.md)), or build it locally on macOS.
2. Sign and install it with AltStore, SideStore, Sideloadly, TrollStore, or Xcode.
3. Open DebianRunner and complete the **Install Debian Minimal** setup wizard. See [Getting Started](GETTING_STARTED.md).

The default bundle identifier is `dev.debianrunner.app`. Optional App Group access uses `group.dev.debianrunner.app` when provisioned; otherwise private application storage is used. Ordinary interpreter execution does not require debugger/JIT permissions; see [JIT](engine/IOS_JIT.md) for optional JIT details.

## Update Without Losing Environments

Back up important files before updating. Keep the same bundle identifier and App Group/container configuration so existing Debian environments remain accessible. Do not uninstall DebianRunner or delete an environment just to troubleshoot a problem. See [Troubleshooting](TROUBLESHOOTING.md).

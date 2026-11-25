# Building DebianRunner

DebianRunner builds the `LinuxRunner` scheme in `iSH.xcodeproj` with display name **DebianRunner** and bundle identifier `dev.debianrunner.app` for headless Debian minimal ARM64 on iOS/iPadOS.

## Build Free Unsigned IPA on GitHub Actions (No Mac Required)

You do not need a Mac to build an installable unsigned `.ipa`:

1. Open **Actions → Build DebianRunner IPA** in [erayarslan/DebianRunner](https://github.com/erayarslan/DebianRunner/actions).
2. Trigger **Run workflow** manually (or push commits to `main`, or push a `v*` tag to publish a GitHub Release automatically).
   - `diagnostic` (`false` by default): set to `true` for `--diagnostic` builds.
   - `bundle_id` (`dev.debianrunner.app` by default): override the bundle identifier if desired.
3. Download the uploaded `DebianRunner-<run>` artifact containing `DebianRunner.ipa`, `DebianRunner.ipa.sha256`, and validation reports.
4. Sideload `DebianRunner.ipa` with AltStore, SideStore, Sideloadly, or TrollStore.

The workflow ([`.github/workflows/build-ipa.yml`](../.github/workflows/build-ipa.yml)) runs on GitHub's `macos-15` Apple Silicon runner, initializes `deps/libarchive`, installs `meson`, `ninja`, and `lld`, builds the unsigned IPA with `scripts/build-ipa.sh --unsigned`, and verifies it with `scripts/verify-ipa.py`.

## Local macOS Build Requirements

Use macOS with full Xcode and an iPhoneOS SDK, Git, Python 3, Meson, Ninja, `ld.lld` (`brew install meson ninja lld`), and system archive/signing tools on `PATH` (including `/opt/homebrew/opt/lld/bin` for Homebrew's keg-only `lld`).

```sh
git clone https://github.com/erayarslan/DebianRunner.git
cd DebianRunner
git submodule update --init --recursive --checkout -- deps/libarchive
scripts/bootstrap-macos.sh
```

The inherited `deps/linux` gitlink is optional and not used to boot a kernel in the app. No CMake, shader compilers, or external GPU dependencies are needed.

## Build Unsigned IPA Locally

```sh
scripts/build-ipa.sh --unsigned
python3 scripts/verify-ipa.py build/releases
```

## Packaging and Signing

Default output is `build/releases/DebianRunner.ipa` along with the `.xcarchive`, symbols, checksum, and validation reports. Set `RELEASE_DIR` and `ARTIFACT_NAME` to customize output destinations.

Unsigned mode applies an ad-hoc signature without Apple provisioning. For your own signing, configure an Apple team in Xcode and run `TEAM_ID=YOUR_TEAM_ID scripts/build-ipa.sh`. Never commit certificates, keys, or provisioning profiles. Optional App Group access uses `group.dev.debianrunner.app` with a private-container fallback.

`verify-ipa.py` verifies archive integrity, `DebianSupport.bundle/manifest.json` against `manifest.sha256`, `Support.bundle/support-manifest.json` resource hashes, source commit metadata, device Mach-O dependencies, and matching dSYM UUIDs.

## Host Runtime Build and Support Manifest Check

```sh
meson setup build/host -Dengine=asbestos -Dguest_arch=arm64
ninja -C build/host ish
python3 scripts/generate-support-manifest.py --check
```

To build a local minimal Debian ARM64 `fakefs` test image on Linux:

```sh
make debian-arm64-fakefs
```

[Architecture](ARCHITECTURE.md) · [Third-party notices](../THIRD_PARTY_NOTICES.md)

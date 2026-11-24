# Troubleshooting

Preserve your Debian environment first. Do not uninstall DebianRunner, delete its root filesystem, manually delete dpkg/APT locks, or disable package signatures as a first step. Back up important files before package repair or upgrades.

## Repair Center and APT Diagnostics

Open **Home → Packages → `⋯` → Repair Center & Advanced** (or **Debian → Packages (APT)**):

1. Run **Diagnose Package State** and **Check Dependencies** first.
2. Review the terminal output.
3. If an installation was interrupted, run **Configure Interrupted Debian Packages** (`dpkg --configure -a`), or **Check / Repair Package State**.

Repair executes Debian's native `dpkg`/`apt-get` tools and saves a `/var/lib/dpkg/status` metadata checkpoint inside `/var/lib/linuxrunner/repair-checkpoints/`. It is not a full filesystem snapshot.

## Debian Minimal Installation Fails or Stops

Keep DebianRunner in the foreground and check network access to `mirror.rabisu.com` / `ftp.linux.org.tr` / `deb.debian.org`, device date/time, and at least 1 GB of free storage. Verified `.deb` downloads are cached so **Try Again** resumes without re-downloading verified packages.

If **Restart DebianRunner** appears (for example when installing a second environment while another is running), swipe DebianRunner away in the app switcher and reopen it to resume setup.

## Package-Manager Lock Errors

Only one modifying `dpkg`/`apt` operation can run in an environment at a time. On first boot, `/usr/lib/linuxrunner/initialize-debian.sh` runs `dpkg --configure -a` and builds the CA trust store; managed package and mode installers automatically wait for it. Never delete `/var/lib/dpkg/lock*` while a package process is active.

## Terminal Does Not Start

Check the Home header status pill. Tap **Start Debian Minimal** if the runtime is stopped. If you want to start over cleanly, open the **Debian** tab and tap **Wipe Debian Minimal…**.

Check the active user in **Settings → Linux Environment → Linux Users**, and verify with `id` and `pwd` inside the terminal.

## Built-in SSH Server

- Ensure Debian Minimal is running before connecting. Open **Home → SSH Server** to check status and expand **SSH Server Log**.
- Root login is disabled by default; create a regular user in **Settings → Linux Environment → Linux Users** (or toggle **Allow Root Login** in **SSH Server** and set a root password) and connect with `ssh -p 2222 <user>@<iPhone-IP>`.
- Verify both devices share the same Wi-Fi network and that DebianRunner has Local Network permission in iOS Settings.
- Enable **Keep Linux Running in Background** (in **SSH Server** or **Settings → General**) and allow **Always** location permission when prompted so iOS keeps SSH sessions active when you lock your iPhone or switch apps.

## Debian Minimal Data After Re-signing

DebianRunner stores data in its App Group container (`group.<bundle-id>`) when provisioned — which also enables mounting the full Linux rootfs in Apple **Files** — and falls back to its private Application Support directory otherwise. Changing bundle identifier or App Group entitlements changes which container iOS provides. Preserve the installed app and backups when changing signing settings.

## JIT Is Unavailable

JIT is optional. Keep using **Interpreter** if iOS does not permit executable memory. Enable **Settings → Advanced → Developer Mode** and inspect **Execution Engine / StikDebug → JIT Status**.

## Collect Logs and Report a Problem

- **Settings → Storage & Maintenance → Export Diagnostics** exports a redacted diagnostic bundle (runtime logs, crash reports, installer/package logs).
- **Home → Diagnostics** lists recorded guest application crashes.
- **Settings → Advanced → Developer Mode → Runtime Diagnostics** shows live runtime health and log filters.

Review exported bundles before sharing to verify no private paths, addresses, or credentials remain. Report issues with device, iOS version, app build, and steps to reproduce; use [SECURITY.md](../SECURITY.md) for security vulnerabilities.

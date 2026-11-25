# Compatibility

DebianRunner runs **Debian GNU/Linux 13 (trixie) minimal ARM64** in headless SSH mode (connecting via Termius or any SSH client). Compatibility depends on the package, device memory, iOS version, and syscall coverage.

## Devices and Environment

- **Target architecture**: ARM64 (iPhone and iPad, minimum iOS/iPadOS deployment target 15.0).
- **Distribution**: Debian GNU/Linux 13 (trixie) minimal ARM64 (`apt`, `dpkg`, `bash`).
- **Single Debian Minimal environment**: DebianRunner manages a single Debian Minimal environment in the **Debian** tab, where you can configure services or wipe and reinstall cleanly at any time.

## Workloads

| Workload | Scope |
| --- | --- |
| Shells & coreutils (`bash`, `sh`, `tmux`, `vim`, `nano`, `jq`, `ripgrep`) | Supported over the built-in OpenSSH server via Termius (`127.0.0.1:2222`) or LAN SSH. |
| Package management (`apt`, `apt-get`, `dpkg`) | Supported headlessly via **Packages** or directly over SSH. |
| Languages & runtimes (`python3`, `nodejs`, `npm`, `gcc`, `git`) | Supported under the ARM64 interpreter; compute-heavy builds are slower than native execution. |
| Built-in OpenSSH server & Termius handoff (`sshd` on port `2222`) | Installed and started by default; controlled via **Home → Termius & SSH** and **Debian → Termius & SSH**. |
| Apple Files rootfs mount | Full Linux `/` browsable in Apple **Files** via embedded `iSHFileProvider.appex` when signed with an App Group. |
| Embedded serial (`/dev/ttyBLE0-3`, `/dev/ttyMIDI0-3`) | Bluetooth LE serial and USB-MIDI serial adapters exposed under **Devices**. Direct USB serial chips (CH340/CP210x/FTDI) are not exposed by iOS. |
| Graphical desktop / GUI apps (X11, Wayland, GPU) | **Not supported.** Desktop and GPU components are removed in this headless build. |

## Execution Engine

DebianRunner executes ARM64 Linux binaries using the Asbestos threaded-gadget interpreter and requires no special entitlements or debugger attachment.

## Networking

Linux TCP, UDP, and unprivileged ICMP sockets map onto iOS host networking. Interface/route queries (`ip addr`, `ip link`, `ip route`) expose a read-only view of host interfaces. Raw packet capture, Wi-Fi monitor mode, kernel modules, and Bluetooth networking are unavailable.

[Limitations](KNOWN_LIMITATIONS.md) · [Troubleshooting](TROUBLESHOOTING.md) · [Performance](PERFORMANCE.md)

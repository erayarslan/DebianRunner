# Compatibility

DebianRunner runs **Debian GNU/Linux 13 (trixie) minimal ARM64** in headless terminal mode. Compatibility depends on the package, device memory, iOS version, and syscall coverage.

## Devices and Environment

- **Target architecture**: ARM64 (iPhone and iPad, minimum iOS/iPadOS deployment target 15.0).
- **Distribution**: Debian GNU/Linux 13 (trixie) minimal ARM64 (`apt`, `dpkg`, `bash`).
- **Multiple environments**: You can create multiple isolated Debian minimal environments under **Environments**. Only one environment runs per app launch; switch via **Use on Next Launch** and a full relaunch.

## Workloads

| Workload | Scope |
| --- | --- |
| Shells & coreutils (`bash`, `sh`, `tmux`, `vim`, `nano`, `jq`, `ripgrep`) | Supported in the native terminal and over SSH Mode. |
| Package management (`apt`, `apt-get`, `dpkg`) | Supported via **Packages** or directly in the terminal. |
| Languages & runtimes (`python3`, `nodejs`, `npm`, `gcc`, `git`) | Supported under the ARM64 interpreter; compute-heavy builds are slower than native execution. |
| Headless services (`Agent Mode`, `SSH Mode`, `Liftoff`, `Pocket Cloud`) | Opt-in via **Home → Modes** / **Settings → General → DebianRunner Modes**. |
| Embedded serial (`/dev/ttyBLE0-3`, `/dev/ttyMIDI0-3`) | Bluetooth LE serial and USB-MIDI serial adapters exposed under **Devices**. Direct USB serial chips (CH340/CP210x/FTDI) are not exposed by iOS. |
| Graphical desktop / GUI apps (X11, Wayland, GPU) | **Not supported.** Desktop and GPU components are removed in this headless build. |

## Execution Engine

The ARM64 interpreter is the default and requires no special entitlements. Optional JIT builds can translate hot blocks when iOS permits executable memory; otherwise execution stays on the interpreter.

## Networking

Linux TCP, UDP, and unprivileged ICMP sockets map onto iOS host networking. Interface/route queries (`ip addr`, `ip link`, `ip route`) expose a read-only view of host interfaces. Raw packet capture, Wi-Fi monitor mode, kernel modules, and Bluetooth networking are unavailable.

[Limitations](KNOWN_LIMITATIONS.md) · [Troubleshooting](TROUBLESHOOTING.md) · [Performance](PERFORMANCE.md)

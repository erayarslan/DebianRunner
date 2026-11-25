# How DebianRunner Works

DebianRunner hosts headless **Debian GNU/Linux 13 (trixie) minimal ARM64** userspace inside an iOS/iPadOS application. It combines ARM64 instruction interpretation with a Linux ABI compatibility layer. It does not boot a Linux kernel, use hardware virtualization, or include desktop/GUI stacks.

```text
Debian 13 (trixie) minimal ARM64 programs and APT packages
       │ ELF loading, guest address spaces
       ▼
ARM64 interpreter (Asbestos threaded gadgets)
       │
Linux syscall compatibility: processes, threads, signals, memory, files, PTYs, sockets
       │
iOS/iPadOS host APIs: storage (fakefs), SwiftUI manager & OpenSSH server, networking, BLE/MIDI serial
```

## Load and Execute ARM64 Programs

The ELF loader maps ARM64 Linux executables and shared libraries into guest address spaces, prepares process state, and transfers control to the runtime. The Asbestos interpreter decodes supported instructions into cached sequences of precompiled host routines (gadgets).

## Supply Linux Semantics

The compatibility layer handles files, memory mappings, pseudo-terminals, sockets, process/thread state, signals, synchronization, and guest `fork`/`clone`/`execve` behavior. These are userspace implementations mapped onto iOS/XNU platform operations rather than a guest Linux kernel.

Each Debian minimal environment has its own root filesystem and APT/dpkg database. `fakefs` combines real backing files with SQLite-held Linux ownership/mode metadata. First launch downloads official Debian packages verified against `DebianSupport.bundle/manifest.json` (`manifest.sha256` + Debian's signed `InRelease`), assembles them into a root archive with `libarchive`, and imports them into `fakefs`.

Guest processes live inside DebianRunner's iOS application lifecycle. The iOS sandbox remains the security boundary.

## Network Through the Host

Linux sockets use host platform networking. Interface, address, and route queries translate available iOS information into Linux-facing netlink and proc views. There is no separate Linux network namespace or unrestricted radio/raw-device access. [Networking](NETWORKING_AND_DISPLAYS.md)

## Implementation Map

- `asbestos/guest-arm64/`: ARM64 interpreter gadgets and instruction decoding.
- `emu/`, `kernel/`, `fs/`: execution state, Linux syscall compatibility, procfs, devfs, and `fakefs`.
- `app/LinuxRunner/`: SwiftUI/UIKit interface, Debian bootstrap (`DebianBootstrap.c`, `DebianInstaller.swift`), native runtime bridge (`RuntimeBridge.m`), `DebianSupport.bundle`, and `Support.bundle`.
- `tests/linuxrunner/`: runtime, syscall, ABI, filesystem, and Debian bootstrap tests.

[Limitations](KNOWN_LIMITATIONS.md) · [Security](../SECURITY.md)

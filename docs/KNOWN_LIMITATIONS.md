# Known Limitations

DebianRunner executes headless **Debian GNU/Linux 13 (trixie) minimal ARM64** userspace through its own runtime. It does not boot a Linux kernel, provide hardware virtualization, run x86 applications, or implement every Linux system call. Kernel modules, systemd-as-init workflows, and conventional Linux containers are unsupported.

- **Headless only:** Desktop environments, X11, Wayland, audio bridges, virtual GPU/Metal rendering, and external-display desktop output are removed.
- **Debian minimal only:** Only Debian GNU/Linux 13 (trixie) ARM64 is supported.
- **First-launch network:** Debian minimal packages are downloaded and verified on-device on first launch; an internet connection to Debian mirrors (`mirror.rabisu.com`, `ftp.linux.org.tr`, or `deb.debian.org`) is required once per fresh environment.
- **JIT:** Optional and restricted by iOS signing/OS policy. The ARM64 interpreter remains the default and fallback. Short-lived commands can be slower under JIT due to translation overhead.
- **Networking:** Host iOS socket compatibility, not unrestricted hardware/raw-packet access. Bluetooth networking, ARP table queries (`ip neigh`), and Wi-Fi monitor mode are unsupported.
- **USB & Serial:** iOS does not grant ordinary apps raw USB host access to CH340/CP210x/FTDI serial chips. Use Bluetooth LE serial (`/dev/ttyBLE0-3`), a USB-MIDI serial adapter (`/dev/ttyMIDI0-3`), or Wi-Fi.
- **Lifecycle:** iOS/iPadOS can suspend or terminate DebianRunner in the background unless background running is enabled, and app termination ends running Linux processes. Saved files persist.
- **Isolation:** Linux accounts and permissions are compatibility features inside the app; the iOS application sandbox remains the security boundary.

See [Compatibility](COMPATIBILITY.md) and [Troubleshooting](TROUBLESHOOTING.md).

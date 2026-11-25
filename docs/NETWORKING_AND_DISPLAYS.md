# Networking

DebianRunner translates Linux networking calls onto host iOS APIs. Inspect the native network status at **Settings → Linux Environment → Network** and compare over SSH:

```sh
ip addr
ip link
ip route
```

Routes reflect available host routing information, not a separate Linux network namespace. VPNs and iOS platform policy affect what is visible.

## Diagnostic Tools

| Tool / interface | Status |
| --- | --- |
| `ping` (ICMP datagram sockets) | Works. `IP_RETOPTS` is accepted and reply TTL is reported. |
| `tracepath`, `traceroute -U` | Works. `IP_RECVERR`/`MSG_ERRQUEUE` deliver ICMP errors through a companion unprivileged ICMP socket; `IP_MTU_DISCOVER` sets the DF bit. |
| `ip route`, `ip route get ADDR` | Works against the host routing table. |
| `ip addr`, `ip link` | Works (host interfaces). |
| `ip neigh` | **Not supported** (`Operation not supported`): iOS exposes no public API to read the ARP/neighbour table. |
| Localhost ports | iOS may refuse certain privileged localhost ports with `EPERM`; normal unprivileged ports behave as expected. |
| IPv6 error queue (`IPV6_RECVERR`) | Not implemented yet. |

Bluetooth networking, raw packet capture, Wi-Fi scanning/monitor mode, and host interface/route administration are unsupported.

## Built-in SSH Server

DebianRunner includes an OpenSSH server managed in **Home → SSH Server** (or **Debian → SSH Server** / **Settings → Linux Environment → SSH Server**):

- **SSH Server**: OpenSSH (`sshd`) listening on TCP port `2222` (`0.0.0.0:2222`), installed and started by default with TCP/SSH keepalives (`ClientAliveInterval=15`, `UsePAM=no`, `UseDNS=no`).
- **On-device & LAN access**: Connect locally to `127.0.0.1:2222` from Termius or any SSH client on the same iPhone/iPad, or use the device's Wi-Fi IP from another machine on the same network.
- Regular Linux users can log in with password or `~/.ssh/authorized_keys`; root login is off by default and can be toggled in **SSH Server**.

The SSH server is reachable locally on `127.0.0.1:2222` and on the same Wi-Fi network while DebianRunner is active or running with **Keep Linux Running in Background** enabled.

## Diagnose a Connection

Verify the device has network connectivity and that DebianRunner has Local Network permission in iOS Settings if using LAN modes. Inspect **Settings → Linux Environment → Network**, review any exported addresses before sharing screenshots, and see [Troubleshooting](TROUBLESHOOTING.md).

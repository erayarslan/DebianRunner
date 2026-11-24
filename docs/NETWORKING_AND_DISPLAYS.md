# Networking

DebianRunner translates Linux networking calls onto host iOS APIs. Inspect the native network status at **Settings → Linux Environment → Network** and compare from a Debian terminal:

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

## Headless Network Modes

Optional LAN services are managed in **Home → Modes** (or **Settings → General → DebianRunner Modes**):

- **SSH Mode**: OpenSSH server on TCP port `2222` (regular user login; root login disabled).
- **Liftoff**: HTTP server for `~/Sites` on TCP port `8080`.
- **Pocket Cloud**: WebDAV server for `~/Pocket Cloud` on TCP port `8081` with a freshly generated password per start.

Network modes are reachable on the same Wi-Fi network while DebianRunner is active or running in the background.

## Diagnose a Connection

Verify the device has network connectivity and that DebianRunner has Local Network permission in iOS Settings if using LAN modes. Inspect **Settings → Linux Environment → Network**, review any exported addresses before sharing screenshots, and see [Troubleshooting](TROUBLESHOOTING.md).

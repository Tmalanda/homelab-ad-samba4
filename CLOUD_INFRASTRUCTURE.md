# Cloud Infrastructure — GCP + WireGuard Site-to-Site Tunnel

Extends the homelab AD DC environment with a cloud-hosted Linux VM, connected
back to the on-prem network via a WireGuard VPN tunnel. This demonstrates a
common hybrid-infrastructure pattern: cloud compute resources reaching an
on-premises directory service securely over the internet.

## Overview

| | |
|---|---|
| **Cloud provider** | Google Cloud Platform (GCP), Always Free tier |
| **Cloud VM** | `gcp-lab-client` — Ubuntu 24.04 LTS, e2-micro, `us-central1` |
| **VPN** | WireGuard, site-to-site tunnel |
| **Tunnel subnet** | `10.10.10.0/24` |
| **On-prem endpoint** | `lab-server` (Samba4 AD DC), `192.168.64.2` |

## Architecture

```
┌────────────────────────────┐              ┌──────────────────────────────┐
│   GCP (us-central1)         │              │   Home network (NAT'd)       │
│                              │              │                               │
│   gcp-lab-client             │              │   lab-server (Samba4 AD DC)  │
│   Ubuntu 24.04, e2-micro     │◄────────────►│   192.168.64.2                │
│   Public IP: 34.123.74.135   │  WireGuard   │   Tunnel IP: 10.10.10.2      │
│   Tunnel IP: 10.10.10.1      │  UDP 51820   │                               │
│   (listens)                  │              │   (dials out — NAT'd, no     │
│                              │              │    public IP of its own)     │
└────────────────────────────┘              └──────────────────────────────┘
```

**Why this direction:** `lab-server` sits behind home router NAT with no public
IP, so it can't accept inbound connections from the internet. The GCP VM has a
stable public IP, so it acts as the WireGuard listener ("server" role), while
`lab-server` initiates the connection outward ("client" role) — the standard
pattern for connecting a NAT'd network to a cloud endpoint.

## Setup summary

1. Create GCP project, enable billing (required even for Always Free tier
   resources — see gotchas below)
2. Provision `e2-micro` VM in a free-tier-eligible region (`us-central1`,
   `us-west1`, or `us-east1`), Ubuntu 24.04 LTS, Standard persistent disk
3. Create a GCP firewall rule allowing inbound UDP/51820 (WireGuard's port)
4. Install WireGuard on both machines
5. Generate a keypair per machine; exchange **public** keys only
6. Write `/etc/wireguard/wg0.conf` on each side (GCP = server role with
   `ListenPort`; home = client role with `Endpoint` + `PersistentKeepalive`)
7. Bring up `wg-quick@wg0` on both sides; verify with `wg show`
8. Confirm tunnel connectivity (`ping` across `10.10.10.0/24`)
9. Confirm LAN reachability — GCP VM pinging `192.168.64.2` directly, proving
   the `AllowedIPs` routing is correctly forwarding home-LAN-bound traffic
   through the tunnel

## Verification (proof of working tunnel)

```
# From GCP VM:
$ ping -c 4 192.168.64.2
4 packets transmitted, 4 received, 0% packet loss
```

The GCP VM, with no direct route to a private home LAN, successfully reaches
the AD DC's actual LAN IP — not just the tunnel endpoint — confirming the
tunnel is correctly routing, not just connected point-to-point.

## Config reference (keys redacted)

**GCP VM (`/etc/wireguard/wg0.conf`) — server role:**
```ini
[Interface]
PrivateKey = <redacted>
Address = 10.10.10.1/24
ListenPort = 51820

[Peer]
PublicKey = <lab-server's public key>
AllowedIPs = 10.10.10.2/32, 192.168.64.0/24
```

**`lab-server` (`/etc/wireguard/wg0.conf`) — client role:**
```ini
[Interface]
PrivateKey = <redacted>
Address = 10.10.10.2/24

[Peer]
PublicKey = <GCP VM's public key>
Endpoint = <GCP VM public IP>:51820
AllowedIPs = 10.10.10.0/24
PersistentKeepalive = 25
```

Note the asymmetry: the GCP side's `AllowedIPs` includes the full home LAN
subnet (`192.168.64.0/24`) since it needs to route to the DC; the home side's
`AllowedIPs` only needs the tunnel subnet, since it isn't routing anywhere
else through this link yet. `PersistentKeepalive` is only needed on the NAT'd
side, to keep the router's NAT mapping alive for return traffic.

## Next steps

- [ ] Confirm DNS resolution from the GCP VM against `HOMELAB.LOCAL`
- [ ] Confirm Kerberos authentication from the GCP VM
- [ ] Domain-join the GCP VM to `HOMELAB.LOCAL`
- [ ] Restrict the GCP firewall rule's source range once a stable use case is
      defined (currently `0.0.0.0/0`, relying on WireGuard's own key-based
      auth rather than IP allowlisting)

See `TROUBLESHOOTING.md` for the diagnostic detail behind the issues hit
while building this phase.

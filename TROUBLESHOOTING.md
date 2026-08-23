# Troubleshooting Log

This document captures the non-trivial issues encountered while building the lab,
the diagnostic process used to isolate each one, and the fix. Included deliberately —
the diagnosis is the actual skill being demonstrated, not just the final config.

---

## 1. DNS resolution chain failure (multi-layer)

**Symptom:** `host homelab.local` and Kerberos SRV lookups failed, even after
Samba's own internal DNS server was confirmed healthy and provisioned correctly.

This turned out to be **four separate, stacked problems**, each masking the next.
Fixing one revealed the next layer down.

### 1a. Samba binding to the wrong interface (silent config typo)

A config typo (`interface` instead of the correct `interfaces` directive in
`smb.conf`) was being **silently ignored** by Samba rather than raising an error.
Running `testparm` (Samba's config validator) surfaced the mistake immediately.

**Lesson:** never assume a config file is correct because the service started
without error. Silent parameter failures are a common Samba/`smb.conf` trap —
`testparm` should be a standard step after any `smb.conf` change.

### 1b. System resolver ignoring Samba's DNS (DHCP override)

Even after confirming (via `dig @192.168.64.2`) that Samba's own DNS was answering
queries correctly, the system's `host` / `resolvectl` commands were still failing.

**Diagnosis:** `resolvectl status` showed the network interface was still using
`192.168.64.1` (the DHCP-supplied gateway) as its DNS server, overriding the
intended `127.0.0.1`. Netplan's default config (`dhcp4: true`, no `nameservers`
override) let DHCP's DNS setting win.

**Fix:** added an explicit `nameservers` block and `dhcp4-overrides.use-dns: false`
/ `dhcp6-overrides.use-dns: false` to the netplan config, forcing the interface to
use `127.0.0.1` regardless of what DHCP offers.

### 1c. `.local` domain colliding with mDNS (RFC 6762)

After fixing 1b, direct queries to `127.0.0.1` worked, but `host homelab.local`
*still* failed — with a distinct `REFUSED` response rather than a timeout.

**Diagnosis:** `dig` surfaced an explicit warning: `.local is reserved for
Multicast DNS`. `systemd-resolved` treats `.local` specially per RFC 6762 and
will not route queries for it to a standard unicast DNS server unless the
interface is explicitly marked authoritative for that domain via a **routing
domain**.

**Fix (temporary, to confirm the diagnosis):**
```bash
sudo resolvectl domain enp0s1 "~homelab.local"
```
**Fix (persistent):** added a `search: [homelab.local]` entry under the
interface's `nameservers` block in netplan. Netplan correctly translated this
into a routing domain (confirmed via the `~` prefix in `resolvectl status`
output), which persists across reboots — the manual `resolvectl domain` command
does not.

> This is a well-documented gotcha for Samba AD domains named `.local` —
> worth choosing a non-`.local` domain name (e.g. `.internal` or a real
> subdomain) in any environment beyond a quick lab.

### 1d. `/etc/hosts` shadowing the correct DNS answer

After 1a–1c were fixed, `homelab.local` resolved correctly, but
`lab-server.homelab.local` — the DC's own FQDN — resolved to `127.0.1.1`
instead of the correct `192.168.64.2`.

**Diagnosis:** Ubuntu's installer writes a default `/etc/hosts` entry
(`127.0.1.1 <hostname> <hostname>.local`-style) for local hostname resolution.
Because `nsswitch.conf` checks `files` (`/etc/hosts`) before `dns`, this static
entry silently shadowed Samba's correct AD DNS record — invisible from the DC
itself, but would have broken any *other* machine trying to resolve the DC by
its AD-registered FQDN.

**Fix:** trimmed the `/etc/hosts` entry to only map the short hostname, removing
the FQDN so DNS resolution for `lab-server.homelab.local` falls through to Samba.

---

## 2. `set -e` + `((var++))` silently killing a Bash script

**Symptom:** `bulk_create_users.sh` would process exactly one CSV row, then exit
with no error message — not a crash, just a clean early return to the shell prompt.

**Diagnosis:** the script uses `set -e` (exit immediately on any non-zero exit
status) combined with post-increment counters like `((created_count++))`. In Bash,
`(( expression ))` uses the *numeric result* of the expression as its exit status,
where `0` counts as "false"/failure. A post-increment **returns the value before
incrementing** — so the very first time a counter goes from `0` to `1`, the
expression evaluates to `0`, which Bash treats as a failed command. Under `set -e`,
that immediately terminates the script.

This is a well-known but easy-to-miss interaction between `set -e` and Bash
arithmetic — it doesn't repro with a debugger or a linter flag, only by noticing
the script always died right after the *first* successful counter increment.

**Fix:** replaced all `((var++))` increments with `var=$((var + 1))`, which
evaluates to the *assignment's* exit status (always `0`/success) rather than the
numeric result of the expression.

```bash
# Before (breaks under set -e on the first increment from 0):
((created_count++))

# After:
created_count=$((created_count + 1))
```

**Lesson:** `set -e` is valuable for catching real failures, but it has sharp
edges around arithmetic contexts and certain command substitutions. Any script
using `set -e` with counters should either avoid `((x++))` entirely or explicitly
neutralize it (`((x++)) || true`).

---

## 3. Password Settings Object (PSO) verification

Not a bug, but worth documenting as a validation step: after applying a
fine-grained password policy to the `IT-Admins` group, the policy was verified
by attempting to set an 8-character password on both a covered user (`jdoe`,
under the 12-character PSO) and an uncovered user (`mgarcia`, under the 7-character
domain default). Both were rejected, with `samba-tool`'s error message explicitly
stating the *different* minimum length in each case — confirming the PSO was
scoped correctly rather than accidentally applying domain-wide.

---

## 4. GCP cost estimator showing a non-zero price for free-tier resources

**Symptom:** an `e2-micro` VM correctly configured for the Always Free tier
(eligible region, correct machine type, Standard persistent disk under 30GB)
still showed a **non-zero "Monthly estimate"** ($6–11 depending on region/disk
choices at the time) on GCP's VM creation page.

**Diagnosis:** GCP's built-in cost estimator on the instance-creation page
calculates **raw list pricing** — it has no visibility into whether a given
account/project actually qualifies for Always Free tier credit (which depends
on account-wide usage: only one `e2-micro` instance per billing account, in an
eligible region, under 744 hours/month). The estimator is not free-tier-aware;
this is a widely-reported, known point of confusion, not a misconfiguration.

**Resolution:** verified against GCP's current published Always Free terms
(region list, instance-type limit, disk allotment) rather than trusting the
estimate widget, and proceeded — actual billing correctly applied the free
credit, unrelated to what the estimator displayed.

**Lesson:** a tool's default UI feedback isn't always authoritative — cross-check
against the source of truth (official docs) when a number doesn't match
expectations, rather than assuming the configuration is wrong.

## 5. GCP console silently resetting form selections mid-configuration

**Symptom:** machine type (`e2-micro`) and boot OS (Ubuntu 24.04) were each
selected correctly at one point during VM creation, but reverted to GCP's
defaults (`e2-medium`/similar, Debian) after navigating between other sections
of the same creation form (e.g., changing region, then coming back).

**Diagnosis:** confirmed only by checking `/etc/os-release` *after* the VM was
already created and running — output showed Debian ("trixie"), not the Ubuntu
24.04 that had been selected earlier in the same session.

**Fix:** deleted and recreated the VM, this time setting OS/storage and machine
type as late as possible in the form, and re-verifying each setting immediately
before clicking Create rather than trusting the sidebar summary text.

**Lesson:** don't trust a multi-step form's summary/breadcrumb display as proof
a setting is still applied — verify the actual running resource after creation
(`/etc/os-release`, `wg show`, etc.) rather than the configuration UI.

## 6. Minimal cloud VM image missing basic CLI tools

**Symptom:** `nano: command not found` and `ping: command not found` on the
freshly created GCP VM, despite both being available by default on the
homelab's Ubuntu Server 24.04 install.

**Diagnosis:** GCP's Ubuntu cloud image is a minimal base image, optimized for
small size and fast boot — it omits several packages that a full Ubuntu Server
ISO install includes by default.

**Fix:** installed as needed (`sudo apt install nano -y`,
`sudo apt install iputils-ping -y`).

**Lesson:** "same OS version" doesn't guarantee "same installed packages" —
cloud provider base images and self-installed ISOs diverge in what ships by
default. Worth checking a new image's installed package set early rather than
assuming parity with a previously built system.

## 7. WireGuard handshake silently failing due to system clock drift

**Symptom:** `wg-quick@wg0` started with no errors on both machines, and both
sides showed the interface as "up" with a correctly configured peer — but
`wg show` on the initiating side (`lab-server`) showed `0 B received` and no
`latest handshake` line, meaning packets were being sent but no response was
coming back.

**Diagnosis:** `date` on `lab-server` showed the system clock had drifted
significantly (this VM had already had one clock-drift incident earlier in the
project, from `apt`'s repository-validity check — see the original DNS/apt
troubleshooting history). WireGuard's handshake protocol includes timestamps as
part of its anti-replay protection (based on Noise Protocol Framework); a
sufficiently incorrect system clock can cause the responding peer to silently
reject the handshake without any explicit error message on either side.

**Fix:**
```bash
sudo timedatectl set-ntp off
sudo timedatectl set-ntp on
```
This forced a fresh NTP resync. Immediately after, `wg show` showed a
successful, recent handshake with real bidirectional transfer on both sides.

**Lesson:** cryptographic protocols with timestamp-based replay protection
(WireGuard, Kerberos, TLS with strict clock checks, etc.) can fail in ways that
look identical to a networking or config problem — no explicit "clock is wrong"
error is guaranteed. When a supposedly-correct config silently fails to
complete a handshake, checking system time on both ends is a fast, cheap step
worth doing early rather than after exhausting config/firewall theories. This
VM in particular has now hit clock drift twice in this project — likely tied
to how UTM/QEMU handles guest clock sync across suspend/resume or extended
idle periods, worth a permanent NTP hardening step in a future revision (e.g.
`systemd-timesyncd` polling interval tuning).

## 8. Private key exposure via chat/log paste (secure-handling process note)

**Symptom:** not a technical fault — a WireGuard private key was pasted into
a chat window while asking for help formatting the config file.

**Resolution:** treated the key as compromised on principle (a secret that has
left its intended boundary should be rotated, regardless of who saw it or how
low the practical risk seems) — regenerated a fresh keypair for that machine
and rebuilt the config with the new key, rather than continuing to use the
exposed one.

**Process change:** for all subsequent key handling, viewed private keys only
directly in the terminal that generated them (`sudo cat ... privatekey`) and
copied them using the terminal's own clipboard integration into the config
file editor, without the key value passing through any external channel
(chat, notes app, etc.) at any point.

**Lesson:** the fix for an exposed secret is rotation, not just "being more
careful next time" — treating exposure as a rotation trigger, consistently, is
a better habit than trying to judge case-by-case how exposed is "exposed
enough" to matter.

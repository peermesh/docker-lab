# Host Hardening Runbook

This runbook covers host-level hardening steps that are outside compose-only changes.

## Scope

- SSH effective-state hardening and recovery-safe apply procedure
- UFW baseline for inbound traffic control
- host detection baseline for FIM, SSH session alerting, and egress monitoring
- verification commands for audit evidence
- rollback commands

## Preconditions

- host access with `sudo`
- PeerMesh services are deployed and healthy
- SSH access must remain available during changes
- keep the current SSH session open and open a second verified SSH session before reloading `sshd`

## Recommended Baseline

Allow only required inbound ports:

- `22/tcp` (SSH)
- `80/tcp` (HTTP challenge + redirect)
- `443/tcp` (HTTPS)
- optional `8448/tcp` only when Matrix federation is required

## Recommended Detection Baseline

Production Core hosts should pair prevention controls with lightweight detection:

- Configure AIDE file integrity monitoring and run the planted-file drill in [`FIM-AIDE-RUNBOOK.md`](FIM-AIDE-RUNBOOK.md).
- Configure SSH session-open alerting, a never-fire successful password-auth alert, and an ISO-safe daily summary in [`SSH-SESSION-ALERTING-RUNBOOK.md`](SSH-SESSION-ALERTING-RUNBOOK.md).
- Treat DOCKER-USER drop rules as prevention, then add egress visibility through baseline diffing or drop logging as described in [`EGRESS-MONITORING-RUNBOOK.md`](EGRESS-MONITORING-RUNBOOK.md).

## Canonical SSH Hardening

Core hosts use recovery-safe key-only SSH and disable forwarding primitives at the source. Egress DROP rules are compensating controls only; they reduce blast radius if a key is compromised, but they are not a substitute for `AllowTcpForwarding no`, `AllowAgentForwarding no`, and `X11Forwarding no`.

Console recovery remains the canonical SSH lockout path. If a reload breaks access, follow [`CONSOLE-RECOVERY-RUNBOOK.md`](CONSOLE-RECOVERY-RUNBOOK.md); do not enable password authentication as a shortcut.

Apply the SSH baseline as a drop-in and validate the effective state:

```bash
sudo install -d -m 0755 /etc/ssh/sshd_config.d
sudo tee /etc/ssh/sshd_config.d/99-hardening.conf >/dev/null <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
AllowTcpForwarding no
AllowAgentForwarding no
X11Forwarding no
PubkeyAuthentication yes
AuthenticationMethods publickey
PermitEmptyPasswords no
PermitTunnel no
EOF

# Safe apply: keep the original SSH session and a second verified session open.
sudo sshd -t
sudo systemctl reload sshd 2>/dev/null || sudo systemctl reload ssh
sudo sshd -T | awk '/^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|allowtcpforwarding|allowagentforwarding|x11forwarding) /'
```

Required effective values:

- `permitrootlogin prohibit-password`
- `passwordauthentication no`
- `kbdinteractiveauthentication no`
- `allowtcpforwarding no`
- `allowagentforwarding no`
- `x11forwarding no`

## Docker Port Bindings

**MANDATORY:** Never bind Docker-managed application or admin services to `0.0.0.0`. On a Core host, Traefik is the only Docker-exposed process allowed on public interfaces. All other services must use `127.0.0.1:xxxx` bindings for host-local access only, or remain container-network-only and be published through Traefik with explicit middleware protections.

The 2026-03-18 to 2026-03-19 WordPress VPS compromise showed why this rule is absolute. That host exposed phpMyAdmin on `0.0.0.0:8083`, plus additional admin services on public ports, and those surfaces were scanned continuously within hours while the host was already in a weakened state.

Correct patterns:

- Bind host-local only services to loopback, not all interfaces:

```yaml
services:
  admin:
    ports:
      - "127.0.0.1:8083:8080"
```

- Prefer container-network-only services behind Traefik with explicit protections:

```yaml
services:
  admin:
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.admin.rule=Host(`admin.example.com`)"
      - "traefik.http.routers.admin.entrypoints=websecure"
      - "traefik.http.routers.admin.tls.certresolver=letsencrypt"
      - "traefik.http.routers.admin.middlewares=admin-auth@file,admin-allowlist@file,admin-ratelimit@file"
```

Detection command:

```bash
ss -tlnp | grep -v '127\.0\.0\.1\|\[::1\]'
```

Anything returned on ports other than `22`, `80`, or `443` is a finding and must be remediated before the host is considered hardened.

## DOCKER-USER And Egress Visibility

The DOCKER-USER chain is the canonical prevention layer for Docker-managed traffic because Docker can bypass UFW through its own iptables rules. DROP rules should not stay silent in production: choose either established-connection baseline diffing or rate-limited drop logging so unexpected outbound behavior becomes an operator-visible signal.

Follow [`EGRESS-MONITORING-RUNBOOK.md`](EGRESS-MONITORING-RUNBOOK.md) for the monitoring pattern and keep known-good destination exclusions narrow enough to avoid hiding new C2, spam relay, or data exfiltration paths.

## Plan Mode (No Changes)

```bash
cd sub-repos/core
./scripts/security/enforce-host-firewall.sh --plan
```

Optional with Matrix federation:

```bash
./scripts/security/enforce-host-firewall.sh --plan --allow-8448
```

## Apply Mode

```bash
cd sub-repos/core
sudo ./scripts/security/enforce-host-firewall.sh --apply --yes
```

Optional with Matrix federation:

```bash
sudo ./scripts/security/enforce-host-firewall.sh --apply --yes --allow-8448
```

## Verification

Run and capture outputs:

```bash
ufw status verbose
sshd -T | awk '/^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|allowtcpforwarding|allowagentforwarding|x11forwarding) /'
iptables -S INPUT
iptables -S DOCKER-USER
ss -tlnp
sudo aide --check
sudo journalctl -u ssh -u sshd --since "24 hours ago" | grep -E "Accepted |Failed password" || true
```

Expected baseline:

- UFW `Status: active`
- SSH effective state matches the canonical block above
- explicit allow rules for required ports only
- host no longer relies solely on Docker-managed rules
- FIM, SSH alerting, and egress monitoring evidence exists for production hosts

## Rollback

Emergency rollback:

```bash
sudo ufw --force disable
```

Then re-validate service reachability and SSH access.

## Notes

- This runbook intentionally separates host firewall operations from application deploy logic.
- Pair this with `scripts/security/validate-host-hardening.sh` for repeatable preflight checks.
- Recovery from SSH lockout must follow [`CONSOLE-RECOVERY-RUNBOOK.md`](CONSOLE-RECOVERY-RUNBOOK.md). Do not enable password authentication as a shortcut.
- Detection runbooks: [`FIM-AIDE-RUNBOOK.md`](FIM-AIDE-RUNBOOK.md), [`SSH-SESSION-ALERTING-RUNBOOK.md`](SSH-SESSION-ALERTING-RUNBOOK.md), and [`EGRESS-MONITORING-RUNBOOK.md`](EGRESS-MONITORING-RUNBOOK.md).
- Production backup posture must satisfy the offsite immutability mandate in [`../BACKUP-RESTORE.md#offsite-requirements`](../BACKUP-RESTORE.md#offsite-requirements).
- Follow-up WO: add a dedicated validator under `scripts/validation/` to parse `ss -tlnp` output and fail on unexpected public Docker bindings.

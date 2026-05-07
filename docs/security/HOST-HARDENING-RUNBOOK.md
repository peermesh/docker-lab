# Host Hardening Runbook

This runbook covers host-level hardening steps that are outside compose-only changes.

## Scope

- UFW baseline for inbound traffic control
- verification commands for audit evidence
- rollback commands

## Preconditions

- host access with `sudo`
- PeerMesh services are deployed and healthy
- SSH access must remain available during changes

## Recommended Baseline

Allow only required inbound ports:

- `22/tcp` (SSH)
- `80/tcp` (HTTP challenge + redirect)
- `443/tcp` (HTTPS)
- optional `8448/tcp` only when Matrix federation is required

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
iptables -S INPUT
iptables -S DOCKER-USER
ss -tlnp
```

Expected baseline:

- UFW `Status: active`
- explicit allow rules for required ports only
- host no longer relies solely on Docker-managed rules

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
- Production backup posture must satisfy the offsite immutability mandate in [`../BACKUP-RESTORE.md#offsite-requirements`](../BACKUP-RESTORE.md#offsite-requirements).
- Follow-up WO: add a dedicated validator under `scripts/validation/` to parse `ss -tlnp` output and fail on unexpected public Docker bindings.

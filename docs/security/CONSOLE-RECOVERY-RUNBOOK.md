# Console Recovery Runbook

Canonical VPS recovery procedure for SSH lockout and key-loss scenarios without weakening SSH authentication.

## Non-Negotiable Rules

- `PasswordAuthentication yes` is FORBIDDEN in every recovery scenario. There are no temporary exceptions.
- `PermitRootLogin prohibit-password` is the canonical setting. It preserves key-based root recovery while blocking password authentication.
- Do not use `PermitRootLogin no` on hosts where root key recovery may be required. Flat `no` creates the exact lockout trap that leads operators to reach for unsafe console edits.

## Why This Runbook Exists

The WordPress VPS compromise is the concrete proof that "temporary password auth" is not a safe category. On 2026-03-18 23:30:33 UTC, a noVNC recovery session changed `/etc/ssh/sshd_config` to `PermitRootLogin yes` and `PasswordAuthentication yes`; by 2026-03-19 03:24 UTC, the host was confirmed compromised with root access in under four hours.

## Approved Recovery Path

Use the VPS provider's rescue system, rescue ISO, or equivalent out-of-band console to repair the installed disk offline. Hetzner Rescue is one example; the procedure is provider-agnostic.

1. Boot the instance into the provider rescue environment or attach the system disk to a trusted helper VM.
2. Mount the root filesystem from the installed system.
3. Inspect and repair `/root/.ssh/authorized_keys` directly.
4. Inspect and repair `/etc/ssh/sshd_config` directly.
5. Ensure the effective target state is:
   - `PasswordAuthentication no`
   - `PermitRootLogin prohibit-password`
6. Unmount cleanly and reboot back into the normal system.
7. Verify SSH access using trusted keys before ending the recovery window.

## Canonical SSH Configuration

Required recovery-safe baseline:

```sshconfig
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
```

Rationale:

- `PermitRootLogin prohibit-password` allows root login with trusted keys during recovery while still blocking password brute-force.
- `PasswordAuthentication no` removes the entire internet-exposed password-auth attack surface.
- `PermitRootLogin no` is not the preferred baseline for this environment because it blocks valid key-based root recovery and pushes operators toward unsafe console workarounds.

## Offline Repair Procedure

### 1. Mount the Installed System

Identify and mount the root filesystem from the installed VPS image:

```bash
lsblk
mkdir -p /mnt/recovery
mount /dev/<root-partition> /mnt/recovery
```

If the host uses a separate boot partition or encrypted volumes, mount or unlock those as required by the provider's rescue workflow.

### 2. Restore Trusted Root Keys

Inspect the existing key file:

```bash
sed -n '1,120p' /mnt/recovery/root/.ssh/authorized_keys
```

If the trusted key is missing, add it directly:

```bash
mkdir -p /mnt/recovery/root/.ssh
chmod 700 /mnt/recovery/root/.ssh
printf '%s\n' 'ssh-ed25519 AAAA... trusted-recovery-key' >> /mnt/recovery/root/.ssh/authorized_keys
chmod 600 /mnt/recovery/root/.ssh/authorized_keys
```

### 3. Repair `sshd_config`

Edit the installed system file directly, not the rescue environment copy:

```bash
sed -n '1,200p' /mnt/recovery/etc/ssh/sshd_config
```

Set or correct these lines:

```sshconfig
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
```

Remove or override any conflicting includes that would re-enable password auth.

### 4. Reboot Into the Installed System

```bash
sync
umount -R /mnt/recovery
reboot
```

## Post-Recovery Verification Checklist

After the host is back on its normal boot path:

1. Confirm trusted key login succeeds.
2. Confirm password auth is still disabled at effective runtime:

```bash
sshd -T | grep -iE 'passwordauth|permitroot'
```

Required effective values:

- `passwordauthentication no`
- `permitrootlogin prohibit-password`

3. Inspect listening ports and confirm no emergency exposure was introduced during recovery:

```bash
ss -tlnp
```

4. Re-check the host hardening baseline in [`HOST-HARDENING-RUNBOOK.md`](HOST-HARDENING-RUNBOOK.md), especially the Docker port binding rule.

## Explicitly Forbidden Shortcuts

- Do not set `PasswordAuthentication yes`, even "just for five minutes."
- Do not set `PermitRootLogin yes`.
- Do not expose temporary admin services to public interfaces to work around SSH access loss.
- Do not declare recovery complete until the effective runtime values confirm password auth is disabled.

## Related Runbooks

- [`HOST-HARDENING-RUNBOOK.md`](HOST-HARDENING-RUNBOOK.md)
- [`../BACKUP-RESTORE.md#offsite-requirements`](../BACKUP-RESTORE.md#offsite-requirements)

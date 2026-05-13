# File Integrity Monitoring Runbook (AIDE)

This runbook defines the canonical PeerMesh Core file integrity monitoring baseline for commodity VPS hosts. It uses AIDE because it is lightweight, local-first, and good enough to detect the persistence paths used in common SSH/root compromises: cron drops, init/systemd persistence, SSH key tampering, account database drift, and sudo policy changes.

FIM is a detective control. It does not prevent host compromise, and it does not replace SSH hardening, backups, or egress controls.

## High-Value Watch List

The production watch list must cover these paths at minimum:

- `/etc/ssh/`
- `/etc/crontab`
- `/etc/cron.*`
- `/etc/systemd/system`
- `/etc/init.d`
- `/root/.ssh/authorized_keys`
- `/etc/passwd`
- `/etc/shadow`
- `/etc/sudoers`
- `/etc/sudoers.d`

Operators may add service-specific configuration paths, but the list above is the minimum Core host baseline.

## Install AIDE

```bash
sudo apt-get update
sudo apt-get install -y aide
```

Create a focused rules file:

```bash
sudo tee /etc/aide/aide.conf.d/99-peermesh-critical-paths >/dev/null <<'EOF'
/etc/ssh                    NORMAL
/etc/crontab                NORMAL
/etc/cron\.d                NORMAL
/etc/cron\.hourly           NORMAL
/etc/cron\.daily            NORMAL
/etc/cron\.weekly           NORMAL
/etc/cron\.monthly          NORMAL
/etc/systemd/system         NORMAL
/etc/init\.d                NORMAL
/root/\.ssh/authorized_keys NORMAL
/etc/passwd                 NORMAL
/etc/shadow                 NORMAL
/etc/sudoers                NORMAL
/etc/sudoers\.d             NORMAL
EOF
```

## Create The Baseline

Create the first database only after the host is hardened, the expected services are installed, and no unexplained changes are present.

```bash
sudo aideinit
sudo mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
sudo chmod 0600 /var/lib/aide/aide.db
```

Record the baseline timestamp in deployment evidence:

```bash
sudo stat /var/lib/aide/aide.db
```

## Daily Check

Install a daily check script that records the diff and sends it to the operator's notification sink when AIDE returns a non-zero status. The sink can be email, ntfy, a webhook, or any local alert wrapper.

```bash
sudo tee /usr/local/sbin/aide-daily-check.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
set -u

LOG=/var/log/aide-last-check.log
DIFF=/var/log/aide-last-diff.log
HOST=$(hostname -f 2>/dev/null || hostname)
NOTIFY_URL="<https-or-mail-wrapper-url>"

OUT=$(aide --check 2>&1)
RC=$?
printf '%s\n' "$OUT" > "$LOG"

if [ "$RC" -ne 0 ]; then
    printf '%s\n' "$OUT" | tail -120 > "$DIFF"
    logger -t peermesh-aide "AIDE reported changes or errors on $HOST; rc=$RC"

    # Replace this curl call with the site's notification wrapper if needed.
    if [ -n "$NOTIFY_URL" ] && [ "$NOTIFY_URL" != "<https-or-mail-wrapper-url>" ]; then
        curl -fsS -X POST --data-binary @"$DIFF" "$NOTIFY_URL" >/dev/null 2>&1 || true
    fi
fi

exit "$RC"
EOF
sudo chmod 0755 /usr/local/sbin/aide-daily-check.sh
```

Schedule it through cron:

```bash
sudo tee /etc/cron.daily/peermesh-aide-check >/dev/null <<'EOF'
#!/bin/sh
exec /usr/local/sbin/aide-daily-check.sh
EOF
sudo chmod 0755 /etc/cron.daily/peermesh-aide-check
```

## Planted-File Drill

Run this drill before declaring a high-value host production-ready and after changing the notification path. It proves that a new persistence-like file under a watched cron path is detected and surfaced.

```bash
TS=$(date -u +%Y%m%dT%H%M%SZ)
DRILL="/etc/cron.d/zz-peermesh-aide-drill-$TS"

# 1. Plant an inert marker in a watched path.
printf '# PeerMesh AIDE drill marker only\n' | sudo tee "$DRILL" >/dev/null
sudo chmod 0644 "$DRILL"

# 2. Run the check manually and confirm the alert reached the operator.
sudo /usr/local/sbin/aide-daily-check.sh || true
sudo tail -120 /var/log/aide-last-diff.log

# 3. Clean up the marker.
sudo rm -f "$DRILL"

# 4. Confirm cleanup. The drill marker should no longer appear.
sudo find /etc/cron.d -maxdepth 1 -name 'zz-peermesh-aide-drill-*' -print
```

Do not run `aide --update` blindly after the drill or after a burst of host changes. A blind update launders unreviewed drift into the trusted baseline. If AIDE reports changes, review every changed path, explain why it changed, remove drill artifacts, and only then run an explicit baseline refresh.

## Baseline Refresh After Approved Changes

Use this only when a reviewed, intentional host change modifies watched paths.

```bash
sudo aide --check
# Review the full report before continuing.

sudo aide --update
sudo mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
sudo chmod 0600 /var/lib/aide/aide.db
sudo stat /var/lib/aide/aide.db
```

If any changed file is unexplained, stop and treat the result as an incident until the change is understood.

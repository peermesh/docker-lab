# SSH Session Alerting Runbook

This runbook defines the lightweight PeerMesh Core pattern for successful SSH session visibility. Failed-auth throttling is not enough: a single successful SSH login from an unexpected source can be the compromise event.

Real-time session alerts are the primary signal. The daily summary is a secondary rollup and must not be treated as authoritative if real-time alerts are not working.

## Session-Open Alert With PAM

Create a generic notification configuration. Use a local mail wrapper, ntfy topic, webhook relay, or another operator-controlled sink.

```bash
sudo tee /etc/default/peermesh-security-alerts >/dev/null <<'EOF'
SECURITY_NOTIFY_URL="<https-or-mail-wrapper-url>"
EOF
sudo chmod 0600 /etc/default/peermesh-security-alerts
```

Create an optional known-source allowlist to reduce alert fatigue on stable admin IPs:

```bash
sudo install -d -m 0755 /etc/peermesh-security
sudo tee /etc/peermesh-security/known-ssh-sources.txt >/dev/null <<'EOF'
# One source IP or hostname per line. Example:
# 203.0.113.10
EOF
sudo chmod 0644 /etc/peermesh-security/known-ssh-sources.txt
```

Install the PAM hook script:

```bash
sudo tee /usr/local/sbin/ssh-login-notify.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
set -u

[ "${PAM_SERVICE:-}" = "sshd" ] || exit 0
[ "${PAM_TYPE:-}" = "open_session" ] || exit 0

[ -r /etc/default/peermesh-security-alerts ] && . /etc/default/peermesh-security-alerts
KNOWN=/etc/peermesh-security/known-ssh-sources.txt
HOST=$(hostname -f 2>/dev/null || hostname)
USER_NAME=${PAM_USER:-unknown}
RHOST=${PAM_RHOST:-unknown}

if [ "$RHOST" != "unknown" ] && grep -qxF "$RHOST" "$KNOWN" 2>/dev/null; then
    logger -t ssh-login-notify "known SSH session suppressed: user=$USER_NAME from=$RHOST"
    exit 0
fi

MSG="SSH session opened on $HOST: user=$USER_NAME from=$RHOST"
logger -t ssh-login-notify "$MSG"

if [ -n "${SECURITY_NOTIFY_URL:-}" ] && [ "$SECURITY_NOTIFY_URL" != "<https-or-mail-wrapper-url>" ]; then
    (curl -fsS -X POST --data "$MSG" "$SECURITY_NOTIFY_URL" >/dev/null 2>&1 || true) &
fi

exit 0
EOF
sudo chmod 0755 /usr/local/sbin/ssh-login-notify.sh
```

Append the hook to `/etc/pam.d/sshd`:

```bash
printf '%s\n' 'session optional pam_exec.so /usr/local/sbin/ssh-login-notify.sh' | sudo tee -a /etc/pam.d/sshd
```

Open a new SSH session from a non-allowlisted source and confirm that the alert fires before relying on it. Keep the current SSH session open while testing.

## Never-Fire Password Auth Alert

On a key-only Core host, successful password authentication should never occur. Alert on it separately from session-open notifications because it indicates configuration drift or active compromise.

For root-only detection:

```ini
# /etc/fail2ban/filter.d/sshd-root-password-success.conf
[Definition]
failregex = ^.*sshd\[\d+\]: Accepted password for root from <HOST>
ignoreregex =
```

For the stricter key-only host rule, alert on any successful password auth:

```ini
# /etc/fail2ban/filter.d/sshd-any-password-success.conf
[Definition]
failregex = ^.*sshd\[\d+\]: Accepted password for \S+ from <HOST>
ignoreregex =
```

Example notification-only checker:

```bash
sudo tee /usr/local/sbin/ssh-password-success-check.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
set -u

[ -r /etc/default/peermesh-security-alerts ] && . /etc/default/peermesh-security-alerts
HOST=$(hostname -f 2>/dev/null || hostname)
HITS=$(journalctl --since "5 minutes ago" -u ssh -u sshd 2>/dev/null | grep -E 'Accepted password for ' || true)

if [ -n "$HITS" ]; then
    MSG="NEVER-FIRE SSH password-auth event on $HOST:
$HITS"
    logger -t ssh-password-success "$MSG"
    if [ -n "${SECURITY_NOTIFY_URL:-}" ] && [ "$SECURITY_NOTIFY_URL" != "<https-or-mail-wrapper-url>" ]; then
        curl -fsS -X POST --data "$MSG" "$SECURITY_NOTIFY_URL" >/dev/null 2>&1 || true
    fi
fi
EOF
sudo chmod 0755 /usr/local/sbin/ssh-password-success-check.sh
```

Run it from cron or convert the fail2ban filters above into a notification-only action. The important property is that this alert should stay quiet forever on a correctly configured key-only host.

## ISO-Safe Daily Security Summary

Use `journalctl --since/--until` windows instead of grepping month names. Month-name filters such as `grep Apr` silently fail when logs use ISO-8601 timestamps like `2026-04-18T03:14:22+00:00`.

```bash
sudo tee /usr/local/sbin/security-daily-summary.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
set -u

[ -r /etc/default/peermesh-security-alerts ] && . /etc/default/peermesh-security-alerts
HOST=$(hostname -f 2>/dev/null || hostname)
DAY=$(date -u -d yesterday +%Y-%m-%d)
SINCE="$DAY 00:00:00 UTC"
UNTIL="$(date -u -d today +%Y-%m-%d) 00:00:00 UTC"

SSH_LOG=$(journalctl --since="$SINCE" --until="$UNTIL" -u ssh -u sshd 2>/dev/null || true)
SSH_OK=$(printf '%s\n' "$SSH_LOG" | grep -c 'Accepted ' || true)
SSH_PASSWORD_OK=$(printf '%s\n' "$SSH_LOG" | grep -c 'Accepted password ' || true)
SSH_FAIL=$(printf '%s\n' "$SSH_LOG" | grep -c 'Failed password' || true)
F2B_BANS=$(journalctl --since="$SINCE" --until="$UNTIL" -u fail2ban 2>/dev/null | grep -c 'Ban ' || true)
AIDE_LAST=$(stat -c '%y' /var/lib/aide/aide.db 2>/dev/null || printf 'missing')

BODY=$(cat <<SUMMARY
Daily security summary for $HOST
Window: $SINCE to $UNTIL
SSH accepted sessions: $SSH_OK
SSH accepted password events: $SSH_PASSWORD_OK
SSH failed passwords: $SSH_FAIL
fail2ban bans: $F2B_BANS
AIDE baseline mtime: $AIDE_LAST
SUMMARY
)

logger -t peermesh-security-summary "$BODY"
if [ -n "${SECURITY_NOTIFY_URL:-}" ] && [ "$SECURITY_NOTIFY_URL" != "<https-or-mail-wrapper-url>" ]; then
    curl -fsS -X POST --data "$BODY" "$SECURITY_NOTIFY_URL" >/dev/null 2>&1 || true
fi
EOF
sudo chmod 0755 /usr/local/sbin/security-daily-summary.sh
```

Schedule it after log rotation has settled:

```bash
sudo tee /etc/cron.daily/peermesh-security-summary >/dev/null <<'EOF'
#!/bin/sh
exec /usr/local/sbin/security-daily-summary.sh
EOF
sudo chmod 0755 /etc/cron.daily/peermesh-security-summary
```

Silent date-filter bugs are dangerous because the summary still appears to run while reporting false zeros. Periodically compare the summary count against a manual `journalctl --since ... --until ...` query, especially after OS, rsyslog, or journald changes.

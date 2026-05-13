# Unexpected Egress Monitoring Runbook

DOCKER-USER drop rules are a prevention layer. They reduce blast radius when a container or SSH session tries to reach blocked destinations, but they are silent unless the host also records or alerts on unexpected outbound behavior.

Use one lightweight visibility pattern on production Core hosts:

- baseline-diff established outbound connections with `ss -tanp`
- log rate-limited egress drops from iptables or nftables

Either pattern needs known-good exclusions. Alerting on every expected Let's Encrypt, package mirror, mail relay, or application API connection creates fatigue and makes the channel useless.

## Pattern A: Established Egress Baseline Diff

This pattern samples established TCP sessions and alerts when a new tuple appears outside the known-good set. It is suitable for small VPS hosts where a short baseline is understandable by a human operator.

Create state and allowlist paths:

```bash
sudo install -d -m 0755 /var/lib/peermesh-security /etc/peermesh-security
sudo touch /etc/peermesh-security/egress-known-good.txt
sudo chmod 0644 /etc/peermesh-security/egress-known-good.txt
```

Known-good entries are fixed strings matched against sampled rows. Keep them specific enough to suppress stable destinations without hiding whole classes of traffic:

```text
# /etc/peermesh-security/egress-known-good.txt examples
# 185.230.212.129:587
# letsencrypt
# api.stripe.com:443
```

Install the watcher:

```bash
sudo tee /usr/local/sbin/egress-baseline-check.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
set -u

[ -r /etc/default/peermesh-security-alerts ] && . /etc/default/peermesh-security-alerts
STATE_DIR=/var/lib/peermesh-security
BASELINE=$STATE_DIR/egress-established.baseline
CURRENT=$STATE_DIR/egress-established.current
NEW=$STATE_DIR/egress-established.new
KNOWN=/etc/peermesh-security/egress-known-good.txt
HOST=$(hostname -f 2>/dev/null || hostname)

ss -Htanp state established 2>/dev/null \
  | awk '{print $4 " -> " $5 " " $NF}' \
  | sed -E 's/pid=[0-9]+/pid=*/g; s/fd=[0-9]+/fd=*/g' \
  | sort -u > "$CURRENT"

if [ ! -s "$BASELINE" ]; then
    cp "$CURRENT" "$BASELINE"
    logger -t peermesh-egress "created initial egress baseline at $BASELINE"
    exit 0
fi

comm -13 "$BASELINE" "$CURRENT" | grep -v -F -f "$KNOWN" > "$NEW" || true

if [ -s "$NEW" ]; then
    MSG="Unexpected established egress on $HOST:
$(cat "$NEW")"
    logger -t peermesh-egress "$MSG"
    if [ -n "${SECURITY_NOTIFY_URL:-}" ] && [ "$SECURITY_NOTIFY_URL" != "<https-or-mail-wrapper-url>" ]; then
        curl -fsS -X POST --data "$MSG" "$SECURITY_NOTIFY_URL" >/dev/null 2>&1 || true
    fi
fi
EOF
sudo chmod 0755 /usr/local/sbin/egress-baseline-check.sh
```

Run once during a clean period to create the baseline, then schedule it:

```bash
sudo /usr/local/sbin/egress-baseline-check.sh

sudo tee /etc/cron.d/peermesh-egress-baseline >/dev/null <<'EOF'
*/5 * * * * root /usr/local/sbin/egress-baseline-check.sh
EOF
```

When a new tuple is legitimate, add a narrow known-good exclusion and refresh the baseline only after review:

```bash
sudo /usr/local/sbin/egress-baseline-check.sh
sudo cp /var/lib/peermesh-security/egress-established.current /var/lib/peermesh-security/egress-established.baseline
```

Do not normalize the baseline during an incident or after unexplained traffic. First identify the process, container, destination, and reason.

## Pattern B: Rate-Limited Egress Drop Logging

This pattern logs blocked egress attempts immediately before the DROP rule. Use rate limits so one noisy source cannot flood kernel logs.

iptables example:

```bash
# Example for known high-risk relay/C2 ports. Put LOG immediately before DROP.
sudo iptables -I DOCKER-USER 1 -p tcp -m multiport --dports 25,465,587,2525,1525 \
  -m limit --limit 6/min --limit-burst 12 \
  -j LOG --log-prefix "PMDL-EGRESS-DROP " --log-level 4

sudo iptables -A DOCKER-USER -p tcp -m multiport --dports 25,465,587,2525,1525 -j DROP
```

nftables equivalent:

```bash
sudo nft add rule inet filter forward tcp dport {25,465,587,2525,1525} \
  limit rate 6/minute burst 12 packets log prefix \"PMDL-EGRESS-DROP \" drop
```

Review drop activity with an ISO-safe journal window:

```bash
sudo journalctl -k --since "1 hour ago" --grep "PMDL-EGRESS-DROP"
```

If drop logging is the chosen pattern, wire that query into the same notification sink as the SSH and AIDE checks. Exclude known-good destinations with explicit ACCEPT rules before the LOG/DROP pair; do not suppress by broad destination ports unless the operational reason is documented.

## Verification

Before production sign-off, capture:

```bash
sudo iptables -S DOCKER-USER
sudo /usr/local/sbin/egress-baseline-check.sh
sudo journalctl -k --since "1 hour ago" --grep "PMDL-EGRESS-DROP" || true
```

Evidence should show both the prevention layer (`DOCKER-USER` policy) and the chosen visibility layer (baseline watcher or drop logging).

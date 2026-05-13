#!/usr/bin/env bash
# ==============================================================
# Host Hardening Validator
# ==============================================================
# Checks minimum host-level hardening signals for deployment:
# - effective sshd state disables password auth and forwarding primitives
# - ufw active (when installed)
# - iptables INPUT policy not ACCEPT
# - DOCKER-USER chain has at least one rule beyond default return
#
# By default this script is advisory and returns 0.
# Use --strict to fail when hardening failures are detected.
# ==============================================================

set -euo pipefail

STRICT=false
FAILURES=0
WARNINGS=0
PASSES=0

usage() {
    cat <<USAGE
Usage: $0 [OPTIONS]

Options:
  --strict      Exit non-zero when hardening failures are detected
  --help, -h    Show this help message
USAGE
}

log_pass() {
    PASSES=$((PASSES + 1))
    echo "[PASS] $1"
}

log_warn() {
    WARNINGS=$((WARNINGS + 1))
    echo "[WARN] $1"
}

log_fail() {
    FAILURES=$((FAILURES + 1))
    echo "[FAIL] $1"
}

find_sshd() {
    if command -v sshd >/dev/null 2>&1; then
        command -v sshd
        return 0
    fi

    for candidate in /usr/sbin/sshd /usr/local/sbin/sshd; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

get_sshd_setting() {
    local key="$1"
    awk -v key="$key" 'tolower($1) == key { print tolower($2); exit }'
}

check_sshd_setting() {
    local effective_config="$1"
    local key="$2"
    local expected="$3"
    local display_name="$4"
    local actual

    actual="$(printf '%s\n' "$effective_config" | get_sshd_setting "$key")"
    if [[ -z "$actual" ]]; then
        log_fail "SSH effective setting ${display_name} is missing (expected ${expected})"
    elif [[ "$actual" == "$expected" ]]; then
        log_pass "SSH effective setting ${display_name} is ${expected}"
    else
        log_fail "SSH effective setting ${display_name} is ${actual} (expected ${expected})"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --strict)
            STRICT=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "[ERROR] Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

echo "== Host Hardening Validation =="

sshd_bin="$(find_sshd || true)"
if [[ -z "$sshd_bin" ]]; then
    log_warn "sshd not available; skipping effective SSH hardening check"
elif ! effective_sshd_config="$("$sshd_bin" -T 2>/dev/null)"; then
    log_fail "Could not read effective SSH configuration with ${sshd_bin} -T"
else
    check_sshd_setting "$effective_sshd_config" "permitrootlogin" "prohibit-password" "PermitRootLogin"
    check_sshd_setting "$effective_sshd_config" "passwordauthentication" "no" "PasswordAuthentication"
    check_sshd_setting "$effective_sshd_config" "kbdinteractiveauthentication" "no" "KbdInteractiveAuthentication"
    check_sshd_setting "$effective_sshd_config" "allowtcpforwarding" "no" "AllowTcpForwarding"
    check_sshd_setting "$effective_sshd_config" "allowagentforwarding" "no" "AllowAgentForwarding"
    check_sshd_setting "$effective_sshd_config" "x11forwarding" "no" "X11Forwarding"
fi

if command -v ufw >/dev/null 2>&1; then
    ufw_status="$(ufw status 2>/dev/null || true)"
    if printf '%s' "$ufw_status" | grep -qi "Status: active"; then
        log_pass "UFW is active"
    else
        log_fail "UFW is installed but not active"
    fi
else
    log_warn "UFW not installed; skipping UFW status check"
fi

if command -v iptables >/dev/null 2>&1; then
    input_policy="$(iptables -S INPUT 2>/dev/null | awk '/^-P INPUT / {print $3; exit}' || true)"
    if [[ -z "$input_policy" ]]; then
        log_warn "Could not read iptables INPUT policy"
    elif [[ "$input_policy" == "ACCEPT" ]]; then
        log_fail "iptables INPUT policy is ACCEPT"
    else
        log_pass "iptables INPUT policy is $input_policy"
    fi

    docker_user_rules="$(iptables -S DOCKER-USER 2>/dev/null || true)"
    if [[ -z "$docker_user_rules" ]]; then
        log_warn "DOCKER-USER chain is missing or inaccessible"
    else
        # Count non-default rules; default return-only chain is weak baseline.
        non_default_rule_count="$(printf '%s\n' "$docker_user_rules" | awk '
            /^-A DOCKER-USER / {
                if ($0 !~ /-j RETURN$/) count++
            }
            END { print count + 0 }
        ')"
        if [[ "$non_default_rule_count" -gt 0 ]]; then
            log_pass "DOCKER-USER has $non_default_rule_count custom rule(s)"
        else
            log_fail "DOCKER-USER has no custom rules beyond default RETURN"
        fi
    fi
else
    log_warn "iptables not available; skipping firewall chain checks"
fi

echo ""
echo "Host hardening summary: FAILURES=${FAILURES} WARNINGS=${WARNINGS} PASSES=${PASSES} STRICT=${STRICT}"

if [[ "$STRICT" == true && "$FAILURES" -gt 0 ]]; then
    exit 1
fi

exit 0

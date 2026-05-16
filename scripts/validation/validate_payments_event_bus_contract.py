#!/usr/bin/env python3
"""Validate the Core Payments event bus contract and simulate fanout delivery."""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict, deque
from pathlib import Path
from typing import Any

EVENT_PATTERN = re.compile(r"^[a-z0-9-]+(\.[a-z0-9-]+){2,}$")
PAYMENTS_PREFIX = "pm-module-payments."
DLQ_PREFIX = "pm-module-payments.dlq."

EXPECTED_PAYMENT_EVENTS = {
    "pm-module-payments.entity-profile.created",
    "pm-module-payments.entity-profile.updated",
    "pm-module-payments.routing-rule.updated",
    "pm-module-payments.payee.kyc.submitted",
    "pm-module-payments.payee.kyc.approved",
    "pm-module-payments.payee.kyc.rejected",
    "pm-module-payments.payee.kyc.pending",
    "pm-module-payments.payment.intake.created",
    "pm-module-payments.payment.intake.succeeded",
    "pm-module-payments.payment.intake.failed",
    "pm-module-payments.payment.intake.refunded",
    "pm-module-payments.payout.scheduled",
    "pm-module-payments.payout.sent",
    "pm-module-payments.payout.failed",
    "pm-module-payments.refund.issued",
    "pm-module-payments.dispute.opened",
    "pm-module-payments.dispute.evidence-required",
    "pm-module-payments.dispute.resolved",
    "pm-module-payments.recurring.sponsorship.renewed",
    "pm-module-payments.recurring.sponsorship.cancelled",
    "pm-module-payments.fee.allocated",
    "pm-module-payments.crypto.received",
    "pm-module-payments.crypto.converted",
    "pm-module-payments.crypto.quarantined",
    "pm-module-payments.tamper.detected",
    "pm-module-payments.audit.entry-written",
}

COMPLIANCE_CRITICAL_EVENTS = {
    "pm-module-payments.payment.intake.succeeded",
    "pm-module-payments.payout.sent",
    "pm-module-payments.payee.kyc.approved",
    "pm-module-payments.payee.kyc.rejected",
    "pm-module-payments.dispute.opened",
    "pm-module-payments.dispute.resolved",
    "pm-module-payments.tamper.detected",
}

LEGACY_COMPAT_EVENTS = {
    "pm-module-payments.payee.kyc-submitted",
    "pm-module-payments.payee.kyc-approved",
    "pm-module-payments.payee.kyc-rejected",
    "pm-module-payments.payment.intake-created",
    "pm-module-payments.payment.intake-succeeded",
    "pm-module-payments.payment.intake-failed",
}


def core_root() -> Path:
    return Path(__file__).resolve().parent.parent.parent


def load_registry(core: Path) -> dict[str, Any]:
    return json.loads((core / "foundation/events/payments-events.json").read_text(encoding="utf-8"))


def load_schema_pattern(core: Path, schema_rel: str, pointer: list[str]) -> str:
    data: Any = json.loads((core / schema_rel).read_text(encoding="utf-8"))
    for key in pointer:
        data = data[key]
    if not isinstance(data, str):
        raise TypeError(f"{schema_rel}:{'.'.join(pointer)} is not a string")
    return data


def validate_registry(data: dict[str, Any], core: Path) -> list[str]:
    errors: list[str] = []

    if data.get("source") != "pm-module-payments":
        errors.append("source must be pm-module-payments")

    backend = data.get("backend") or {}
    preferred = backend.get("preferredConnection") or {}
    if preferred.get("type") != "eventbus" or preferred.get("provider") != "redis":
        errors.append("backend.preferredConnection must be eventbus redis")
    if backend.get("mode") != "streams":
        errors.append("backend.mode must be streams for durable fanout")
    if backend.get("persistence") != "aof-required":
        errors.append("backend.persistence must require AOF")

    defaults = data.get("defaults") or {}
    if defaults.get("idempotencyKey") != "eventId":
        errors.append("defaults.idempotencyKey must be eventId")
    if defaults.get("ackMode") != "manual":
        errors.append("defaults.ackMode must be manual")
    if not isinstance(defaults.get("maxDeliveryAttempts"), int) or defaults["maxDeliveryAttempts"] < 1:
        errors.append("defaults.maxDeliveryAttempts must be a positive integer")

    events = data.get("events")
    if not isinstance(events, list):
        return errors + ["events must be an array"]

    seen: set[str] = set()
    registered: set[str] = set()
    for index, event in enumerate(events):
        if not isinstance(event, dict):
            errors.append(f"events[{index}] must be an object")
            continue
        event_type = event.get("type")
        if not isinstance(event_type, str):
            errors.append(f"events[{index}].type must be a string")
            continue
        if event_type in seen:
            errors.append(f"duplicate event type: {event_type}")
        seen.add(event_type)
        registered.add(event_type)
        if not event_type.startswith(PAYMENTS_PREFIX):
            errors.append(f"{event_type}: must be in the pm-module-payments namespace")
        if not EVENT_PATTERN.fullmatch(event_type):
            errors.append(f"{event_type}: must match multi-segment event topic pattern")
        if event_type in LEGACY_COMPAT_EVENTS:
            errors.append(f"{event_type}: legacy compatibility event must not be in Core canonical registry")

        delivery_tier = event.get("deliveryTier")
        delivery_guarantee = event.get("deliveryGuarantee")
        if event_type in COMPLIANCE_CRITICAL_EVENTS:
            if delivery_tier != "compliance-critical":
                errors.append(f"{event_type}: must be compliance-critical")
            if delivery_guarantee != "at-least-once":
                errors.append(f"{event_type}: must require at-least-once delivery")
            if event.get("requiresAck") is not True:
                errors.append(f"{event_type}: must require consumer ack")
            dlq = event.get("deadLetterTopic")
            if not isinstance(dlq, str) or not dlq.startswith(DLQ_PREFIX):
                errors.append(f"{event_type}: must declare a Payments DLQ topic")
            elif not EVENT_PATTERN.fullmatch(dlq):
                errors.append(f"{event_type}: deadLetterTopic must be a valid topic")
        elif delivery_tier == "compliance-critical":
            errors.append(f"{event_type}: unexpected compliance-critical classification")

    missing = sorted(EXPECTED_PAYMENT_EVENTS - registered)
    extra = sorted(registered - EXPECTED_PAYMENT_EVENTS)
    if missing:
        errors.append("missing canonical Payments events: " + ", ".join(missing))
    if extra:
        errors.append("unexpected Payments events: " + ", ".join(extra))

    event_schema_pattern = load_schema_pattern(core, "foundation/schemas/event.schema.json", ["properties", "type", "pattern"])
    module_schema_pattern = load_schema_pattern(
        core,
        "foundation/schemas/module.schema.json",
        ["properties", "provides", "properties", "events", "items", "pattern"],
    )
    for pattern_name, pattern in (("event.schema.json", event_schema_pattern), ("module.schema.json", module_schema_pattern)):
        compiled = re.compile(pattern)
        if not compiled.fullmatch("pm-module-payments.payment.intake.succeeded"):
            errors.append(f"{pattern_name}: does not accept canonical four-segment Payments event topics")

    return errors


def simulate_delivery(data: dict[str, Any]) -> dict[str, Any]:
    max_attempts = int(data["defaults"]["maxDeliveryAttempts"])
    event_type = "pm-module-payments.payment.intake.succeeded"
    event = next(e for e in data["events"] if e["type"] == event_type)
    message = {
        "id": "550e8400-e29b-41d4-a716-446655440000",
        "eventId": "evt_payment_intake_succeeded_1",
        "type": event_type,
        "deliveryGuarantee": event["deliveryGuarantee"],
    }

    consumer_queues: dict[str, deque[dict[str, Any]]] = {
        "email-payments": deque([message.copy()]),
        "groups-payments": deque([message.copy()]),
    }
    acked: dict[str, list[str]] = defaultdict(list)
    dlq: dict[str, list[dict[str, Any]]] = defaultdict(list)

    for group, queue in consumer_queues.items():
        attempts = 0
        while queue:
            current = queue.popleft()
            attempts += 1
            if group == "groups-payments" and attempts < max_attempts:
                queue.append(current)
                continue
            if group == "groups-payments":
                dead_letter = event["deadLetterTopic"]
                dlq[dead_letter].append(current)
                break
            acked[group].append(current["eventId"])

    return {
        "published": event_type,
        "acked": dict(acked),
        "deadLetters": {key: len(value) for key, value in dlq.items()},
        "multipleConsumerGroupsObserved": set(consumer_queues) == {"email-payments", "groups-payments"},
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulate", action="store_true", help="also run deterministic fanout/retry/DLQ simulation")
    args = parser.parse_args()

    core = core_root()
    data = load_registry(core)
    errors = validate_registry(data, core)
    if errors:
        print("[payments-event-bus-contract] validation failed", file=sys.stderr)
        for error in errors:
            print(error, file=sys.stderr)
        return 1

    print("[payments-event-bus-contract] ok: checked 26 canonical Payments events")
    if args.simulate:
        simulation = simulate_delivery(data)
        print(json.dumps(simulation, indent=2, sort_keys=True))
        if not simulation["multipleConsumerGroupsObserved"]:
            print("[payments-event-bus-contract] simulation failed: missing consumer groups", file=sys.stderr)
            return 1
        if simulation["acked"].get("email-payments") != ["evt_payment_intake_succeeded_1"]:
            print("[payments-event-bus-contract] simulation failed: email ack missing", file=sys.stderr)
            return 1
        expected_dlq = "pm-module-payments.dlq.payment.intake.succeeded"
        if simulation["deadLetters"].get(expected_dlq) != 1:
            print("[payments-event-bus-contract] simulation failed: DLQ route missing", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

# Module Authoring Guide

This guide is self-contained for the Core sub-repo and does not require parent-repo docs.

## Scope

Use this guide when creating or updating a Core module under `modules/<module-id>/`.

## Module baseline

Every module must include:

- `module.json` (identity, compatibility, lifecycle contract)
- `docker-compose.yml` (service definition and runtime labels)
- `hooks/` scripts (`install`, `start`, `stop`, `health`, optional `uninstall`)
- `.env.example` (documented module config)
- `secrets-required.txt` (file-based secret contract)

## Manifest schema reference

For modules authored directly under Core at `modules/<module-id>/module.json`,
use the template's relative `$schema` value:
`../../foundation/schemas/module.schema.json`.

For standalone module source repositories whose manifest lives at
`module/module.json`, use the published Core schema `$id`:
`https://peermesh.io/foundation/v1/module.schema.json`. Do not use the
Core-relative `../../foundation/schemas/module.schema.json` path from
`module/module.json`; it does not resolve to the Core schema authority in a
standalone repo.

## Lifecycle requirements

Module lifecycle hooks must be safe, idempotent, and script-portable:

- use POSIX shell compatible scripting
- fail fast on invalid prerequisites
- avoid non-deterministic side effects
- report health clearly for `module health`

## Runtime contract

Module runtime must:

- consume file-based secrets (no hardcoded credentials)
- use explicit env vars for config discovery
- avoid reliance on undocumented host paths
- avoid production dependency on `process.cwd()` fallback discovery

## Payment-capable modules

Modules that expose billing capabilities, accept provider webhooks, or publish
financial events must also follow the payment-capable lifecycle contract in
`foundation/docs/LIFECYCLE-HOOKS.md`.

At minimum:

- declare provider credentials in `config.properties` with `secret: true`
- list emitted billing events in `provides.events[]`
- advertise billing surfaces in `provides.capabilities[]`
- declare consumed billing topics in `requires.events[]`
- use durable consumer groups and idempotency keys for `at-least-once`
  financial event subscriptions

The Core Payments event bus registration lives at
`foundation/events/payments-events.json`.

## Validation workflow

Before merge:

1. `./launch_pm-core.sh module validate <module-id>`
2. `./launch_pm-core.sh module enable <module-id>`
3. `./launch_pm-core.sh module health <module-id>`
4. Confirm container status and logs

## Networking and routing

For web modules:

- attach to the expected Core proxy network
- define Traefik labels with explicit host rules
- keep domain behavior configurable via env vars

## Ownership boundary

- Core owns platform/runtime contract and orchestration behavior.
- Module owns feature semantics and module-specific behavior.

If a required behavior change affects shared runtime contract, update Core docs and tooling before adding module-only workarounds.

## Related docs (self-contained links)

- [DEPLOYMENT-REPO-PATTERN.md](DEPLOYMENT-REPO-PATTERN.md)
- [DEPLOYMENT-PROMOTION-RUNBOOK.md](DEPLOYMENT-PROMOTION-RUNBOOK.md)
- [WEBHOOK-DEPLOYMENT.md](WEBHOOK-DEPLOYMENT.md)
- [MULTI-ENVIRONMENT.md](MULTI-ENVIRONMENT.md)

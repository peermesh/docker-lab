# PeerMesh Core Authentik Isolated Staging Fixture

This directory contains a review-only synthetic Authentik provisioning artifact
for the isolated staging compose overlay:

- `/Users/grig/work/peermesh/repo/peermesh-core/sub-repos/core/docker-compose.authentik-staging.yml`
- compose project: `peermesh-authentik-staging-proof`
- Authentik service used for apply: `authentik-worker`

Do not run this artifact against production, shared staging, live Authentik, a
module router, DNS, Cloudflare, HSTS, GAS PA, GAS Explorer, or Model
Benchmarking. It must be reviewed before execution and must only be run inside
the isolated staging stack with synthetic credentials.

## Artifact

- `peermesh-core-f1-synthetic-blueprint.yaml` provisions only synthetic
  fixtures after applying the bundled Authentik default dependency blueprints
  it references:
  - `peermesh-admins`
  - `peermesh-users`
  - synthetic admin and non-admin users
  - one proxy-provider scope mapping for the five F2 headers
  - ordinary-route proxy provider `PeerMesh Core F1 ForwardAuth`
  - admin-route proxy provider `PeerMesh Core F1 Admin ForwardAuth`
  - application `PeerMesh Core`
  - application `PeerMesh Core Admin`
  - embedded outpost assignment
  - admin-host expression policy and admin application policy binding
- `apply-synthetic-blueprint.sh` records the guarded isolated-staging
  invocation. It copies the blueprint to Authentik's accepted `/blueprints`
  path, applies it, and activates the synthetic users' runtime-only passwords
  from environment variables without writing those passwords to the repository.
  It is not executed by this work order.

## Required Review Before Execution

Before execution, a reviewer must confirm:

- the running stack is the isolated staging compose project only;
- the Authentik image tag-plus-digest has been reviewed separately;
- no production secrets, production users, production groups, production
  domains, production Authentik objects, or live routers are in scope;
- the application policy bindings are valid for the pinned Authentik version and
  apply to the proxy providers' forward-auth decision paths,
  or the run must stop for a provider-binding review update.

## Invocation

Run only from:

`/Users/grig/work/peermesh/repo/peermesh-core/sub-repos/core`

Use generated, throwaway, staging-only values. Do not commit them.

```bash
export AUTHENTIK_STAGING_SYNTHETIC_CONFIRM=reviewed-isolated-staging-only
export AUTHENTIK_STAGING_SYNTHETIC_ADMIN_PASSWORD='<generated-staging-only-password>'
export AUTHENTIK_STAGING_SYNTHETIC_USER_PASSWORD='<generated-staging-only-password>'

sh ./configs/authentik-staging/apply-synthetic-blueprint.sh
```

The wrapper copies the blueprint into the `authentik-worker` container and then
runs this command inside the isolated staging stack:

```bash
ak apply_blueprint /blueprints/peermesh-core-f1-synthetic-blueprint.yaml
```

After the blueprint apply succeeds, the wrapper runs `ak shell` inside the same
isolated staging worker to call `set_password()` for
`peermesh-synthetic-admin` and `peermesh-synthetic-user` using only the two
staging-only environment variables above. The command prints only a synthetic
activation status line and must not persist cookies, bearer tokens, JWTs,
bootstrap tokens, real passwords, or real subject identifiers.

The wrapper deliberately does not call production deploy scripts and does not
attach `peermesh-auth@file` to any production or module router.

## Current Remediated State

As of the separate admin host remediation, the reviewed artifact no longer
uses a same-host path-specific Authentik authorization split. That earlier
shape used `https://auth-proof.example.invalid/api/admin` as the admin
provider external host, and the runtime proof showed authenticated non-admin
`/api/admin` requests still reached backend with HTTP `200` and role `user`.

The remediated design uses a separate synthetic admin host:
`https://auth-admin-proof.example.invalid`. The ordinary proof router remains
on `https://auth-proof.example.invalid` with router-facing
`peermesh-auth@file` and excludes `/api/admin`. The admin proof router uses
`https://auth-admin-proof.example.invalid/api/admin` with
`peermesh-admin-auth@file`, backed by a separate Authentik admin proxy
provider and application whose policy requires membership in
`peermesh-admins`. The ordinary and admin forward-auth middlewares both
forward exactly the same five F2 headers.

In Authentik `2026.5.0`, the proxy provider primary key is not a valid
`authentik_policies.policybinding.target`, while applications are valid
policy-binding targets for provider-backed authorization paths. The blueprint
also explicitly meta-applies the bundled Authentik default flow/scope
blueprints it references because fresh file-based blueprint discovery does not
guarantee dependency order.

The public `/outpost.goauthentik.io` callback route exists on both the ordinary
proof host and the dedicated admin proof host so Authentik forward-auth
callbacks remain reachable without routing admin application traffic through
the ordinary host.

Next safe proof step: rerun the isolated staging runtime F2/object capture
against this separate admin host/application boundary with generated
synthetic-only passwords and sanitize all evidence before writing it to disk.

# Events Gateway Rate-Limit Contract v0.1

Status: local candidate and sandbox attachment validated; not production-proven

## Purpose

PeerMesh Core owns gateway enforcement for the Events module. Events owns the
route classes and declared request rates. This contract prepares the Core
middleware names and attachment rules without pretending the Events runtime,
router, client-IP topology, or production enforcement already exists.

## Middleware mapping

- `events-ratelimit-30-per-hour@file`: create, submit, and withdraw routes.
- `events-ratelimit-60-per-hour@file`: admin review transitions and RSVP writes.
- `events-ratelimit-120-per-hour@file`: authenticated event reads/lists and attendance check-in.
- `POST /api/maintenance/cleanup`: no public router; keep internal and protected by the module secret.

Each named middleware is a chain with two token buckets:

1. the default Traefik remote-address bucket;
2. an actor bucket keyed by `X-Peermesh-Actor-WebID`.

Both buckets apply and the stricter result wins. The checked-in candidate uses
`period: 1h` and `burst: 1` so it does not silently grant a large instantaneous
burst. Traefik implements a token bucket, not a fixed rolling-hour window; any
different burst policy is an operations decision that must be tested before
production promotion.

## Required router order

Protected Events routers must attach middleware in this order:

```text
peermesh-auth@file,events-ratelimit-<class>@file
```

`peermesh-auth@file` strips client-supplied identity headers, runs ForwardAuth,
and installs only the trusted `X-Peermesh-*` response headers. Evaluating the
actor bucket before that chain would trust spoofable input and is forbidden.

## Production proof gates

The candidate definitions are not production enforcement until all of these
are proven on the target runtime:

- an Events container/service and its Traefik routers exist;
- every public Events route maps to the correct rate class;
- the cleanup route is absent from public ingress;
- ForwardAuth provides the trusted actor header before rate limiting;
- the IP criterion resolves to the real client in the deployed proxy topology;
- a breach returns HTTP 429 and a usable retry signal;
- counters cover all Events application replicas through the shared Core edge;
- if Core runs more than one Traefik instance, a distributed gateway limiter
  replaces the per-instance Traefik counters or equivalence is otherwise proven.

Until those gates pass, the supported claim is: "Core has a locally validated,
inert Events gateway rate-limit candidate." Do not claim deployed Events rate
limiting or Events production readiness.

## Local validation

Run:

```bash
./scripts/validation/validate-vps-production-authentik-overlay.sh
./scripts/validation/validate-events-sandbox-router-attachment.sh
```

The validator confirms the three IP/actor chains, hourly rates, actor source
criterion, and required production dynamic-config render alongside the existing
Core security and Authentik middleware set.

The sandbox validator builds the Events return from its sibling checkout,
attaches the three classes after the existing `peermesh-auth@file` chain, and
exercises readiness, spoof removal, trusted actor and synthetic client-IP
buckets, `200`/`429`/`Retry-After`, route inventory, and absent cleanup ingress.
Its local auth fixture and fixed sandbox client addresses are proof-only;
neither is a production configuration or substitute for deployed Authentik and
real client-IP/trusted-proxy evidence.

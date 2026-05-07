# ADR-0005: Retire the Repo-Level Traefik TLS Options File

## Metadata

| Field | Value |
|-------|-------|
| **Date** | 2026-04-12 |
| **Status** | accepted |
| **Authors** | AI-assisted |

---

## Context

WO-298 removed `tls.options=default@file` labels from Docker-provider routers after
Traefik v2 emitted `unknown TLS options: default@file`. The underlying issue is a
provider boundary: routers declared through Docker labels cannot safely depend on a
TLS option name declared in the file provider.

The repo previously carried a `configs/traefik/tls.yml` file for custom TLS options.
That file is no longer present, and the remaining file-provider configuration in
`configs/traefik/dynamic.yml` is limited to middlewares and the catchall router.

Keeping the project ambiguous about repo-level TLS option customization would invite
future regressions where operators add `tls.options=...@file` back to Docker labels.

## Decision

**PeerMesh Core will not ship a repo-level Traefik TLS options file.**

Docker-label routers rely on Traefik's built-in TLS defaults. The file provider stays
enabled for dynamic middlewares, the catchall router, and any future services that are
fully declared via the file provider, but not for shared repo-level TLS option tuning.

If a future deployment genuinely needs custom TLS behavior, it must do one of:

1. Use Traefik's Docker-provider label vocabulary where supported.
2. Move that specific router/service to a file-provider definition owned together with
   its TLS settings.
3. Add a deployment-specific override with clear documentation, rather than restoring a
   generic repo-level `tls.yml`.

## Consequences

### Positive

- Removes the ambiguity that caused WO-298.
- Keeps the default path simple for VPS operators.
- Preserves the file provider only for configuration it actively serves today.

### Negative

- There is no repo-wide place to tweak TLS option details for Docker-label routers.
- Operators with advanced TLS requirements must use a more explicit deployment pattern.

## Implementation Notes

- `sub-repos/core/configs/traefik/tls.yml` is intentionally absent.
- `sub-repos/core/configs/traefik/dynamic.yml` remains the only shipped Traefik
  dynamic file.
- `docs/DNS-TLS-DEPLOYMENT-GUIDE.md` documents this retired-default posture and the
  supported override patterns.

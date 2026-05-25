#!/usr/bin/env sh
set -eu

expected_confirm="reviewed-isolated-staging-only"
if [ "${AUTHENTIK_STAGING_SYNTHETIC_CONFIRM:-}" != "${expected_confirm}" ]; then
  printf '%s\n' "Refusing to apply: set AUTHENTIK_STAGING_SYNTHETIC_CONFIRM=${expected_confirm} after review." >&2
  exit 64
fi

if [ -z "${AUTHENTIK_STAGING_SYNTHETIC_ADMIN_PASSWORD:-}" ]; then
  printf '%s\n' "Refusing to apply: AUTHENTIK_STAGING_SYNTHETIC_ADMIN_PASSWORD is required and must be staging-only." >&2
  exit 64
fi

if [ -z "${AUTHENTIK_STAGING_SYNTHETIC_USER_PASSWORD:-}" ]; then
  printf '%s\n' "Refusing to apply: AUTHENTIK_STAGING_SYNTHETIC_USER_PASSWORD is required and must be staging-only." >&2
  exit 64
fi

project_root="$(pwd)"
blueprint_path="${project_root}/configs/authentik-staging/peermesh-core-f1-synthetic-blueprint.yaml"
remote_blueprint_path="/blueprints/peermesh-core-f1-synthetic-blueprint.yaml"

if [ ! -f "${project_root}/docker-compose.authentik-staging.yml" ]; then
  printf '%s\n' "Refusing to apply: run from /Users/grig/work/peermesh/repo/peermesh-core/sub-repos/core." >&2
  exit 64
fi

if [ ! -f "${blueprint_path}" ]; then
  printf '%s\n' "Refusing to apply: blueprint not found at ${blueprint_path}." >&2
  exit 66
fi

compose() {
  docker compose -p peermesh-authentik-staging-proof -f docker-compose.yml -f docker-compose.authentik-staging.yml "$@"
}

compose ps authentik-worker >/dev/null
compose cp "${blueprint_path}" "authentik-worker:${remote_blueprint_path}"
compose exec -T \
  -e AUTHENTIK_STAGING_SYNTHETIC_ADMIN_PASSWORD \
  -e AUTHENTIK_STAGING_SYNTHETIC_USER_PASSWORD \
  authentik-worker \
  ak apply_blueprint "${remote_blueprint_path}"

compose exec -T \
  -e AUTHENTIK_STAGING_SYNTHETIC_ADMIN_PASSWORD \
  -e AUTHENTIK_STAGING_SYNTHETIC_USER_PASSWORD \
  authentik-worker \
  ak shell <<'PY'
from os import environ

from authentik.core.models import User

synthetic_users = [
    ("peermesh-synthetic-admin", "AUTHENTIK_STAGING_SYNTHETIC_ADMIN_PASSWORD"),
    ("peermesh-synthetic-user", "AUTHENTIK_STAGING_SYNTHETIC_USER_PASSWORD"),
]

for username, env_name in synthetic_users:
    password = environ.get(env_name)
    if not password:
        raise RuntimeError(f"{env_name} is required for synthetic password activation")
    user = User.objects.get(username=username)
    user.set_password(password)
    user.save(update_fields=["password"])

print("synthetic_password_activation=ok users=peermesh-synthetic-admin,peermesh-synthetic-user")
PY

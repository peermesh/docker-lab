# Module Manifest Reference

The module manifest (`module.json`) is the central configuration file that describes a PeerMesh module. This document provides detailed documentation for each field.

## Schema Location

JSON Schema: [`../schemas/module.schema.json`](../schemas/module.schema.json)

## Schema Reference Standard

Core owns the module manifest schema. The authoritative schema source is
`foundation/schemas/module.schema.json`, whose published `$id` is
`https://peermesh.io/foundation/v1/module.schema.json`.

Use the `$schema` value that matches the manifest's source layout:

- Core-managed modules installed at `modules/<module-id>/module.json` should use
  `../../foundation/schemas/module.schema.json`. This is the path emitted by the
  Core module template and it resolves inside a Core installation.
- Standalone module source repositories whose manifest lives at
  `module/module.json` must use
  `https://peermesh.io/foundation/v1/module.schema.json`. Do not use
  `../../foundation/schemas/module.schema.json` from `module/module.json`; in a
  standalone repo that path points outside the module repo and is not the Core
  schema authority.

Validation should still pin to the Core-owned schema file from the Core checkout
or an approved packaged copy. The manifest `$schema` field is the supported
editor/reference URI, not permission to create a module-local schema authority.

## Required Fields

### `id`

**Type**: `string`
**Pattern**: `^[a-z0-9][a-z0-9-]*[a-z0-9]$` or single character `^[a-z0-9]$`
**Required**: Yes

Unique identifier for the module. Must be:
- Lowercase alphanumeric with hyphens
- Start and end with alphanumeric character
- 1-64 characters

```json
{
  "id": "my-awesome-module"
}
```

**Best practices**:
- Use descriptive names: `backup-module`, `secrets-manager`
- Avoid generic names: `module1`, `my-module`
- Prefix related modules: `provider-postgres`, `provider-mysql`

### `version`

**Type**: `string`
**Pattern**: Semantic versioning with optional pre-release and build metadata
**Required**: Yes

Module version following [Semantic Versioning 2.0.0](https://semver.org/).

```json
{
  "version": "1.0.0"
}
```

Valid examples:
- `1.0.0` - Release version
- `1.0.0-alpha.1` - Pre-release
- `1.0.0-beta.2+build.123` - Pre-release with build metadata
- `2.0.0+20240116` - Release with build metadata

**Versioning guidelines**:
- **MAJOR**: Breaking changes to API or behavior
- **MINOR**: New features, backward compatible
- **PATCH**: Bug fixes, backward compatible

### `name`

**Type**: `string`
**Max Length**: 128
**Required**: Yes

Human-readable display name for the module.

```json
{
  "name": "PostgreSQL Provider"
}
```

### `foundation`

**Type**: `object`
**Required**: Yes

Declares compatibility with foundation versions.

```json
{
  "foundation": {
    "minVersion": "1.0.0",
    "maxVersion": "2.0.0"
  }
}
```

| Property | Type | Required | Description |
|----------|------|----------|-------------|
| `minVersion` | string | Yes | Minimum foundation version required |
| `maxVersion` | string | No | Maximum foundation version supported |

**Compatibility rules**:
- Module will not install if foundation version < `minVersion`
- Module will warn if foundation version > `maxVersion`
- Omit `maxVersion` if module should work with all future versions

## Optional Fields

### `description`

**Type**: `string`
**Max Length**: 1024

Brief description of what the module does.

```json
{
  "description": "Provides PostgreSQL database connections for other modules"
}
```

### `author`

**Type**: `object`

Module author information.

```json
{
  "author": {
    "name": "Jane Developer",
    "email": "jane@example.com",
    "url": "https://example.com"
  }
}
```

### `license`

**Type**: `string`

SPDX license identifier.

```json
{
  "license": "MIT"
}
```

Common values: `MIT`, `Apache-2.0`, `GPL-3.0`, `BSD-3-Clause`

### `repository`

**Type**: `string` (URI)

Git repository URL.

```json
{
  "repository": "https://github.com/org/module-name"
}
```

### `tags`

**Type**: `array` of `string`

Categorization tags for discovery.

```json
{
  "tags": ["database", "provider", "postgresql"]
}
```

## Dependencies: `requires`

### `requires.connections`

Declare connection types the module needs.

```json
{
  "requires": {
    "connections": [
      {
        "type": "database",
        "providers": ["postgres", "mysql", "sqlite"],
        "required": true,
        "alias": "primary-db"
      },
      {
        "type": "cache",
        "providers": ["redis", "memcached"],
        "required": false
      }
    ]
  }
}
```

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `type` | enum | - | Connection category: `database`, `cache`, `storage`, `queue`, `custom` |
| `providers` | array | - | Acceptable provider types |
| `required` | boolean | `true` | Whether module fails without this connection |
| `alias` | string | - | Name when module needs multiple connections of same type |

**Connection resolution**:
1. Foundation checks installed provider modules
2. Matches requirement type to available provider
3. Injects connection configuration into module

### `requires.modules`

Declare dependencies on other modules.

```json
{
  "requires": {
    "modules": [
      {
        "id": "secrets-module",
        "minVersion": "1.0.0",
        "optional": false
      },
      {
        "id": "dashboard-ui",
        "optional": true
      }
    ]
  }
}
```

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `id` | string | - | Required module ID |
| `minVersion` | string | - | Minimum version required |
| `optional` | boolean | `false` | Whether module can work without this dependency |

Dependency resolver behavior:

1. Module enable/install now resolves `requires.modules[]` transitively.
2. Resolver executes in dependency-first order (topological sort).
3. Missing required dependencies fail closed with actionable errors.
4. Version constraints (`minVersion`) are enforced for required dependencies.
5. Circular dependency graphs fail closed with cycle output.
6. Dry-run planning is available:
   - `./launch_pm-core.sh module enable <module-id> --dry-run`
   - `./foundation/lib/dependency-resolve.sh <module-id> --dry-run`

### `requires.events`

Declare event bus topics the module subscribes to.

```json
{
  "requires": {
    "events": [
      {
        "topic": "pm-module-payments.payment.intake.succeeded",
        "source": "pm-module-payments",
        "required": false,
        "consumerGroup": "email-payments",
        "deliveryGuarantee": "at-least-once",
        "idempotencyKey": "eventId",
        "deadLetterTopic": "pm-module-payments.dlq.payment.intake.succeeded"
      },
      {
        "topic": "pm-module-payments.#",
        "source": "pm-module-payments",
        "required": false,
        "consumerGroup": "analytics-payments",
        "deliveryGuarantee": "best-effort"
      }
    ]
  }
}
```

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `topic` | string | - | Event topic or wildcard pattern |
| `source` | string | - | Expected source module |
| `required` | boolean | `false` | Whether startup fails if subscription cannot register |
| `consumerGroup` | string | - | Durable subscriber group |
| `deliveryGuarantee` | enum | - | `fire-and-forget`, `best-effort`, or `at-least-once` |
| `idempotencyKey` | string | - | Event field used for deduplication |
| `deadLetterTopic` | string | - | Topic for retry exhaustion |

For financial events that require `at-least-once` delivery, consumers must
persist the `idempotencyKey` before acknowledging the event.

## Capabilities: `provides`

### `provides.connections`

Declare connection types this module provides.

```json
{
  "provides": {
    "connections": [
      {
        "type": "database",
        "provider": "postgres"
      }
    ]
  }
}
```

This makes the module a **connection provider**. Other modules requiring `database:postgres` will be able to use this module's connection.

### `provides.events`

Declare event types this module may emit.

```json
{
  "provides": {
    "events": [
      "backup-module.backup.started",
      "backup-module.backup.completed",
      "backup-module.backup.failed"
    ]
  }
}
```

**Event naming convention**: event names are module-scoped topics with at
least three segments. Use `module-id.entity.action` for simple domains and
additional segments for deeper domains, for example
`pm-module-payments.payment.intake.succeeded`.

### `provides.capabilities`

Declare discoverable capabilities this module exposes to other modules.
Payment-capable modules use billing capabilities so dependency resolution can
find billing providers without hard-coding a specific module id.

```json
{
  "provides": {
    "capabilities": [
      {
        "id": "billing.checkout",
        "category": "billing",
        "version": "1.0.0",
        "description": "Creates checkout sessions and publishes payment intake events",
        "events": [
          "pm-module-payments.payment.intake.created",
          "pm-module-payments.payment.intake.succeeded",
          "pm-module-payments.payment.intake.failed"
        ]
      }
    ]
  }
}
```

| Property | Type | Description |
|----------|------|-------------|
| `id` | string | Stable capability id such as `billing.checkout` |
| `category` | enum | Capability category, including `billing` |
| `version` | string | Capability contract version |
| `description` | string | Human-readable contract summary |
| `events` | array | Events associated with this capability |

## Dashboard Integration: `dashboard`

Register UI elements with the dashboard module.

```json
{
  "dashboard": {
    "displayName": "Backup Manager",
    "icon": "archive",
    "routes": [
      {
        "path": "/backups",
        "component": "./ui/BackupList.jsx",
        "nav": {
          "label": "Backups",
          "icon": "archive",
          "order": 50
        }
      },
      {
        "path": "/backups/:id",
        "component": "./ui/BackupDetail.jsx"
      }
    ],
    "statusWidget": {
      "component": "./ui/BackupStatusWidget.jsx",
      "size": "small",
      "order": 10
    },
    "configPanel": {
      "component": "./ui/BackupConfig.jsx"
    }
  }
}
```

| Property | Type | Description |
|----------|------|-------------|
| `displayName` | string | Name shown in dashboard |
| `icon` | string | Icon identifier |
| `routes` | array | URL routes to register |
| `statusWidget` | object | Widget for dashboard overview |
| `configPanel` | object | Configuration panel |

**Note**: If `dashboard-ui` module is not installed, registration is a no-op.

## Lifecycle Hooks: `lifecycle`

Define scripts for lifecycle events.

```json
{
  "lifecycle": {
    "install": "./scripts/install.sh",
    "start": "./scripts/start.sh",
    "stop": "./scripts/stop.sh",
    "uninstall": "./scripts/uninstall.sh",
    "health": {
      "script": "./scripts/health.sh",
      "timeout": 30
    }
  }
}
```

See [LIFECYCLE-HOOKS.md](LIFECYCLE-HOOKS.md) for detailed documentation.

## Configuration Schema: `config`

Define module configuration options.

```json
{
  "config": {
    "version": "1.0",
    "properties": {
      "backupPath": {
        "type": "string",
        "description": "Directory for backup storage",
        "default": "/data/backups",
        "env": "BACKUP_PATH"
      },
      "retentionDays": {
        "type": "number",
        "description": "Days to retain backups",
        "default": 30,
        "minimum": 1,
        "maximum": 365,
        "env": "BACKUP_RETENTION_DAYS"
      },
      "encryptionKey": {
        "type": "string",
        "description": "Key for backup encryption",
        "secret": true,
        "env": "BACKUP_ENCRYPTION_KEY"
      }
    },
    "required": ["backupPath"]
  }
}
```

| Property Schema Field | Type | Description |
|-----------------------|------|-------------|
| `type` | enum | `string`, `number`, `boolean`, `array`, `object` |
| `description` | string | Human-readable description |
| `default` | any | Default value |
| `env` | string | Environment variable mapping |
| `secret` | boolean | Marks sensitive values (BYOK pattern) |
| `enum` | array | Allowed values |
| `minimum`/`maximum` | number | Numeric constraints |
| `minLength`/`maxLength` | integer | String length constraints |
| `pattern` | string | Regex validation for strings |

**BYOK Pattern**: Properties marked `secret: true` indicate values the user must provide. These are never stored in the module repository and are loaded from environment variables or a secrets manager.

## Complete Example

```json
{
  "id": "backup-module",
  "version": "1.2.0",
  "name": "Backup Manager",
  "description": "Automated backup and recovery for PeerMesh modules",
  "author": {
    "name": "PeerMesh Team",
    "email": "team@peermesh.io"
  },
  "license": "Apache-2.0",
  "repository": "https://github.com/peermesh/backup-module",
  "tags": ["backup", "recovery", "storage"],
  "foundation": {
    "minVersion": "1.0.0"
  },
  "requires": {
    "connections": [
      {
        "type": "storage",
        "providers": ["minio", "s3"],
        "required": true
      }
    ],
    "modules": [
      {
        "id": "secrets-module",
        "optional": true
      }
    ]
  },
  "provides": {
    "events": [
      "backup-module.backup.started",
      "backup-module.backup.completed",
      "backup-module.backup.failed",
      "backup-module.restore.started",
      "backup-module.restore.completed"
    ]
  },
  "dashboard": {
    "displayName": "Backups",
    "icon": "archive",
    "routes": [
      {
        "path": "/backups",
        "nav": {"label": "Backups", "order": 60}
      }
    ],
    "statusWidget": {
      "size": "small"
    }
  },
  "lifecycle": {
    "install": "./scripts/install.sh",
    "health": "./scripts/health.sh"
  },
  "config": {
    "version": "1.0",
    "properties": {
      "schedule": {
        "type": "string",
        "description": "Cron expression for backup schedule",
        "default": "0 2 * * *",
        "env": "BACKUP_SCHEDULE"
      },
      "retentionDays": {
        "type": "number",
        "default": 30,
        "env": "BACKUP_RETENTION_DAYS"
      }
    }
  }
}
```

## Validation

Validate your manifest against the JSON Schema:

```bash
# Core-managed module under modules/<module-id>/
npx ajv validate -s foundation/schemas/module.schema.json -d modules/my-module/module.json

# Standalone module source repo with module/module.json
npx ajv validate -s /path/to/core/foundation/schemas/module.schema.json -d module/module.json

# Same checks with check-jsonschema
check-jsonschema --schemafile foundation/schemas/module.schema.json modules/my-module/module.json
check-jsonschema --schemafile /path/to/core/foundation/schemas/module.schema.json module/module.json
```

## Related Documentation

- [Lifecycle Hooks Guide](LIFECYCLE-HOOKS.md)
- [Event Schema](../schemas/event.schema.json)
- [Foundation README](../README.md)

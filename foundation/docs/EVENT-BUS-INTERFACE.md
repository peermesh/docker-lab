# Event Bus Interface

The event bus provides a standardized way for modules to communicate asynchronously. The foundation core defines only the **interface** - actual implementations are provided by add-on modules.

## Overview

The event bus follows a publish-subscribe pattern where:

- **Publishers** emit events to topics
- **Subscribers** listen for events on topic patterns
- **Events** are structured messages with metadata

## Core Principle: Interface Over Implementation

The foundation core includes:

- Interface definitions (TypeScript, Python)
- No-op implementation (for when no event bus is installed)
- Event schema (JSON Schema)

The foundation does NOT include:

- Redis implementation → Install `eventbus-redis` module
- NATS implementation → Install `eventbus-nats` module
- In-memory implementation → Install `eventbus-memory` module

## Event Format

Events follow the [CloudEvents](https://cloudevents.io/) specification:

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "timestamp": 1705420800000,
  "source": "backup-module",
  "type": "backup-module.backup.completed",
  "specversion": "1.0",
  "datacontenttype": "application/json",
  "subject": "daily-backup-2024-01-16",
  "correlationId": "optional-correlation-id",
  "payload": {
    "backupId": "daily-backup-2024-01-16",
    "size": 1073741824
  }
}
```

### Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `id` | string (UUID) | Unique event identifier |
| `timestamp` | integer | Unix timestamp in milliseconds |
| `source` | string | Module ID that emitted the event |
| `type` | string | Event type in `source.entity.action` format |

### Optional Fields

| Field | Type | Description |
|-------|------|-------------|
| `subject` | string | Specific resource this event relates to |
| `correlationId` | string (UUID) | Links related events in a workflow |
| `causationId` | string (UUID) | ID of the event that caused this one |
| `payload` | object | Event-specific data |
| `metadata` | object | Additional metadata |

## Topic Naming Convention

Topics follow the format: `<source>.<entity>.<action>` and may add extra
domain segments when the source module has a deeper event vocabulary. The
first segment is always the module id or `foundation`.

```
backup-module.backup.started
backup-module.backup.completed
backup-module.backup.failed
secrets-module.secret.created
secrets-module.secret.rotated
pm-module-payments.payment.intake.succeeded
pm-module-payments.recurring.sponsorship.cancelled
```

### Wildcards

When subscribing, you can use wildcards:

- `*` matches a single segment
- `#` matches zero or more segments

```
backup-module.backup.*     → matches all backup events
backup-module.#            → matches all events from backup-module
*.*.created                → matches all "created" events
```

### Payments and Financial Event Topics

Payments events use the canonical namespace `pm-module-payments.*`. Core
accepts multi-segment topics such as
`pm-module-payments.payment.intake.succeeded` so Payments can preserve its
domain vocabulary without collapsing event names into compatibility aliases.

Core registers the Payments event bus contract in
[`../events/payments-events.json`](../events/payments-events.json). That
registry defines the 26 canonical Payments events, their delivery tier, the
preferred `eventbus:redis` Streams backend, manual acknowledgments for durable
events, and DLQ topics for compliance-critical delivery failures.

## Standard Foundation Events

The foundation emits these events for module lifecycle:

| Event Type | When | Payload |
|------------|------|---------|
| `foundation.module.installed` | Module added | `{moduleId, version}` |
| `foundation.module.started` | Module activated | `{moduleId, startupDuration}` |
| `foundation.module.stopped` | Module deactivated | `{moduleId, reason}` |
| `foundation.module.uninstalled` | Module removed | `{moduleId}` |
| `foundation.module.health-changed` | Health status changes | `{moduleId, status, checks}` |
| `foundation.system.startup` | Foundation starts | `{}` |
| `foundation.system.shutdown` | Foundation stops | `{}` |

## Usage Examples

### TypeScript

```typescript
import { EventBus, Event, FOUNDATION_EVENT_TYPES } from 'foundation/interfaces/eventbus';

// Publishing an event
await eventBus.publish('my-module.item.created', {
  itemId: '123',
  name: 'Example Item'
});

// Subscribing to events
const subscription = eventBus.subscribe(
  'my-module.item.*',
  (event: Event) => {
    console.log(`Received: ${event.type}`, event.payload);
  }
);

// Cleanup
eventBus.unsubscribe(subscription);
```

### Python

```python
from foundation.interfaces.eventbus import EventBus, Event, FoundationEventTypes

# Publishing an event
await event_bus.publish('my-module.item.created', {
    'item_id': '123',
    'name': 'Example Item'
})

# Subscribing to events
def handler(event: Event):
    print(f"Received: {event.type}", event.payload)

subscription = event_bus.subscribe('my-module.item.*', handler)

# Cleanup
event_bus.unsubscribe(subscription)
```

### Bash

```bash
source /path/to/foundation/lib/eventbus-noop.sh

# Initialize (required for some implementations)
eventbus_init

# Publishing
eventbus_publish "my-module.item.created" '{"itemId": "123", "name": "Example Item"}'

# Subscribing (handler function must be defined)
my_handler() {
    local event_json="$1"
    echo "Received event: $event_json"
}
sub_id=$(eventbus_subscribe "my-module.item.*" my_handler)

# Cleanup
eventbus_unsubscribe "$sub_id"
```

## No-Op Implementation

When no event bus module is installed, the foundation uses a no-op implementation:

- `publish()` does nothing (logs warning once)
- `subscribe()` returns a dummy subscription ID
- `unsubscribe()` does nothing
- `is_connected()` returns false

This ensures modules can always call event bus functions without errors, even when no messaging infrastructure is installed.

## Delivery Guarantees and Subscriber Groups

Event bus implementations must document which delivery semantics they support:

- `fire-and-forget`: publish without persistence or consumer acknowledgment.
- `best-effort`: attempt delivery and expose operational visibility, but do
  not guarantee recovery after process or broker failure.
- `at-least-once`: persist events until each registered consumer group
  acknowledges processing. Consumers must deduplicate by event id.

Financial events that are classified as compliance-critical must use
`at-least-once` delivery with manual acknowledgment, a durable consumer group
per subscribing module, and a dead-letter topic after retry exhaustion. The
recommended backend is `eventbus-redis` backed by Redis Streams with AOF
persistence enabled on the Core Redis profile.

Consumer modules subscribe by declaring `requires.events[]` in `module.json`
and by registering their event handlers during the `start` lifecycle hook.
Multiple modules can subscribe to the same Payments topic because each module
uses a distinct consumer group; adding Email, Groups, or another consumer must
not require a Payments code change.

## Implementing an Event Bus Module

To create a new event bus implementation:

1. Create a module that provides an `EventBus` implementation
2. Register it as a provider for the `eventbus` connection type
3. Implement all interface methods

Example module structure:

```
eventbus-redis/
├── module.json           # Declares: provides.connections = ["eventbus"]
├── docker-compose.yml    # Redis container
└── lib/
    ├── eventbus-redis.ts # TypeScript implementation
    ├── eventbus-redis.py # Python implementation
    └── eventbus-redis.sh # Bash implementation
```

## Best Practices

1. **Keep payloads small** - Large payloads impact performance
2. **Use correlation IDs** - Link related events in workflows
3. **Handle failures gracefully** - Events may not be delivered
4. **Make handlers idempotent** - Events may be delivered more than once
5. **Document your events** - Include event types in module manifest

## Related Documentation

- [Module Manifest](./MODULE-MANIFEST.md) - Declaring event types in `provides.events`
- [Lifecycle Hooks](./LIFECYCLE-HOOKS.md) - Module lifecycle events
- [Connection Abstraction](./CONNECTION-ABSTRACTION.md) - Connection provider pattern
- [Event Schema](../schemas/event.schema.json) - JSON Schema for events

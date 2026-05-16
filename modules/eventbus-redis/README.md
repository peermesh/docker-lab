# Redis Event Bus Provider

`eventbus-redis` registers the Core Redis profile as the non-noop event bus
provider for modules that declare `requires.connections[]` with
`type: "eventbus"` and `providers: ["redis"]`.

The provider contract is Redis Streams, not Redis pub/sub:

- one stream per event topic
- one durable consumer group per subscribing module
- manual acknowledgments for `at-least-once` financial events
- retry exhaustion routed to the event's declared DLQ topic
- Redis AOF persistence required for compliance-critical financial events

The base Core `redis` profile already starts Redis with `--appendonly yes`.
Operators must enable the `redis` profile in environments that need durable
financial event fanout.

## Payments Contract

The canonical Payments event registry lives at:

`../../foundation/events/payments-events.json`

Consumers such as Email or Groups subscribe by declaring `requires.events[]`
for the relevant `pm-module-payments.*` topics and by using their own durable
consumer group name.

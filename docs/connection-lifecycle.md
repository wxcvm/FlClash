# Connection lifecycle history

FlClash keeps a bounded, in-memory view of recent Mihomo connections so the
Requests screen can show more than the currently open sockets.

## Data flow

- Core request events add successful connections and failed dial attempts.
- Request-traffic events update byte counters and report when a connection closes.
- The app reconciles those events with periodic connection snapshots. Snapshot
  reads that fail do not erase the last successful live view.
- The retained history is bounded by `maxRequestsLength`; trimmed connection
  IDs are remembered within the retention window so late open events cannot
  resurrect entries that have already been evicted.

## UI behavior

- The recent feed exposes All, Active, and Failed filters with counts.
- The live feed keeps the existing throughput-based ranking and newest-first
  tie breaking.
- Connection details show the observed creation, close, and failure events.
  Failure details include a normalized category and the Core error message.

## Current timing limitation

The timeline is intentionally based only on data the pinned Core currently
emits. It can show the connection start time, an app-observed close time, and a
failed-dial timestamp. Full DNS, rule-selection, dial, TLS, and decryption phase
timings are not yet emitted by this Core revision; optional model fields do not
manufacture those events or display placeholder timings.

## Scope

This is an observability feature. It does not change routing, proxy selection,
DNS resolution, or network transport behavior. The history is held in the
application's in-memory provider state and is bounded; this feature does not
write a separate connection-history database.

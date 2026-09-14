# Transfer worker live progress sidecar (PP-071)

The transfer worker can optionally expose live, non-authoritative progress for a user interface while the same qualified transfer execution is running.

## CLI

Existing invocations remain valid:

```sh
bitmatch-transfer-worker run --job /absolute/job.json --evidence /absolute/evidence.json
```

A caller that negotiated the `live-progress-jsonl-v1` capability may add:

```sh
bitmatch-transfer-worker run \
  --job /absolute/job.json \
  --evidence /absolute/evidence.json \
  --progress /absolute/progress.jsonl
```

Failure to create or append the progress sidecar does not change the transfer result. The worker writes a diagnostic to stderr and continues because progress is observability, not transfer authority.

## JSONL record

Each line is an independent JSON object with `schemaVersion: 1` and a strictly increasing `sequence` within that process. Fields include:

- `kind`: `progress` or `heartbeat`;
- `observedAt`: when this record was emitted;
- `lastProgressAt`: when file/byte/stage progress last changed;
- `phase`: `scanning`, `copying`, `verifying`, or `finishing_records`;
- `filesCompleted` / `filesTotal`;
- optional `bytesCompleted` / `bytesTotal` and `fractionCompleted`;
- optional `currentFile`;
- optional `elapsedSeconds`, `bytesPerSecond`, and `approximateRemainingSeconds`.

The sidecar maps values from the existing `OperationProgress` objects produced by `SharedFileOperationsService`. The protocol v3 single-source-read fan-out emits source-oriented byte observations from its bounded 4 MiB chunk loop, including an initial partial-file observation, so a large file advances before its terminal file result. During the pre-publication checksum and full destination readback passes, the same observational path emits `verifying` phase updates and liveness while keeping copied-byte totals monotonic; it does not pretend verification bytes are additional copied bytes. The copy observation is once per source byte rather than multiplied by destination count; destination result/evidence accounting remains unchanged. Heartbeats repeat the last observed counters; they advance `observedAt` but preserve `lastProgressAt`, so a responsive worker cannot be mistaken for forward copy progress.

Throughput and ETA are withheld until there has been enough runtime/progress history to avoid displaying a startup guess as a fact.

## Authority boundary

The sidecar is intentionally lossy and non-durable. It is not part of `TransferEvidence`, does not alter the evidence schema, and must never be used to conclude that a transfer succeeded, verified strongly, or is safe to clear.

In particular:

- `fractionCompleted == 1` is not terminal success;
- the `finishing_records` phase is not terminal success;
- a stale or missing sidecar is not transfer failure;
- worker exit status plus the existing evidence artifact remain the terminal transfer contract;
- Post Prep safety conclusions remain derived from its existing durable operation/evidence/replica policies.

PP-071 changes no job semantics, exact-subset selection, copy/fan-out behavior, SHA-256 verification, no-clobber publication, source-read-only behavior, terminal statuses, or evidence schema.

# BitMatch transfer worker protocol

## Purpose and boundary

`bitmatch-transfer-worker` is a headless macOS safety-engine surface for an
external owner such as Post Prep. The caller owns project state, durable job
intent, evidence acceptance, recovery decisions, and any eventual clearing
policy. The worker owns one bounded filesystem copy/verification attempt.

The process may read a machine-local source and write to explicitly supplied
destination roots and evidence paths. It does not open or modify Post Prep
`project.sqlite`, does not use GRDB or PostPrepPersistence, does not require a
network service or commercial ingest license, and has no card erase, format, or
delete operation. A worker crash is therefore outside the authoritative project
database process.

The worker reuses the same BitMatch safety path used by the app:

```text
TransferWorkerRuntime
  -> SharedFileOperationsService
  -> SafetyValidator + FileCopyService + SharedChecksumService
```

It does not contain a simplified second copy implementation. The Swift package
selects only Foundation/core sources, so launching the executable requires no
SwiftUI/AppKit application or window state.

## Commands

```bash
swift build --product bitmatch-transfer-worker
.build/debug/bitmatch-transfer-worker capabilities --json
.build/debug/bitmatch-transfer-worker run \
  --job /absolute/path/job.json \
  --evidence /absolute/path/evidence.json
```

Machine callers must use JSON and process exit status. Human UI text and GUI
preferences are not protocol inputs.

## Capability discovery

`capabilities --json` is deterministic for a worker build. V1 advertises:

- protocol version `1`;
- verification policy `sha256` and algorithm `SHA-256`;
- at most 16 destinations;
- atomic no-overwrite publication for copied files;
- bounded detailed evidence;
- the source-read-only guarantee;
- no pause/resume support yet;
- worker semantic version/build and exact upstream repository/revision.

A required capability absent from the advertised `capabilities` list rejects
the job before any destination write. Unknown optional capabilities are retained
as caller requests but do not weaken execution.

## TransferJobSpec V1

Dates use ISO-8601. IDs are UUIDs. Paths are absolute machine-local execution
inputs and are never durable asset identities.

```json
{
  "protocolVersion": 1,
  "jobID": "11111111-1111-1111-1111-111111111111",
  "attemptID": "22222222-2222-2222-2222-222222222222",
  "requestedAt": "2026-09-10T12:00:00Z",
  "sourceRoot": "/Volumes/CAMERA_CARD",
  "destinations": [
    {
      "requestID": "working-1",
      "executionRoot": "/Volumes/WORKING",
      "role": "working"
    },
    {
      "requestID": "backup-1",
      "executionRoot": "/Volumes/BACKUP",
      "role": "backup"
    }
  ],
  "verificationPolicy": "sha256",
  "requestedCapabilities": [
    { "name": "source-read-only", "required": true }
  ]
}
```

`verificationPolicy` defaults to `sha256` when omitted. V1 supports no
non-checksum mode. An unknown policy fails closed; `UserDefaults` and old GUI
preferences cannot select Quick mode or disable the worker's requested policy.

Before destination writes, V1 rejects malformed/unsupported versions, unknown
mandatory capabilities, empty or missing sources, zero or more than 16
destinations, duplicate request IDs, non-existing roots, duplicate/nested
destinations, source/destination containment in either direction, unsafe
symlinks/traversal, protected destinations, and insufficient storage. Evidence
paths must be absolute, must have an existing parent, must not be inside the
source tree, and must not already exist.

Destination roles are `working`, `backup`, and `optional`. PP-015 records roles
but does not interpret them as a clearing policy.

## Source-read-only invariant

The worker may enumerate source paths, inspect metadata, and open regular source
files for reading. It must not create, delete, rename, rewrite, chmod, touch, or
otherwise intentionally mutate any source-tree item. The deterministic fixture
captures relative paths, bytes, sizes, modification dates, and POSIX permissions
before execution and asserts that the same snapshot exists afterward.

A physical write-protected card remains a useful field safeguard, but it is not
a substitute for this software contract. PP-015 fixture results are not physical
device qualification.

## Destination ownership and publication

Each `executionRoot` is an existing directory explicitly delegated for this
attempt. BitMatch pins destination directories with descriptor-relative,
no-follow operations, writes temporary files, and publishes without overwriting
an item that already exists. Matching existing files can be reused only after
checksum verification. A conflicting non-identical file is preserved and
reported as a failure.

V1 processes destinations through the existing BitMatch multi-destination path.
It does not claim PP-017's one-source-read fan-out or physical-device topology.

## TransferEvidence V1

The final JSON contains:

- protocol, job, and attempt identity;
- worker semantic version/build and exact upstream provenance;
- start/end timestamps and a typed terminal status;
- source file/byte summary;
- separate summaries keyed by stable destination request ID;
- the verification policy actually used;
- warnings, typed errors, and capabilities used;
- a reference to detailed newline-delimited JSON evidence.

Detailed file results are streamed to `<evidence>.details.jsonl`, not accumulated
in the final JSON object. The final reference records its format, record count,
and SHA-256 digest. Successful records include source/destination SHA-256 values.

Both detailed and final artifacts are written under unique `.partial-*` names
and atomically renamed only when complete. Existing final artifacts are never
overwritten. A crash can leave a partial artifact, but a missing final evidence
file can never be interpreted as terminal success. PP-016 will address stronger
filesystem durability and cold readback guarantees.

## Exit and terminal states

| Exit | Evidence terminal status | Meaning |
| ---: | --- | --- |
| `0` | `succeeded` | Every planned file/destination verified. |
| `2` | `completedWithFailures` | Execution completed with one or more file/destination failures. |
| `3` | `invalidJob` | Decode/preflight/topology/input rejection. Malformed JSON may have no final evidence because job/attempt identity is unavailable. |
| `4` | `unsupportedProtocolOrCapability` | Unsupported protocol, verification policy, mandatory capability, or destination count. |
| `5` | `interrupted` | Cancellation/interruption observed by the worker. |
| `70` | `internalFailure` | Unexpected worker or evidence-publication failure. |

The caller must require both the expected process result and a complete,
decodable evidence artifact matching its job and attempt. PP-015 does not solve
unknown-success reconciliation after a process crash.

## Explicitly deferred work

- PP-016: full-fsync/durability and cache-bypassed cold readback hardening.
- PP-017: one-source-read N-destination fan-out and physical topology policy.
- PP-018: Post Prep process launch, SQLite/project-state integration, bounded
  orchestration, reconciliation, and evidence acceptance.
- PP-019: production qualification on physical cards, readers, hubs, and drives.

There is **no Safe-to-clear authority in PP-015**. Neither worker success nor its
fixture tests authorize erasing or formatting source media.

## Provenance

The exact upstream fork point is
`3debabe2e1049c7e02ee5f3587464894f3b190d5` from
`https://github.com/mikecerisano/Bitmatch`. See [UPSTREAM.md](../UPSTREAM.md) and
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).

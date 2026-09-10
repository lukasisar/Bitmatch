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

`capabilities --json` is deterministic for a worker build. V2 advertises:

- protocol version `2`;
- verification policy `sha256` and algorithm `SHA-256`;
- at most 16 destinations;
- atomic no-overwrite publication for copied files;
- bounded detailed evidence;
- the source-read-only guarantee;
- pre-publication SHA-256 verification of worker-owned temporary files;
- Darwin `F_FULLFSYNC` and directory-publication flush facts;
- independent full destination readback with a Darwin `F_NOCACHE` request;
- no pause/resume support yet;
- worker semantic version/build and exact upstream repository/revision.

A required capability absent from the advertised `capabilities` list rejects
the job before any destination write. Unknown optional capabilities are retained
as caller requests but do not weaken execution.

## TransferJobSpec V2

Dates use ISO-8601. IDs are UUIDs. Paths are absolute machine-local execution
inputs and are never durable asset identities.

```json
{
  "protocolVersion": 2,
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

`verificationPolicy` defaults to `sha256` when omitted. V2 supports no
non-checksum mode. An unknown policy fails closed; `UserDefaults` and old GUI
preferences cannot select Quick mode or disable the worker's requested policy.

Before destination writes, V2 rejects malformed/unsupported versions, unknown
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
no-follow operations. A new file follows this bounded sequence:

```text
exclusive worker-owned temporary file
  -> write from a read-only opened source descriptor
  -> preserve the source modification time on the temporary file
  -> ordinary synchronize/fsync
  -> SHA-256-check the temporary bytes before publication
  -> recheck opened-source stability
  -> request Darwin F_FULLFSYNC for the final data + preserved-mtime state
  -> atomic linkat no-overwrite publication
  -> remove only the worker-owned temporary name
  -> fsync the containing destination directory
  -> independently reopen final file and perform full readback
```

A pre-existing destination is never replaced. A matching regular file may be
reused only after checksum verification, but is reported as degraded because
this attempt did not perform its original write, flush, or publication. A
conflicting item is preserved and reported as a failure. Cleanup applies only
to names created by this attempt with the `.bitmatch.tmp.` prefix.

V2 processes destinations through the existing BitMatch multi-destination path.
It does not claim PP-017's one-source-read fan-out or physical-device topology.

## TransferEvidence V2

The final JSON contains:

- protocol, job, and attempt identity;
- worker semantic version/build and exact upstream provenance;
- start/end timestamps and a typed terminal status;
- an explicit `VERIFIED_STRONG`, `VERIFIED_DEGRADED`, or `FAILED` verification
  outcome, separate from process completion;
- source file/byte summary;
- separate summaries keyed by stable destination request ID;
- the verification policy actually used;
- warnings, deterministic typed errors, and capabilities used;
- a reference to detailed newline-delimited JSON evidence.

Detailed file results are streamed to `<evidence>.details.jsonl`, not accumulated
in the final JSON object. The final reference records its format, record count,
and SHA-256 digest. Every record exposes the source and destination SHA-256
digests when available, attempt-wide/read-time source stability facts,
pre-publication checksum result, publication disposition, complete-readback
byte count, and separate outcomes for `F_FULLFSYNC`, directory `fsync`, and
`F_NOCACHE`.

Both detailed and final artifacts are written under unique `.partial-*` names
and atomically renamed only when complete. Existing final artifacts are never
overwritten. A crash can leave a partial artifact, but a missing final evidence
file can never be interpreted as terminal success.

V1 job specs are rejected explicitly as unsupported by the V2 worker. This is
intentional: a V1 caller does not understand the new degraded result and must
not silently interpret ordinary checksum success as a strong verification.

## Verification outcome derivation

The worker reports facts; Post Prep remains responsible for deciding whether
those facts satisfy a future Safe-to-clear policy.

Before deriving any successful outcome, the worker constructs the exact
expected pair set from the frozen source manifest crossed with every requested
destination ID. The returned operation results must contain exactly one row for
each expected pair, with no missing, duplicate, unexpected-source, or
unexpected-destination row. Per-destination successful/failed counts are
derived over the frozen manifest, and every fully successful destination's
verified byte count must equal the frozen source byte total. Structural
discrepancies emit deterministic `result-set-incomplete`,
`result-set-duplicate`, `result-set-unexpected`, or
`result-set-inconsistent` errors and force `FAILED` before strong/degraded
aggregation.

`VERIFIED_STRONG` requires every planned file/destination pair to have all of
the following facts: stable source observations, ordinary flush success,
successful `F_FULLFSYNC`, matching temporary SHA-256 before publication,
successful no-overwrite publication, successful containing-directory `fsync`,
a successful `F_NOCACHE` request on an independently reopened final file, a
complete read of the expected byte count, and matching source/destination
SHA-256 digests.

`VERIFIED_DEGRADED` means all bytes completed full SHA-256 readback and matched,
but a stronger capability was explicitly unsupported or the destination was a
verified pre-existing file. `FAILED` means a required operation failed, facts
are missing, source stability failed, or any checksum/read length differs.
Unsupported is never encoded as strong success. Missing facts or an inexact
result set can produce neither `VERIFIED_STRONG` nor `VERIFIED_DEGRADED`.

## Guarantee table

| Evidence step | What it proves | What it does not prove |
| --- | --- | --- |
| Copy completion | The write loop reached EOF and the temporary file had the expected length. | That bytes match, are durable, or were published. |
| Exact result-set validation | There is exactly one terminal result for every frozen source-relative-path × requested-destination-ID pair; destination counts and successful byte totals reconcile to that plan. | Byte correctness, durability, or storage independence without the other evidence steps. |
| SHA-256 destination match | The bytes read for source and destination produced the same SHA-256 digest; PP-016 also checks the temporary file before publication. | Physical media residence, future readability, or device independence. |
| Ordinary synchronize/fsync | The OS accepted its normal file-data synchronization request. | That a device with volatile caches committed bytes to NAND/platter. |
| Darwin `F_FULLFSYNC` success | After data writing, mtime preservation, temporary SHA-256, and source-stability checks, macOS accepted the stronger full-sync request for that pre-publication inode state. | Absolute physical persistence; later publication metadata and bridges, filesystems, firmware, and hardware remain separately bounded. |
| Atomic no-overwrite publication + directory fsync | The final name was created without replacing an existing item and the OS accepted synchronization of its containing directory metadata. | That all higher/lower storage layers are power-loss proof. |
| Full `F_NOCACHE`-requested readback | An independently reopened final descriptor returned the complete expected byte count and matching SHA-256 while the OS-cache-bypass request was active. | A guaranteed physical reread from flash/platter; `F_NOCACHE` is an OS-cache-bypass request only. |

## Exit and terminal states

| Exit | Evidence terminal status | Meaning |
| ---: | --- | --- |
| `0` | `succeeded` | Every planned file/destination verified; inspect `verificationOutcome` to distinguish strong from degraded. |
| `2` | `completedWithFailures` | Execution completed with one or more file/destination failures. |
| `3` | `invalidJob` | Decode/preflight/topology/input rejection. Malformed JSON may have no final evidence because job/attempt identity is unavailable. |
| `4` | `unsupportedProtocolOrCapability` | Unsupported protocol, verification policy, mandatory capability, or destination count. |
| `5` | `interrupted` | Cancellation/interruption observed by the worker. |
| `70` | `internalFailure` | Unexpected worker or evidence-publication failure. |

The caller must require both the expected process result and a complete,
decodable evidence artifact matching its job and attempt. PP-015 does not solve
unknown-success reconciliation after a process crash.

## Explicitly deferred work

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

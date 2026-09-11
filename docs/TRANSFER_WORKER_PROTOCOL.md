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
  -> SafetyValidator + FileCopyService fan-out + macOS topology resolver
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

`capabilities --json` is deterministic for a worker build. V3 advertises:

- protocol version `3`;
- verification policy `sha256` and algorithm `SHA-256`;
- at most 16 destinations;
- no-overwrite publication for copied files (atomic visibility where hard links
  are available, direct exclusive-name publication on exFAT/FAT);
- bounded detailed evidence;
- the source-read-only guarantee;
- pre-publication SHA-256 verification of worker-owned temporary files;
- Darwin `F_FULLFSYNC` and directory-publication flush facts;
- independent full destination readback with a Darwin `F_NOCACHE` request;
- one-source-read multi-destination fan-out;
- synchronous backpressure with at most one 4 MiB source chunk buffered;
- macOS physical-storage topology facts;
- no pause/resume support yet;
- worker semantic version/build and exact upstream repository/revision.

A required capability absent from the advertised `capabilities` list rejects
the job before any destination write. Unknown optional capabilities are retained
as caller requests but do not weaken execution.

## TransferJobSpec V3

Dates use ISO-8601. IDs are UUIDs. Paths are absolute machine-local execution
inputs and are never durable asset identities.

```json
{
  "protocolVersion": 3,
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

`verificationPolicy` defaults to `sha256` when omitted. V3 supports no
non-checksum mode. An unknown policy fails closed; `UserDefaults` and old GUI
preferences cannot select Quick mode or disable the worker's requested policy.

Before destination writes, V3 rejects malformed/unsupported versions, unknown
mandatory capabilities, empty or missing sources, zero or more than 16
destinations, duplicate request IDs, non-existing roots, duplicate/nested
destinations, source/destination containment in either direction, unsafe
symlinks/traversal, protected destinations, and insufficient storage. Evidence
paths must be absolute, must have an existing parent, must not be inside the
source tree, and must not already exist.

Destination roles are `working`, `backup`, and `optional`. A role expresses
business intent only. It neither establishes nor implies physical independence.

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
  -> receive chunks from one read-only opened source descriptor
  -> preserve the source modification time on the temporary file
  -> ordinary synchronize/fsync
  -> SHA-256-check the temporary bytes before publication
  -> recheck opened-source stability
  -> request Darwin F_FULLFSYNC for the verified temporary inode
  -> publish without replacing an existing final name:
       hard-link filesystem: atomic linkat publication
       exFAT/FAT: O_EXCL claim of the real final name, then descriptor copy,
                  mtime preservation, fsync, and F_FULLFSYNC of the final inode
  -> bind subsequent evidence to the published st_dev/st_ino identity
  -> remove only the worker-owned temporary name
  -> fsync the containing destination directory
  -> independently reopen the same final identity and perform full readback
```

A pre-existing destination is never replaced. A matching regular file may be
reused only after checksum verification, but is reported as degraded because
this attempt did not perform its original write, flush, or publication. A
conflicting item is preserved and reported as a failure.

`linkat` is the preferred publication primitive because it provides both
atomic visibility and no-clobber publication. exFAT has no hard links, and
macOS does not provide a working exclusive-rename primitive on the qualified
exFAT volumes. On an explicit `ENOTSUP`/`EOPNOTSUPP` from `linkat`, the worker
therefore keeps the non-negotiable no-clobber property and gives up atomic
visibility: `O_CREAT | O_EXCL` claims the real final name, and the worker copies
the already-verified bytes directly between the still-open temporary and final
descriptors. The final inode receives its own timestamp preservation, ordinary
`fsync`, and `F_FULLFSYNC`; the temporary inode's earlier flush is not reused as
evidence for this distinct object.

The claimed final identity is recorded before copying and required again before
readback and after the complete read. A replacement is rejected even if its
size and SHA-256 happen to match the source, so a different writer's file cannot
inherit this attempt's durability evidence. The worker never tries to roll back
a published pathname after a verification or directory-sync failure: identity
check followed by pathname unlink would itself be a race that could delete a
concurrent replacement. Instead it fails closed and retains the suspect final
entry. A failure after an exFAT final-name claim also retains the verified
temporary entry when it is still present. Such residue requires reconciliation
or human review and can never be reported as verified.

For each manifest file, V3 opens the source once, freezes its descriptor identity,
and makes one sequential transfer pass. Each source chunk updates one SHA-256
state and is then written to every active destination temporary file. The worker
does not read the next source chunk until all active writers have accepted the
current one. This synchronous producer/consumer design is the backpressure
mechanism: it retains at most one 4 MiB source chunk regardless of destination
count or file size. A slow destination therefore slows the producer instead of
growing a queue.

A destination writer that fails is removed from the active set and its result
remains failed in the exact Cartesian result set. A temporary file is cleaned
only if no final name was claimed; post-claim failures retain recovery evidence.
Other writers continue receiving the same source stream and can independently
complete. One successful destination never changes the requested operation as
a whole into success when another destination failed.

After EOF, the source digest from that single transfer pass is the reference for
every destination. Each published destination is independently reopened, given
an `F_NOCACHE` request, read completely, hashed, and compared with that reference.
There is no destination-count-multiplied source verification read. Metadata-only
read-only source descriptor checks before readback and the attempt-wide frozen
manifest comparison preserve source-stability protection without consuming the
source byte stream again.

## Physical-storage topology

V3 resolves topology behind the injectable `StorageTopologyResolving` seam.
Tests use deterministic synthetic identities; CI does not need two SSDs.
Production uses macOS `/usr/sbin/diskutil info -plist` facts for the mounted
volume, follows `APFSPhysicalStores` to each backing store and then its
`ParentWholeDisk`, and records the whole device's I/O Registry device-tree path
qualified by its current BSD whole-disk identifier. If the I/O Registry identity
is unavailable, topology stays unknown. Volume names, mount
paths, folders, partition identifiers, and volume UUIDs are never treated as
proof of independence.

Only a single confidently resolved physical leaf can participate in a
`samePhysicalDevice` or `differentPhysicalDevices` relationship. Network
filesystems, disk images, virtual media, RAID, multi-store APFS/Fusion or other
composite devices, missing system facts, and ambiguous bridges resolve to
`unknown`. Unknown is evidence of unresolved topology, not independence.

Topology is reported as facts for the caller. It does not alter destination
`VERIFIED_STRONG`/`VERIFIED_DEGRADED` integrity and durability classification,
and the worker does not implement PP-018's Safe-to-clear rule.

## TransferEvidence V3

The final JSON contains:

- protocol, job, and attempt identity;
- worker semantic version/build and exact upstream provenance;
- start/end timestamps and a typed terminal status;
- an explicit `VERIFIED_STRONG`, `VERIFIED_DEGRADED`, or `FAILED` verification
  outcome, separate from process completion;
- source file/byte summary, transfer-read-pass count, bytes read, and observed
  maximum chunk size;
- separate summaries keyed by stable destination request ID;
- source/destination storage identities and pairwise destination physical-device
  relationships (`samePhysicalDevice`, `differentPhysicalDevices`, or `unknown`);
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

V1 and V2 job specs are rejected explicitly as unsupported by the V3 worker.
This deliberate protocol bump prevents a V2 caller from silently ignoring the
new source-read and storage-topology evidence required by PP-017.

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

The worker also requires exactly one recorded transfer-byte pass per frozen
source file, total transfer bytes equal to the frozen manifest byte total, and
no observed chunk larger than 4 MiB. Missing or inconsistent source-read facts
emit `source-read-incomplete` and force `FAILED`.

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
These outcomes classify destination integrity/durability evidence only. Two
strong destinations can still have `samePhysicalDevice` or `unknown` topology.

## Guarantee table

| Evidence step | What it proves | What it does not prove |
| --- | --- | --- |
| Copy completion | The write loop reached EOF and the temporary file had the expected length. | That bytes match, are durable, or were published. |
| Exact result-set validation | There is exactly one terminal result for every frozen source-relative-path × requested-destination-ID pair; destination counts and successful byte totals reconcile to that plan. | Byte correctness, durability, or storage independence without the other evidence steps. |
| Single transfer source SHA-256 | Each source file's transfer bytes were read once and produced the reference digest used by all destinations. | Destination correctness or physical independence without destination readback/topology evidence. |
| SHA-256 destination match | The independently reopened destination produced the same SHA-256 digest as the one-pass transfer source digest; the temporary file was also checked before publication. | Physical media residence, future readability, or device independence. |
| Ordinary synchronize/fsync | The OS accepted its normal file-data synchronization request. | That a device with volatile caches committed bytes to NAND/platter. |
| Darwin `F_FULLFSYNC` success | After data writing, mtime preservation, temporary SHA-256, and source-stability checks, macOS accepted the stronger full-sync request for that pre-publication inode state. | Absolute physical persistence; later publication metadata and bridges, filesystems, firmware, and hardware remain separately bounded. |
| No-overwrite publication + identity binding + directory fsync | The final name was claimed without replacing an existing item, still named the inode claimed by this attempt, and the OS accepted synchronization of its containing directory metadata. | Atomic visibility on exFAT, immunity from later mutation by another process, or power-loss proof across every storage layer. |
| Full `F_NOCACHE`-requested readback | An independently reopened final descriptor returned the complete expected byte count and matching SHA-256 while the OS-cache-bypass request was active. | A guaranteed physical reread from flash/platter; `F_NOCACHE` is an OS-cache-bypass request only. |
| Physical-leaf relationship | macOS storage facts resolved two destinations to the same or different single underlying physical leaf. | Integrity, durability, Safe-to-clear, or independence when the result is `unknown`. |

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
decodable evidence artifact matching its job and attempt. Typed
`publication-interrupted` and `publication-ownership-lost` errors distinguish
post-claim ambiguity from an ordinary pre-publication failure. A process crash
can still prevent final evidence from being written; a partial exFAT final file
or retained `.bitmatch.tmp.` file is deliberately treated as unresolved residue,
never inferred success and never automatically deleted by pathname.

## Explicitly deferred work

- PP-018: Post Prep process launch, SQLite/project-state integration, bounded
  orchestration, reconciliation, and evidence acceptance.
- PP-019: production qualification on physical cards, readers, hubs, and drives.

There is **no Safe-to-clear authority in PP-017**. Neither worker success nor its
fixture tests authorize erasing or formatting source media.

## Provenance

The exact upstream fork point is
`3debabe2e1049c7e02ee5f3587464894f3b190d5` from
`https://github.com/mikecerisano/Bitmatch`. See [UPSTREAM.md](../UPSTREAM.md) and
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).

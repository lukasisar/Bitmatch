# BitMatch transfer worker protocol V4 — exact source subset

PP-068 adds one bounded operation to the already-qualified V3 transfer worker: copy exactly a caller-supplied set of source-root-relative regular files.

This document is additive to `docs/TRANSFER_WORKER_PROTOCOL.md`. All durability, publication, SHA-256, source-stability, full destination readback, topology, fan-out, cancellation and no-clobber rules documented there continue to apply.

## Compatibility contract

Protocol selection is explicit.

- **V3** means whole-source transfer. A V3 request must not contain `includeRelativePaths`. The worker enumerates the accepted source root exactly as before PP-068.
- **V4** means exact-subset transfer. A V4 request must contain a non-empty `includeRelativePaths` list.
- There is no implicit "latest protocol" behavior.
- The Post Prep PP-036 fresh-card path remains pinned to V3. PP-068 does not promote fresh-card Copy to V4.

`capabilities --json` advertises supported protocol versions `[3, 4]` and the V4 capability `exact-relative-path-subset-v4`. A caller that requires V4 must negotiate version 4 and that capability explicitly.

## V4 request field

A V4 job adds:

```json
{
  "protocolVersion": 4,
  "includeRelativePaths": [
    "DCIM/100MEDIA/C0001.MP4",
    "PRIVATE/M4ROOT/CLIP/C0001M01.XML"
  ]
}
```

The list is canonicalized by raw UTF-8 byte order. It is exact and duplicate-free. The worker rejects before destination writes if the set is empty or contains an absolute path, home-relative path, backslash separator, NUL, empty path component, `.` component, `..` component, traversal, duplicate raw path, symlink traversal, missing final file or a non-regular final item.

Names are not lowercased and are not Unicode-normalized. Distinct filesystem names remain distinct.

## Direct source selection

V4 does not construct a staging tree, symlink farm or temporary source root. It resolves each selected relative path directly beneath the real source root and freezes the resulting `FileEntry` manifest.

That manifest is then consumed by the same `SharedFileOperationsService` and fan-out path as V3. In practice this means a V4 subset still receives:

- read-only source behavior;
- one-source-read fan-out;
- worker-owned temporary destination writes;
- SHA-256 verification;
- opened-source stability checks;
- APFS hard-link/no-clobber publication where supported;
- exFAT/FAT exclusive-name publication where hard links are unavailable;
- durability flush facts;
- full independent destination readback;
- physical-storage topology facts;
- interruption/failure semantics already qualified for the shared path.

Excluded source files are not members of the V4 manifest. They are not copied and do not appear in V4 per-file detail evidence.

## Request/artifact binding

For V4 the final `TransferEvidence` envelope echoes the exact canonical `includeRelativePaths` list. The detailed JSONL contains one record per selected relative path per requested destination.

This gives Post Prep two independent checks before accepting evidence:

1. the envelope's V4 selected set must equal the persisted requested set exactly;
2. the union of detailed relative paths must equal that same selected set exactly for every destination.

A missing selected path, unexpected extra path, duplicate detail row, different job/attempt, wrong protocol version, or V3 artifact presented as V4 proof fails closed.

V3 evidence omits `includeRelativePaths`.

## Recovery

The logical selected set belongs to the durable caller request, not to a later source rescan. Post Prep persists protocol version 4 plus the canonical `includeRelativePaths` before launching the worker. Retry and reconciliation therefore replay or validate the same logical operation even if the physical card is subsequently rescanned.

## Production qualification gate

V4 is not production-qualified by deterministic tests alone. PP-068 remains open until the exact BitMatch and Post Prep candidate commits pass the bounded local PP-019-style qualification on macOS using representative media, an APFS destination, an exFAT destination and two genuinely independent physical devices for independence claims.

The qualification must prove at minimum:

- selected input bytes equal selected destination bytes by an independent SHA-256 calculation;
- excluded source files are absent from the operation output;
- source masters remain unchanged;
- mixed old/new reused-card-style roots copy only the selected new/changed files;
- primary plus sidecar/support selections work together;
- Unicode and case-preserving path behavior;
- interruption/retry/reconcile behavior;
- conflict/no-clobber behavior;
- two-destination fan-out and physical-topology evidence;
- exFAT-safe publication remains correct.

Production promotion requires Lukas's explicit approval of that exact qualified pair.
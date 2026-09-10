# Upstream provenance

BitMatch Transfer Worker is maintained as a fork of the MIT-licensed BitMatch
project. This file is the durable record of the fork point and local divergence.

| Field | Value |
| --- | --- |
| Upstream repository | `https://github.com/mikecerisano/Bitmatch` |
| Controlled fork | `https://github.com/lukasisar/Bitmatch` |
| Fork date | 2026-09-10 |
| Upstream default branch | `main` |
| Exact fork commit | `3debabe2e1049c7e02ee5f3587464894f3b190d5` |
| Reviewed baseline | `3debabe2e1049c7e02ee5f3587464894f3b190d5` |
| First divergence commit | `edcfac29f2ed40a19a7c7e1e9b7c63d76c72389b` |
| Divergence branch | `pp-015-transfer-worker-boundary` |
| PP-015 review pull request | `https://github.com/lukasisar/Bitmatch/pull/1` |

On 2026-09-10, upstream `main` was fetched before the fork point was selected.
It still resolved to the reviewed baseline, so there were no intervening upstream
commits or safety changes to reconcile.

## Local patch set

The first divergence establishes a Foundation-only macOS worker package and
versioned job/evidence contract while reusing BitMatch's existing
`SharedFileOperationsService`, `FileCopyService`, `SafetyValidator`, and
`SharedChecksumService` implementations. It also separates transfer primitives
from `SharedModels.swift`, makes verification scheduling explicit for headless
callers, and adds deterministic worker fixtures and tests.

PP-016 strengthens that worker with durable publication/readback evidence and
exact manifest × destination result accounting. PP-017 builds on merged commit
`f0210efdde188912625376ece0179b5e6b3d5a7f`: every source file now has one bounded
transfer-byte pass fanned out to all requested destinations, and protocol V3
reports conservative macOS physical-leaf topology separately from integrity and
durability outcomes. These changes do not move the recorded upstream fork point.

Future updates must record any new upstream base or cherry-picked upstream
revision here. The PP-015 pull request is intentionally review-only and must not
be merged as part of this issue.

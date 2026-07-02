# Contributing to Sort

Thanks for your interest. Sort is a native macOS app that browses any folder's photos
grouped by face — **on-device and read-only**. That last part is the one rule everything
else bends around.

## The one invariant

**Sort never modifies the source tree.** It never edits, moves, renames, or drops sidecar
files next to a user's photos. The *only* write to a scanned file is a user-initiated **Move
to Trash** (recoverable), routed through the single `SourceTrash` path. All app state lives in
Application Support + SQLite. PRs that write into the source tree will not be merged. This is
guarded by `ReadOnlyInvariantTests` and `TrashTests` — keep them green.

## Setup

- macOS 15+, Apple Silicon, Xcode 16+ (Swift 6 toolchain).
- `swift build` · `swift test` · `swift run sort-app` — no extra tooling; SwiftPM fetches deps.
- `SORT_FRESH=1 swift run sort-app` wipes the index + onboarding for a clean first-run test.

## Before you open a PR

1. `swift test` is green (CI runs `swift build && swift test` on `macos-15`).
2. New non-trivial logic ships with a test — match the existing `Tests/SortKitTests` style
   (in-memory `AppDatabase`, no fixtures/frameworks).
3. Keep it lean: prefer the standard library / Apple frameworks over new dependencies, and
   delete more than you add where you can.
4. Keep docs in sync with code (`AGENTS.md` is canonical; `README.md` is the user-facing entry;
   [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) has the full design rationale if you're touching
   something non-trivial).

## Reporting bugs / ideas

Use GitHub Issues on this repo — bug or idea, no template required.

## Project layout

```
Sources/SortKit/   engine — Data (GRDB), FileAccess, ML (Vision/Core ML), Clustering, IndexService
Sources/sort/      CLI (swift-argument-parser)
Sources/SortApp/   SwiftUI + AppKit macOS app
Tests/SortKitTests/
```

## The face-embedding model

The packaged `.app`/`.dmg` bundles **AuraFace v1** (Apache-2.0) — commercial-clean. A plain
`swift build` uses Apple Vision (no model, no license issue). ArcFace `buffalo_l` is an optional
higher-accuracy swap but is **non-commercial** (personal use) — see [docs/MODELS.md](docs/MODELS.md).
Don't commit model weights (`.gitignore` covers them), and don't attach a **buffalo_l**-bundled `.dmg`
to a public release. (EdgeFace is also non-commercial — CC BY-NC-SA — not a commercial swap.)

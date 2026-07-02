# AGENTS.md — sort

A native **macOS** app that turns any folder or mounted drive into a Google-Photos-style
**browse-by-person** view, **without moving or modifying the source files**. `sort` is a
read-only index/viewer layer: it scans photos (recursively, incl. external SSDs), detects and
embeds faces on-device, clusters them into people, and lets you browse by face.

> Status: **v0.1 — working engine + CLI; SwiftUI app builds.** The full pipeline (scan → detect →
> embed → cluster → browse) is implemented as a **Swift Package** with 76 passing tests. The 6
> pivotal decisions are confirmed (see [docs/DECISIONS.md](docs/DECISIONS.md)).
>
> Build/test/run: `swift build` · `swift test` · `swift run sort scan <folder>` · `swift run sort-app`.
>
> **Layout note:** we shipped as a SwiftPM package (`Sources/SortKit` engine + `sort` CLI + `SortApp`
> GUI), not the standalone `.xcodeproj` originally sketched in ARCHITECTURE.md — this keeps the engine
> headlessly testable and the GUI buildable with no xcodegen/brew. `./packaging/make_app.sh` assembles
> a **sandboxed**, double-clickable `Sort.app` (D2 revised): App Sandbox + security-scoped read-write
> bookmarks — the in-app folder picker is the grant, persisted across launches (no Full Disk Access,
> no cert). Ad-hoc signing runs it locally for free; distributing to others needs a paid Developer ID
> / App Store account (`SIGN_ID` + notarization). The `sort` CLI stays unsandboxed.
>
> **UI (D9, Apple-Photos-native):** default landing screen is the **Library** (`LibraryView`, the
> Photos side of the `ScreenToggle`); `CollectionsView` is the other toggle — quick-access pills + an
> auto-detected CATEGORIES grid. **Live cards:** People & pets, Screenshots, Documents, Places, No
> faces (tap → `CategoryDetailView`, each shows a real representative thumbnail); Videos + Identity &
> cards are "Soon". **Places** is populated from EXIF GPS read during scan (`ImageLoader.metadata`).
> Person browse = `PhotosBrowseView` (sidebar + `PhotoGridView`). Palette in `Theme.swift` (warm
> paper); `design/` holds the wireframe.
>
> **Testing a clean run:** `SORT_FRESH=1 swift run sort-app` wipes the index + onboarding flag so you
> start from the first-run experience every time (Advanced Settings → "Reset & start fresh" does the
> same in-app). The on-disk index persists across normal launches, so re-tests accumulate state —
> reset before judging grouping quality. One `ClusteringConfig` (from Settings) is used by both scan
> and every Review correction, so people don't shift between actions.
>
> **Grouping quality lever:** ArcFace embeddings are only discriminative on faces warped to its
> canonical 5-point template — `FaceAligner.embeddingCrop` does this similarity transform (the
> detector's `landmarks5`). A plain bbox crop (the pre-fix path) collapsed identity separation
> (same-person spread ~0.60 vs different-people ~0.09). Default cluster threshold is **0.45** (tuned on
> real photos: same-identity ≤0.30, distinct ≥~0.45). Don't revert to a bbox crop for the embedder.
>
> **Photo interactions:** click → in-app `LightboxView` (zoom, ←/→, info, Reveal, Trash); ⌘-click /
> ⇧-click select → Move to Trash; `Highlight` overlays the person's face box (#6). Folders sheet adds
> a **Remove** (untrack) action.
>
> **Classifier (F4 / D8):** `PhotoClassifier` (Apple Vision `VNClassifyImageRequest` +
> `VNDetectDocumentSegmentationRequest` + screenshot metadata; Places from GPS) runs during scan and
> as a backlog pass; `sort reclassify` categorizes an already-indexed library. No model download.
>
> **Self-learning grouping:** every correction — Same / Different (review) and **"Not this person"**
> (select photos in a person → re-evaluated) — is a persisted `faceConstraint` (must-/cannot-link)
> that `AgglomerativeClustering` re-applies on **every full re-cluster** (must-link transitive,
> cannot-link enforced per merge). Corrections are never silently reverted: a full re-cluster re-applies
> all constraints, and the incremental scan path (>2000 faces) only ever *adds* brand-new faces — it
> never moves an already-grouped face, so a merge/split can't come undone on a rescan. The grouping
> improves with use; the Review screen shows "learned from N corrections" (`IndexService.learnedCorrections`).

## The one invariant

**Read-only by default; one sanctioned write (D7).** The app never edits, moves, renames a source
file in place, and never drops sidecar/thumbnail files into the scanned tree. All app state (index,
embeddings, clusters, thumbnail cache) lives in the app's own Application Support directory + SQLite
DB. The **only** write to the source tree is a user-initiated **Move to Trash** (recoverable),
routed through the single audited `SourceTrash` path; `SourceAccess` still exposes no in-place write
API. Guarded by `ReadOnlyInvariantTests` (scan/read never mutate) + `TrashTests` (only the target
moves, to Trash; siblings byte-identical).

## Where to read

| Doc | What it holds |
|---|---|
| [README.md](README.md) | Product vision, the read-only promise, reference UX (Google Photos) |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Recommended stack, end-to-end pipeline, project tree, MVP scope, risks |
| [docs/DECISIONS.md](docs/DECISIONS.md) | The 6 pivotal decisions + options |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to contribute, the one invariant, PR checklist |
| [docs/MODELS.md](docs/MODELS.md) | Face-embedding model licensing + how to build/swap them |

## Stack (decided 2026-06-20)

Swift 6 + SwiftUI shell · **SwiftUI `LazyVGrid`** for the photo grid (as-built; an AppKit
`NSCollectionView` is the planned upgrade for 100k+ libraries, not yet wired) · **Apple Vision**
for face detect/landmarks/quality · **Core ML, bundled AuraFace v1 (512-d, Apache-2.0)** for
identity embeddings — converted ONNX→Core ML with `coremltools`, kept swappable behind
`embedding_model`/`embedding_dim` columns (a Python/MLX `SidecarEmbedder` is a documented
escape-hatch, not yet built) · **threshold agglomerative +
nearest-centroid incremental** clustering with stable `person_id`, biased **conservative
(over-split)** · **SQLite via GRDB.swift** (WAL `DatabasePool`, `ValueObservation`) ·
ImageIO/QLThumbnail cache · shipped as a **sandboxed, ad-hoc-signed `.app`/DMG** (App Sandbox +
security-scoped read-write bookmarks, D2 revised; Mac App Store path kept open behind the
file-access abstraction; notarized Developer ID distribution is the paid step for sharing beyond
this Mac).

> ⚠️ The DMG bundles **AuraFace v1** (Apache-2.0, commercial-clean — free to redistribute). ArcFace
> **buffalo_l** is an optional higher-accuracy *personal-use* swap — non-commercial, never ship it in a
> public DMG. (EdgeFace is also non-commercial — CC BY-NC-SA — not a commercial option either.)

## The pipeline

`grant & persist access → recursive incremental scan → Vision detect+gate → align+Core ML embed →
agglomerative/incremental cluster (stable IDs) → SQLite index + thumbnail cache → browse-by-person UI`

## Conventions

- AGENTS.md is canonical; `CLAUDE.md` is just a `@AGENTS.md` import.
- Keep docs in sync with code as it lands. Prune dead code/stale docs as you go.
- Establish `graphify-out/` once there's Swift source (verify Swift AST coverage first), then query
  it before grepping.
- Never read `secrets/` or any `.env`.

---

*Created 2026-06-20 from the `sort-project-research` workflow.*

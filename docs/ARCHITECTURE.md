# sort — Architecture

`sort` turns a folder or mounted drive into a Google-Photos-style browse-by-person view without
touching the source files. This document explains what the system does end-to-end and why it's
built the way it is. For the pivotal decisions and the options considered, see
[DECISIONS.md](DECISIONS.md); for embedder details and licensing, see [MODELS.md](MODELS.md).

## Overview

`sort` is a native Swift 6 + SwiftUI app (with AppKit interop for parts of the photo grid). It uses
Apple **Vision** for face (and pet) detection, a bundled **Core ML** model for the face-identity
embedding Vision doesn't provide, **threshold agglomerative clustering with a stable-ID incremental
assigner** to group faces into people, and **SQLite via GRDB.swift** as the index. Distribution is a
sandboxed, ad-hoc-signed `.app`/DMG using App Sandbox and security-scoped bookmarks.

### Why native Swift, not a web/Electron/Tauri stack

The app has two hard requirements that both favor native Swift and penalize a web-based stack:
heavy on-device ML over libraries that can run to 100k+ photos, and a smooth thumbnail grid at that
scale. Vision and Core ML are free, Neural-Engine-accelerated, and run in-process — exactly their
intended use. A Google-Photos-grade thumbnail grid is the canonical `NSCollectionView` use case (cell
reuse, prefetch, Metal-backed decode); SwiftUI's `LazyVGrid` starts to jitter and balloon memory well
past that scale, and a WebView grid hits the same ceiling with image decode happening inside the
WebView. Tauri would turn every ML call into objc2 FFI marshaling, and Electron+Python has the
heaviest footprint and the worst fit for the Neural Engine. Even within native, this is why the app
is a SwiftUI shell for chrome/navigation with AppKit reserved for the hot grid path.

### Why sort owns the face-identity embedding

Apple Vision has **no public face-identity embedding**. Vision gives bounding boxes, 76-point
landmarks, pose (roll/yaw/pitch), and a capture-quality score — all free on the Neural Engine — but
the vector that actually distinguishes one person from another lives in Apple's private
FaceKit/Photos stack, not in the public Vision API. `VNGenerateImageFeaturePrint` is a *general
image* descriptor: it clusters by "same photo session / outfit / lighting," not by person, so it
can't serve as the identity engine. `sort` therefore owns this piece itself: it aligns each detected
face to a canonical pose and runs a bundled Core ML face-recognition model to produce a 512-d
embedding. This embedding-plus-clustering engine is the part of the system with no off-the-shelf
answer, and it's treated as a swappable component from the start — every embedding is tagged with
`embedding_model` / `embedding_dim` so a model swap is detectable and triggers a clean re-index
rather than silently mixing incompatible vectors.

(A local Python/MLX sidecar embedder over HTTP was considered as a prototyping/escape-hatch path,
since it can reach slightly higher accuracy on hard poses. It isn't built — the native Core ML path
covers current needs — but the embedder is defined behind a `FaceEmbedder` protocol specifically so
a sidecar implementation could be dropped in later without touching the rest of the pipeline.)

### Why SQLite via GRDB.swift

The read-only constraint — "grouping lives in the app's own index, never in the filesystem" — maps
directly onto a local SQLite database: a repository-plus-cache layer that owns all derived state
(photos, faces, embeddings, person clusters) while the source files stay untouched. GRDB.swift
reaches raw-C-API speed while adding what a long-running scan needs: a WAL `DatabasePool` so a
multi-hour background scan never blocks the live browsing UI, `ValueObservation` so the People grid
updates as clusters form, and migrations. Each 512-d embedding is stored as a 2048-byte Float32 BLOB;
brute-force cosine similarity via Accelerate/vDSP stays well under 150ms even at 100k photos, so no
approximate nearest-neighbor index is required for the current scale (see "Not yet built" below for
where that changes).

### Why agglomerative + stable-ID clustering, not DBSCAN/HDBSCAN

Clustering mirrors Apple Photos' own shipping approach: **threshold-based agglomerative clustering**
(average/median linkage) for the initial batch, then a **nearest-centroid incremental assigner**
backed by a persisted, never-reissued `person_id` so re-scans never renumber people. Density-based
methods like DBSCAN/HDBSCAN were ruled out because they dump rare-but-real people — someone who
appears in only two or three photos — into a "noise" bucket, which is unacceptable for a personal
photo library where every person matters. Agglomerative clustering with a fixed similarity threshold
keeps every face assigned to some cluster and auto-discovers the number of people without needing
that count up front.

### The conservative, over-split merge bias

Same-person similarity and different-people similarity separate around **0.35–0.45 cosine
distance**, and that boundary is dataset- and model-specific — it shifts with the embedder and the
demographics of the photo library, so it's tuned empirically rather than hardcoded as a universal
constant. Clustering is deliberately biased **conservative (over-split rather than over-merge)**:
merging two groups that are really the same person is a single tap in the review flow, but
un-merging a group that wrongly fused two different people is tedious and erodes trust in the whole
system. Every user correction — "Same" or "Different" in the review queue, or "Not this person"
pulled out of a group — is persisted as a must-link or cannot-link constraint and re-applied on
**every** full re-cluster, so a correction is never silently undone by a later rescan. The
incremental scan path (used once a library exceeds ~2000 faces) only ever adds newly-detected faces
to existing centroids — it never moves an already-grouped face — so a merge or split a user made
can't come undone between full re-clusters either.

### Why a sandboxed app with security-scoped bookmarks

`sort` is a personal tool meant to scan arbitrary external folders and mounted SSDs, and it also
needs to write — moving photos to the Trash is the one sanctioned write to the source tree. App
Sandbox turns out to fit both needs well: the system folder picker (`NSOpenPanel`) *is* the grant,
and a read-write security-scoped bookmark persists it across relaunches, including on external SSDs,
with no Full Disk Access and no manual re-authorization. It's also the model the Mac App Store
requires, so a future MAS build is a distribution step rather than a rewrite. File access goes
through an abstraction layer (`FileAccess`) so the underlying grant mechanism can change without
touching the rest of the pipeline. File identity is keyed on `(volume_uuid, file_id)` plus mtime and
size, with a content-hash backstop, so moved or renamed files update in place instead of losing
their cluster assignment and getting re-embedded from scratch. Ad-hoc signing runs the sandboxed app
on the building Mac for free; sharing it with others still needs a paid Apple Developer ID for
notarization, the one remaining paid step.

## The pipeline

```
grant & persist access → scan → detect → align + embed → cluster → SQLite index → browse
```

1. **Grant & persist access** — the user picks a folder or drive via the system file picker; a
   read-write security-scoped bookmark is stored in the index so access survives relaunches,
   including on external SSDs.
2. **Scan** — recursively enumerate image files, filtered by UTType; read `(volume_uuid, file_id)`,
   mtime, and size for each file, and diff against the index so an already-processed, unchanged file
   is skipped on a rescan. Progress is shown live and the UI stays responsive throughout.
3. **Detect** — Apple Vision runs face and pet detection, landmarks, and capture-quality scoring on
   the Neural Engine; low-quality faces (blurry, extreme pose) are gated out before embedding to keep
   cluster purity high.
4. **Align & embed** — each face is aligned via a 5-point similarity transform to the embedder's
   canonical 112×112 template, then run through the bundled Core ML model to produce a 512-d
   embedding, stored as a Float32 BLOB alongside its `embedding_model`/`embedding_dim`.
5. **Cluster** — embeddings are L2-normalized and grouped by threshold agglomerative clustering on
   the initial pass; later scans assign new faces to the nearest existing centroid. Must-link and
   cannot-link constraints from user corrections are re-applied on every full re-cluster, and each
   person keeps a stable `person_id` across rescans.
6. **SQLite index** — photos, faces, persons, and their join tables persist via GRDB (WAL mode);
   thumbnails and face crops are cached on disk in Application Support, keyed by content hash, and
   fronted by an in-memory cache for smooth scrolling.
7. **Browse** — a People grid of face chips, per-person photo grids, a person header (cover photo,
   count, rename), a "Same or different person?" review queue for borderline pairs, and multi-person
   filtering. The grid updates live via `ValueObservation` as clustering runs in the background.

## Project layout

See [README.md](../README.md#project-layout) for the actual SwiftPM package layout
(`Sources/SortKit`, `Sources/sort`, `Sources/SortApp`, `Tests/SortKitTests`, `packaging/`, `tools/`).

## Current status

`sort` is implemented as a SwiftPM package — `SortKit` (engine), `sort` (CLI), and `SortApp`
(SwiftUI/AppKit GUI) — with 76 passing XCTest tests (`swift test`). The full pipeline described above
is built and working: scan, detect, align+embed, cluster, index, and browse. Packaging
(`packaging/make_app.sh`, `packaging/make_dmg.sh`) builds a sandboxed, ad-hoc-signed `.app`/DMG, with
notarized Developer ID signing wired in as the paid step for sharing beyond the building Mac.

### Not yet built / future directions

- **sqlite-vec ANN index** — brute-force cosine is fast enough at current library sizes; an
  approximate nearest-neighbor index is the natural next step if libraries grow large enough that
  merge-suggestion lookups start to slow down.
- **Cross-Mac index sync** — the index currently lives on one machine; syncing it across multiple
  Macs is unbuilt.
- **Mac App Store submission** — notarized Developer ID distribution and MAS submission both need a
  paid Apple Developer account; the signing/notarization scripts are already wired, this is a
  distribution step rather than an engineering one.
- **MLX sidecar embedder** — a local Python/MLX sidecar (e.g. InsightFace over HTTP) remains a
  documented escape hatch for prototyping alternate embedders, but has not been implemented; the
  `FaceEmbedder` protocol is designed to accommodate it without touching the rest of the app.

## Key risks & traps

- Vision exposes no face-identity embedding, so the embedding-plus-clustering engine is the highest-
  risk part of the system, not the UI. The embedder is a swappable component guarded by
  `embedding_model`/`embedding_dim` columns for exactly this reason.
- The cluster similarity threshold is dataset-specific (roughly 0.35–0.45 cosine distance for the
  current embedder) and shifts with the model and the demographics of the photo library — it needs
  validation against real photos rather than being treated as a universal constant. The bias stays
  conservative, since over-merging is much harder to recover from than over-splitting.
- Stable person IDs don't fall out of any clustering algorithm for free: without an explicit
  centroid-assignment step and a persisted `person_id` table, every rescan would renumber people and
  break the UI. This was the single biggest implementation trap.
- Manual must-link/cannot-link corrections have to be re-applied on every incremental and full
  re-cluster pass, or a later scan can silently re-merge a person a user deliberately split.
- The read-only invariant is safety-critical: any write into the source tree (thumbnails, sidecar
  files, in-place edits) would violate the app's central promise. All writes are routed through one
  audited boundary and covered by a dedicated test class (`ReadOnlyInvariantTests`, `TrashTests`).
- Thumbnail memory is a classic OOM risk: full-resolution images are never bound directly to grid
  cells — everything goes through downsampling, on-disk caching keyed by content hash, and
  cancellable async loads.
- The first full index of a 100k+ photo library (decode + detect + embed) is a heavy one-time batch
  that needs a resumable, throttled job with visible progress to avoid thermal and UX problems.
- `file_id`/inode identity is per-volume, and APFS safe-save can reassign inodes on edit, so file
  identity is keyed on `(volume_uuid, file_id)` with a content-hash backstop to keep clusters attached
  to edited or moved files; network volumes (SMB/NFS) may need a path+size+mtime fallback instead.
- The bundled embedder's license determines what can ship in a public DMG. ArcFace `buffalo_l`
  weights are non-commercial (personal use only); EdgeFace is also non-commercial (CC BY-NC-SA). The
  bundled default is **AuraFace v1** (Apache-2.0, commercial-clean, ~125 MB) specifically because it's
  safe to redistribute — see [MODELS.md](MODELS.md) for the full licensing picture.
- sqlite-vec's loadable extensions complicate sandboxing and notarization; the BLOB-plus-Accelerate-
  cosine approach avoids that entirely and is sufficient at current scale, which is why it's deferred
  rather than adopted preemptively.

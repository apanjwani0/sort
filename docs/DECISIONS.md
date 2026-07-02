# sort — Decisions log

Pivotal choices that shape everything downstream. The chosen option is marked ✅.

> Decided 2026-06-20, all 6 finalized the same day. Full reasoning in
> [ARCHITECTURE.md](ARCHITECTURE.md).

## Resolved summary

| # | Decision | Chosen |
|---|---|---|
| D1 | Embedder location | **Native Core ML, bundled model** |
| D2 | Distribution | **Sandboxed `.app`/DMG + security-scoped bookmarks** (revised from non-sandboxed DMG) |
| D3 | Clustering | **Agglomerative + stable-ID incremental** |
| D4 | Merge bias | **Conservative (over-split)** |
| D5 | DB layer | **GRDB.swift** |
| D6 | Embedder model | **ArcFace ResNet50 (buffalo_l, 512-d)** — accuracy over the small-model rec |

> ⚠️ **D1 × D6 coupling:** a bundled Core ML model adds ~100+ MB to the app. The embedder is swappable
> behind `embedding_model` / `embedding_dim`. **As-built:** the public DMG bundles **AuraFace v1**
> (Apache-2.0, commercial-clean) — buffalo_l is an optional non-commercial *personal* swap, not shipped.
> (EdgeFace, once eyed as the commercial option, is also non-commercial — CC BY-NC-SA.) Convert ONNX →
> Core ML with `coremltools`; the Python/MLX sidecar (`SidecarEmbedder`) remains a documented escape hatch.

---

### D1 — Where should the face-identity embedding model run?
**Status:** ✅ DECIDED — **Native Core ML, bundled model** (2026-06-20)
*Why it matters:* Vision has **no** identity embedding, so this engine is ours to own — it's ~30% of the effort and the core product risk.

- ✅ **Native Core ML, bundled model** — one double-click app, on the Neural Engine, App-Store-viable; some conversion + license vetting.
- **MLX Python sidecar** (local Python/MLX) — best out-of-box accuracy, but adds a Python/launchd runtime and blocks the App Store.
- **Sidecar to prototype, Core ML to ship** — validate quality fast in Python, then bake into Core ML (both emit 512-d, so the app code is identical). Most total work.

### D2 — How should v1 be distributed?
**Status:** 🔄 REVISED — **App Sandbox + security-scoped bookmarks** (2026-06-21), superseding the
original non-sandboxed-DMG choice.

> **Why the change:** we want in-app folder grants with **read + write** (to move photos to
> Trash), persistent with no manual steps, and a path to real distribution. App Sandbox is exactly
> that: the NSOpenPanel pick *is* the grant, a read-write security-scoped bookmark persists it
> (keyed to the bundle id, so it survives rebuilds — no Full Disk Access, no cert, no terminal). It's
> also the model the Mac App Store requires.
>
> Entitlements (`packaging/sort.entitlements`): `app-sandbox`, `files.user-selected.read-write`,
> `files.bookmarks.app-scope`. `make_app.sh` ad-hoc signs **with** these → runs on this Mac, free.
> **Distribution to others still needs the $99 account** (App Store, or notarized Developer ID — set
> `SIGN_ID`); that's the only remaining paid step, deferred until you ship beyond this Mac.
> The `sort` CLI stays unsandboxed (dev/headless, plain paths).
*Why it matters:* Determines the file-access friction for scanning arbitrary folders / external SSDs.

- **Notarized non-sandboxed DMG** (original choice, superseded) — frictionless folder/SSD access; no per-folder grants or fragile bookmarks. Ideal for a personal tool.
- ✅ **Sandboxed `.app`/DMG, App Sandbox + security-scoped bookmarks** — the NSOpenPanel grant persists across launches with no manual steps, and it's the model the Mac App Store requires.

### D3 — What clustering strategy groups faces into people?
**Status:** ✅ DECIDED — **Agglomerative + stable-ID incremental** (2026-06-20)
*Why it matters:* Stable IDs + respecting user merge/split are the hard parts no batch algorithm gives for free.

- ✅ **Agglomerative + stable-ID incremental** — threshold linkage batch, then nearest-centroid assignment with persisted `person_id` + must-link/cannot-link. Apple Photos' approach.
- **HDBSCAN / DBSCAN** — auto-discovers count but dumps rare-but-real people into "noise" and gives no stable IDs across rescans.
- **Chinese Whispers (dlib)** — one-call, good accuracy, but nondeterministic and no incremental/stable-ID story. Prototype only.

### D4 — How aggressively should clusters auto-merge?
**Status:** ✅ DECIDED — **Conservative (over-split)** (2026-06-20)
*Why it matters:* Merge is a one-tap fix; un-merge is painful. Bias protects trust.

- ✅ **Conservative (over-split)** — more separate groups, borderline pairs surfaced in the review card; merging is one tap.
- **Aggressive (over-merge)** — fewer/larger groups, but wrongly-fused people need tedious manual splitting and erode trust.

### D5 — Which SQLite layer for the index/cache?
**Status:** ✅ DECIDED — **GRDB.swift** (2026-06-20)
*Why it matters:* A long background scan must not block the live browsing grid.

- ✅ **GRDB.swift** — C-API speed, WAL `DatabasePool` (writer never blocks reads), `ValueObservation` for live grid updates, migrations.
- **SQLite.swift** — clean DSL but ~5× slower on the dominant ops and no built-in observation.
- **Raw libsqlite3** — max control, zero deps, but you reimplement migrations/observation/threading. Wrong altitude.

### D6 — How fast/accurate should the v1 embedder be?
**Status:** ✅ DECIDED — **ArcFace ResNet50 (buffalo_l, 512-d)** — chose accuracy over the small-model rec (2026-06-20)
*Why it matters:* Trades bundle size + scan speed against cluster purity on hard poses.

- **MobileFaceNet / EdgeFace (small, 512-d)** — ~16 MB, thousands of embeddings/sec, clean Core ML conversion. (Note: EdgeFace is **non-commercial** — CC BY-NC-SA — so not a commercial swap, contrary to the original assumption. The commercial-clean choice is AuraFace v1, Apache-2.0.)
- **ArcFace ResNet50 (buffalo_l, 512-d)** — best accuracy (~99.6% LFW) but 326 MB, fiddlier conversion, non-commercial license. Best via the sidecar.

---

These decisions are treated as binding going forward.

---

## Post-v0.1 feedback decisions (2026-06-21)

From real-usage feedback after v0.1.

### D7 — In-app deletion vs the read-only invariant
**Decided:** **Move to Trash.** Multi-select delete across folders is allowed, but only via macOS
Trash (recoverable). The founding promise is **relaxed** from "never modify/delete a source file" to:
> **Never *silently* modify the source tree. The only writes are user-initiated deletions, which go to
> the Trash (reversible) — never in-place edits, renames, or sidecar files.**
*Impact:* update `SourceAccess`/repository boundary to allow a single audited "move to Trash" path
(`NSWorkspace.recycle`/`FileManager.trashItem`); update the read-only docs + `ReadOnlyInvariant` test
to assert "no writes **except** explicit trashing"; add multi-select + confirm + undo in the grid.

### D8 — Non-face classification (No faces / Screenshots / Documents)
**Decided:** **Proper on-device classifier, deferred past v1.** Don't ship the cheap "No faces"-only
bucket now; do it properly later with a Core ML scene/document classifier. Design should leave room
for future top-level categories alongside People.

### D9 — Visual design direction
**Decided:** **Apple Photos-native** — first-party macOS feel (materials/vibrancy, SF Pro, SF Symbols,
system colors, familiar People-grid layout). Drives the design brief.

### Also queued from feedback
- **#6 face-highlight overlay (experimental):** a per-photo toggle that draws the current person's
  detected face box on each photo. Data is already stored (`face.bbox*`); needs an overlay view.

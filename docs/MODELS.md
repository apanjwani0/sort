# Face embedding models

`sort` turns each detected face into a vector ("embedding") so the same person's faces cluster
together. The embedder is **swappable** — every embedding records its `embeddingModel` and
`embeddingDim`, so changing models is detected and a re-index re-embeds cleanly. Every supported Core
ML model shares one contract: input `image` 112×112 **BGR** normalized `(x-127.5)/127.5`, output
`embedding` 512-d Float32.

## What ships where

| Build | Embedder | License | Notes |
|---|---|---|---|
| `swift build` / `swift run` (no model) | Apple Vision feature-print | — | Zero setup, on-device, but **not** face-specialized → modest grouping. |
| Packaged `.app` / `.dmg` | **AuraFace v1** (Core ML) | **Apache-2.0** | Commercial-clean, ~125 MB, bundled — **free to redistribute**. The default for the shippable DMG. |
| Optional personal swap | ArcFace **buffalo_l** (Core ML) | **non-commercial** | Sharper on hard poses; personal use only — never ship it in a public DMG. |

> ⚠️ **EdgeFace is also non-commercial** (CC BY-NC-SA 4.0) — it is *not* a commercial swap. AuraFace is
> the commercial-clean choice for a redistributable build.

`sort` auto-detects a model from the **app bundle** first, then from
`~/Library/Application Support/sort/models/<name>.mlmodelc`, preferring `auraface` then `arcface`.

## Build the bundled model — AuraFace v1 (Apache-2.0)

```bash
# venv on Python <= 3.12 (coremltools lags new Python releases)
python3.12 -m venv .venv && source .venv/bin/activate
pip install "coremltools>=8" onnx onnx2torch torch numpy

# AuraFace recognition weights (Apache-2.0) — the 512-d, ArcFace-compatible model
curl -L -o glintr100.onnx https://huggingface.co/fal/AuraFace-v1/resolve/main/glintr100.onnx

# convert + install where sort looks for it
python tools/convert_arcface_to_coreml.py \
  --onnx glintr100.onnx \
  --out  "$HOME/Library/Application Support/sort/models/auraface.mlmodelc"

# rebuild so the model is bundled into the app/DMG
./packaging/make_dmg.sh
```

The converted model has input `image` (112×112 BGR, `(x-127.5)/127.5`) and output `embedding` (512-d
Float32) — exactly what `CoreMLEmbedder` expects.

## Optional: ArcFace buffalo_l (higher accuracy, personal use only)

Same converter, different weights. buffalo_l (InsightFace, `w600k_r50`, ResNet50) is sharper on hard
poses but **non-commercial** — fine for your own library, never in a redistributed DMG.

```bash
pip install insightface
python -c "import insightface; insightface.app.FaceAnalysis(name='buffalo_l').prepare(ctx_id=-1)"
python tools/convert_arcface_to_coreml.py \
  --onnx ~/.insightface/models/buffalo_l/w600k_r50.onnx \
  --out  "$HOME/Library/Application Support/sort/models/arcface.mlmodelc"
```

Because pickup prefers `auraface`, drop buffalo_l in as the **only** model (remove
`auraface.mlmodelc`) or force it explicitly with `sort scan --model …/arcface.mlmodelc`.

## Why models aren't committed

Weights are 100+ MB and licensed separately — gitignored (`*.mlmodelc`, `*.mlpackage`, `*.onnx`,
`models/`). coremltools 6+ has no ONNX front-end, so conversion goes ONNX → PyTorch → Core ML and
needs a Python toolchain you run once locally.

## Tuning the cluster threshold

Face identities typically separate around **0.35–0.45** cosine distance. Clustering is biased
**conservative / over-split** (D4) — merging is one tap in the review flow, un-merging is painful.
Adjust with `sort scan --threshold <value>` and validate on your own photos. AuraFace is trained on a
smaller (commercial) dataset than buffalo_l, so re-check the threshold after switching models.

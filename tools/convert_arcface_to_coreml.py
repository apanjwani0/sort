#!/usr/bin/env python3
"""
Convert an ArcFace-architecture ONNX recognition model into a Core ML model that `sort`'s
CoreMLEmbedder can load (D1/D6). Works for both supported models — they share one contract:

  - AuraFace v1  (fal/AuraFace-v1, glintr100.onnx) — Apache-2.0, the COMMERCIAL-CLEAN default bundled
                 in the public DMG.
  - ArcFace buffalo_l (InsightFace, w600k_r50.onnx) — NON-COMMERCIAL, optional higher-accuracy personal swap.

The produced model:
  - input  "image"     : 112x112 image (CVPixelBuffer), BGR channel order, normalized (x-127.5)/127.5
  - output "embedding" : 512-d Float32 face embedding

Why a script (not committed): the weights are 100+ MB and licensed separately. coremltools 6+ has no
ONNX front-end, so we go ONNX -> PyTorch (onnx2torch) -> Core ML.

Setup (use a venv with Python <= 3.12; coremltools lags new Python releases):
    python3.12 -m venv .venv && source .venv/bin/activate
    pip install "coremltools>=8" onnx onnx2torch torch numpy

Default — AuraFace v1 (Apache-2.0), bundled in the DMG:
    curl -L -o glintr100.onnx https://huggingface.co/fal/AuraFace-v1/resolve/main/glintr100.onnx
    python tools/convert_arcface_to_coreml.py \
        --onnx glintr100.onnx \
        --out  "$HOME/Library/Application Support/sort/models/auraface.mlmodelc"

Optional — buffalo_l (NON-COMMERCIAL, personal use only; pip install insightface first):
    python -c "import insightface; insightface.app.FaceAnalysis(name='buffalo_l').prepare(ctx_id=-1)"
    python tools/convert_arcface_to_coreml.py \
        --onnx ~/.insightface/models/buffalo_l/w600k_r50.onnx \
        --out  "$HOME/Library/Application Support/sort/models/arcface.mlmodelc"

Then `sort scan <folder>` (and the app) auto-use it; pass --model <path> to force a specific one.
NOTE: EdgeFace is ALSO non-commercial (CC BY-NC-SA) — not a commercial alternative to buffalo_l.
"""
import argparse
import os
import subprocess
import sys
from pathlib import Path


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--onnx", required=True,
                    help="Path to the ArcFace-arch ONNX model (glintr100.onnx or w600k_r50.onnx).")
    ap.add_argument("--out", required=True, help="Output path; .mlmodelc (compiled) or .mlpackage.")
    ap.add_argument("--input-size", type=int, default=112)
    args = ap.parse_args()

    onnx_path = Path(args.onnx).expanduser()
    out_path = Path(args.out).expanduser()
    if not onnx_path.exists():
        print(f"ONNX model not found: {onnx_path}", file=sys.stderr)
        return 1

    try:
        import numpy as np
        import torch
        import coremltools as ct
        from onnx2torch import convert as onnx2torch_convert
    except ImportError as e:
        print(f"Missing dependency: {e}\nSee the setup instructions at the top of this file.", file=sys.stderr)
        return 2

    size = args.input_size
    print(f"Loading ONNX → PyTorch: {onnx_path}")
    torch_model = onnx2torch_convert(str(onnx_path)).eval()

    example = torch.rand(1, 3, size, size)
    traced = torch.jit.trace(torch_model, example)

    # ArcFace preprocessing: BGR, (pixel - 127.5) / 127.5  ->  scale = 1/127.5, bias = -1 per channel.
    scale = 1.0 / 127.5
    bias = [-1.0, -1.0, -1.0]
    image_input = ct.ImageType(name="image", shape=(1, 3, size, size),
                               scale=scale, bias=bias, color_layout=ct.colorlayout.BGR)

    print("Converting → Core ML (this can take a minute)…")
    mlmodel = ct.convert(traced, inputs=[image_input],
                         minimum_deployment_target=ct.target.macOS15,
                         compute_units=ct.ComputeUnit.ALL)

    # Rename the single output to the stable name the Swift CoreMLEmbedder expects.
    spec = mlmodel.get_spec()
    out_name = spec.description.output[0].name
    if out_name != "embedding":
        ct.utils.rename_feature(spec, out_name, "embedding")
        mlmodel = ct.models.MLModel(spec, weights_dir=mlmodel.weights_dir)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    if out_path.suffix == ".mlmodelc":
        pkg = out_path.with_suffix(".mlpackage")
        mlmodel.save(str(pkg))
        print(f"Compiling {pkg} → {out_path}")
        if out_path.exists():
            subprocess.run(["rm", "-rf", str(out_path)], check=True)
        compiled = subprocess.run(
            ["xcrun", "coremlcompiler", "compile", str(pkg), str(out_path.parent)],
            check=True, capture_output=True, text=True)
        print(compiled.stdout.strip())
    else:
        mlmodel.save(str(out_path))

    print(f"✅ Wrote {out_path}\n   input 'image' 112x112 BGR, output 'embedding' 512-d.")
    print("   sort will now use it automatically (or pass --model <path>).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""
Script 1: Diagnose and fix the ONNX model before OpenVINO conversion.
Fixes:
  - Identifies all graph inputs (SFFN is dual-stream, may have 2 inputs)
  - Locates and reports ATen nodes
  - Patches dynamic shapes to static [1, 3, 224, 224]
  - Runs ONNX shape inference
  - Outputs a clean 'sffn_fixed.onnx' ready for OpenVINO
"""

import onnx
from onnx import shape_inference
import numpy as np

MODEL_PATH  = "sffn_qdq_deployment.onnx"
OUTPUT_PATH = "sffn_fixed.onnx"

# ─── STEP 1: Load and inspect ────────────────────────────────────────────────
print("=" * 60)
print("STEP 1: Inspecting ONNX model structure")
print("=" * 60)

model = onnx.load(MODEL_PATH)
print(f"IR version  : {model.ir_version}")
print(f"Opset       : {model.opset_import[0].version}")
print(f"Graph inputs: {len(model.graph.input)}")

print("\n--- INPUTS ---")
input_names = []
for i, inp in enumerate(model.graph.input):
    t = inp.type.tensor_type
    shape = [
        (d.dim_value if d.dim_value > 0 else "?")
        for d in t.shape.dim
    ] if t.HasField("shape") else ["unknown"]
    dtype = t.elem_type
    print(f"  [{i}] name='{inp.name}'  shape={shape}  dtype={dtype}")
    input_names.append(inp.name)

print("\n--- OUTPUTS ---")
for i, out in enumerate(model.graph.output):
    t = out.type.tensor_type
    shape = [
        (d.dim_value if d.dim_value > 0 else "?")
        for d in t.shape.dim
    ] if t.HasField("shape") else ["unknown"]
    print(f"  [{i}] name='{out.name}'  shape={shape}")

# ─── STEP 2: Find ATen and other problematic nodes ───────────────────────────
print("\n--- SEARCHING FOR PROBLEMATIC OPS ---")
aten_nodes  = []
custom_ops  = {}

for node in model.graph.node:
    if node.op_type == "ATen":
        aten_nodes.append(node)
        op_name = None
        for attr in node.attribute:
            if attr.name == "operator":
                op_name = attr.s.decode("utf-8")
        print(f"  [ATen] operator='{op_name}'  "
              f"inputs={list(node.input)}  outputs={list(node.output)}")
    if node.domain not in ("", "com.microsoft"):
        custom_ops[node.op_type] = node.domain

if not aten_nodes:
    print("  No ATen nodes found — model may already be clean")
else:
    print(f"\n  ⚠  Found {len(aten_nodes)} ATen node(s) — must be resolved before conversion")

if custom_ops:
    print(f"\n  Other non-standard op domains: {custom_ops}")

# ─── STEP 3: Patch shapes + run ONNX shape inference ─────────────────────────
print("\n" + "=" * 60)
print("STEP 2: Patching shapes + running ONNX shape inference")
print("=" * 60)

# Force static [1, 3, 224, 224] on all graph inputs
print("  Patching dynamic input shapes → static [1, 3, 224, 224]...")
for inp in model.graph.input:
    tensor_type = inp.type.tensor_type
    if tensor_type.HasField("shape"):
        static_dims = [1, 3, 224, 224]
        for i, d in enumerate(tensor_type.shape.dim):
            if i < len(static_dims):
                d.dim_value = static_dims[i]
                d.ClearField("dim_param")   # remove the "?" dynamic symbol

# Run shape inference with the patched shapes
print("  Running shape inference...")
try:
    inferred_model = shape_inference.infer_shapes(model, strict_mode=False)
    print("  ✅ Shape inference complete")
except Exception as e:
    print(f"  ⚠  Shape inference failed ({e}) — saving as-is")
    inferred_model = model

# Report remaining ATen nodes after inference
remaining_aten = [n for n in inferred_model.graph.node if n.op_type == "ATen"]
print(f"\n  ATen nodes before : {len(aten_nodes)}")
print(f"  ATen nodes after  : {len(remaining_aten)}")

if remaining_aten:
    print("\n  ⚠  ATen nodes still present. Listing them:")
    for n in remaining_aten:
        for attr in n.attribute:
            if attr.name == "operator":
                print(f"    → ATen op: '{attr.s.decode()}'  "
                      f"inputs={list(n.input)}  outputs={list(n.output)}")
    print("\n  These will be handled during OpenVINO conversion in Script 2.")
else:
    print("  ✅ No ATen nodes remaining — model is clean")

# ─── STEP 4: Save fixed model ─────────────────────────────────────────────────
print("\n" + "=" * 60)
print("STEP 3: Saving fixed model")
print("=" * 60)

onnx.save(inferred_model, OUTPUT_PATH)
print(f"  ✅ Saved: {OUTPUT_PATH}")

# ─── STEP 5: Summary for Script 2 ────────────────────────────────────────────
print("\n" + "=" * 60)
print("SUMMARY — Copy this into Script 2's INPUT_SPEC")
print("=" * 60)

if len(input_names) == 1:
    print(f'  INPUT_SPEC = [("{input_names[0]}", [1, 3, 224, 224])]')
elif len(input_names) == 2:
    print(f'  INPUT_SPEC = [')
    print(f'      ("{input_names[0]}", [1, 3, 224, 224]),')
    print(f'      ("{input_names[1]}", [1, 3, 224, 224]),')
    print(f'  ]')
else:
    print("  More than 2 inputs detected — review manually:")
    for name in input_names:
        print(f'    ("{name}", [1, 3, 224, 224])')

print("\n✅ Script 1 complete. Run Script 2 next.")
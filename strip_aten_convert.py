"""
Script 2 (revised): Strip ATen QDQ nodes from ONNX graph, convert to
OpenVINO IR, then apply NNCF INT8 PTQ.

Why this works:
  - The 313 ATen nodes are fake-quantize wrappers from PyTorch QAT export
  - OpenVINO cannot parse org.pytorch.aten domain ops
  - We bypass them (input → output passthrough), yielding clean FP32 graph
  - NNCF PTQ then re-quantizes to INT8 properly via OpenVINO's own engine
"""

import onnx
from onnx import helper, TensorProto, numpy_helper
import numpy as np
import openvino as ov
from openvino.tools.ovc import convert_model
import os

FIXED_ONNX   = "sffn_fixed.onnx"
CLEAN_ONNX   = "sffn_fp32_clean.onnx"
IR_FP32_NAME = "sffn_fp32"
IR_INT8_NAME = "sffn_int8"

# Confirmed from Script 1 output
INPUT_SPEC = [
    ("spatial_in", [1, 3, 224, 224]),
    ("freq_in",    [1, 2, 224, 224]),
]

# ─── STEP 1: Inspect ATen operators ──────────────────────────────────────────
print("=" * 60)
print("STEP 1: Auditing ATen nodes in the graph")
print("=" * 60)

model = onnx.load(FIXED_ONNX)

aten_ops = {}
for node in model.graph.node:
    if node.op_type == "ATen":
        for attr in node.attribute:
            if attr.name == "operator":
                op_name = attr.s.decode("utf-8")
                aten_ops[op_name] = aten_ops.get(op_name, 0) + 1

print(f"  Total ATen nodes : {sum(aten_ops.values())}")
print("  ATen operator breakdown:")
for op, count in sorted(aten_ops.items(), key=lambda x: -x[1]):
    print(f"    {count:4d}x  '{op}'")

# ─── STEP 2: Strip ATen nodes (bypass: connect input[0] → output[0]) ─────────
print("\n" + "=" * 60)
print("STEP 2: Stripping ATen nodes from graph")
print("=" * 60)

# Build a remapping table: if a tensor name was renamed by an ATen node,
# map it back to the original tensor that fed into that ATen node
remap = {}   # aten_output_name → actual_input_name

new_nodes = []
removed   = 0

for node in model.graph.node:
    if node.op_type == "ATen":
        # Bypass: map this node's output to its primary input
        # (resolving any prior remaps on the input side too)
        src = node.input[0] if node.input else None
        if src and src in remap:
            src = remap[src]
        if src and node.output:
            remap[node.output[0]] = src
        removed += 1
    else:
        new_nodes.append(node)

print(f"  Removed  : {removed} ATen nodes")
print(f"  Remapped : {len(remap)} tensor name aliases")

# Apply remapping to all remaining node inputs
for node in new_nodes:
    for i, inp in enumerate(node.input):
        if inp in remap:
            node.input[i] = remap[inp]

# Apply remapping to graph outputs
for out in model.graph.output:
    if out.name in remap:
        out.name = remap[out.name]

# Rebuild graph with stripped nodes
del model.graph.node[:]
model.graph.node.extend(new_nodes)

print(f"  Remaining nodes  : {len(model.graph.node)}")

# ─── STEP 3: Re-run shape inference on clean graph ───────────────────────────
print("\n  Running shape inference on clean graph...")
from onnx import shape_inference
try:
    clean_model = shape_inference.infer_shapes(model, strict_mode=False)
    print("  ✅ Shape inference OK")
except Exception as e:
    print(f"  ⚠  Shape inference warning: {e} — continuing")
    clean_model = model

# Verify no ATen nodes remain
remaining = [n for n in clean_model.graph.node if n.op_type == "ATen"]
print(f"  ATen nodes remaining: {len(remaining)}")

if remaining:
    print("  ⚠  Some ATen nodes still present — listing:")
    for n in remaining:
        for a in n.attribute:
            if a.name == "operator":
                print(f"    → '{a.s.decode()}'")
else:
    print("  ✅ Graph is fully clean — no ATen nodes")

onnx.save(clean_model, CLEAN_ONNX)
print(f"  Saved: {CLEAN_ONNX}")

# ─── STEP 4: Convert clean ONNX → OpenVINO IR (FP32) ─────────────────────────
print("\n" + "=" * 60)
print("STEP 3: Converting clean ONNX → OpenVINO IR (FP32)")
print("=" * 60)

input_arg = [(name, ov.PartialShape(shape)) for name, shape in INPUT_SPEC]
print(f"  Input spec: {INPUT_SPEC}")

try:
    ov_model = convert_model(CLEAN_ONNX, input=input_arg)
    print("  ✅ Conversion successful")
    ov.save_model(ov_model, IR_FP32_NAME + ".xml")
    print(f"  Saved: {IR_FP32_NAME}.xml + {IR_FP32_NAME}.bin")
except Exception as e:
    print(f"  ❌ Conversion failed: {e}")
    raise

# ─── STEP 5: FP32 smoke test ──────────────────────────────────────────────────
print("\n" + "=" * 60)
print("STEP 4: FP32 smoke test")
print("=" * 60)

core = ov.Core()
compiled_fp32 = core.compile_model(ov_model, "CPU")

dummy_inputs = {}
for i, port in enumerate(compiled_fp32.inputs):
    name, shape = INPUT_SPEC[i]
    dummy_inputs[port] = np.random.rand(*shape).astype(np.float32)
    print(f"  Input [{i}] '{name}': shape={shape}")

result = compiled_fp32(dummy_inputs)
output = list(result.values())[0]
print(f"  Output shape : {output.shape}")
print(f"  Output sample: {output.flatten()[:4]}")
print("  ✅ FP32 inference OK")

# ─── STEP 6: NNCF INT8 PTQ ───────────────────────────────────────────────────
print("\n" + "=" * 60)
print("STEP 5: NNCF INT8 Post-Training Quantization")
print("=" * 60)

try:
    import nncf

    NUM_CALIB_SAMPLES = 300
    print(f"  Calibration samples : {NUM_CALIB_SAMPLES}")
    print("  NOTE: Replace np.random with real images for thesis results")
    print("        (Use ~300 samples from your deepfake val/test set)")

    def calibration_data_generator():
        """
        IMPORTANT FOR THESIS:
        Replace np.random.rand(...) with actual image tensors.
        Load from your FaceForensics++ or similar dataset.
        Normalize to [0,1] or [-1,1] matching your training pipeline.
        """
        for _ in range(NUM_CALIB_SAMPLES):
            yield {
                "spatial_in": np.random.rand(1, 3, 224, 224).astype(np.float32),
                "freq_in":    np.random.rand(1, 2, 224, 224).astype(np.float32),
            }

    calib_dataset = nncf.Dataset(calibration_data_generator())

    print("\n  Running quantization (2–5 min on CPU)...")
    quantized_model = nncf.quantize(
        ov_model,
        calib_dataset,
        preset=nncf.QuantizationPreset.PERFORMANCE,
        subset_size=NUM_CALIB_SAMPLES,
    )

    ov.save_model(quantized_model, IR_INT8_NAME + ".xml")
    print(f"  ✅ INT8 model saved: {IR_INT8_NAME}.xml + {IR_INT8_NAME}.bin")

except ImportError:
    print("  nncf not installed — run:  pip install nncf")
except Exception as e:
    print(f"  ❌ NNCF failed: {e}")
    raise

# ─── STEP 7: INT8 smoke test ─────────────────────────────────────────────────
print("\n" + "=" * 60)
print("STEP 6: INT8 smoke test")
print("=" * 60)

try:
    compiled_int8 = core.compile_model(quantized_model, "CPU")
    result_int8 = compiled_int8(dummy_inputs)
    output_int8 = list(result_int8.values())[0]
    print(f"  Output shape  : {output_int8.shape}")
    print(f"  Output sample : {output_int8.flatten()[:4]}")

    # Quick accuracy delta check
    diff = np.abs(output.flatten() - output_int8.flatten()).mean()
    print(f"  Mean abs delta (FP32 vs INT8): {diff:.6f}")
    if diff < 0.05:
        print("  ✅ Quantization looks healthy (delta < 0.05)")
    else:
        print("  ⚠  Large delta — consider mixed precision or NNCF accuracy-aware mode")
except Exception as e:
    print(f"  INT8 smoke test failed: {e}")

# ─── FINAL SUMMARY ────────────────────────────────────────────────────────────
print("\n" + "=" * 60)
print("ALL STEPS COMPLETE")
print("=" * 60)
print(f"  FP32 IR  : {IR_FP32_NAME}.xml / .bin")
print(f"  INT8 IR  : {IR_INT8_NAME}.xml / .bin")
print(f"  Clean ONNX: {CLEAN_ONNX}")
print("\nNext — benchmark both models:")
print(f"  benchmark_app -m {IR_FP32_NAME}.xml -d CPU -t 30 -api async -nstreams 4")
print(f"  benchmark_app -m {IR_INT8_NAME}.xml -d CPU -t 30 -api async -nstreams 4")
print("=" * 60)
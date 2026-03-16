"""
Extracts everything needed for RTL/FPGA design from the INT8 ONNX model:
1. INT8 weights per layer as .npy files
2. Quantization scale factors and zero points
3. Layer architecture specification CSV
4. MAC unit requirements summary
"""

import onnx
from onnx import numpy_helper
import numpy as np
import os
import csv
import json

MODEL_PATH  = "sffn_fp32_clean.onnx"
OUTPUT_DIR  = "rtl_design_files"
os.makedirs(OUTPUT_DIR, exist_ok=True)
os.makedirs(f"{OUTPUT_DIR}/weights", exist_ok=True)

model = onnx.load(MODEL_PATH)
inits = {i.name: numpy_helper.to_array(i) for i in model.graph.initializer}

# Debug check
print(f"Total initializers (weights/biases): {len(inits)}")
conv_nodes = [n for n in model.graph.node if n.op_type == 'Conv']
print(f"Total Conv nodes in graph: {len(conv_nodes)}")
print(f"First Conv node inputs: {conv_nodes[0].input if conv_nodes else 'None'}")
# ── 1. Extract all conv layers + weights ─────────────────────────────────────
print("=" * 60)
print("STEP 1: Extracting Conv layer weights")
print("=" * 60)

arch_rows = []
conv_idx  = 0

for node in model.graph.node:
    if node.op_type != 'Conv':
        continue

    weight_name = node.input[1] if len(node.input) > 1 else None
    bias_name   = node.input[2] if len(node.input) > 2 else None
    if weight_name not in inits:
        continue

    w      = inits[weight_name]
    bias   = inits[bias_name] if bias_name and bias_name in inits else None
    groups = next((a.i for a in node.attribute if a.name == 'group'), 1)
    strides= list(next((a.ints for a in node.attribute if a.name == 'strides'), [1,1]))
    pads   = list(next((a.ints for a in node.attribute if a.name == 'pads'), [0,0,0,0]))

    layer_type = "DWConv" if groups == w.shape[0] else "Conv"
    layer_name = f"layer_{conv_idx:03d}_{layer_type}_{w.shape[0]}x{w.shape[1]}_{w.shape[2]}x{w.shape[3]}"

    # Determine which stream
    name = node.name or ""
    if   "backbone" in name: stream = "spatial"
    elif "freq"     in name: stream = "frequency"
    elif "recon"    in name: stream = "recon_head"
    else:                    stream = "classifier"

    # Save weights as npy
    np.save(f"{OUTPUT_DIR}/weights/{layer_name}_w.npy", w)
    if bias is not None:
        np.save(f"{OUTPUT_DIR}/weights/{layer_name}_b.npy", bias)

    # MACs (approximate, assuming 224x224 input — adjust per actual feature map)
    macs = int(w.shape[0] * w.shape[1] * w.shape[2] * w.shape[3])

    arch_rows.append({
        "idx"        : conv_idx,
        "stream"     : stream,
        "layer_type" : layer_type,
        "out_ch"     : w.shape[0],
        "in_ch"      : w.shape[1],
        "kernel_h"   : w.shape[2],
        "kernel_w"   : w.shape[3],
        "groups"     : groups,
        "stride"     : strides,
        "padding"    : pads,
        "weight_dtype": str(w.dtype),
        "params"     : w.size + (bias.size if bias is not None else 0),
        "weight_file": f"{layer_name}_w.npy",
        "bias_file"  : f"{layer_name}_b.npy" if bias is not None else "none",
    })

    print(f"  [{conv_idx:03d}] {stream:<12} {layer_type:<8} "
          f"out={w.shape[0]:>4} in={w.shape[1]:>4} "
          f"k={w.shape[2]}x{w.shape[3]}  stride={strides}  dtype={w.dtype}")
    conv_idx += 1

print(f"\n  Total conv layers extracted: {conv_idx}")

# ── 2. Save architecture CSV ──────────────────────────────────────────────────
arch_csv = f"{OUTPUT_DIR}/sffn_architecture.csv"
with open(arch_csv, 'w', newline='') as f:
    writer = csv.DictWriter(f, fieldnames=arch_rows[0].keys())
    writer.writeheader()
    writer.writerows(arch_rows)
print(f"\n  Architecture spec saved: {arch_csv}")

# ── 3. Extract QDQ scale factors ─────────────────────────────────────────────
print("\n" + "=" * 60)
print("STEP 2: Extracting quantization scale factors")
print("=" * 60)

scales     = {}
zero_points= {}

for node in model.graph.node:
    if node.op_type == 'QuantizeLinear':
        scale_name = node.input[1] if len(node.input) > 1 else None
        zp_name    = node.input[2] if len(node.input) > 2 else None
        if scale_name and scale_name in inits:
            scales[node.output[0]] = float(inits[scale_name].flat[0])
        if zp_name and zp_name in inits:
            zero_points[node.output[0]] = int(inits[zp_name].flat[0])

print(f"  Found {len(scales)} quantization scale factors")
print(f"  Found {len(zero_points)} zero point values")

# Save scales as JSON (for RTL fixed-point design)
quant_params = {
    "scales"      : scales,
    "zero_points" : zero_points,
    "bit_width"   : 8,
    "scheme"      : "asymmetric_per_tensor",
}
quant_json = f"{OUTPUT_DIR}/quantization_params.json"
with open(quant_json, 'w') as f:
    json.dump(quant_params, f, indent=2)
print(f"  Quantization params saved: {quant_json}")

# ── 4. MAC Unit Requirements Summary ─────────────────────────────────────────
print("\n" + "=" * 60)
print("STEP 3: MAC Unit Requirements for RTL Design")
print("=" * 60)

from collections import Counter
shapes = Counter(
    (r["layer_type"], r["out_ch"], r["in_ch"], r["kernel_h"], r["kernel_w"], r["groups"])
    for r in arch_rows
)

print(f"\n{'Type':<8} {'Out_Ch':>7} {'In_Ch':>6} {'Kernel':>8} "
      f"{'Groups':>7} {'Count':>6} {'Parallelism Hint':<25}")
print("-" * 70)
for (lt, oc, ic, kh, kw, g), cnt in sorted(shapes.items(), key=lambda x: -x[1]):
    if lt == "DWConv":
        hint = f"1 MAC unit per channel"
    elif kh == 1:
        hint = f"1x1: high reuse, low BW"
    else:
        hint = f"3x3: systolic array ideal"
    print(f"{lt:<8} {oc:>7} {ic:>6} {str(kh)+'x'+str(kw):>8} "
          f"{g:>7} {cnt:>6}   {hint:<25}")

# ── 5. Stream-wise parameter budget ──────────────────────────────────────────
print("\n" + "=" * 60)
print("STEP 4: Stream-wise Parameter Budget (BRAM sizing)")
print("=" * 60)

from collections import defaultdict
stream_params = defaultdict(int)
for r in arch_rows:
    stream_params[r["stream"]] += r["params"]

total_params = sum(stream_params.values())
print(f"\n{'Stream':<15} {'Parameters':>12} {'FP32 (KB)':>10} "
      f"{'INT8 (KB)':>10} {'% Total':>8}")
print("-" * 60)
for stream, params in sorted(stream_params.items(), key=lambda x: -x[1]):
    fp32_kb = params * 4 / 1024
    int8_kb = params * 1 / 1024
    pct     = params / total_params * 100
    print(f"{stream:<15} {params:>12,} {fp32_kb:>10.1f} "
          f"{int8_kb:>10.1f} {pct:>7.1f}%")
print("-" * 60)
fp32_total = total_params * 4 / 1024
int8_total = total_params * 1 / 1024
print(f"{'TOTAL':<15} {total_params:>12,} {fp32_total:>10.1f} "
      f"{int8_total:>10.1f} {'100.0%':>8}")

print("\n" + "=" * 60)
print("ALL RTL DESIGN FILES GENERATED")
print("=" * 60)
print(f"  Output directory  : {OUTPUT_DIR}/")
print(f"  Weight files      : {OUTPUT_DIR}/weights/  ({conv_idx} layers)")
print(f"  Architecture spec : {arch_csv}")
print(f"  Quantization JSON : {quant_json}")
print(f"\nNext step: Use these files for")
print("  1. BRAM initialization in Quartus (Stratix III)")
print("  2. Fixed-point MAC unit sizing in RTL")
print("  3. Systolic array dimensioning")
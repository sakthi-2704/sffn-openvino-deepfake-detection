"""
run_benchmarks.py
Runs all benchmark_app commands, parses results, and prints a thesis-ready table.
"""

import subprocess
import re

BENCHMARKS = [
    {
        "label": "FP32 Baseline",
        "cmd": [
            "benchmark_app",
            "-m", "sffn_fp32.xml",
            "-d", "CPU",
            "-t", "30",
            "-api", "async",
            "-hint", "none",
            "-nstreams", "4",
            "-niter", "1000",
        ]
    },
    {
        "label": "INT8 Optimized",
        "cmd": [
            "benchmark_app",
            "-m", "sffn_int8.xml",
            "-d", "CPU",
            "-t", "30",
            "-api", "async",
            "-hint", "none",
            "-nstreams", "4",
            "-niter", "1000",
        ]
    },
    {
        "label": "INT8 (explicit dual-stream shapes)",
        "cmd": [
            "benchmark_app",
            "-m", "sffn_int8.xml",
            "-d", "CPU",
            "-t", "30",
            "-api", "async",
            "-hint", "none",
            "-nstreams", "4",
            "-niter", "1000",
            "-data_shape", "spatial_in[1,3,224,224],freq_in[1,2,224,224]",
        ]
    },
]

def parse_metrics(output: str) -> dict:
    """Extract key metrics from benchmark_app stdout."""
    metrics = {
        "throughput_fps" : None,
        "latency_median" : None,
        "latency_avg"    : None,
        "latency_min"    : None,
        "latency_max"    : None,
        "total_iters"    : None,
        "duration_s"     : None,
    }

    patterns = {
        "throughput_fps" : r"Throughput:\s+([\d.]+)\s+FPS",
        "latency_median" : r"Median\s*:\s*([\d.]+)\s*ms",
        "latency_avg"    : r"Average\s*:\s*([\d.]+)\s*ms",
        "latency_min"    : r"Min\s*:\s*([\d.]+)\s*ms",
        "latency_max"    : r"Max\s*:\s*([\d.]+)\s*ms",
        "total_iters"    : r"Count:\s+(\d+)\s+iterations",
        "duration_s"     : r"Duration:\s+([\d.]+)\s+ms",
    }

    for key, pattern in patterns.items():
        match = re.search(pattern, output, re.IGNORECASE)
        if match:
            val = match.group(1)
            metrics[key] = float(val) if "." in val else int(val)

    # Convert duration ms → seconds
    if metrics["duration_s"]:
        metrics["duration_s"] = round(metrics["duration_s"] / 1000, 2)

    return metrics

def run_benchmark(label, cmd):
    print(f"\n{'='*60}")
    print(f"Running: {label}")
    print(f"Command: {' '.join(cmd)}")
    print("=" * 60)

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=180   # 3 min max per benchmark
        )
        output = result.stdout + result.stderr

        # Print live output for visibility
        print(output)

        if result.returncode != 0:
            print(f"⚠  benchmark_app exited with code {result.returncode}")

        return output

    except subprocess.TimeoutExpired:
        print("❌ Benchmark timed out after 3 minutes")
        return ""
    except FileNotFoundError:
        print("❌ benchmark_app not found — make sure openvino_env is activated")
        return ""

def print_summary_table(results):
    """Print a formatted thesis-ready results table."""

    print("\n")
    print("=" * 80)
    print("THESIS RESULTS TABLE — OpenVINO Benchmark Summary")
    print("=" * 80)

    # Header
    col_w = [35, 12, 12, 12, 12, 12]
    headers = ["Model", "FPS", "Lat Avg(ms)", "Lat Med(ms)", "Lat Min(ms)", "Lat Max(ms)"]
    header_row = "".join(h.ljust(col_w[i]) for i, h in enumerate(headers))
    print(header_row)
    print("-" * 80)

    for label, metrics in results:
        fps     = f"{metrics['throughput_fps']:.2f}"  if metrics["throughput_fps"] else "N/A"
        avg     = f"{metrics['latency_avg']:.2f}"     if metrics["latency_avg"]    else "N/A"
        med     = f"{metrics['latency_median']:.2f}"  if metrics["latency_median"] else "N/A"
        mn      = f"{metrics['latency_min']:.2f}"     if metrics["latency_min"]    else "N/A"
        mx      = f"{metrics['latency_max']:.2f}"     if metrics["latency_max"]    else "N/A"

        row = [label, fps, avg, med, mn, mx]
        print("".join(str(row[i]).ljust(col_w[i]) for i in range(len(row))))

    print("=" * 80)

    # Speedup analysis (FP32 vs INT8)
    if len(results) >= 2:
        fp32_fps  = results[0][1]["throughput_fps"]
        int8_fps  = results[1][1]["throughput_fps"]
        fp32_lat  = results[0][1]["latency_avg"]
        int8_lat  = results[1][1]["latency_avg"]

        if fp32_fps and int8_fps:
            speedup    = int8_fps / fp32_fps
            lat_reduc  = ((fp32_lat - int8_lat) / fp32_lat * 100) if fp32_lat and int8_lat else None

            print("\nPERFORMANCE ANALYSIS")
            print("-" * 80)
            print(f"  Throughput speedup  (INT8 vs FP32) : {speedup:.2f}x")
            if lat_reduc:
                print(f"  Latency reduction   (INT8 vs FP32) : {lat_reduc:.1f}%")
            target_fps = 300.0
            print(f"\n  Target throughput                  : {target_fps} FPS")
            print(f"  INT8 achieved                      : {int8_fps:.2f} FPS")
            gap = int8_fps - target_fps
            if gap >= 0:
                print(f"  ✅ Target EXCEEDED by              : +{gap:.2f} FPS")
            else:
                print(f"  ⚠  Gap to target                   : {gap:.2f} FPS")
                print(f"     → Consider: more async streams, batch inference, or GPU device")

        print("=" * 80)

    # Raw data dump for thesis appendix
    print("\nRAW METRICS (for thesis appendix)")
    print("-" * 80)
    for label, metrics in results:
        print(f"\n  [{label}]")
        for k, v in metrics.items():
            if v is not None:
                print(f"    {k:<20}: {v}")

    print("\n✅ Copy the table above into your Results & Discussion section.")

# ─── MAIN ────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    all_results = []

    for bench in BENCHMARKS:
        output  = run_benchmark(bench["label"], bench["cmd"])
        metrics = parse_metrics(output)
        all_results.append((bench["label"], metrics))

    print_summary_table(all_results)
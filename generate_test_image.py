"""
generate_test_image.py
Generates a test image in SystemVerilog format
using a real face image or synthetic pattern
"""
import numpy as np

OUTPUT_FILE = "sim_test_image.sv"

# Generate a simple test pattern (replace with real image later)
# 4x4 image, 3 channels spatial, 2 channels freq
np.random.seed(42)  # reproducible

spatial_img = np.random.randint(0, 255,
              (4, 4, 3), dtype=np.uint8)
freq_img    = np.random.randint(0, 255,
              (4, 4, 2), dtype=np.uint8)

with open(OUTPUT_FILE, 'w') as f:
    f.write("// Test image for sffn_top simulation\n\n")

    # Write spatial pixels
    f.write("// Spatial pixels [row][col] = {ch2,ch1,ch0}\n")
    f.write("localparam int SPATIAL_PIX [0:15] = '{\n")
    pixels = []
    for r in range(4):
        for c in range(4):
            ch0 = spatial_img[r,c,0]
            ch1 = spatial_img[r,c,1]
            ch2 = spatial_img[r,c,2]
            pixels.append(f"  24'h{ch2:02x}{ch1:02x}{ch0:02x}")
    f.write(',\n'.join(pixels))
    f.write("\n};\n\n")

    # Write freq pixels
    f.write("// Freq pixels [row][col] = {ch1,ch0}\n")
    f.write("localparam int FREQ_PIX [0:15] = '{\n")
    fpixels = []
    for r in range(4):
        for c in range(4):
            ch0 = freq_img[r,c,0]
            ch1 = freq_img[r,c,1]
            fpixels.append(f"  16'h{ch1:02x}{ch0:02x}")
    f.write(',\n'.join(fpixels))
    f.write("\n};\n\n")

print(f"Generated: {OUTPUT_FILE}")
print(f"Spatial image shape: {spatial_img.shape}")
print(f"Freq image shape   : {freq_img.shape}")
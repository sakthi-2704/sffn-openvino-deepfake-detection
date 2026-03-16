import openvino as ov
from openvino.tools.ovc import convert_model
import numpy as np

# 1. Path to your model
# Ensure this filename is exactly what is in your folder
model_path = "sffn_qdq_deployment.onnx"

print("--- Step 1: Force-converting ONNX to OpenVINO IR ---")
print("This handles custom PyTorch ops and fixes the rank/shape errors.")

try:
    # We lock the input size to 1 image, 3 channels, 224x224
    # This resolves the 'static rank' errors you saw earlier
    ov_model = convert_model(
        model_path, 
        input=[1, 3, 224, 224]
    )
    print("Graph conversion successful!")
    
    # 2. Save the model
    # This creates the .xml and .bin files you need for the 300 FPS benchmark
    ir_name = "sffn_final_optimized"
    ov.save_model(ov_model, ir_name + ".xml")
    print(f"--- Step 2: Files Created: {ir_name}.xml and {ir_name}.bin ---")

    # 3. Quick Verification
    core = ov.Core()
    compiled_model = core.compile_model(ov_model, "CPU")
    print("Verification: Model loaded into CPU successfully. Ready for Task 2.")

except Exception as e:
    print(f"FAILED: {e}")
    print("If you still see 'ATen' errors, we will apply a specialized fallback mapping.")
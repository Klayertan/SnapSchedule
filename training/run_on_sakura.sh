#!/usr/bin/env bash
# One-shot training run for a Sakura 高火力 DOK H100 task (or any Linux machine with a big NVIDIA GPU).
# Run it from this folder in the task's terminal:  bash run_on_sakura.sh
set -euo pipefail

BASE="${BASE:-unsloth/Qwen2.5-14B-Instruct-bnb-4bit}"
COUNT="${COUNT:-5000}"
# DOK keeps whatever is in this folder after the task ends; everything else is deleted.
ARTIFACTS="${SAKURA_ARTIFACT_DIR:-/opt/artifact}"

nvidia-smi
pip install --quiet unsloth

python make_dataset.py --count "$COUNT" --size full --out data
if [ -f make_real_test.py ]; then python make_real_test.py; fi

time python train.py --base "$BASE" --max-seq 32768 --batch 2 --out out 2>&1 | tee train.log

mkdir -p "$ARTIFACTS"
cp train.log "$ARTIFACTS/"
cp -r out/gguf "$ARTIFACTS/" 2>/dev/null || cp -r out/merged "$ARTIFACTS/"
cp -r out/lora "$ARTIFACTS/"
ls -lh "$ARTIFACTS"
echo "Finished. Download the artifact from the DOK task page, then STOP THE TASK so billing ends."

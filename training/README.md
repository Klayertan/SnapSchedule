# Training kit: a timetable-reading model for SnapSchedule

Goal: a model that runs on your Mac (through Ollama), reads timetables the way the app sends them
(text fragments with positions), and returns calendar events. The app talks to it through
Settings › AI server.

Nothing here has been trained or scored yet. `make_dataset.py` and `make_real_test.py` have been run;
`eval.py` and `train.py` have not.

> The real-timetable files (`make_real_test.py`, `data/real_nara_layout.txt`, `data/real_test.jsonl`) are not in the
> public repository. Copy them into `training/` yourself; without them, skip the `real_test` commands.

## Step 0 — Check whether you need to train at all (Mac, about 15 minutes)

    brew install ollama && ollama serve          # or install the app from ollama.com
    ollama create timetable-baseline -f Modelfile.baseline
    python3 eval.py --model timetable-baseline --limit 20
    python3 eval.py --model timetable-baseline --data data/real_test.jsonl --show

The last command is your real 奈良高専 timetable with the answer for 5S. If an untrained model
already gets it right, stop here and just use it. Your real timetable is long (roughly 20,000+
tokens), which is why the Modelfiles set a 32k context; on the 16 GB Air that is slow and tight on
memory, so run this test on the M1 Max if you can. On the 64 GB M1 Max you can also try a bigger
model (edit the `FROM` line in `Modelfile.baseline`, e.g. `qwen2.5:14b` or `qwen2.5:32b`).

## Step 1 — Make training data (any computer)

    python3 make_dataset.py --count 3000 --size small     # 12 GB GPU
    python3 make_dataset.py --count 5000 --size full      # H100: whole-school grids, up to 25 classes

The data is synthetic: randomly generated timetables whose correct answer is known. Two layouts
exist so far (whole-school grid, personal weekly grid). A model trained on them learns those two
layouts; add more generators to `make_dataset.py` for other kinds of schedule.

## Step 2 — Train (NVIDIA GPU)

    pip install unsloth
    python train.py                                                    # RTX 4070 Super
    python train.py --base unsloth/Qwen2.5-14B-Instruct-bnb-4bit --max-seq 32768 --batch 2   # H100

The 4070 Super's 12 GB limits both model size and timetable size: with `--size small` and the 3B
model it should fit, but your real whole-school PDF is far longer than what it will have trained on.
The H100 can train a larger model on full-size grids. Stop the H100 when training ends; it bills
by the second.

On Sakura 高火力 DOK the whole of Steps 1–2 is one command: `bash run_on_sakura.sh` (see
`blog-sakura-dok.md` for the walkthrough).

## Step 3 — Run it on the Mac

    cp out/gguf/*.gguf model.gguf        # copy the file from the training machine first
    ollama create snapschedule -f Modelfile
    python3 eval.py --model snapschedule --limit 20
    python3 eval.py --model snapschedule --data data/real_test.jsonl --show

Compare with the Step 0 numbers. Keep the fine-tuned model only if it is better on the real test.

## Step 4 — Connect the app

Settings › AI server:
- Server address: `http://localhost:11434/v1` (same Mac), or `http://<name-of-mac>.local:11434/v1`
  from the iPhone/iPad or another Mac. For other devices, start Ollama with `OLLAMA_HOST=0.0.0.0`.
- Model name: `snapschedule` (or `timetable-baseline`)
- API key: empty. "Model can see images": off.

## Files

- `prompt_template.txt` — the app's exact instructions, exported from the app's code. Re-export it
  if the prompt in `ScheduleExtractor.swift` changes, or the model trains on a stale prompt.
- `data/real_nara_layout.txt` — your timetable PDF as the app sends it.
- `make_real_test.py` — the expected 5S answer, as read by Claude. Fix it there if it is wrong.

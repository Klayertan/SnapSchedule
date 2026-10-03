#!/usr/bin/env python3
"""Fine-tune a small open model on the synthetic timetables (QLoRA via Unsloth), then export it for Ollama.

Needs an NVIDIA GPU (Linux or Windows/WSL):  pip install unsloth
  RTX 4070 Super (12 GB):  python train.py                                  # 3B model, short grids
  Sakura H100 (80 GB):     python train.py --base unsloth/Qwen2.5-14B-Instruct-bnb-4bit --max-seq 32768 --batch 2
NOTE: written from Unsloth's documented API but not run by its author; expect to adjust for your installed versions.
"""
import argparse
from unsloth import FastLanguageModel  # must be imported before transformers
from unsloth.chat_templates import train_on_responses_only
from datasets import load_dataset
from transformers import TrainingArguments
from trl import SFTTrainer

ap = argparse.ArgumentParser()
ap.add_argument("--base", default="unsloth/Qwen2.5-3B-Instruct-bnb-4bit")
ap.add_argument("--data", default="data/train.jsonl")
ap.add_argument("--max-seq", type=int, default=8192, help="examples longer than this are dropped")
ap.add_argument("--epochs", type=float, default=1)
ap.add_argument("--batch", type=int, default=1)
ap.add_argument("--out", default="out")
ap.add_argument("--quant", default="q4_k_m", help="GGUF quantisation for the Mac (q4_k_m is a good default; q8_0 for 64 GB Macs)")
args = ap.parse_args()

model, tokenizer = FastLanguageModel.from_pretrained(args.base, max_seq_length=args.max_seq, load_in_4bit=True)
model = FastLanguageModel.get_peft_model(
    model, r=16, lora_alpha=16, lora_dropout=0, bias="none", random_state=0,
    target_modules=["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"],
    use_gradient_checkpointing="unsloth")

data = load_dataset("json", data_files=args.data, split="train")
data = data.map(lambda row: {"text": tokenizer.apply_chat_template(row["messages"], tokenize=False)})
before = len(data)
data = data.filter(lambda row: len(tokenizer(row["text"]).input_ids) <= args.max_seq)
print(f"training on {len(data)} of {before} examples (the rest exceed --max-seq)")

trainer = SFTTrainer(
    model=model, tokenizer=tokenizer, train_dataset=data, dataset_text_field="text", max_seq_length=args.max_seq,
    args=TrainingArguments(
        output_dir=args.out, per_device_train_batch_size=args.batch, gradient_accumulation_steps=max(8 // args.batch, 1),
        num_train_epochs=args.epochs, learning_rate=2e-4, warmup_steps=20, lr_scheduler_type="cosine",
        optim="adamw_8bit", weight_decay=0.01, logging_steps=10, save_strategy="epoch", report_to="none", seed=0))
# Learn only from the JSON answer, not from re-predicting the prompt (these markers are Qwen's chat format).
trainer = train_on_responses_only(trainer, instruction_part="<|im_start|>user\n", response_part="<|im_start|>assistant\n")
trainer.train()

model.save_pretrained(f"{args.out}/lora"); tokenizer.save_pretrained(f"{args.out}/lora")
try:
    # Needs a C compiler on the training machine (it builds llama.cpp).
    model.save_pretrained_gguf(f"{args.out}/gguf", tokenizer, quantization_method=args.quant)
    print(f"done. Copy the .gguf file in {args.out}/gguf to your Mac, next to Modelfile.")
except Exception as error:
    print(f"GGUF export failed ({error}); saving the merged model instead.")
    model.save_pretrained_merged(f"{args.out}/merged", tokenizer, save_method="merged_16bit")
    print(f"done. Copy {args.out}/merged to your Mac and import it with: ollama create snapschedule -f Modelfile.merged --quantize q4_K_M")

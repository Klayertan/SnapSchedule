#!/usr/bin/env python3
"""Score a model served over an OpenAI-compatible API (Ollama, vLLM, LM Studio, Sakura AI Engine).

Run this BEFORE training to see how good an untrained model already is, and again after.
  python eval.py --model qwen2.5:7b                        # Ollama on this machine
  python eval.py --model snapschedule --data data/real_test.jsonl --show
An event counts as correct when its day, start time and end time all match (titles are reported separately).
"""
import argparse, json, re, urllib.request

def ask(url, key, model, messages):
    body = json.dumps({"model": model, "temperature": 0, "messages": messages}).encode()
    headers = {"Content-Type": "application/json"}
    if key: headers["Authorization"] = f"Bearer {key}"
    with urllib.request.urlopen(urllib.request.Request(url.rstrip("/") + "/chat/completions", body, headers), timeout=900) as r:
        return json.load(r)["choices"][0]["message"]["content"] or ""

def parse(text):
    m = re.search(r"\{.*\}", text, re.S)
    try: return json.loads(m.group(0)).get("events", []) if m else None
    except Exception: return None

def norm(s): return re.sub(r"\s+", "", s or "")

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://localhost:11434/v1")
    ap.add_argument("--key", default="")
    ap.add_argument("--model", required=True)
    ap.add_argument("--data", default="data/test.jsonl")
    ap.add_argument("--limit", type=int, default=30)
    ap.add_argument("--show", action="store_true", help="print each answer next to the expected one")
    args = ap.parse_args()
    tp = fp = fn = titles = broken = perfect = n = 0
    for line in list(open(args.data, encoding="utf-8"))[: args.limit]:
        msgs = json.loads(line)["messages"]
        want = json.loads(msgs[2]["content"])["events"]
        got = parse(ask(args.url, args.key, args.model, msgs[:2]))
        n += 1
        if got is None: broken += 1; got = []
        key = lambda e: (e.get("start", "")[:16], e.get("end", "")[:16])
        want_by, got_keys = {key(e): e for e in want}, [key(e) for e in got]
        hit = [e for e in got if key(e) in want_by]
        tp += len(hit); fp += len(got) - len(hit); fn += len([k for k in want_by if k not in got_keys])
        titles += sum(norm(want_by[key(e)]["title"]) in norm(e.get("title", "")) or norm(e.get("title", "")) in norm(want_by[key(e)]["title"]) for e in hit)
        perfect += len(hit) == len(got) == len(want)
        if args.show:
            print("EXPECTED:", *[f"\n  {e['start']}–{e['end'][11:]} {e['title']}" for e in want])
            print("GOT:     ", *[f"\n  {e.get('start')}–{str(e.get('end'))[11:]} {e.get('title')}" for e in got], "\n")
        print(f"[{n}] correct {len(hit)}/{len(want)}, extra {len(got) - len(hit)}", flush=True)
    p, r = tp / max(tp + fp, 1), tp / max(tp + fn, 1)
    print(f"\n{n} timetables | fully correct: {perfect} | precision {p:.0%} recall {r:.0%} F1 {2 * p * r / max(p + r, 1e-9):.0%}"
          f" | right title among correct slots: {titles}/{max(tp, 1)} | unparseable answers: {broken}")

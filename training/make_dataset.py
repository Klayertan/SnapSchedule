#!/usr/bin/env python3
"""Generate synthetic timetables as training data for SnapSchedule's "AI server" mode.

Each example is a chat in exactly the shape the app sends:
  system    = the app's instructions (prompt_template.txt)
  user      = "Extract the calendar events from this source." + positioned text fragments
  assistant = the JSON the app expects

Usage:  python make_dataset.py --count 3000 --size small --out data
"""
import argparse, datetime as dt, json, random
from pathlib import Path

HERE = Path(__file__).parent
TEMPLATE = (HERE / "prompt_template.txt").read_text(encoding="utf-8")

SUBJECTS_JA = """数値解析 応用システム設計 機械力学 ロボティクス 卒業研究 線形代数 微分積分 応用数学 電磁気学 熱力学 流体力学
材料力学 制御工学 電気回路 電子回路 情報理論 計算機ネットワーク データベース ソフトウェア工学 信号処理 画像処理 人工知能
プログラミング アルゴリズム 英語 国語 歴史 地理 政治・経済 物理 化学 生物 保健・体育 美術 音楽 倫理 現代社会と法
国語表現法 技術者倫理 工学実験 創造設計製作 計測工学 半導体工学 通信工学 機械設計製図 有機化学 無機化学 物理化学
分析化学 統計学 確率論 離散数学 オペレーティングシステム コンパイラ 情報セキュリティ 経営工学 ドイツ語 中国語""".split()
SUBJECTS_EN = """Calculus|Linear Algebra|Physics|Chemistry|Biology|English Literature|World History|Geography|Economics|
Computer Science|Algorithms|Databases|Operating Systems|Statistics|Art|Music|Physical Education|Philosophy|Psychology|
Signal Processing|Thermodynamics|Robotics|Machine Learning|Lab|Seminar|Thesis Research|Spanish|French""".replace("\n", "").split("|")
ELECTIVES_JA = "地域学 日本文化学 人間環境学 伝送工学 高電圧工学 音楽 美術 数理データサイエンス 経営学 心理学 哲学".split()
SUFFIX_JA = ["", "", "", "Ⅰ", "Ⅱ", "Ⅲ", "演習", "実験", "特論", "α", "β"]
TEACHERS_JA = "佐藤 鈴木 高橋 田中 伊藤 渡辺 山本 中村 小林 加藤 吉田 山田 松本 井上 木村 橋爪 太田 増山 新井 上島 早川 山野 福岡 永井 池田 石丸".split()
TEACHERS_EN = "Smith Johnson Lee Brown Garcia Miller Davis Wilson Tanaka Kim Patel Nguyen Martin Clark".split()
ROOMS = ["情報処理演習室1", "情報処理演習室2", "合同教室", "大視聴覚室", "第2講義室", "Room 101", "Room 204", "Lab B", "Hall A", "3-205"]
DAYS = {"ja": ["月", "火", "水", "木", "金", "土"], "ja2": ["月曜日", "火曜日", "水曜日", "木曜日", "金曜日", "土曜日"],
        "en": ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat"], "en2": ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]}
# (start, end) in minutes since midnight for each period.
PERIOD_SCHEMES = [
    [(540, 585), (585, 630), (640, 685), (685, 730), (780, 825), (825, 870), (880, 925), (925, 970)],  # 45 min x 8
    [(540, 630), (640, 730), (780, 870), (880, 970)],                                                  # 90 min x 4
    [(530, 580), (590, 640), (650, 700), (710, 760), (810, 860), (870, 920)],                          # 50 min x 6
    [(540, 640), (650, 750), (800, 900), (910, 1010), (1020, 1120)],                                   # 100 min x 5
    [(480, 540), (540, 600), (600, 660), (660, 720), (780, 840), (840, 900), (900, 960)],              # 60 min x 7
]


def clock(m): return f"{m // 60}:{m % 60:02d}"
def width(text, scale): return sum(scale if ord(c) > 0x2E7F else scale * 0.55 for c in text)


class Page:
    def __init__(self): self.chunks = []
    def put(self, text, cx, cy, scale=5.0, max_width=None):
        """Place text centred on (cx, cy), shrinking it to fit its cell like a real PDF would."""
        w = width(text, scale)
        if max_width and w > max_width: w = max_width
        j = random.uniform(-0.8, 0.8)
        self.chunks.append((cy + random.uniform(-0.5, 0.5), cx - w / 2 + j, cx + w / 2 + j, text))
    def left(self, text, x, cy, scale=5.0):
        self.chunks.append((cy, x, x + width(text, scale), text))
    def render(self):
        rows = sorted(self.chunks, key=lambda c: (c[0], c[1]))
        return "## Page 1\n" + "\n".join(f"y={round(y)} x={round(a)}-{round(b)} | {t}" for y, a, b, t in rows)


def subject(lang):
    if lang == "en": return random.choice(SUBJECTS_EN)
    return random.choice(SUBJECTS_JA) + random.choice(SUFFIX_JA)

def teacher(lang):
    names = TEACHERS_EN if lang == "en" else TEACHERS_JA
    n = "・".join(random.sample(names, random.choice([1, 1, 1, 2])))
    return n, random.choice(["（{}）", "({})", "（{}）"]).format(n)

def next_date(now, weekday):  # weekday: 0 = Monday
    return now.date() + dt.timedelta(days=(weekday - now.weekday()) % 7)

def event(now, weekday, start, end, title, location="", notes=""):
    d = next_date(now, weekday).isoformat()
    return {"title": title, "start": f"{d}T{start // 60:02d}:{start % 60:02d}", "end": f"{d}T{end // 60:02d}:{end % 60:02d}",
            "allDay": False, "location": location, "notes": notes, "repeatsWeekly": True}


def wide_grid(now, size):
    """Whole-school grid: days across the top, each split into periods; one row per class."""
    lang = random.choice(["ja", "ja", "ja", "en"])
    periods = random.choice(PERIOD_SCHEMES)
    n_days, n_periods = random.choice([5, 5, 6]), len(periods)
    n_rows = random.randint(2, 6) if size == "small" else random.randint(5, 25)
    letters = random.sample("MESICABDKJ", 5)
    labels = [f"{g}{c}" for g in range(1, 6) for c in letters]
    random.shuffle(labels)
    labels = sorted(labels[:n_rows])
    mine = random.choice(labels)
    page = Page()
    x0, x1 = random.uniform(70, 110), random.uniform(930, 970)
    col = (x1 - x0) / (n_days * n_periods)
    top = random.uniform(80, 160)
    row_h = random.uniform(15, 24) if n_rows > 8 else random.uniform(24, 60)
    scale = min(5.0, col * 0.42)
    page.left(random.choice(["授業時間割", "時間割（後期）", "Class Timetable", "令和8年度 授業時間割"]), random.uniform(300, 500), top - 25, 7)
    names = DAYS[lang]
    for d in range(n_days):
        page.put(names[d], x0 + (d + 0.5) * n_periods * col, top)
        for p in range(n_periods):
            cx = x0 + (d * n_periods + p + 0.5) * col
            page.put(str(p + 1), cx, top + 9, scale)
            page.put(clock(periods[p][0]), cx, top + 17, scale * 0.8)
            page.put(clock(periods[p][1]), cx, top + 25, scale * 0.8)
    electives = random.sample(ELECTIVES_JA, 3)
    taken = random.sample(electives, random.choice([0, 1, 1, 2]))
    events, body = [], top + 34
    for r, label in enumerate(labels):
        cy = body + (r + 0.5) * row_h
        page.put(label, x0 - random.uniform(8, 14), cy, 5)
        for d in range(n_days):
            p = 0
            while p < n_periods:
                roll = random.random()
                span = 1 if roll < 0.25 else 2 if roll < 0.8 else random.choice([3, 4, n_periods])
                span = min(span, n_periods - p)
                if random.random() < 0.35:  # free slot
                    p += span; continue
                is_elective = lang != "en" and random.random() < 0.12
                name = random.choice(electives) if is_elective else subject(lang)
                shown = f"[選]{name}" if is_elective else name
                who, who_shown = teacher(lang)
                cx = x0 + (d * n_periods + p + span / 2) * col
                page.put(shown, cx, cy - row_h * 0.2, scale, span * col - 2)
                if random.random() < 0.9:
                    page.put(who_shown, cx, cy + row_h * 0.2, scale * 0.9, span * col - 2)
                else:
                    who = ""
                if label == mine and (not is_elective or name in taken):
                    events.append(event(now, d, periods[p][0], periods[p + span - 1][1], shown, notes=who))
                p += span
    if random.random() < 0.6:
        page.left(random.choice(["※空き時間は自学自習に活用すること", "※教室変更は掲示で確認", "* Rooms may change; check the notice board."]), x0, body + n_rows * row_h + 12, 5)
    ctx = random.choice([
        f"{mine}の学生です。" + (f"選択科目は{'と'.join(taken)}を取っています。" if taken else "選択科目は取っていません。"),
        f"I'm in class {mine}. " + (f"Electives: {', '.join(taken)}." if taken else "I take no electives."),
        f"クラス: {mine}　選択: {'、'.join(taken) if taken else 'なし'}",
    ])
    return page.render(), events, ctx


def classic_grid(now, size):
    """Personal timetable: weekdays across the top, one row per period with its time on the left."""
    lang = random.choice(["ja", "ja2", "en", "en2"])
    simple = "en" if lang.startswith("en") else "ja"
    periods = random.choice(PERIOD_SCHEMES)
    n_days = random.choice([5, 5, 6])
    page = Page()
    x0, x1 = random.uniform(120, 200), random.uniform(850, 960)
    col = (x1 - x0) / n_days
    top = random.uniform(100, 220)
    row_h = random.uniform(40, 90)
    for d in range(n_days):
        page.put(DAYS[lang][d], x0 + (d + 0.5) * col, top, 6)
    style = random.choice(["two", "one", "wave"])
    for p, (s, e) in enumerate(periods):
        cy = top + 20 + (p + 0.5) * row_h
        page.put(str(p + 1) + random.choice(["", "限", ""]), x0 - 70, cy, 6)
        if style == "two":
            page.put(clock(s), x0 - 35, cy - 6, 4.5); page.put(clock(e), x0 - 35, cy + 6, 4.5)
        else:
            page.put(f"{clock(s)}{'-' if style == 'one' else '〜'}{clock(e)}", x0 - 35, cy, 4)
    events = []
    for d in range(n_days):
        slots, p = [], 0
        while p < len(periods):
            if random.random() < 0.3: p += 1; continue
            run = min(random.choice([1, 1, 2]), len(periods) - p)
            name = subject(simple); who, who_shown = teacher(simple)
            room = random.choice(ROOMS) if random.random() < 0.5 else ""
            for q in range(p, p + run):  # a double period is printed once per row
                cx, cy = x0 + (d + 0.5) * col, top + 20 + (q + 0.5) * row_h
                page.put(name, cx, cy - row_h * 0.22, 5.5, col - 4)
                page.put(who_shown, cx, cy, 4.5, col - 4)
                if room: page.put(room, cx, cy + row_h * 0.22, 4.5, col - 4)
            events.append(event(now, d, periods[p][0], periods[p + run - 1][1], name, room, who))
            p += run + (1 if run == 2 else 0)  # keep back-to-back copies of a subject from merging by accident
    ctx = random.choice(["", "", "大学3年生です", "This is my own timetable."])
    return page.render(), events, ctx


def system_prompt(now, ctx):
    text = TEMPLATE.replace("{{NOW}}", now.strftime("%A, %Y-%m-%d %H:%M")).replace("{{TZ}}", "Asia/Tokyo")
    if ctx: return text.replace("{{CONTEXT}}", ctx)
    head, rest = text.split("\n\nAbout the user", 1)  # the app omits this block when the box is empty
    return head + "\n\nThe source's text is given" + rest.split("\n\nThe source's text is given", 1)[1]


def example(size):
    now = dt.datetime(2025, 1, 1) + dt.timedelta(minutes=random.randint(0, 3 * 365 * 24 * 60))
    layout, events, ctx = random.choice([wide_grid, wide_grid, classic_grid])(now, size)
    events.sort(key=lambda e: e["start"])
    return {"messages": [
        {"role": "system", "content": system_prompt(now, ctx)},
        {"role": "user", "content": "Extract the calendar events from this source.\n\n" + layout},
        {"role": "assistant", "content": json.dumps({"events": events}, ensure_ascii=False)},
    ]}


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--count", type=int, default=3000)
    ap.add_argument("--test", type=int, default=100, help="held-out examples for eval.py")
    ap.add_argument("--size", choices=["small", "full"], default="small",
                    help="small: up to 6 classes per grid (fits a 12 GB GPU). full: up to 25 classes (needs a big GPU)")
    ap.add_argument("--out", default="data")
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()
    random.seed(args.seed)
    out = Path(args.out); out.mkdir(exist_ok=True)
    for name, n in [("train.jsonl", args.count), ("test.jsonl", args.test)]:
        with open(out / name, "w", encoding="utf-8") as f:
            for _ in range(n): f.write(json.dumps(example(args.size), ensure_ascii=False) + "\n")
        print(f"wrote {n} examples to {out / name}")

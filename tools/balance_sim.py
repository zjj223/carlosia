# -*- coding: utf-8 -*-
"""场景数值平衡自测：模拟每个场景探索 100 次，看能不能升到该场景满级。"""
import re, random, io

SRC = r"D:\上课游戏\app.js"
src = io.open(SRC, encoding="utf-8").read()

# ---- 1. 取出 SCENE_SPOTS 的 6 个探索点经验区间 ----
spots_start = src.index("const SCENE_SPOTS = Object.freeze({")
spots_end = src.index("\n  });", spots_start)
spot_block = src[spots_start:spots_end]

scene_ids = ["grassland", "volcano", "mermaid-bay", "academy", "snow-valley",
             "thunder-valley", "shadow-forest", "dark-swamp", "dragon-realm", "sky-city"]
pos = []
for sid in scene_ids:
    key = ('        "%s": [' % sid) if "-" in sid else ('        %s: [' % sid)
    idx = spot_block.find(key)
    if idx < 0:
        idx = spot_block.find('    "%s": [' % sid)
    if idx < 0:
        idx = spot_block.find('    %s: [' % sid)
    pos.append(idx)

spot_exp = {}
for i, sid in enumerate(scene_ids):
    end = pos[i + 1] if i + 1 < len(pos) else len(spot_block)
    seg = spot_block[pos[i]:end]
    pairs = re.findall(r"exp:\s*\[(\d+),\s*(\d+)\]", seg)
    spot_exp[sid] = [(int(a), int(b)) for a, b in pairs]

# ---- 2. 经验倍率 & 遇敌率 & 等级段 ----
# 只在 SCENE_EXP_MULT 这一块里取，避免抓到别的配置
ms = src.index("const SCENE_EXP_MULT")
me = src.index("});", ms)
mult_block = src[ms:me]
mult = {}
for sid, m in re.findall(
    r'"?(grassland|volcano|mermaid-bay|academy|snow-valley|thunder-valley|shadow-forest|dark-swamp|dragon-realm|sky-city)"?:\s*([0-9.]+)',
    mult_block,
):
    mult[sid] = float(m)

enc = {}
for sid, rate in re.findall(r'"?(grassland|volcano|mermaid-bay|academy|snow-valley|thunder-valley|shadow-forest|dark-swamp|dragon-realm|sky-city)"?:\s*\{[^\n]*?encounterRate:\s*([0-9.]+)', src):
    enc[sid] = float(rate)

levels = {}
for sid, body in re.findall(r'"?(grassland|volcano|mermaid-bay|academy|snow-valley|thunder-valley|shadow-forest|dark-swamp|dragon-realm|sky-city)"?:\s*\{[^\n]*?levels:\s*\[([^\]]*(?:\][^\]]*)*?)\],\s*levelRange', src):
    levels[sid] = [(int(a), int(b)) for a, b in re.findall(r"\[(\d+),\s*(\d+)\]", "[" + body + "]")]

def upgrade_cost(lv):
    if lv <= 10:
        return 110 + lv * 70
    if lv <= 30:
        return 220 + lv * 110
    return 450 + lv * 170

# ---- 3. 模拟 ----
random.seed(20261121)
TRIALS = 300   # 每个场景跑 300 次"100 步探索"，取平均
results = []

for sid in scene_ids:
    if sid not in spot_exp or len(spot_exp.get(sid, [])) != 6:
        results.append((sid, "数据缺失", 0, 0, 0))
        continue
    lv_floor = levels[sid][0][0]
    lv_ceiling = levels[sid][-1][1]
    p = enc.get(sid, 0.5)
    m = mult.get(sid, 1.0)
    comp = 1.0 / (1.0 - p)

    reached = []
    for _ in range(TRIALS):
        lv = lv_floor
        exp = 0
        for step in range(100):
            lo, hi = spot_exp[sid][random.randrange(6)]
            if random.random() >= p:          # 没遇敌才给经验
                exp += int(round(random.randint(lo, hi) * comp * m))
            c = upgrade_cost(lv)
            if exp >= c and lv < 120:          # 每次探索最多升一级
                exp -= c
                lv += 1
        reached.append(lv)

    avg_lv = sum(reached) / len(reached)
    hit = sum(1 for x in reached if x >= lv_ceiling) / len(reached)
    results.append((sid, spot_exp[sid][0], lv_floor, lv_ceiling, avg_lv, hit))

print("%-14s %-8s %-8s %-8s %-10s %s" % ("场景", "起点", "满级", "均等级", "达标率", "例子"))
for r in results:
    if len(r) == 5:
        print(r)
    else:
        sid, first, lo, hi, avg, hit = r
        print("%-14s %-8d %-8d %-8.1f %-10s %s" % (sid, lo, hi, avg, "%.0f%%" % (hit * 100), first))

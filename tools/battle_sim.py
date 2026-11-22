# -*- coding: utf-8 -*-
"""战斗胜率自测：玩家宠物等级取该探索点的等级上限，对同点野生宠物平均等级。"""
import re, random, io

src = io.open(r"D:\上课游戏\app.js", encoding="utf-8").read()

BASE_HP, BASE_ATK, BASE_DEF, BASE_SPD = 80, 10, 8, 8
ATK_PER, DEF_PER, SPD_PER = 2, 1.5, 1

def hp(lv):  return BASE_HP + (lv - 1) * 10
def atk(lv): return int(BASE_ATK + (lv - 1) * ATK_PER)
def dfn(lv): return int(BASE_DEF + (lv - 1) * DEF_PER)
def spd(lv): return int(BASE_SPD + (lv - 1) * SPD_PER)

def battle(plv, wlv, trials=4000):
    wins = 0
    gap = max(0, min(2, wlv - plv))   # 越级保护：补攻防
    for _ in range(trials):
        php, whp = hp(plv), hp(wlv)
        pfirst = spd(plv) >= spd(wlv)
        patk, pdef, watk, wdef = atk(plv) + gap * 3, dfn(plv) + gap * 2, atk(wlv), dfn(wlv)
        round_ = 0
        while php > 0 and whp > 0 and round_ < 30:
            round_ += 1
            if pfirst:
                whp -= max(1, patk - wdef // 2 + random.randint(-2, 2))
                if whp <= 0: break
                php -= max(1, watk - pdef // 2 + random.randint(-2, 2))
            else:
                php -= max(1, watk - pdef // 2 + random.randint(-2, 2))
                if php <= 0: break
                whp -= max(1, patk - wdef // 2 + random.randint(-2, 2))
        if php > 0 and whp <= 0: wins += 1
    return wins / trials

# 各场景 6 个点的等级段（与 app.js 一致）
levels = {
 "grassland": [[1,2],[2,5],[4,7],[6,9],[7,10],[10,10]],
 "volcano": [[11,12],[12,15],[14,17],[16,19],[17,20],[20,20]],
 "mermaid-bay": [[21,22],[22,25],[24,27],[26,29],[27,30],[30,30]],
 "academy": [[31,32],[32,35],[34,37],[36,39],[37,40],[40,40]],
 "snow-valley": [[41,42],[42,45],[44,47],[46,49],[47,50],[50,50]],
 "thunder-valley": [[51,52],[52,55],[54,57],[56,59],[57,60],[60,60]],
 "shadow-forest": [[61,62],[62,65],[64,67],[66,69],[67,70],[70,70]],
 "dark-swamp": [[71,72],[72,75],[74,77],[76,79],[77,80],[80,80]],
 "dragon-realm": [[81,82],[82,85],[84,87],[86,89],[87,90],[90,90]],
 "sky-city": [[91,92],[92,95],[94,97],[96,99],[97,100],[100,100]],
}

random.seed(7)
print("%-14s %s" % ("场景", "宠物=该点上限 时的胜率（6 个点）"))
for sid, segs in levels.items():
    row = []
    for lo, hi in segs:
        wlv = (lo + hi) // 2
        row.append("%.0f%%" % (battle(hi, wlv) * 100))
    print("%-14s %s" % (sid, "  ".join(row)))

print()
print("宠物比该点上限低 1 级")
for sid, segs in levels.items():
    row = []
    for lo, hi in segs:
        wlv = (lo + hi) // 2
        row.append("%.0f%%" % (battle(max(1, hi - 1), wlv) * 100))
    print("%-14s %s" % (sid, "  ".join(row)))

print()
print("宠物比该点上限低 2 级")
for sid, segs in levels.items():
    row = []
    for lo, hi in segs:
        wlv = (lo + hi) // 2
        row.append("%.0f%%" % (battle(max(1, hi - 2), wlv) * 100))
    print("%-14s %s" % (sid, "  ".join(row)))

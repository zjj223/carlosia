# -*- coding: utf-8 -*-
"""新手期（草原 1-10 级）逐格胜率：验证"1 级宠也能打过 2 级怪"，不卡关。"""
import random

BASE_HP, BASE_ATK, BASE_DEF, BASE_SPD = 80, 10, 8, 8

def hp(lv):  return BASE_HP + (lv - 1) * 10
def atk(lv): return int(BASE_ATK + (lv - 1) * 2)
def dfn(lv): return int(BASE_DEF + (lv - 1) * 1.5)
def spd(lv): return int(BASE_SPD + (lv - 1) * 1)

def battle(plv, wlv, trials=4000):
    wins = 0
    gap = max(0, min(2, wlv - plv))
    for _ in range(trials):
        php, whp = hp(plv), hp(wlv)
        pfirst = spd(plv) >= spd(wlv)
        patk, pdef, watk, wdef = atk(plv) + gap * 3, dfn(plv) + gap * 2, atk(wlv), dfn(wlv)
        r = 0
        while php > 0 and whp > 0 and r < 30:
            r += 1
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

random.seed(11)
print("宠物等级 → 打 1~10 级野怪的胜率")
print("       " + "".join("怪%3d " % w for w in range(1, 11)))
for p in range(1, 11):
    cells = "".join("%4.0f%%" % (battle(p, w) * 100) for w in range(1, 11))
    print("宠%2d → %s" % (p, cells))

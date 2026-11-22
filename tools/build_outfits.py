"""批量处理服装立绘：白底转透明 + 统一尺寸 + 底部对齐。"""
import os
from PIL import Image

RAW = r"D:\上课游戏\assets\outfits\raw"
OUT = r"D:\上课游戏\assets\outfits"
TARGET_W, TARGET_H = 480, 640
WHITE_MIN = 238      # 三通道都高于此值视为背景
WHITE_CHROMA = 12    # 通道之间最大差值，避免把浅色衣服抠掉


def soft_alpha(px):
    r, g, b = px[0], px[1], px[2]
    mx, mn = max(r, g, b), min(r, g, b)
    # 纯白核心区域 -> 全透明
    if mn >= WHITE_MIN and (mx - mn) <= WHITE_CHROMA:
        return 0
    # 接近白但不够纯 -> 半透明过渡，消除毛边
    edge = min(r, g, b)
    if edge >= 225 and (mx - mn) <= 20:
        return int(255 * (WHITE_MIN - edge) / (WHITE_MIN - 225))
    return 255


def process(path, out_path):
    im = Image.open(path).convert("RGBA")
    im = im.resize((TARGET_W, TARGET_H), Image.LANCZOS)
    px = im.load()
    for y in range(TARGET_H):
        for x in range(TARGET_W):
            r, g, b, a = px[x, y]
            alpha = soft_alpha((r, g, b))
            if alpha < a:
                px[x, y] = (r, g, b, alpha)
    # 裁掉四周全透明留白后，按脚底对齐方式重新贴到统一画布
    bbox = im.getbbox()
    if bbox:
        im = im.crop((bbox[0], bbox[1], bbox[2], bbox[3]))
    canvas = Image.new("RGBA", (TARGET_W, TARGET_H), (0, 0, 0, 0))
    if im.width > TARGET_W or im.height > TARGET_H:
        ratio = min(TARGET_W / im.width, TARGET_H / im.height)
        im = im.resize((max(1, int(im.width * ratio)), max(1, int(im.height * ratio)), ), Image.LANCZOS)
    # 水平居中、贴底（人物脚底同一条线）
    canvas.paste(im, ((TARGET_W - im.width) // 2, TARGET_H - im.height), im)
    canvas.save(out_path, "PNG", optimize=True)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    done = 0
    for name in sorted(os.listdir(RAW)):
        if not name.lower().endswith(".png"):
            continue
        src = os.path.join(RAW, name)
        dst = os.path.join(OUT, name)
        process(src, dst)
        done += 1
        print("ok", name, os.path.getsize(dst))
    print("total", done)

"""生成 iOS App 图标 1024x1024（无圆角，系统自己裁）。
用法：~/.workbuddy/binaries/python/envs/default/Scripts/python.exe tools/gen_ios_icon.py
"""
from PIL import Image, ImageDraw
import os

SIZE = 1024
BG = (8, 11, 17)
A = (0x4C, 0x7D, 0xFF)
B = (0x22, 0xD3, 0xEE)
INK = (6, 16, 31)


def lerp(c1, c2, t):
    return tuple(int(c1[i] + (c2[i] - c1[i]) * t) for i in range(3))


def gradient(size, c1, c2, horizontal=True):
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            t = (x / (size - 1) if horizontal else y / (size - 1))
            px[x, y] = lerp(c1, c2, t)
    return img


def main():
    canvas = Image.new("RGB", (SIZE, SIZE), BG)
    d = ImageDraw.Draw(canvas)

    # 背景一点点径向提亮，避免死黑
    glow = Image.new("RGB", (SIZE, SIZE), BG)
    gp = glow.load()
    cx, cy = SIZE * 0.5, SIZE * 0.32
    for y in range(SIZE):
        for x in range(SIZE):
            dist = ((x - cx) ** 2 + (y - cy) ** 2) ** 0.5 / (SIZE * 0.9)
            t = max(0.0, 1.0 - dist) ** 2
            gp[x, y] = lerp(BG, (24, 42, 74), t * 0.9)
    canvas = glow

    # 中央渐变方块（iOS 会自动裁圆角，这里留足安全边距）
    pad = 192
    box = gradient(SIZE - pad * 2, A, B, horizontal=False).convert("RGBA")
    mask = Image.new("L", box.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, box.size[0] - 1, box.size[1] - 1], radius=170, fill=255)
    canvas.paste(box, (pad, pad), mask)

    d = ImageDraw.Draw(canvas)
    # 向下箭头
    cxm = SIZE // 2
    top, bottom = 330, 640
    stem_w = 52
    d.rounded_rectangle([cxm - stem_w // 2, top, cxm + stem_w // 2, bottom - 92], radius=26, fill=INK)
    d.polygon(
        [(cxm - 118, bottom - 168), (cxm + 118, bottom - 168), (cxm, bottom)],
        fill=INK,
    )
    # 底部托盘
    d.rounded_rectangle([cxm - 132, bottom + 52, cxm + 132, bottom + 92], radius=20, fill=INK)

    out = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "GrabBox", "Assets.xcassets", "AppIcon.appiconset", "icon-1024.png",
    )
    canvas.save(out, "PNG")
    print("saved", out, canvas.size)


if __name__ == "__main__":
    main()

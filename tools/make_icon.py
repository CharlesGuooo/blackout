"""Generate assets/blackout.ico — 只用标准库，不依赖 Pillow。

图标就是这个软件本身的样子：黑色圆角方块 + 三条白横线（一份清单）。
16/32/48 用 BMP DIB，256 用 PNG（压缩后才 1-2KB，不然光这一张就 260KB）。

用法： python tools/make_icon.py           -> assets/blackout.ico
      python tools/make_icon.py --icns    -> assets/blackout.icns（macOS）
"""

import os
import struct
import sys
import zlib

SIZES_BMP = (16, 32, 48)
SIZE_PNG = 256

BG = (0, 0, 0, 255)          # 黑底
FG = (255, 255, 255, 255)    # 白线
CLEAR = (0, 0, 0, 0)

# 三条横线的相对位置：(左, 上, 右, 下)，取值 0..1
BARS = (
    (0.18, 0.24, 0.82, 0.36),
    (0.18, 0.44, 0.82, 0.56),
    (0.18, 0.64, 0.62, 0.76),   # 最后一条短一点，看着像没写完的清单
)


def render(size):
    """返回 size*size 的 RGBA 像素，行优先，从上到下。"""
    radius = max(1, round(size / 5.0))
    px = [[CLEAR] * size for _ in range(size)]

    # 黑色圆角方块
    for y in range(size):
        for x in range(size):
            cx = x if x >= radius else radius
            cx = cx if cx <= size - 1 - radius else size - 1 - radius
            cy = y if y >= radius else radius
            cy = cy if cy <= size - 1 - radius else size - 1 - radius
            if (x - cx) ** 2 + (y - cy) ** 2 <= radius * radius:
                px[y][x] = BG

    # 三条白线
    for l, t, r, b in BARS:
        x0, x1 = round(l * size), round(r * size)
        y0, y1 = round(t * size), round(b * size)
        if y1 <= y0:
            y1 = y0 + 1
        for y in range(y0, min(y1, size)):
            for x in range(x0, min(x1, size)):
                px[y][x] = FG
    return px


def bmp_dib(px, size):
    """ICO 里的 BMP：BITMAPINFOHEADER + 32bpp BGRA（自下而上）+ AND 掩码。"""
    header = struct.pack(
        "<IiiHHIIiiII",
        40,            # biSize
        size,          # biWidth
        size * 2,      # biHeight = 图像 + 掩码
        1,             # biPlanes
        32,            # biBitCount
        0, 0, 0, 0, 0, 0,
    )
    body = bytearray()
    for y in range(size - 1, -1, -1):        # 自下而上
        for x in range(size):
            r, g, b, a = px[y][x]
            body += bytes((b, g, r, a))

    # 32bpp 用 alpha，AND 掩码全 0 即可，但每行仍要补齐到 4 字节
    mask_row = (size + 31) // 32 * 4
    body += bytes(mask_row * size)
    return header + bytes(body)


def png(px, size):
    def chunk(tag, data):
        payload = tag + data
        return (struct.pack(">I", len(data)) + payload
                + struct.pack(">I", zlib.crc32(payload) & 0xFFFFFFFF))

    raw = bytearray()
    for y in range(size):
        raw.append(0)                        # 每行的 filter 字节
        for x in range(size):
            raw += bytes(px[y][x])           # RGBA

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b""))


def main():
    images = []
    for s in SIZES_BMP:
        images.append((s, bmp_dib(render(s), s)))
    images.append((SIZE_PNG, png(render(SIZE_PNG), SIZE_PNG)))

    out = bytearray(struct.pack("<HHH", 0, 1, len(images)))   # ICONDIR
    offset = 6 + 16 * len(images)
    for s, data in images:
        out += struct.pack(
            "<BBBBHHII",
            0 if s >= 256 else s,   # 256 在这里写 0
            0 if s >= 256 else s,
            0, 0, 1, 32,
            len(data), offset,
        )
        offset += len(data)
    for _, data in images:
        out += data

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    dest = os.path.join(root, "assets")
    os.makedirs(dest, exist_ok=True)
    path = os.path.join(dest, "blackout.ico")
    with open(path, "wb") as f:
        f.write(out)
    print("wrote %s (%d bytes, %d images)" % (path, len(out), len(images)))


# macOS 图标：(类型码, 像素尺寸)。每项都是一张 PNG，icns 容器本身极简单，
# 直接拼字节，不依赖 iconutil，Windows 上也能生成。
ICNS_TYPES = (
    (b"icp4", 16), (b"icp5", 32), (b"ic11", 32), (b"ic12", 64),
    (b"ic07", 128), (b"ic13", 256), (b"ic08", 256), (b"ic14", 512),
    (b"ic09", 512), (b"ic10", 1024),
)


def render_mac(size):
    """macOS 规范：圆角方块只占画布中间 824/1024，四周留透明边。"""
    inner = round(size * 824 / 1024)
    pad = (size - inner) // 2
    small = render(inner)
    px = [[CLEAR] * size for _ in range(size)]
    for y in range(inner):
        px[pad + y][pad:pad + inner] = small[y]
    return px


def main_icns():
    cache = {}
    body = bytearray()
    for tag, s in ICNS_TYPES:
        if s not in cache:
            cache[s] = png(render_mac(s), s)
        body += tag + struct.pack(">I", 8 + len(cache[s])) + cache[s]
    out = b"icns" + struct.pack(">I", 8 + len(body)) + bytes(body)

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    path = os.path.join(root, "assets", "blackout.icns")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(out)
    print("wrote %s (%d bytes, %d images)" % (path, len(out), len(ICNS_TYPES)))


if __name__ == "__main__":
    if "--icns" in sys.argv[1:]:
        main_icns()
    else:
        main()

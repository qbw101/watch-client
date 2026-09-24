"""生成手表客户端需要的图标 PNG（纯标准库，不依赖 Pillow）。

产物：
    AppScope/resources/base/media/app_icon.png           216x216  应用列表图标
    entry/src/main/resources/base/media/background.png    512x512  分层图标背景
    entry/src/main/resources/base/media/foreground.png    512x512  分层图标前景（带透明）
    entry/src/main/resources/base/media/startIcon.png     216x216  启动窗口图标

为什么不用 Pillow：这个仓库的 Python 环境只装了 playwright 等运行期依赖，
画几个圆角矩形不值得再引一个图像库进来。PNG 的编码本身只需要 zlib + struct。

用法（在项目根目录）：
    python watch-client/tools/make_icons.py
"""

from __future__ import annotations

import math
import struct
import zlib
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]

# 与 bridge/watch.html 同一套配色
BG = (11, 13, 16)
ACCENT = (254, 44, 85)
ACCENT_2 = (37, 244, 238)
WHITE = (255, 255, 255)


# ---------------------------------------------------------------- PNG 编码

def _chunk(tag: bytes, data: bytes) -> bytes:
    return (
        struct.pack(">I", len(data))
        + tag
        + data
        + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    )


def write_png(path: Path, width: int, height: int, pixels: list[tuple[int, int, int, int]]) -> None:
    """pixels 是逐行、从左到右的 RGBA 列表，长度必须是 width*height。"""
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter type 0 (None)
        row = pixels[y * width : (y + 1) * width]
        for r, g, b, a in row:
            raw += bytes((r, g, b, a))

    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)  # 8bit RGBA
    body = _chunk(b"IHDR", header) + _chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + _chunk(b"IEND", b"")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + body)


# ---------------------------------------------------------------- 形状

def rounded_rect_sdf(x: float, y: float, x0: float, y0: float, x1: float, y1: float, r: float) -> float:
    """圆角矩形的近似有符号距离：<=0 在内部。"""
    cx = (x0 + x1) / 2
    cy = (y0 + y1) / 2
    hx = (x1 - x0) / 2 - r
    hy = (y1 - y0) / 2 - r
    dx = abs(x - cx) - hx
    dy = abs(y - cy) - hy
    outside = math.hypot(max(dx, 0.0), max(dy, 0.0))
    inside = min(max(dx, dy), 0.0)
    return outside + inside - r


def circle_sdf(x: float, y: float, cx: float, cy: float, r: float) -> float:
    return math.hypot(x - cx, y - cy) - r


def mix(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    t = max(0.0, min(1.0, t))
    return (
        int(round(a[0] + (b[0] - a[0]) * t)),
        int(round(a[1] + (b[1] - a[1]) * t)),
        int(round(a[2] + (b[2] - a[2]) * t)),
    )


SS = 3  # 每个像素 3x3 超采样，拿到抗锯齿边缘


def render(width: int, height: int, shade):
    """shade(x, y) -> (rgb, alpha)，坐标是像素中心；这里做超采样平均。"""
    pixels: list[tuple[int, int, int, int]] = []
    for py in range(height):
        for px in range(width):
            acc_r = acc_g = acc_b = acc_a = 0.0
            for sy in range(SS):
                for sx in range(SS):
                    x = px + (sx + 0.5) / SS
                    y = py + (sy + 0.5) / SS
                    rgb, alpha = shade(x, y)
                    acc_r += rgb[0] * alpha
                    acc_g += rgb[1] * alpha
                    acc_b += rgb[2] * alpha
                    acc_a += alpha
            n = SS * SS
            a = acc_a / n
            if a <= 0.0005:
                pixels.append((0, 0, 0, 0))
            else:
                pixels.append(
                    (
                        int(round(acc_r / acc_a)),
                        int(round(acc_g / acc_a)),
                        int(round(acc_b / acc_a)),
                        int(round(a * 255)),
                    )
                )
    return pixels


# ---------------------------------------------------------------- 具体画面

def draw_app_icon(size: int):
    """深色底 + 抖音粉对话框 + 青色小圆点。"""
    margin = size * 0.16
    bubble_x0, bubble_y0 = margin, margin * 1.05
    bubble_x1, bubble_y1 = size - margin, size - margin * 1.35
    radius = size * 0.15
    tail_cx, tail_cy = size * 0.36, size * 0.79
    dot_cx, dot_cy = size * 0.40, size * 0.545
    dot_r = size * 0.052
    dot2_cx = size * 0.60

    def shade(x: float, y: float):
        inside_bubble = rounded_rect_sdf(x, y, bubble_x0, bubble_y0, bubble_x1, bubble_y1, radius) <= 0
        inside_tail = circle_sdf(x, y, tail_cx, tail_cy, size * 0.115) <= 0
        if not (inside_bubble or inside_tail):
            return BG, 1.0
        if circle_sdf(x, y, dot_cx, dot_cy, dot_r) <= 0 or circle_sdf(x, y, dot2_cx, dot_cy, dot_r) <= 0:
            return BG, 1.0
        # 气泡本体走抖音配色：左上粉、右下青
        t = (x / size) * 0.35 + (y / size) * 0.65
        return mix(ACCENT, ACCENT_2, t * 0.8), 1.0

    return render(size, size, shade)


def draw_background(size: int):
    """分层图标的背景层：对角渐变（粉 -> 深），不透明。"""
    def shade(x: float, y: float):
        t = (x + y) / (2 * size)
        color = mix(ACCENT, (26, 12, 22), t * 1.15)
        return color, 1.0

    return render(size, size, shade)


def draw_foreground(size: int):
    """分层图标的前景层：居中白色对话框，四周透明。"""
    margin = size * 0.30
    bubble_x0, bubble_y0 = margin, margin * 1.06
    bubble_x1, bubble_y1 = size - margin, size - margin * 1.28
    radius = size * 0.10
    tail_cx, tail_cy = size * 0.39, size * 0.745
    dot_cx, dot_cy = size * 0.42, size * 0.545
    dot_r = size * 0.032
    dot2_cx = size * 0.58

    def shade(x: float, y: float):
        inside_bubble = rounded_rect_sdf(x, y, bubble_x0, bubble_y0, bubble_x1, bubble_y1, radius) <= 0
        inside_tail = circle_sdf(x, y, tail_cx, tail_cy, size * 0.075) <= 0
        if not (inside_bubble or inside_tail):
            return WHITE, 0.0
        if circle_sdf(x, y, dot_cx, dot_cy, dot_r) <= 0 or circle_sdf(x, y, dot2_cx, dot_cy, dot_r) <= 0:
            return ACCENT, 0.0  # 挖空，露出背景层的粉色
        return WHITE, 1.0

    return render(size, size, shade)


def main() -> int:
    targets = [
        (PROJECT_ROOT / "AppScope/resources/base/media/app_icon.png", 216, draw_app_icon),
        (PROJECT_ROOT / "entry/src/main/resources/base/media/startIcon.png", 216, draw_app_icon),
        (PROJECT_ROOT / "entry/src/main/resources/base/media/background.png", 512, draw_background),
        (PROJECT_ROOT / "entry/src/main/resources/base/media/foreground.png", 512, draw_foreground),
    ]
    for path, size, drawer in targets:
        write_png(path, size, size, drawer(size))
        print(f"已生成 {path.relative_to(PROJECT_ROOT)}  ({size}x{size}, {path.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""量一下截图里图标画得正不正。

用法: python tools/measure_icon.py <shots/xxx.jpeg> <shots/xxx.json>

为什么要量而不是靠眼睛：自绘的 Shape/Path 在这块表上会整体偏到左上角，
肉眼看「有点歪」说不清偏多少，量重心能一眼看出偏差是 1px 还是 9px。
"""
import json
import sys

from PIL import Image

TREE_TYPES = {'Stack', 'SymbolGlyph', 'Shape', 'List', 'ListItem', 'Row', 'Text', 'TextInput'}


def nodes(path):
    data = json.load(open(path, encoding='utf-8'))
    if isinstance(data, list):
        data = {'children': data}
    out = []

    def walk(node, depth=0):
        attr = node.get('attributes', {}) or {}
        out.append((depth, attr.get('type', ''), attr.get('text', ''),
                    attr.get('bounds', ''), attr.get('clickable', '')))
        for child in node.get('children', []) or []:
            walk(child, depth + 1)

    walk(data)
    return out


def parse_bounds(text):
    a, b = text.split('][')
    vals = (a.strip('[') + ',' + b.strip(']')).split(',')
    return tuple(int(v) for v in vals)


def centroid(px, box, thr=120):
    l, t, r, b = box
    xs = ys = n = 0
    for y in range(t, b):
        for x in range(l, r):
            if px[x, y] >= thr:
                xs += x
                ys += y
                n += 1
    return (xs / n, ys / n, n) if n else None


def main():
    jpeg, js = sys.argv[1], sys.argv[2]
    im = Image.open(jpeg).convert('L')
    px = im.load()

    print('--- 控件树 ---')
    for depth, typ, text, bounds, clk in nodes(js):
        if bounds and (text or typ in TREE_TYPES):
            pad = '  ' * depth
            print(f"{pad}{typ:<12} '{str(text)[:14]}' {bounds} clk={clk}")

    print()
    print('--- 亮像素重心（图标白、底深灰，所以重心就是图标中心）---')
    for depth, typ, text, bounds, clk in nodes(js):
        if typ not in ('Shape', 'SymbolGlyph'):
            continue
        box = parse_bounds(bounds)
        c = centroid(px, box)
        if c is None:
            continue
        print(f"{typ:<12} {bounds} 重心=({c[0]:.1f},{c[1]:.1f}) "
              f"自身盒中心=({(box[0]+box[2])/2:.1f},{(box[1]+box[3])/2:.1f}) "
              f"偏差=({c[0]-(box[0]+box[2])/2:+.1f},{c[1]-(box[1]+box[3])/2:+.1f})")


if __name__ == '__main__':
    main()

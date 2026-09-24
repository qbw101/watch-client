"""把 uitest dumpLayout 的控件树摊平成「类型 文本 @ 坐标」。
用法: python flat.py <layout.json> [--all]
根节点可能是数组(=dumpLayout -i)或对象，两种都兼容。
"""
import json
import sys

KEEP = {
    'Text', 'Button', 'Image', 'TextInput', 'List', 'Scroll', 'Grid',
    'Toggle', 'Slider', 'Swiper', 'ListItem', 'GridItem', 'Flex',
}


def main():
    path = sys.argv[1]
    show_all = '--all' in sys.argv
    with open(path, encoding='utf-8') as fp:
        data = json.load(fp)
    if isinstance(data, list):
        data = {'attributes': {}, 'children': data}

    lines = []

    def walk(node, depth=0):
        attr = node.get('attributes', {}) or {}
        typ = attr.get('type', '')
        text = attr.get('text', '')
        bounds = attr.get('bounds', '')
        focused = attr.get('focused', '')
        clickable = attr.get('clickable', '')
        if show_all or typ in KEEP or text:
            lines.append(
                f"{'  ' * depth}{typ:<12} {str(text)[:30]:<32} {bounds}"
                f"  clk={clickable} foc={focused}"
            )
        for child in node.get('children', []) or []:
            walk(child, depth + 1)

    walk(data)
    print('\n'.join(lines))


if __name__ == '__main__':
    main()

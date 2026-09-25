"""DevEco 工程的静态预检（纯标准库）。

本机没有装 DevEco Studio，也就没有 ArkTS 编译器，所以这里把「一打开工程
就报错」的那几类问题用脚本挡住：

  1. 所有 json5 配置去掉注释后能否解析；
  2. module.json5 / app.json5 里出现的 $string: / $media: / $color: /
     $profile: 引用是否真的存在对应资源；
  3. main_pages.json 里的页面、module.json5 里的 srcEntry 路径是否落盘；
  4. .ets 源码的括号是否配对（漏一个花括号在 ArkTS 里报的错会离谱到看不出位置）。

它不能替代真机编译，只能在编译之前把低级错误清掉。

用法：
    python watch-client/tools/check_project.py
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]
APP_SCOPE = PROJECT_ROOT / "AppScope"
ENTRY = PROJECT_ROOT / "entry"
# entry 模块的资源在 src/main/resources 下；AppScope 的直接在 resources 下
ENTRY_RES = ENTRY / "src/main"

problems: list[str] = []
notes: list[str] = []


# ---------------------------------------------------------------- json5

def strip_json5(text: str) -> str:
    """把 json5 变成标准 json：去 // 与 /* */ 注释、去尾随逗号。

    只做够用的一层：字符串内的 // 不会被误伤（先按状态机扫一遍）。
    """
    out: list[str] = []
    i = 0
    n = len(text)
    in_string = False
    while i < n:
        ch = text[i]
        if in_string:
            out.append(ch)
            if ch == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
            continue
        if ch == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        if ch == "/" and i + 1 < n and text[i + 1] == "*":
            end = text.find("*/", i + 2)
            i = n if end < 0 else end + 2
            continue
        out.append(ch)
        i += 1
    cleaned = "".join(out)
    cleaned = re.sub(r",(\s*[}\]])", r"\1", cleaned)
    return cleaned


def load_json5(path: Path):
    try:
        return json.loads(strip_json5(path.read_text(encoding="utf-8")))
    except Exception as exc:  # noqa: BLE001
        problems.append(f"{path.relative_to(PROJECT_ROOT)} 解析失败: {exc}")
        return None


# ---------------------------------------------------------------- 资源索引

def collect_element_names(root: Path, kind: str) -> set[str]:
    """收集 $string / $color 这类 element 资源名。kind = 'string' | 'color'"""
    names: set[str] = set()
    for path in root.glob(f"resources/*/element/{kind}.json"):
        data = load_json5(path)
        if isinstance(data, dict):
            for item in data.get(kind, []):
                if isinstance(item, dict) and "name" in item:
                    names.add(str(item["name"]))
    return names


def collect_media_names(root: Path) -> set[str]:
    names: set[str] = set()
    for path in root.glob("resources/*/media/*"):
        names.add(path.stem)
    return names


def collect_profile_names(root: Path) -> set[str]:
    names: set[str] = set()
    for path in root.glob("resources/*/profile/*.json"):
        names.add(path.stem)
    return names


RESOURCE_ROOTS = [APP_SCOPE, ENTRY_RES]
INDEX = {
    "string": set().union(*[collect_element_names(r, "string") for r in RESOURCE_ROOTS]),
    "color": set().union(*[collect_element_names(r, "color") for r in RESOURCE_ROOTS]),
    "media": set().union(*[collect_media_names(r) for r in RESOURCE_ROOTS]),
    "profile": set().union(*[collect_profile_names(r) for r in RESOURCE_ROOTS]),
}

RESOURCE_REF = re.compile(r"\$(string|color|media|profile):([A-Za-z0-9_]+)")


def check_resource_refs(path: Path, data) -> None:
    """递归找出所有 $type:name 引用并核对资源是否存在。"""
    if isinstance(data, dict):
        for value in data.values():
            check_resource_refs(path, value)
    elif isinstance(data, list):
        for value in data:
            check_resource_refs(path, value)
    elif isinstance(data, str):
        for kind, name in RESOURCE_REF.findall(data):
            if name not in INDEX[kind]:
                problems.append(
                    f"{path.relative_to(PROJECT_ROOT)} 引用了不存在的资源 ${kind}:{name}"
                )
            else:
                notes.append(f"ok  ${kind}:{name}  {path.relative_to(PROJECT_ROOT)}")


# ---------------------------------------------------------------- 结构检查

def check_pages() -> None:
    pages_file = ENTRY / "src/main/resources/base/profile/main_pages.json"
    data = load_json5(pages_file)
    if not isinstance(data, dict):
        return
    for page in data.get("src", []):
        target = ENTRY / "src/main/ets" / f"{page}.ets"
        if not target.is_file():
            problems.append(f"main_pages.json 里的页面不存在: {page} -> {target.relative_to(PROJECT_ROOT)}")


def check_src_entries() -> None:
    module_file = ENTRY / "src/main/module.json5"
    data = load_json5(module_file)
    if not isinstance(data, dict):
        return
    module = data.get("module", {})
    for ability in module.get("abilities", []) + module.get("extensionAbilities", []):
        src = ability.get("srcEntry")
        if not src:
            continue
        target = ENTRY / "src/main" / src.lstrip("./")
        if not target.is_file():
            problems.append(f"{ability.get('name')} 的 srcEntry 不存在: {src}")


def check_no_stray_files() -> None:
    """拦下会被打进 HAP 的临时/备份文件。

    hvigor 打包**不看 .gitignore** —— `entry/src` 下有什么就塞什么。
    调试脚本留下的 `.ets.bak` 备份就是这么混进产物的（曾经让 827KB 的包
    虚胖到 1.2MB），而备份是改动**之前**的原文，可能带着当时还没脱敏的内容。
    """
    suffixes = ("~", ".orig", ".tmp", ".old", ".swp", ".bak")
    for path in sorted((ENTRY / "src").rglob("*")):
        if not path.is_file():
            continue
        name = path.name
        if name.endswith(suffixes) or ".bak" in name:
            problems.append(
                f"会被打进 HAP 的临时/备份文件: {path.relative_to(PROJECT_ROOT)}"
                "（删除，或移到 entry/src 之外）"
            )


def check_brace_balance() -> None:
    """粗略检查 .ets 的括号配对：先剥字符串和注释，再数括号。"""
    pairs = {"}": "{", ")": "(", "]": "["}
    for path in sorted((ENTRY / "src/main/ets").rglob("*.ets")):
        text = path.read_text(encoding="utf-8")
        stripped: list[str] = []
        i = 0
        n = len(text)
        in_string: str | None = None
        while i < n:
            ch = text[i]
            if in_string:
                if ch == "\\":
                    i += 2
                    continue
                if ch == in_string:
                    in_string = None
                i += 1
                continue
            if ch in ('"', "'", "`"):
                in_string = ch
                i += 1
                continue
            if ch == "/" and i + 1 < n and text[i + 1] == "/":
                while i < n and text[i] != "\n":
                    i += 1
                continue
            if ch == "/" and i + 1 < n and text[i + 1] == "*":
                end = text.find("*/", i + 2)
                i = n if end < 0 else end + 2
                continue
            stripped.append(ch)
            i += 1

        stack: list[tuple[str, int]] = []
        line = 1
        for ch in stripped:
            if ch == "\n":
                line += 1
            elif ch in "{([":
                stack.append((ch, line))
            elif ch in pairs:
                if not stack or stack[-1][0] != pairs[ch]:
                    problems.append(f"{path.relative_to(PROJECT_ROOT)}:{line} 多余的 '{ch}'")
                    stack.clear()
                    break
                stack.pop()
        if stack:
            ch, line = stack[-1]
            problems.append(f"{path.relative_to(PROJECT_ROOT)}:{line} 未闭合的 '{ch}'")


def main() -> int:
    config_files = [
        PROJECT_ROOT / "build-profile.json5",
        PROJECT_ROOT / "oh-package.json5",
        APP_SCOPE / "app.json5",
        APP_SCOPE / "resources/base/element/string.json",
        ENTRY / "build-profile.json5",
        ENTRY / "oh-package.json5",
        ENTRY / "src/main/module.json5",
        ENTRY / "src/main/resources/base/element/string.json",
        ENTRY / "src/main/resources/base/element/color.json",
        ENTRY / "src/main/resources/base/profile/main_pages.json",
        ENTRY / "src/main/resources/base/media/layered_image.json",
    ]
    for path in config_files:
        if not path.is_file():
            problems.append(f"缺少文件: {path.relative_to(PROJECT_ROOT)}")
            continue
        data = load_json5(path)
        if data is not None:
            check_resource_refs(path, data)

    check_pages()
    check_src_entries()
    check_no_stray_files()
    check_brace_balance()

    print(f"检查了 {len(config_files)} 个配置文件、资源索引 "
          f"string={len(INDEX['string'])} color={len(INDEX['color'])} "
          f"media={len(INDEX['media'])} profile={len(INDEX['profile'])}")
    if problems:
        print("\n发现问题:")
        for item in problems:
            print("  ✗ " + item)
        return 1
    print("\n静态检查通过（仍需 DevEco Studio 真机编译验证）")
    return 0


if __name__ == "__main__":
    sys.exit(main())

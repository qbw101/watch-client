"""对着桥接服务调一次任意 op 并把 JSON 打出来（排查手表端「看到的」和「服务端给的」不一致）。

用法:
    python tools/tcp_probe.py <host:port> <op> [json-params]

例:
    python tools/tcp_probe.py 192.168.1.15:8787 status
    python tools/tcp_probe.py 192.168.1.15:8787 conversations '{"limit":10}'
"""
import json
import os
import sys
from pathlib import Path

BRIDGE = Path('F:/Desktop/watch-bridge')
sys.path.insert(0, str(BRIDGE))
os.chdir(BRIDGE)

from scripts.tcp_smoke import BridgeTcpClient  # noqa: E402


def _fallback(obj: object) -> str:
    """图片帧等二进制字段：只报长度，不把几百 KB 打进终端。"""
    if isinstance(obj, (bytes, bytearray)):
        return f'<bytes {len(obj)}>'
    return repr(obj)


def main() -> None:
    target = sys.argv[1]
    op = sys.argv[2]
    params = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}
    host, port = target.rsplit(':', 1)
    token = Path('artifacts/watch_token.txt').read_text(encoding='utf-8').strip()
    client = BridgeTcpClient(host, int(port), token)
    client.connect()
    try:
        reply = client.request(op, **params)
        print(json.dumps(reply, ensure_ascii=False, indent=2, default=_fallback)[:6000])
    finally:
        client.close()


if __name__ == '__main__':
    main()

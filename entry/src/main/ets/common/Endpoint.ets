/**
 * 电脑地址的解析。
 *
 * 链路换成裸 TCP 之后，配置项从「http://ip:8787」变成了「地址[:端口]」，因为
 * 已经没有协议头可写了。这里负责把这一个字符串拆成 host + port。
 *
 * 三处刻意的宽容：
 *   1. 端口省略时补默认值 —— 手表上打字极慢，少打四个字符是实打实的体验差别。
 *   2. 连 `http://` / `tcp://` 开头也照收 —— 旧版本存的就是完整 URL，升级后
 *      用户手上和脑子里都是那个旧值，直接报「格式不对」会让人以为地址坏了。
 *   3. 结尾的路径、查询、斜杠一律丢掉 —— 从浏览器地址栏复制粘贴时会带上来。
 */

/** 与 scripts/watch_server.py 的 --port 默认值保持一致 */
export const DEFAULT_PORT: number = 8787;

export interface Endpoint {
  host: string;
  port: number;
  /** 回显用，形如 192.168.1.5:8787 或 [fe80::1]:8787 */
  label: string;
}

/**
 * 解析失败返回 null（调用方据此提示「格式不对」），不抛异常 —— 这个函数在
 * 输入框的每次保存路径上跑，异常会让「保存」按钮直接崩掉。
 */
export function parseEndpoint(text: string): Endpoint | null {
  let raw: string = text.trim();
  if (raw.length === 0) {
    return null;
  }

  const schemeAt: number = raw.indexOf('://');
  if (schemeAt >= 0) {
    raw = raw.slice(schemeAt + 3);
  }
  const separators: string[] = ['/', '?', '#'];
  for (const separator of separators) {
    const at: number = raw.indexOf(separator);
    if (at >= 0) {
      raw = raw.slice(0, at);
    }
  }
  raw = raw.trim();
  if (raw.length === 0) {
    return null;
  }

  let host: string = '';
  let portText: string = '';
  if (raw.startsWith('[')) {
    // IPv6 带端口必须写成 [addr]:port
    const close: number = raw.indexOf(']');
    if (close < 0) {
      return null;
    }
    host = raw.slice(1, close);
    const rest: string = raw.slice(close + 1);
    if (rest.startsWith(':')) {
      portText = rest.slice(1);
    } else if (rest.length > 0) {
      return null;
    }
  } else {
    const colons: number = raw.split(':').length - 1;
    if (colons > 1) {
      // 裸 IPv6，末尾那段也可能是端口，但分不清就不猜：这种地址必须用方括号形式
      host = raw;
    } else if (colons === 1) {
      const at: number = raw.indexOf(':');
      host = raw.slice(0, at);
      portText = raw.slice(at + 1);
    } else {
      host = raw;
    }
  }

  host = host.trim();
  if (host.length === 0 || host.indexOf(' ') >= 0) {
    return null;
  }

  let port: number = DEFAULT_PORT;
  if (portText.trim().length > 0) {
    port = Number(portText.trim());
    if (!Number.isInteger(port) || port < 1 || port > 65535) {
      return null;
    }
  }

  const label: string = host.indexOf(':') >= 0 ? `[${host}]:${port}` : `${host}:${port}`;
  return { host: host, port: port, label: label };
}

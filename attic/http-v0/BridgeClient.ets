/**
 * 电脑端桥接服务的 HTTP 客户端。
 *
 * 与 bridge/server.py 的接口一一对应：
 *     GET  /api/status                       → WatchStatus（含 watch_stickers 表情库）
 *     GET  /api/messages?name=&limit=&rev=   → WatchMessages（rev 未变时只回 unchanged）
 *     POST /api/send   { name, text|sticker }→ WatchSendResult
 *     GET  /api/media?url=&token=            → 图片二进制（由 Image 组件直接加载，不走这里）
 *     GET  /api/sticker_thumb?id=&token=     → 表情库缩略图（同上，直接喂给 Image）
 *
 * 两处刻意的设计：
 * 1. 每个请求都新建 HttpRequest 并在 finally 里 destroy()。轮询和发送会并发，
 *    共用一个实例在 HarmonyOS 上是不允许的（同实例不能同时发多个请求）。
 * 2. usingCache 一律 false。服务端已经用 Cache-Control: no-store 表了态，
 *    这里再关一层，免得拿到过期的消息列表。
 */
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

import { SendPayload, WatchErrorBody, WatchMessages, WatchSendResult, WatchStatus } from '../common/Types';

const DOMAIN: number = 0x0001;
const TAG: string = 'BridgeClient';

/** 服务端 /api/send 最多允许 180s，这里给 60s 已经足够（实测发送 3~10s） */
const SEND_TIMEOUT_MS: number = 60000;
const READ_TIMEOUT_MS: number = 30000;
const STATUS_TIMEOUT_MS: number = 20000;

export class BridgeError extends Error {
  /** HTTP 状态码；网络层失败时为 0 */
  code: number;

  constructor(message: string, code: number) {
    super(message);
    this.code = code;
  }
}

export class BridgeClient {
  /** 形如 http://192.168.1.10:8787 */
  baseUrl: string = '';
  token: string = '';

  configure(baseUrl: string, token: string): void {
    this.baseUrl = BridgeClient.normalize(baseUrl);
    this.token = token.trim();
  }

  get configured(): boolean {
    return this.baseUrl.length > 0 && this.token.length > 0;
  }

  /** 容忍用户只填「192.168.1.10:8787」或结尾多打斜杠 */
  static normalize(raw: string): string {
    let value: string = raw.trim();
    if (value.length === 0) {
      return '';
    }
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      value = 'http://' + value;
    }
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  /**
   * 媒体代理地址。图片由 ArkUI 的 Image 组件直接加载，没法带自定义请求头，
   * 所以这里只能把令牌放进查询串（服务端 _auth 同时支持这两种方式）。
   */
  mediaUrl(rawUrl: string): string {
    if (rawUrl.length === 0) {
      return '';
    }
    return `${this.baseUrl}/api/media?url=${encodeURIComponent(rawUrl)}&token=${encodeURIComponent(this.token)}`;
  }

  /**
   * 表情库缩略图地址。图在扫描时就落到电脑磁盘上了，不依赖抖音会话，
   * 所以这个地址在服务刚启动、会话还没就绪时也能正常出图。
   */
  stickerThumbUrl(id: string): string {
    if (id.length === 0) {
      return '';
    }
    return `${this.baseUrl}/api/sticker_thumb?id=${encodeURIComponent(id)}&token=${encodeURIComponent(this.token)}`;
  }

  // ------------------------------------------------------------ 业务接口

  async status(): Promise<WatchStatus> {
    const body: string = await this.send('/api/status', http.RequestMethod.GET, '', STATUS_TIMEOUT_MS);
    return BridgeClient.parseBody(body) as WatchStatus;
  }

  async messages(name: string, limit: number, rev: string): Promise<WatchMessages> {
    let path: string = `/api/messages?name=${encodeURIComponent(name)}&limit=${limit}`;
    if (rev.length > 0) {
      path += `&rev=${encodeURIComponent(rev)}`;
    }
    const body: string = await this.send(path, http.RequestMethod.GET, '', READ_TIMEOUT_MS);
    return BridgeClient.parseBody(body) as WatchMessages;
  }

  /**
   * 发文字或原生表情。sticker 非空时优先发表情（与服务端 send_message 的分支一致）。
   * 成功时响应体里已经带了最新消息列表，调用方不用再拉一次。
   */
  async sendMessage(name: string, text: string, sticker: string): Promise<WatchSendResult> {
    const payload: SendPayload = { name: name, text: text, sticker: sticker };
    const body: string = await this.send('/api/send', http.RequestMethod.POST, JSON.stringify(payload), SEND_TIMEOUT_MS);
    return BridgeClient.parseBody(body) as WatchSendResult;
  }

  // ------------------------------------------------------------ 底层

  private async send(path: string, method: http.RequestMethod, bodyJson: string, timeoutMs: number): Promise<string> {
    const request: http.HttpRequest = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: method,
        header: {
          'X-Auth-Token': this.token,
          'Content-Type': 'application/json'
        },
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs,
        expectDataType: http.HttpDataType.STRING,
        usingCache: false
      };
      if (bodyJson.length > 0) {
        options.extraData = bodyJson;
      }
      const response: http.HttpResponse = await request.request(`${this.baseUrl}${path}`, options);
      const text: string = response.result as string;
      if (response.responseCode >= 200 && response.responseCode < 300) {
        return text;
      }
      throw new BridgeError(BridgeClient.errorText(text, response.responseCode), response.responseCode);
    } catch (err) {
      if (err instanceof BridgeError) {
        throw err;
      }
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, '请求 %{public}s 失败: code=%{public}d msg=%{public}s', path, e.code, e.message);
      throw new BridgeError(BridgeClient.networkHint(e), 0);
    } finally {
      request.destroy();
    }
  }

  /**
   * 解析响应体。
   *
   * 地址填成了别的 HTTP 服务（路由器后台、别的网页服务）时，对方会回 HTML，
   * JSON.parse 抛出的是 "Unexpected token < in JSON at position 0" —— 这种东西
   * 摆在手表上没法看，也指导不了任何操作，这里统一换成一句能照着做的提示。
   */
  private static parseBody(body: string): Object {
    try {
      return JSON.parse(body);
    } catch (err) {
      throw new BridgeError('这个地址不是桥接服务：检查 IP 和端口', 0);
    }
  }

  /** 服务端错误体形如 {"error": "..."}，取不到就退回状态码文案 */
  private static errorText(body: string, responseCode: number): string {
    try {
      const parsed: WatchErrorBody = JSON.parse(body) as WatchErrorBody;
      if (parsed.error !== undefined && parsed.error.length > 0) {
        return parsed.error;
      }
    } catch (err) {
      // 非 JSON（比如代理返回的 HTML 错误页），忽略
    }
    return `请求失败（HTTP ${responseCode}）`;
  }

  /** 网络层错误码翻成人话：手表上没地方看日志，提示必须能直接指导操作 */
  private static networkHint(err: BusinessError): string {
    const code: number = err.code;
    if (code === 2300006) {
      return '找不到电脑：检查地址里的 IP 是否写对';
    }
    if (code === 2300007) {
      return '连不上电脑：服务没启动，或不在同一个 Wi-Fi';
    }
    if (code === 2300028) {
      return '请求超时：电脑端可能正忙，稍后重试';
    }
    return `网络异常（${code}）`;
  }
}

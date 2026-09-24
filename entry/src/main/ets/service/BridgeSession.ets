/**
 * 业务层的连接封装：地址解析、连接去重、JSON 解析、图片取数。
 *
 * 这一层替代了原来 BridgeClient 的位置，但它不再是「一次请求一次连接」——
 * 底下是一条常连的 BridgeLink。分层的理由是各自只关心一件事：
 *
 *   BridgeLink   帧、握手、加密、请求/应答配对      —— 不知道抖音的存在
 *   BridgeSession 地址、类型化的返回、图片缓存接线   —— 不知道帧的存在
 *   Index        界面状态                            —— 只调这一层
 *
 * 这里所有方法在失败时抛的都是 BridgeError，`kind` 决定界面怎么反应：
 * token → 跳配置页；network / timeout → 停在错误态并重试；server → 原样转述。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';

import { Endpoint, parseEndpoint } from '../common/Endpoint';
import { WatchConversations, WatchMessages, WatchPush, WatchSendResult, WatchStatus } from '../common/Types';
import { BridgeError, KIND_NETWORK, KIND_SERVER, asBridgeError } from './BridgeError';
import { BridgeLink, ImageReply, StickerThumbBatch } from './BridgeLink';
import { ImageCache } from './ImageCache';

const DOMAIN: number = 0x0001;
const TAG: string = 'BridgeSession';

/**
 * 拉一张图的超时。
 *
 * 比普通请求宽得多：图片字节是在应答之后分帧慢慢过来的，而穿透链路上首图
 * 经常要等几秒（服务端要先去抖音 CDN 取原图再降采样）。
 */
const IMAGE_TIMEOUT_MS: number = 20000;

/**
 * 批量拉整库表情缩略图的超时。
 *
 * 一次几百 KB，慢的链路上要几秒；给得比单张更宽 —— 这一笔失败就等于整屏表情
 * 退回「一张一次往返」的老路，代价远比多等几秒大。
 */
const THUMB_BATCH_TIMEOUT_MS: number = 60000;

export type PushHandler = (data: WatchPush) => void;
export type StateHandler = (connected: boolean, detail: string) => void;

export class BridgeSession {
  private link: BridgeLink = new BridgeLink();
  private host: string = '';
  private port: number = 0;
  private token: string = '';
  private label_: string = '';
  /** 正在建立的那条连接。并发的 connect() 共用它，避免开出两条连接 */
  private connecting: Promise<void> | null = null;

  /** 服务端推来的新消息（已解析） */
  onPush: PushHandler | null = null;
  /** 连接状态变化；断开时要让界面显示出来，否则用户看到的是「卡住不动」 */
  onState: StateHandler | null = null;

  constructor() {
    this.link.onPush = (payload: string) => {
      const handler: PushHandler | null = this.onPush;
      if (handler === null) {
        return;
      }
      try {
        handler(JSON.parse(payload) as WatchPush);
      } catch (err) {
        // 推送内容坏了不能把连接拖下水：丢掉这一帧，下一轮服务端还会再推
        hilog.warn(DOMAIN, TAG, '推送内容无法解析，已忽略');
      }
    };
    this.link.onState = (connected: boolean, detail: string) => {
      const handler: StateHandler | null = this.onState;
      if (handler !== null) {
        handler(connected, detail);
      }
    };
    // 图片缓存不自己持有连接，只能从外面把「怎么取图」塞进去
    ImageCache.instance.setFetcher((kind: string, key: string, px: number): Promise<Uint8Array> => {
      return this.link.fetchImage(kind, key, px, IMAGE_TIMEOUT_MS)
        .then((reply: ImageReply): Uint8Array => reply.bytes);
    });
  }

  // ------------------------------------------------------------ 配置

  /** 解析并保存地址与令牌。地址非法时返回 false，此时不改动已有配置 */
  configure(endpointText: string, token: string): boolean {
    const trimmedToken: string = token.trim();
    if (trimmedToken.length === 0) {
      return false;
    }
    const parsed: Endpoint | null = parseEndpoint(endpointText);
    if (parsed === null) {
      return false;
    }
    this.host = parsed.host;
    this.port = parsed.port;
    this.label_ = parsed.label;
    this.token = trimmedToken;
    return true;
  }

  get configured(): boolean {
    return this.host.length > 0 && this.port > 0 && this.token.length > 0;
  }

  /** 回显给用户看的地址，形如 192.168.1.5:8787 */
  get label(): string {
    return this.label_;
  }

  get connected(): boolean {
    return this.link.connected;
  }

  // ------------------------------------------------------------ 连接

  connect(useCrypto: boolean): Promise<void> {
    if (this.link.connected) {
      return Promise.resolve();
    }
    const flying: Promise<void> | null = this.connecting;
    if (flying !== null) {
      return flying;
    }
    if (!this.configured) {
      return Promise.reject(new BridgeError(KIND_NETWORK, '还没填写电脑地址'));
    }

    const task: Promise<void> = this.link.connect(this.host, this.port, this.token, useCrypto)
      .then(() => {
        this.connecting = null;
        // 换了一条连接，旧的图片地址（带签名的 CDN URL）已经不可用了
        ImageCache.instance.clear();
        hilog.info(DOMAIN, TAG, '已连接 %{public}s', this.label_);
      })
      .catch(async (err: Object): Promise<void> => {
        this.connecting = null;
        // 握手被拒时 socket 还开着，不收掉的话下次 connect 会先在服务端留下
        // 一个已经废弃的会话，那边等到心跳超时才会清
        await this.link.close();
        // 回退类型给 server 而不是 network：socket 层的问题在 BridgeLink 里
        // 都被显式包成了 KIND_NETWORK，走到这里还没被包的只可能是握手/加密
        // 本身出的错 —— 而界面正是靠这个区分「要不要用明文重试一次」。
        throw asBridgeError(err, KIND_SERVER);
      });
    this.connecting = task;
    return task;
  }

  async disconnect(): Promise<void> {
    this.connecting = null;
    await this.link.close();
  }

  /**
   * 立刻探一次链路。回到前台时调用 —— 空转着等心跳定时器醒来，那几秒正好是
   * 用户在盯着屏幕的几秒。
   */
  poke(): void {
    this.link.poke();
  }

  // ------------------------------------------------------------ 业务接口

  async status(): Promise<WatchStatus> {
    const text: string = await this.link.status();
    return BridgeSession.parse(text) as WatchStatus;
  }

  async messages(name: string, limit: number, rev: string): Promise<WatchMessages> {
    const text: string = await this.link.messages(name, limit, rev);
    return BridgeSession.parse(text) as WatchMessages;
  }

  /**
   * 读一次会话列表（昵称 + 最后一条消息预览），只用于给列表行补一行小字。
   * 失败时调用方应当忽略 —— 好友名单本身来自 status，不依赖这一笔。
   */
  async conversations(limit: number): Promise<WatchConversations> {
    const text: string = await this.link.conversations(limit);
    return BridgeSession.parse(text) as WatchConversations;
  }

  /** 发文字或原生表情。成功时服务端已带回最新消息列表，调用方不用再拉一次 */
  async sendMessage(name: string, text: string, sticker: string): Promise<WatchSendResult> {
    const reply: string = await this.link.sendMessage(name, text, sticker);
    return BridgeSession.parse(reply) as WatchSendResult;
  }

  /** 订阅某个会话。之后有新内容时服务端会主动推，不再需要轮询 */
  async watch(name: string, limit: number, active: boolean, rev: string): Promise<void> {
    await this.link.subscribe(name, limit, active, rev);
  }

  /** 取消订阅。已经断开时直接返回 —— 断线后发这一帧只会白等一个超时 */
  async unwatch(): Promise<void> {
    if (!this.link.connected) {
      return;
    }
    await this.link.unsubscribe();
  }

  /**
   * 一次把整库表情缩略图取回来（id → 字节）。
   *
   * 这是「表情网格一格一格往外蹦」的正解：见 BridgeLink.fetchStickerThumbs。
   */
  async fetchStickerThumbs(px: number): Promise<StickerThumbBatch> {
    return this.link.fetchStickerThumbs(px, THUMB_BATCH_TIMEOUT_MS);
  }

  /** 请电脑端立刻重扫一次表情面板（不等结果，刷新完由推送通知） */
  async syncStickers(): Promise<void> {
    await this.link.syncStickers();
  }

  // ------------------------------------------------------------ 内部

  private static parse(text: string): Object {
    try {
      return JSON.parse(text);
    } catch (err) {
      throw new BridgeError(KIND_SERVER, '电脑端返回了无法识别的内容');
    }
  }
}

/**
 * 手表端到电脑的长连接（裸 TCP，非 HTTP）。
 *
 * 与 bridge/tcp_server.py 配对。相对原来的 BridgeClient（HTTP）有三处根本不同：
 *
 * 1. **一条长连接复用全部请求**。HTTP 那版每个请求都要重新建连、重发请求头，
 *    而 2 秒一次的轮询绝大多数结果是「什么都没变」——纯浪费无线电。
 * 2. **消息靠服务端推**。不再有 2 秒轮询，服务端只在内容真的变了才推一帧过来。
 * 3. **图片走同一条连接**的二进制帧。代价是没法再用 `Image(url)` 直接加载，
 *    要自己把字节解成 PixelMap —— 见 service/ScaledImage.ets。
 *
 * 线程模型：全部收包都在 socket 的 'message' 回调里进入 FrameParser，再由
 * drain() 按帧处理。drain 是串行的（带 draining 标志），因为解密要 await ——
 * 两帧同时进解密会打乱 GCM 的计数器。
 */
import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

import {
  FLAG_ERROR,
  FLAG_MORE,
  FLAG_PUSH,
  Frame,
  FrameParser,
  PROTOCOL_VERSION,
  TYPE_HELLO,
  TYPE_IMAGE,
  TYPE_PING,
  TYPE_PONG,
  TYPE_REQ,
  TYPE_RES,
  decodeJsonText,
  decodeUtf8,
  encodeJsonText,
  packFrame
} from '../common/Protocol';
import { HandshakeMaterial, PlainChannel, SecureChannel, createHandshakeMaterial, deriveSessionKey, fromBase64, toBase64 } from './WireCrypto';
import { BridgeError, KIND_NETWORK, KIND_SERVER, KIND_TIMEOUT, KIND_TOKEN, networkHint } from './BridgeError';

const DOMAIN: number = 0x0001;
const TAG: string = 'BridgeLink';

/** 单次请求的默认超时；发消息那条要另给（服务端最多允许 180s） */
const DEFAULT_TIMEOUT_MS: number = 30000;
/**
 * 读会话列表预览的超时。
 *
 * 服务端这一笔要和推送轮询抢浏览器，慢的时候十几秒才轮到；给 8 秒就拿不到就放弃 ——
 * 它只负责给列表行补一行小字，绝不能拖住整屏列表（列表用 status 的好友名单先出来）。
 */
const CONVERSATIONS_TIMEOUT_MS: number = 8000;
export const SEND_TIMEOUT_MS: number = 120000;
const CONNECT_TIMEOUT_MS: number = 8000;

/**
 * 心跳。形状是「安静了才发，安静太久就判死」。
 *
 * 表端必须自己探活，不能只等 socket 报错。手表上最常见的断线不是 RST，而是
 * **半开连接**：熄屏、切 Wi-Fi、穿过穿透节点时映射过期，对端已经不在了，但这条
 * socket 在本机看仍然「已连接」。此时界面显示一切正常，任何请求却要等到 30 秒
 * 超时才失败 —— 用户看到的就是「卡住不动，偶尔才断开」。
 *
 * PONG 由服务端的 ping 处理直接回（见 tcp_server.py），不需要额外协议。
 * 这个节奏顺带还有个用处：穿透和家用路由器对空闲连接通常只留 30~120 秒，
 * 每 6 秒一次的帧正好把映射一直续着。
 */
const HEARTBEAT_TICK_MS: number = 4000;
/** 安静超过这么久就发一帧 PING 出去试探 */
const HEARTBEAT_QUIET_MS: number = 6000;
/** 安静超过这么久就认定链路已经死了。宁可早判 —— 判错了重连也就几百毫秒 */
const HEARTBEAT_DEAD_MS: number = 14000;

/** 握手应答里服务端选定的加密方式 */
interface HelloReply {
  v: number;
  ok: boolean;
  error?: string;
  crypto?: string;
  pub?: string;
  nonce?: string;
}

/** 服务端回的通用应答。字段是可选的，具体看 op。 */
export interface LinkReply {
  op?: string;
  ok?: boolean;
  error?: string;
  friend?: string;
  rev?: string;
  unchanged?: boolean;
  contentType?: string;
  bytes?: number;
}

/** 图片请求的应答，附带本地拼好的字节 */
export interface ImageReply {
  contentType: string;
  bytes: Uint8Array;
}

/**
 * 一次批量取回的表情缩略图：表情库 id → 图片字节。
 *
 * 用 Map 而不是数组：调用方（ImageCache.prime）要按 id 直接把字节灌进缓存，
 * 数组还得先自己建一遍索引。
 */
export interface StickerThumbBatch {
  /** 服务端实际装进来的张数（与 items.size 一致，单张坏掉会被服务端跳过） */
  count: number;
  items: Map<string, Uint8Array>;
}

/**
 * 一次请求的完整结果。
 *
 * 文本和字节一起回传，而不是让调用方稍后再去读一个共享字段：图片的字节是分帧
 * 攒出来的，如果放在 `this.lastImage` 这种单槽字段里，两个图片请求同时在飞时
 * 后到的那个会把先到的覆盖掉 —— 手表上表现为「偶尔有一格表情是别人」。
 */
export interface LinkResult {
  /** 服务端的 JSON 应答文本 */
  text: string;
  /** 仅图片请求非空 */
  bytes: Uint8Array;
}

class Pending {
  resolve: (value: LinkResult) => void = () => {
  };
  /**
   * 类型写成 BridgeError 而不是 Error。
   *
   * 在 ArkTS 里 `Error` 是内置接口，`class BridgeError extends Error` 构造出来的
   * 类型只是**结构上**长得像 Error，并不构成名义上的继承关系 —— 传进 `(err: Error)`
   * 的参数位会被 arkts-no-structural-typing 拦下来。收窄成自己的类反而两边都通顺。
   */
  reject: (err: BridgeError) => void = () => {
  };
  timer: number = -1;
  /** 图片请求：载荷分多帧到达，全部收完才算成功 */
  wantImage: boolean = false;
  chunks: Uint8Array[] = [];
  total: number = 0;
  imageDone: boolean = false;
  /** 服务端回的那一帧头（JSON 文本），普通请求也就是最终结果 */
  pendingText: string = '';
  hasError: boolean = false;
  error: string = '';
}

export type PushHandler = (payload: string) => void;
export type StateHandler = (connected: boolean, detail: string) => void;

export class BridgeLink {
  private tcp: socket.TCPSocket | null = null;
  private parser: FrameParser = new FrameParser();
  private channel: SecureChannel | PlainChannel | null = null;
  private pending: Map<number, Pending> = new Map<number, Pending>();
  private nextId: number = 1;
  private draining: boolean = false;
  private drainAgain: boolean = false;
  /** 发送链：保证同一时刻只有一次加密+send 在跑，见 sendFrame */
  private sendChain: Promise<void> = Promise.resolve();

  private handshake: HandshakeMaterial | null = null;
  private helloWaiter: ((reply: HelloReply) => void) | null = null;
  private clientNonce: Uint8Array = new Uint8Array(0);
  private useCrypto: boolean = true;

  /** 心跳定时器；-1 表示没在跑 */
  private heartbeatTimerId: number = -1;
  /** 最近一次收到任何一帧的时刻（毫秒）。心跳靠它判断链路是不是已经静默 */
  private lastRxAt: number = 0;

  /** 服务端主动推送的新消息（载荷是 JSON 文本） */
  onPush: PushHandler | null = null;
  /** 连接状态变化。断开时手表要显示出来，否则用户看到的是「界面卡住不动」 */
  onState: StateHandler | null = null;

  private host: string = '';
  private port: number = 0;
  private token: string = '';

  get connected(): boolean {
    return this.tcp !== null && this.channel !== null;
  }

  // ------------------------------------------------------------ 连接

  async connect(host: string, port: number, token: string, useCrypto: boolean): Promise<void> {
    await this.close();
    this.host = host;
    this.port = port;
    this.token = token;
    this.useCrypto = useCrypto;
    this.parser.reset();
    this.pending.clear();
    this.nextId = 1;

    const tcp: socket.TCPSocket = socket.constructTCPSocketInstance();
    this.tcp = tcp;
    tcp.on('message', (info: socket.SocketMessageInfo) => {
      // 任何一帧都算「链路还活着」—— 心跳应答、推送、请求应答都算
      this.lastRxAt = Date.now();
      const chunk: Uint8Array = new Uint8Array(info.message);
      this.parser.push(chunk);
      this.drain();
    });
    tcp.on('error', (err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'socket 错误: %{public}s', err.message);
      this.stopHeartbeat();
      this.failAll('连接中断');
      this.reportState(false, '连接中断');
    });
    tcp.on('close', () => {
      // 对端收连接（服务重启、它那边心跳超时）走的是这条，不是 'error'。
      // 之前没接这个事件，于是手表一直以为自己还连着 —— 之后每个请求都要熬到
      // 超时才失败，表现就是「明明显示已连接，点什么都转圈」。
      hilog.info(DOMAIN, TAG, 'socket 已被对端关闭');
      this.stopHeartbeat();
      this.failAll('与电脑的连接已断开');
      this.reportState(false, '与电脑的连接已断开');
    });

    const startedAt: number = Date.now();
    try {
      await tcp.connect({
        address: { address: host, port: port, family: host.indexOf(':') >= 0 ? 2 : 1 },
        timeout: CONNECT_TIMEOUT_MS
      });
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      // 底层给的是 2300006 / 2300007 这种数字码，手表上没法查，在这里就翻成人话
      throw new BridgeError(KIND_NETWORK, networkHint(e));
    }
    await BridgeLink.applySocketOptions(tcp);

    await this.doHandshake();
    this.reportState(true, '');
    this.startHeartbeat();
    // 把耗时打出来：卡在 TCP 建连、卡在握手、还是卡在服务端，看这一行就能分。
    // 手表上没法开 profiler，这行 hilog 是唯一能拿到的现场。
    hilog.info(DOMAIN, TAG, '已连接 %{public}s:%{public}d（建连+握手 %{public}dms）',
      host, port, Date.now() - startedAt);
  }

  /**
   * 关掉 Nagle、开 keepalive。
   *
   * 这套协议全是几十字节的小帧、严格一问一答。Nagle 会把小包攒着等前一个 ACK，
   * 每次交互平白多几十毫秒 —— 单看不致命，但「点一下要愣半秒」的手感就是这么来的。
   * keepAlive 只是兜底（心跳已经能发现问题），防的是系统把定时器冻结住的情况。
   *
   * 个别系统版本上这个接口会失败，那也不该连不上，所以只记日志。
   */
  private static async applySocketOptions(tcp: socket.TCPSocket): Promise<void> {
    try {
      const extra: socket.TCPExtraOptions = { TCPNoDelay: true, keepAlive: true };
      await tcp.setExtraOptions(extra);
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      hilog.debug(DOMAIN, TAG, '设置 TCP 选项失败（不影响连接）: %{public}s', e.message);
    }
  }
  private async doHandshake(): Promise<void> {
    if (this.tcp === null) {
      throw new BridgeError(KIND_NETWORK, '尚未建立连接');
    }
    const hello: HelloPayload = { v: PROTOCOL_VERSION, token: this.token };
    if (this.useCrypto) {
      this.handshake = await createHandshakeMaterial();
      this.clientNonce = this.handshake.nonce;
      hello.crypto = 'gcm';
      hello.pub = toBase64(this.handshake.publicKey);
      hello.nonce = toBase64(this.handshake.nonce);
    } else {
      hello.crypto = 'plain';
    }

    const reply: HelloReply = await this.waitHello(JSON.stringify(hello));
    if (!reply.ok) {
      // 服务端明确拒绝时要把原因带出来：令牌错、协议版本不一致、服务端要求加密，
      // 这三种在手表上的处理方式完全不同，糊成一句「连接失败」没法排查。
      const reason: string = reply.error !== undefined && reply.error.length > 0 ? reply.error : '握手被拒绝';
      // 令牌错在界面上要跳到配置页，所以单独标出来 —— 服务端的文案是
      // 「令牌无效，请重新填写」，两边文案变了这里会退化成普通服务端错误，
      // 影响只是「少跳一次配置页」，不会走到错误的处理分支上。
      const kind: string = reason.indexOf('令牌') >= 0 ? KIND_TOKEN : KIND_SERVER;
      throw new BridgeError(kind, reason);
    }
    const mode: string = reply.crypto !== undefined ? reply.crypto : 'plain';
    if (mode === 'gcm') {
      if (this.handshake === null || reply.pub === undefined || reply.nonce === undefined) {
        throw new BridgeError(KIND_SERVER, '服务端要加密，但没有给出密钥材料');
      }
      const key: Uint8Array = await deriveSessionKey(
        this.handshake,
        fromBase64(reply.pub),
        this.clientNonce,
        fromBase64(reply.nonce)
      );
      this.channel = await SecureChannel.create(key);
    } else {
      this.channel = new PlainChannel();
    }
    this.handshake = null;
  }

  private waitHello(body: string): Promise<HelloReply> {
    const tcp: socket.TCPSocket | null = this.tcp;
    if (tcp === null) {
      return Promise.reject(new BridgeError(KIND_NETWORK, '尚未建立连接'));
    }
    return new Promise<HelloReply>((resolve, reject) => {
      const timer: number = setTimeout(() => {
        this.helloWaiter = null;
        reject(new BridgeError(KIND_TIMEOUT, '等待服务端握手应答超时'));
      }, CONNECT_TIMEOUT_MS);
      this.helloWaiter = (reply: HelloReply) => {
        clearTimeout(timer);
        this.helloWaiter = null;
        resolve(reply);
      };
      tcp.send({ data: toArrayBuffer(packFrame(TYPE_HELLO, 0, encodeJsonText(body), 0)) }).catch((err: BusinessError) => {
        clearTimeout(timer);
        this.helloWaiter = null;
        reject(new BridgeError(KIND_NETWORK, networkHint(err)));
      });
    });
  }

  async close(): Promise<void> {
    const tcp: socket.TCPSocket | null = this.tcp;
    this.tcp = null;
    this.channel = null;
    this.stopHeartbeat();
    this.lastRxAt = 0;
    this.failAll('连接已关闭');
    if (tcp !== null) {
      try {
        // 先把监听摘掉再关：否则自己关连接也会走一遍 'close' 分支，界面会
        // 因为「我主动断开」而闪一次错误提示。
        tcp.off('message');
        tcp.off('error');
        tcp.off('close');
        await tcp.close();
      } catch (err) {
        hilog.debug(DOMAIN, TAG, '关闭 socket 失败（多半已经断了）');
      }
    }
  }

  // ------------------------------------------------------------ 心跳

  private startHeartbeat(): void {
    this.stopHeartbeat();
    this.lastRxAt = Date.now();
    this.heartbeatTimerId = setInterval(() => {
      this.heartbeatTick();
    }, HEARTBEAT_TICK_MS);
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimerId >= 0) {
      clearInterval(this.heartbeatTimerId);
      this.heartbeatTimerId = -1;
    }
  }

  /**
   * 立刻做一次心跳检查，不等下一个 tick。
   *
   * 抬腕回到前台时用：熄屏期间应用的定时器可能被系统冻结，等下一次 tick 还要
   * 好几秒，而那几秒用户正盯着屏幕。这里立刻探一次，链路其实是断的就可以当场
   * 判死、马上重连，而不是让用户先看几秒转圈。
   */
  poke(): void {
    if (this.tcp !== null) {
      this.heartbeatTick();
    }
  }

  /**
   * 心跳的一次检查：安静了就发 PING，安静太久就判死。
   *
   * 判死之前不重试、不犹豫 —— 半开连接是等不回来的，早一点断开重连，
   * 用户就早一点拿到一条能用的链路。这里只负责「断开」这件事，
   * 重连由 BridgeSession 上面的页面决定。
   */
  private heartbeatTick(): void {
    if (this.tcp === null) {
      this.stopHeartbeat();
      return;
    }
    if (this.lastRxAt <= 0) {
      // 建连过程中 lastRxAt 还没初始化（close() 会把它清零）：这时拿它算静默
      // 时长会得出天文数字，把一条刚握完手的新连接当场判死 —— 表现为
      // 「有时候明明能连上却被秒断」。见到 0 就当「刚收到帧」处理。
      this.lastRxAt = Date.now();
      return;
    }
    const silence: number = Date.now() - this.lastRxAt;
    if (silence >= HEARTBEAT_DEAD_MS) {
      hilog.warn(DOMAIN, TAG, '链路静默 %{public}dms，判定已断开', silence);
      this.stopHeartbeat();
      this.failAll('与电脑的连接已中断');
      this.reportState(false, '与电脑的连接已中断');
      this.close().then(() => {
      });
      return;
    }
    if (silence >= HEARTBEAT_QUIET_MS) {
      // 服务端收到 PING 会原样回一帧 PONG，收到就算活着
      this.sendFrame(TYPE_PING, 0, new Uint8Array(0), 0).catch((err: Object) => {
        const e = err as Error;
        hilog.debug(DOMAIN, TAG, '心跳发送失败: %{public}s', e.message);
      });
    }
  }

  // ------------------------------------------------------------ 收帧

  private async drain(): Promise<void> {
    if (this.draining) {
      // 解密是异步的：上一批还没处理完就又来数据时，标个记号，处理完再跑一轮，
      // 不能让两批帧同时进 GCM —— 那会把接收计数器搞乱。
      this.drainAgain = true;
      return;
    }
    this.draining = true;
    try {
      do {
        this.drainAgain = false;
        let frame: Frame | null = this.parser.next();
        while (frame !== null) {
          await this.handleFrame(frame);
          frame = this.parser.next();
        }
      } while (this.drainAgain);
    } catch (err) {
      const e = err as Error;
      hilog.warn(DOMAIN, TAG, '处理帧失败: %{public}s', e.message);
      this.failAll(e.message);
      this.reportState(false, e.message);
      // 走到这里说明解密已经失败过一次，接收计数器永久错位，这条连接救不回来了。
      // 必须主动断开，让上层马上重连 —— 之前只标记状态不关 socket，界面提示着
      // 「连接断开」，轮询却还在这条僵尸连接上跑，每一发都再失败一次。
      await this.close();
    } finally {
      this.draining = false;
    }
  }

  private async handleFrame(frame: Frame): Promise<void> {
    if (frame.type === TYPE_HELLO) {
      // 握手应答是明文（此刻还没有密钥），单独走一条路
      const waiter: ((reply: HelloReply) => void) | null = this.helloWaiter;
      if (waiter !== null) {
        waiter(JSON.parse(decodeJsonText(frame.payload)) as HelloReply);
      }
      return;
    }

    const channel: SecureChannel | PlainChannel | null = this.channel;
    if (channel === null) {
      throw new BridgeError(KIND_NETWORK, '还没握手就收到了数据');
    }
    const plain: Uint8Array = await channel.decrypt(frame.payload);

    if (frame.type === TYPE_PING) {
      await this.sendFrame(TYPE_PONG, frame.reqId, plain, 0);
      return;
    }
    if (frame.type === TYPE_PONG) {
      return;
    }
    if (frame.type === TYPE_IMAGE) {
      const entry: Pending | undefined = this.pending.get(frame.reqId);
      if (entry !== undefined) {
        entry.chunks.push(plain);
        entry.total += plain.length;
        if ((frame.flags & FLAG_MORE) === 0) {
          entry.imageDone = true;
          this.settle(frame.reqId);
        }
      }
      return;
    }
    if (frame.type !== TYPE_RES) {
      return;
    }

    const text: string = decodeJsonText(plain);
    if ((frame.flags & FLAG_PUSH) !== 0 || frame.reqId === 0) {
      const handler: PushHandler | null = this.onPush;
      if (handler !== null) {
        handler(text);
      }
      return;
    }

    const entry: Pending | undefined = this.pending.get(frame.reqId);
    if (entry === undefined) {
      return;
    }
    const reply: LinkReply = JSON.parse(text) as LinkReply;
    if ((frame.flags & FLAG_ERROR) !== 0) {
      entry.hasError = true;
      entry.error = reply.error !== undefined ? reply.error : '服务端返回了错误';
      // pendingText 必须一并写上：settle() 用它判断「这一笔是否已经有着落」，
      // 空着的话错误帧会被当成「还没收完」，请求一直挂到超时才失败。
      entry.pendingText = text;
      this.settle(frame.reqId);
      return;
    }
    if (entry.wantImage) {
      // 图片的应答只是个头（带 content-type 和字节数），真正的字节在后面几帧路上。
      // 这里只记下应答文本，settle() 会等 IMAGE 帧收全再放行。
      entry.pendingText = text;
      return;
    }
    entry.pendingText = text;
    this.settle(frame.reqId);
  }

  /** 一个请求的收尾条件：错误、普通应答、或图片字节收全 */
  private settle(reqId: number): void {
    const entry: Pending | undefined = this.pending.get(reqId);
    if (entry === undefined || entry.pendingText.length === 0) {
      return;
    }
    if (entry.wantImage && !entry.hasError && !entry.imageDone) {
      // 图片的应答只是一帧头，字节还在后面几帧路上
      return;
    }
    this.pending.delete(reqId);
    if (entry.timer >= 0) {
      clearTimeout(entry.timer);
    }
    if (entry.hasError) {
      // 服务端的错误必须变成 reject。早先这里是 resolve，于是 status() 会把
      // {"ok":false,"error":"..."} 当成一个正常的 WatchStatus 解析下去，
      // 界面表现成「抖音会话正在启动」—— 真正的失败原因被静默丢掉了。
      entry.reject(new BridgeError(KIND_SERVER, entry.error));
      return;
    }
    let bytes: Uint8Array = new Uint8Array(0);
    if (entry.wantImage) {
      // 分帧攒起来的字节在这里合流。放在 settle 而不是让调用方去翻 Pending，
      // 是因为 Pending 马上就要从表里摘掉了。
      bytes = concatChunks(entry.chunks, entry.total);
    }
    entry.resolve({ text: entry.pendingText, bytes: bytes });
  }

  private failAll(reason: string): void {
    const entries: Pending[] = [];
    this.pending.forEach((value: Pending) => {
      entries.push(value);
    });
    this.pending.clear();
    for (const entry of entries) {
      if (entry.timer >= 0) {
        clearTimeout(entry.timer);
      }
      entry.reject(new BridgeError(KIND_NETWORK, reason));
    }
  }

  private reportState(connected: boolean, detail: string): void {
    const handler: StateHandler | null = this.onState;
    if (handler !== null) {
      handler(connected, detail);
    }
  }

  // ------------------------------------------------------------ 发帧

  private async sendFrame(frameType: number, reqId: number, plaintext: Uint8Array, flags: number): Promise<void> {
    // 发送必须串行。SecureChannel.encrypt 里的计数器是「读—用—加一」，两个请求
    // 同时进来会读到同一个值、用同一个 nonce 加密，GCM 下同 key 同 nonce 会直接
    // 泄露两段明文的异或，而且服务端从那之后每一帧都解不开。请求并发是常态
    // （拉表情图的同时推送还在走），所以这里用一条 promise 链把发送串起来。
    const task: () => Promise<void> = async (): Promise<void> => {
      const tcp: socket.TCPSocket | null = this.tcp;
      const channel: SecureChannel | PlainChannel | null = this.channel;
      if (tcp === null) {
        throw new Error('连接已断开');
      }
      let payload: Uint8Array = plaintext;
      if (frameType !== TYPE_HELLO && channel !== null) {
        payload = await channel.encrypt(plaintext);
      }
      await tcp.send({ data: toArrayBuffer(packFrame(frameType, reqId, payload, flags)) });
    };
    const chained: Promise<void> = this.sendChain.then(task, task);
    // 链本身要吞掉异常，否则一次发送失败会让后面所有发送跟着一起 reject
    this.sendChain = chained.then(() => {
    }, () => {
    });
    return chained;
  }

  private reserveId(): number {
    const value: number = this.nextId;
    this.nextId = value >= 0xffff ? 1 : value + 1;
    return value;
  }

  /**
   * 发一个请求并等应答。
   *
   * `wantImage` 为真时，等服务端的 IMAGE 帧全部到齐才返回 —— 图片的应答是
   * 「一帧头 + 若干帧字节」，只等头会拿到一张空图。
   */
  private request(op: string, body: object, timeoutMs: number, wantImage: boolean): Promise<LinkResult> {
    const reqId: number = this.reserveId();
    return new Promise<LinkResult>((resolve, reject) => {
      const entry: Pending = new Pending();
      entry.resolve = resolve;
      entry.reject = reject;
      entry.wantImage = wantImage;
      entry.timer = setTimeout(() => {
        this.pending.delete(reqId);
        reject(new BridgeError(KIND_TIMEOUT, '请求超时'));
      }, timeoutMs);
      this.pending.set(reqId, entry);
      this.sendFrame(TYPE_REQ, reqId, encodeJsonText(JSON.stringify(body)), 0).catch((err: Object) => {
        this.pending.delete(reqId);
        if (entry.timer >= 0) {
          clearTimeout(entry.timer);
        }
        reject(err);
      });
    });
  }

  // ------------------------------------------------------------ 对外能力

  async status(): Promise<string> {
    // 请求体必须先落到一个有名字的接口上：ArkTS 不允许把裸对象字面量当参数传，
    // 这一条在 await 表达式里更容易触发（上下文类型传不进去）
    const body: StatusRequest = { op: 'status' };
    return (await this.request('status', body, DEFAULT_TIMEOUT_MS, false)).text;
  }

  async messages(name: string, limit: number, rev: string): Promise<string> {
    const body: MessagesRequest = { op: 'messages', name: name, limit: limit, rev: rev };
    return (await this.request('messages', body, DEFAULT_TIMEOUT_MS, false)).text;
  }

  /**
   * 读一次电脑端左侧的会话列表（昵称 + 最后一条消息预览）。
   *
   * 超时给得短：这是给列表行「加一行小字」用的锦上添花，服务端忙着刷表情面板时
   * 它可能排很久。等不到就算了 —— 列表本身必须秒出，不能为了一行预览卡住整屏。
   */
  async conversations(limit: number): Promise<string> {
    const body: ConversationsRequest = { op: 'conversations', limit: limit };
    return (await this.request('conversations', body, CONVERSATIONS_TIMEOUT_MS, false)).text;
  }

  async sendMessage(name: string, text: string, sticker: string): Promise<string> {
    const body: SendRequest = { op: 'send', name: name, text: text, sticker: sticker };
    return (await this.request('send', body, SEND_TIMEOUT_MS, false)).text;
  }

  async subscribe(name: string, limit: number, active: boolean, rev: string): Promise<string> {
    const body: WatchRequest = { op: 'watch', name: name, limit: limit, active: active, rev: rev };
    return (await this.request('watch', body, DEFAULT_TIMEOUT_MS, false)).text;
  }

  async unsubscribe(): Promise<string> {
    const body: StatusRequest = { op: 'unwatch' };
    return (await this.request('unwatch', body, DEFAULT_TIMEOUT_MS, false)).text;
  }

  /**
   * 拉一张图。`kind` 为 "sticker" 时 key 是表情库 id，为 "media" 时 key 是抖音的图片地址。
   *
   * 服务端对这两种来源的字段名不一样（ref / url），是在这里分开拼的 —— 别改成
   * 统一的 key 字段，那边是按 bridge/tcp_server.py::_op_image 读的。
   */
  async fetchImage(kind: string, key: string, px: number, timeoutMs: number): Promise<ImageReply> {
    const body: ImageRequest = kind === 'sticker'
      ? { op: 'image', kind: kind, ref: key, px: px }
      : { op: 'image', kind: kind, url: key, px: px };
    const result: LinkResult = await this.request('image', body, timeoutMs, true);
    const reply: LinkReply = JSON.parse(result.text) as LinkReply;
    return {
      contentType: reply.contentType !== undefined ? reply.contentType : 'image/png',
      bytes: result.bytes
    };
  }

  /**
   * 一次往返把整库表情缩略图拉回来。
   *
   * 为什么非要批量：手表这侧的 Wi-Fi 实测往返 32~117ms（均值 74ms），而原来
   * 「一张图一次 op=image」就等于 70 次往返 —— 并发闸门开 3 也只是把它摊到 8 秒
   * 上下，表情网格于是一格一格往外蹦。可服务端处理一张其实只要 1ms（派生小图命中），
   * 瓶颈全在往返次数上。整库实测 643KB，一次拿回来一秒左右，剩下只是本地解码。
   *
   * 载荷格式（大端，跟在 JSON 应答之后的 IMAGE 帧里）：
   *     u16 张数 | 每张 { u16 id 长度 | u32 数据长度 | id | 字节 }
   * 与 bridge/tcp_server.py::_op_sticker_thumbs 一一对应，改一边必须改另一边。
   */
  async fetchStickerThumbs(px: number, timeoutMs: number): Promise<StickerThumbBatch> {
    const body: StickerThumbsRequest = { op: 'sticker_thumbs', px: px };
    const result: LinkResult = await this.request('sticker_thumbs', body, timeoutMs, true);
    return parseStickerThumbs(result.bytes);
  }

  /**
   * 请电脑端立刻重扫一次表情面板。
   *
   * 「刚在手机上收藏的表情要马上出现在手表上」靠的就是这一脚：服务端原有的自动刷新
   * 一律在用户**没盯着聊天页**时才做（刷新要独占浏览器十几秒），于是恰恰在用表情的
   * 时候不刷、收藏的新表情迟迟不出现。这里只负责排一次刷新然后立刻返回 ——
   * 库文件被改写后，推送循环会把新状态推过来，界面自己会重画。
   */
  async syncStickers(): Promise<string> {
    const body: StatusRequest = { op: 'sync_stickers' };
    return (await this.request('sync_stickers', body, DEFAULT_TIMEOUT_MS, false)).text;
  }
}

// ---------------------------------------------------------------- 请求体

/** 只带 op 的请求（status / unwatch） */
interface StatusRequest {
  op: string;
}

interface HelloPayload {
  v: number;
  token: string;
  crypto?: string;
  pub?: string;
  nonce?: string;
}

interface MessagesRequest {
  op: string;
  name: string;
  limit: number;
  rev: string;
}

/**
 * 会话列表（左侧栏）。只用来给列表行补「最后一条消息 + 时间」——
 * 好友名单本身来自 status，即使这一笔失败，列表也照常出得来。
 */
interface ConversationsRequest {
  op: string;
  limit: number;
}

interface SendRequest {
  op: string;
  name: string;
  text: string;
  sticker: string;
}

interface WatchRequest {
  op: string;
  name: string;
  limit: number;
  active: boolean;
  rev: string;
}

interface ImageRequest {
  op: string;
  kind: string;
  /** kind 为 sticker 时用它（表情库 id） */
  ref?: string;
  /** kind 为 media 时用它（抖音图片地址） */
  url?: string;
  px?: number;
}

interface StickerThumbsRequest {
  op: string;
  px: number;
}

/**
 * 拆批量缩略图的载荷。
 *
 * 按服务端报的张数逐条走，任何一条越界就停下 —— 半截的载荷不能用「猜」的方式补完：
 * 把后面那张图的字节当成前面那张的，手表上显示的就是**别人的脸**，比缺一格难查得多。
 * 真丢了几张也只是那几格退回文字按钮（服务端本来就会跳过坏掉的单张）。
 */
function parseStickerThumbs(blob: Uint8Array): StickerThumbBatch {
  const items: Map<string, Uint8Array> = new Map<string, Uint8Array>();
  if (blob.byteLength < 2) {
    return { count: 0, items: items };
  }
  const view: DataView = new DataView(blob.buffer, blob.byteOffset, blob.byteLength);
  const count: number = view.getUint16(0, false);
  let at: number = 2;
  for (let i = 0; i < count; i++) {
    if (at + 6 > view.byteLength) {
      break;
    }
    const idLength: number = view.getUint16(at, false);
    const dataLength: number = view.getUint32(at + 2, false);
    at += 6;
    if (at + idLength + dataLength > view.byteLength) {
      break;
    }
    const id: string = decodeUtf8(blob.subarray(at, at + idLength));
    at += idLength;
    // 必须 slice（复制）而不是 subarray：subarray 只是原载荷上的视图，缓存里
    // 每留一张图就把它背后那 643KB 一起钉在内存里，几十张就是几十份。
    items.set(id, blob.slice(at, at + dataLength));
    at += dataLength;
  }
  return { count: count, items: items };
}

/** 把分帧收到的图片字节合并成一份 */
function concatChunks(chunks: Uint8Array[], total: number): Uint8Array {
  const out: Uint8Array = new Uint8Array(total);
  let offset: number = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.length;
  }
  return out;
}

/** Uint8Array 可能只是某个更大 buffer 上的视图，发之前必须裁到自己的范围 */
function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}

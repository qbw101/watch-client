/**
 * 图片的下载 + 解码 + 缓存。
 *
 * HTTP 版可以直接把 URL 交给 `Image()` 组件，由它在后台下载、解码、缓存。换成
 * 二进制帧之后这条路断了：图是跟着自己那条 TCP 连接来的，`Image()` 不认识。
 * 所以这里补上 `Image()` 原来替我们做的那三件事。
 *
 * 三个设计点：
 *   1. **按 (来源, 尺寸, 标识) 缓存解码结果**。缓存的是 PixelMap 而不是原始字节：
 *      解码是这里最贵的一步（一张 72px 的 PNG 解出来 20KB 位图），而同一张图
 *      在聊天记录里可能出现很多次，缓存字节等于每次都要重解一遍。
 *   2. **同一个键的并发请求只发一次**。表情网格一屏十几格是同时挂载的，没有这层
 *      去重的话首屏会一口气打出十几张图的请求，穿透链路上这就是几秒钟的排队。
 *   3. **失败要记住**。表情名大量重复，缩略图缺失/解码失败时这一格退化成纯文字格，
 *      不能每次重建都再试一遍 —— 那会让网格一直闪。
 *   4. **整库表情走一次批量往返**（`prime`）。手表这侧往返实测 74ms 上下，
 *      「一张图一次请求」乘上七十张就是几秒钟的排队；服务端一次把整库塞过来，
 *      这边只剩解码（每张 5~15ms）。
 *
 * 尺寸由服务端降采样保证（见 bridge/tcp_server.py 的 _downscale），这里不做
 * 二次缩放：手表上再缩一次只是多占一次 CPU，视觉上毫无收益。
 */
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'ImageCache';

/** 表情格缩略图边长，与服务端 STICKER_PX 一致 */
export const STICKER_PX: number = 72;
/** 消息里的表情/图片边长，与服务端 MEDIA_PX 一致 */
export const MEDIA_PX: number = 128;

/**
 * 缓存条目上限。
 *
 * 一张 72px 的图解码后约 72×72×4 ≈ 20KB，180 张不到 4MB —— 相对手表的内存
 * 不算什么，而 65 张表情全放下正是一屏网格的规模。
 */
const MAX_ENTRIES: number = 180;

/**
 * 同时在飞的取图数。
 *
 * 取 3 而不是更大：一条 TCP 连接上的请求是共享的，图片又是「越小越早回来」的
 * 东西 —— 并发拉高只会让每张图都变慢，交互帧（发消息、切会话）还得跟着等。
 */
const MAX_CONCURRENT: number = 3;

type FetchFn = (kind: string, key: string, px: number) => Promise<Uint8Array>;

interface CacheEntry {
  /** 解码好的图；null 表示这张图不可用 */
  map: image.PixelMap | null;
  failed: boolean;
}

/**
 * 取图并发的闸门。
 *
 * 不设上限的话，表情网格一屏十几格会在同一瞬间挂载、把十几张图的请求一起发出去。
 * 服务端取图的线程池只有 8 个 worker，排在后面的那张要等好几秒才回来 —— 手表上
 * 就是图一格一格地往外蹦。更糟的是这一批会把线程池占满：这时候用户点「发送」，
 * 那一帧得排在这十几张图后面。
 *
 * 所以这里限流。用户看得见的那几张走优先位（`low = false` 插到队首），后台预热
 * （`low = true`）排到队尾 —— 冷启动那一下不该让用户为「预热」买单。
 */
class ImageGate {
  private running: number = 0;
  private waiting: (() => void)[] = [];

  enter(low: boolean): Promise<void> {
    if (this.running < MAX_CONCURRENT) {
      this.running++;
      return Promise.resolve();
    }
    return new Promise<void>((resolve: () => void) => {
      if (low) {
        this.waiting.push(resolve);
      } else {
        this.waiting.unshift(resolve);
      }
    });
  }

  /** 交还名额。有人等着就把名额直接递过去，running 不变 */
  leave(): void {
    const next: (() => void) | undefined = this.waiting.shift();
    if (next !== undefined) {
      next();
      return;
    }
    this.running--;
  }
}

export class ImageCache {
  private static shared: ImageCache | null = null;

  static get instance(): ImageCache {
    if (ImageCache.shared === null) {
      ImageCache.shared = new ImageCache();
    }
    return ImageCache.shared;
  }

  private fetchFn: FetchFn | null = null;
  private entries: Map<string, CacheEntry> = new Map<string, CacheEntry>();
  private inflight: Map<string, Promise<image.PixelMap | null>> = new Map<string, Promise<image.PixelMap | null>>();
  private gate: ImageGate = new ImageGate();
  /** 批量取回来的原始字节，等 load() 来取用；取走即删（见 prime） */
  private staged: Map<string, Uint8Array> = new Map<string, Uint8Array>();
  private gen: number = 0;

  /** 由 BridgeSession 在连接建立时注入，避免这里反向依赖传输层 */
  setFetcher(fetchFn: FetchFn): void {
    this.fetchFn = fetchFn;
  }

  /**
   * 连接代次，每 clear() 一次加一。
   *
   * 调用方靠它判断「我上次批量灌进来的那批图还在不在」：重连会把缓存和暂存区
   * 一起清掉，只对着表情库指纹比对的调用方就会以为还是热缓存、跳过重新批量拉取，
   * 于是每一格都悄悄退回「一张一次往返」的老路 —— 表现是「偶发地又变慢了」，
   * 极难查。把清空这件事显式报出去，比让调用方去猜要可靠。
   */
  get generation(): number {
    return this.gen;
  }

  /**
   * 清空缓存。
   *
   * 换连接时调用：抖音 CDN 的图片地址带签名，重连拿到的新地址和旧的不是同一个键，
   * 留着旧图只会白占内存。（表情缩略图键是稳定的库 id，清掉只是多下一次。）
   */
  clear(): void {
    this.entries.clear();
    this.inflight.clear();
    this.staged.clear();
    this.gen++;
  }

  /**
   * 灌入一批已经拿到的图片字节，等 load() 逐个解码。
   *
   * 批量接口一次往返就把整库缩略图拿回来了，剩下只有本地解码 —— 这一段的
   * 往返成本从「几十次」降到「一次」。字节先存暂存区，解码仍然由 load() 按需触发：
   * 用户当前屏幕上的那几格先解，其余的等滚到再解，不做一次性 70 张的批量解码
   * （那会在打开面板的一瞬间把 CPU 占满，反而拖慢同时发生的发送）。
   *
   * 返回真正收下的张数，供日志核对「库里 K 项、这次拿到 N 张」。
   */
  prime(kind: string, px: number, blobs: Map<string, Uint8Array>): number {
    let stored: number = 0;
    blobs.forEach((bytes: Uint8Array, key: string) => {
      if (key.length === 0 || bytes.length === 0) {
        return;
      }
      const cacheKey: string = ImageCache.cacheKey(kind, key, px);
      if (this.entries.has(cacheKey)) {
        // 已经解好了，别用字节把解码结果顶掉（暂存区存的是字节、entries 存的是位图）
        return;
      }
      this.staged.set(cacheKey, bytes);
      stored++;
    });
    return stored;
  }

  /** 已经拿到图就同步返回，用于列表重建时避免「先空一帧再出图」 */
  peek(kind: string, key: string, px: number): image.PixelMap | null {
    const entry: CacheEntry | undefined = this.entries.get(ImageCache.cacheKey(kind, key, px));
    return entry === undefined ? null : entry.map;
  }

  /** 这张图已经确认取不到（没缩略图 / 解码失败），调用方应直接退化成文字 */
  isFailed(kind: string, key: string, px: number): boolean {
    const entry: CacheEntry | undefined = this.entries.get(ImageCache.cacheKey(kind, key, px));
    return entry !== undefined && entry.failed;
  }

  /**
   * 忘掉某一类图所有「失败」的记账，让它们下次重新取一遍。
   *
   * 为什么必须有这个口子：失败是要记的（表情网格十几格同时在挂载，不记就会一直闪），
   * 但「记着」等于「永远不再试」。链路刚好断那一刻打开表情面板，整屏十几格会一起
   * 记成失败文案 —— 之后链路恢复了、缓存也重建了，那些格子却因为记账还在，一直是
   * 光秃秃的字。表现就是「表情包加载不出来，怎么刷都是空的」。
   *
   * 所以在「重新批量拉一遍缩略图」这个动作开始时清一次：失败过的图有了第二次机会，
   * 已经拿到图的那些不受影响（只删 failed=true 的条目）。
   */
  dropFailed(kind: string): void {
    const stale: string[] = [];
    this.entries.forEach((value: CacheEntry, key: string) => {
      if (value.failed && key.startsWith(`${kind}:`)) {
        stale.push(key);
      }
    });
    for (const key of stale) {
      this.entries.delete(key);
    }
  }

  /**
   * 取一张图。永远不抛异常 —— 返回 null 就代表「这张图用不了」，让调用方走
   * 文字兜底。图片挂掉不该把整个列表渲染带崩。
   */
  async load(kind: string, key: string, px: number, low: boolean = false): Promise<image.PixelMap | null> {
    if (key.length === 0) {
      return null;
    }
    const cacheKey: string = ImageCache.cacheKey(kind, key, px);
    const cached: CacheEntry | undefined = this.entries.get(cacheKey);
    if (cached !== undefined) {
      return cached.map;
    }
    const flying: Promise<image.PixelMap | null> | undefined = this.inflight.get(cacheKey);
    if (flying !== undefined) {
      return flying;
    }
    const fetchFn: FetchFn | null = this.fetchFn;
    // 暂存区里有字节就不用走网络：批量接口刚把整库塞进来了
    if (fetchFn === null && !this.staged.has(cacheKey)) {
      return null;
    }

    const task: Promise<image.PixelMap | null> = this.loadGated(kind, key, px, cacheKey, fetchFn, low);
    this.inflight.set(cacheKey, task);
    return task;
  }

  /**
   * 后台预热一批图。
   *
   * 表情网格和聊天里的图都是「挂载到那一格才去取」的，一屏十几张同时发出去时
   * 每张都要排队。提前用低优先级把它们拉进缓存，用户翻到那一屏时图已经在本地了，
   * 观感就从「一格一格往外蹦」变成「一屏直接是图」。
   *
   * 低优先级是关键：预热排到队尾，用户当前屏幕上的图始终优先。
   */
  prefetch(kind: string, keys: string[], px: number): void {
    for (const key of keys) {
      if (key.length === 0) {
        continue;
      }
      const cacheKey: string = ImageCache.cacheKey(kind, key, px);
      if (this.entries.has(cacheKey) || this.inflight.has(cacheKey)) {
        continue;
      }
      this.load(kind, key, px, true).then(() => {
      });
    }
  }

  // ------------------------------------------------------------ 内部

  /**
   * 真正取数的部分：过闸门 → 下载（或取暂存字节）→ 解码 → 记账。
   *
   * 单独拆出来是为了让「交还名额」只出现在一个地方。写成 then/catch 链的话，
   * decode 失败时 catch 交一次、成功路径的 then 再交一次，闸门很快就数不上了。
   */
  private async loadGated(kind: string, key: string, px: number, cacheKey: string,
    fetchFn: FetchFn | null, low: boolean): Promise<image.PixelMap | null> {
    await this.gate.enter(low);
    let map: image.PixelMap | null = null;
    try {
      const bytes: Uint8Array = await this.takeBytes(kind, key, px, cacheKey, fetchFn);
      map = await ImageCache.decode(bytes);
    } catch (err) {
      const e = err as Error;
      hilog.debug(DOMAIN, TAG, '取图失败 %{public}s: %{public}s', cacheKey, e.message);
      map = null;
    }
    this.gate.leave();
    this.inflight.delete(cacheKey);
    this.remember(cacheKey, map);
    return map;
  }

  /**
   * 拿到这张图的字节：优先取暂存区，没有才去网络。
   *
   * 暂存区**取走即删**：解码只需要一次，留在那里等于把整批几百 KB 一直攥着。
   * 删在这里还有个好处 —— 万一后面解码失败，也不会留下「有字节但永远不解码」的
   * 半成品状态，下次照样会重新走网络。
   */
  private async takeBytes(kind: string, key: string, px: number, cacheKey: string,
    fetchFn: FetchFn | null): Promise<Uint8Array> {
    const staged: Uint8Array | undefined = this.staged.get(cacheKey);
    if (staged !== undefined) {
      this.staged.delete(cacheKey);
      return staged;
    }
    if (fetchFn === null) {
      return new Uint8Array(0);
    }
    return fetchFn(kind, key, px);
  }

  private static cacheKey(kind: string, key: string, px: number): string {
    return `${kind}:${px}:${key}`;
  }

  private remember(cacheKey: string, map: image.PixelMap | null): void {
    if (this.entries.size >= MAX_ENTRIES) {
      // Map 按插入顺序迭代，所以最早进来的一定排在最前
      const stale: string[] = [];
      this.entries.forEach((value: CacheEntry, key: string) => {
        if (stale.length < MAX_ENTRIES / 4) {
          stale.push(key);
        }
      });
      for (const key of stale) {
        // 只从表里摘掉，不 recycle()：这个 PixelMap 可能正被某个 Image 组件持有，
        // 释放了画面会当场变白。真正的回收交给 GC。
        this.entries.delete(key);
      }
    }
    this.entries.set(cacheKey, { map: map, failed: map === null });
  }

  private static async decode(bytes: Uint8Array): Promise<image.PixelMap | null> {
    if (bytes.length === 0) {
      return null;
    }
    // Uint8Array 可能只是更大 buffer 上的一段视图，必须裁到自己的范围 ——
    // 多带一点尾巴对 PNG 解码是致命的。
    const buffer: ArrayBuffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
    const source: image.ImageSource = image.createImageSource(buffer);
    try {
      return await source.createPixelMap();
    } finally {
      // ImageSource 是 native 资源，解完就该放掉；PixelMap 不依赖它
      await source.release();
    }
  }
}

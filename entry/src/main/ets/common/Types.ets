/**
 * 与电脑端桥接服务（bridge/tcp_server.py）一一对应的数据结构。
 *
 * 字段名严格对齐服务端 JSON，不做驼峰转换 —— 两边对照着看不会错。
 * 可能为 null 的字段（如 media）显式声明成联合类型，避免 ArkTS 里
 * 「看着是 string 实际是 null」的运行时坑。
 */

/** 表情库里的一项：status 应答的 watch_stickers 元素 */
export interface WatchSticker {
  /** 稳定 id，取缩略图时作为 image 请求的 ref 传过去 */
  id: string;
  /** 发表情时用的名字（服务端拿去抖音表情面板里精确匹配），一个字都不能改 */
  name: string;
  /** 手表上显示的文字 */
  label: string;
  /** 抖音面板里的分类；为空表示「默认那一屏」 */
  category: string;
  /** 服务端有本地缩略图，可以通过 image 请求取到 */
  has_thumb: boolean;
}

/** status 应答 */
export interface WatchStatus {
  ready: boolean;
  /** 会话启动失败时才有 */
  error?: string;
  current_chat?: string;
  friends?: string[];
  stickers?: string[];
  /** 配置里出现过的表情名，作为一键快捷回复 */
  presets?: string[];
  /**
   * 手表端自己的表情库（watch_stickers.json，由 scripts/scan_stickers.py 扫描生成）。
   * 与 presets 的区别：presets 是 config.json 里任务用到的表情，这里是从抖音表情面板
   * 里扫出来的全部（含自己收藏的），带缩略图。
   */
  watch_stickers?: WatchSticker[];
}

/**
 * 电脑端左侧会话列表里的一项，对应 bridge/reader.py 的 read_conversations 输出。
 *
 * 只用来给列表行补「最后一条消息的预览」，所以两个字段都可能很脏：
 * 抖音的会话行是嵌套 DOM，name 里会带换行和未读数、preview 里也会混进时间。
 * 解析放在 Index 里做，这里只如实描述结构。
 */
export interface WatchConversation {
  name: string;
  preview: string;
}

/** conversations 应答 */
export interface WatchConversations {
  items: WatchConversation[];
}

/** 单条消息，对应 bridge/reader.py 的 read_messages 输出 */export interface WatchMessage {
  /** 抖音的 data-index；虚拟列表滑动时会重排，不能当稳定 ID 用 */
  key: string;
  /** 'me' | 'them' | 'system' */
  side: string;
  /** 'text' | 'sticker' | 'image' | 'time' */
  type: string;
  text: string;
  time: string;
  /** 表情/图片的抖音 CDN 原始地址，作为 image 请求的 key 传过去才能取到图 */
  media: string | null;
}

/** messages / watch 推送的应答 */
export interface WatchMessages {
  friend: string;
  /** 内容指纹；把它回传给服务端可换来 {"unchanged": true} */
  rev: string;
  /** 内容没变时为 true，此时 messages 为空数组 */
  unchanged?: boolean;
  messages: WatchMessage[];
}

/**
 * 服务端主动推送（FLAG_PUSH 帧）：op=status 是状态推送（电脑端表情库重扫后触发），
 * 其余按 messages 推送处理。字段是 WatchStatus 和 WatchMessages 的并集。
 */
export interface WatchPush extends WatchStatus, WatchMessages {
  op?: string;
}

/** send 应答：成功时直接带回最新消息列表，省掉一次往返 */
export interface WatchSendResult {
  friend?: string;
  ok: boolean;
  rev?: string;
  messages?: WatchMessage[];
  text?: string;
  sticker?: string;
}

/** 表情网格里的一格：表情库项与快捷表情合并去重后的渲染数据 */
export interface StickerTile {
  /** ForEach 的键，保证唯一 */
  key: string;
  /** 表情库 id；快捷表情为空串 */
  id: string;
  /** 发送时用的名字 */
  name: string;
  /** 格子下方的文字 */
  label: string;
  /** 这一格有没有缩略图；有的话由 ImageCache 去取（不再是一个 URL） */
  hasThumb: boolean;
}

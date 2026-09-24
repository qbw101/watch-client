/**
 * 抖音手表助手 · 主页面（华为 WATCH 5 / HarmonyOS 6，圆屏 233×233 vp）
 *
 * 交互与旧版网页仪表盘一一对齐：
 *   地址缺失 → 配置页        连接中 → 加载页
 *   好友列表（顶部胶囊 + 滚动内容带）
 *   聊天页（返回 + 标题 + 刷新 / 消息列表 / 底部圆形发送按钮）
 *   发送用「居中卡片弹层」（圆屏贴底横排输入框会被裁成一条窄缝）
 *
 * 链路是裸 TCP 长连接，消息由电脑端主动推过来，所以这里没有轮询：
 *   1. 内容没变时链路上一个字节都不走 —— 原来那套 2 秒轮询里绝大多数请求的
 *      结果都是「什么都没变」，白唤醒一次无线电，那是手表续航的隐形杀手。
 *   2. 断线要能自己恢复。穿透链路会断，电脑端服务也会重启，所以连接丢失后按
 *      退避节奏重连（先快后慢），重连成功再把「消息 + 订阅」整条状态接回来。
 *   3. 图片不能再用 `Image(url)`。字节跟着这条连接来，要自己解码成 PixelMap，
 *      见 service/ImageCache.ets 与 view/MessageBubble.ets。
 */
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
// 智慧手势的「捏合确认」以 KEYCODE_ENTER 的按键事件下发，比对时用 KeyCode 常量
import { KeyCode } from '@kit.InputKit';

import { WatchGeometry } from '../common/Geometry';
import { Palette } from '../common/Palette';
import { Endpoint, parseEndpoint } from '../common/Endpoint';
import { KEY_ENDPOINT, KEY_HAPTICS, KEY_LEGACY_BASE_URL, KEY_PHRASES, KEY_PHRASES_READY, KEY_TOKEN, WatchPrefs } from '../common/WatchPrefs';
import { Haptics } from '../common/Haptics';
import { BridgeSession } from '../service/BridgeSession';
import { asBridgeError, KIND_NETWORK, KIND_TOKEN } from '../service/BridgeError';
import { ImageCache, MEDIA_PX, STICKER_PX } from '../service/ImageCache';
import { StickerThumbBatch } from '../service/BridgeLink';
import { WatchMessage, WatchMessages, WatchPush, WatchSendResult, WatchStatus, WatchSticker, StickerTile, WatchConversation, WatchConversations } from '../common/Types';
import { MessageBubble } from '../view/MessageBubble';
import { FriendRow } from '../view/FriendRow';
import { StickerCell } from '../view/StickerCell';

const DOMAIN: number = 0x0001;
const TAG: string = 'WatchIndex';

/** 会话没就绪时的重试间隔 */
const RETRY_MS: number = 4000;
/**
 * 重连退避，按次数往上取，到最后一档就不再涨。
 *
 * 固定 5 秒是错的：手表上断线绝大多数是熄屏、切 AP、穿透节点换线这类几百毫秒
 * 的事（链路层恢复得很快，是应用层不知道），等满 5 秒纯属白等；而电脑上服务真
 * 没起来时又不该每 5 秒去敲一次门。第一档给 600ms —— 一松手就能回来。
 */
const RECONNECT_STEPS_MS: number[] = [600, 1200, 2500, 5000, 8000];
/** 后台预热的聊天图片条数。只取最新几条 —— 列表底部就是用户正在看的地方 */
const PREFETCH_MEDIA: number = 6;
/** 最近 30 条足够铺满圆屏，再多只是白读 */
const READ_LIMIT: number = 30;
/** 首次连接允许加密握手失败后回退明文的开关，见 connectWithFallback */
const ALLOW_PLAIN_FALLBACK: boolean = true;
/**
 * 回复面板的四种形态。
 *
 * 原来只有一张卡片（输入框 + 表情网格挤在一起），圆屏上卡片高度一超就被切四角。
 * 改成整屏四种形态之后每个形态都有完整一屏可用，也更贴近演示页：
 *   menu      回复方式（表情 / 文字 / 快捷短语）—— 才是「点回复」后的第一屏
 *   stickers  表情网格
 *   phrases   快捷短语
 *   text      键盘输入
 */
const MODE_MENU: string = 'menu';
const MODE_STICKERS: string = 'stickers';
const MODE_PHRASES: string = 'phrases';
const MODE_TEXT: string = 'text';
/**
 * 短语的两层子页（都不在「四种形态」里，是短语页往下的层级）：
 *   phrase_edit   短语管理（增 / 改 / 删）
 *   phrase_input  短语输入（整屏键盘，加一条或改一条）
 *
 * 为什么不把编辑直接做在短语页上：那一页的行是「点一下就发出去」的，
 * 同一行再挂一个删除手势，误发和误删会互相咬。分层之后每一页只干一件事。
 */
const MODE_PHRASE_EDIT: string = 'phrase_edit';
const MODE_PHRASE_INPUT: string = 'phrase_input';

/**
 * 表冠滚动的两个刻度（聊天页专用，见 onCrownScroll）。
 *
 * 为什么不直接用 `digitalCrownSensitivity`：那是 Scroll/List 这些「系统默认支持表冠」
 * 的组件才认的档位，而聊天页的 Scroll 拿不到焦点、压根收不到表冠事件（见 onCrownScroll），
 * 只能自己收事件自己滚，于是灵敏度也就得自己定。
 *
 *   CROWN_PX_PER_DEGREE  表冠转 1° 让内容滚多少 px —— **手感就靠这一个数调**，
 *                        转起来嫌慢就调大、嫌窜就调小。
 *   CROWN_STEP_MAX       单次事件的封顶。表冠甩得快时一次上报的 degree 会很大，
 *                        不封顶会出现「轻轻一甩越过半屏」。
 */
const CROWN_PX_PER_DEGREE: number = 1.15;
const CROWN_STEP_MAX: number = 26;
/**
 * 根容器的 id。
 *
 * 聊到表冠就离不开焦点，所以这里是那个「消息灵通」的锚点：表冠事件只发给**获焦组件**，
 * 而真机 dumpLayout 里聊天页获焦的就是根容器（`root` / `Stack` / `Stack` 一路 focused=true，
 * 底下那个 Scroll 是 false）。挂 id 是为了 `ensureCrownFocus` 能在切进聊天页时显式把
 * 焦点要回这一层 —— 子页面的滚动容器（会话列表 / 表情网格 / 短语）各自有自己的 id。
 */
const CROWN_TARGET_ID: string = 'rootStack';
/** 表情网格一行放几个。原来是 Flex 自动换行，现在自己切行，见 stickerRows */
const STICKERS_PER_ROW: number = 3;
/** 「回复方式」那一屏有几项：表情 / 文字 / 快捷短语 */
const MENU_ITEM_COUNT: number = 3;
/** 表冠在这一屏上转多少度换一项 —— 表冠是连续量，不设步长的话手指一划就窜到最后一项 */
const MENU_CROWN_STEP: number = 45;

/** 短语在 preferences 里的分隔符 */
const PHRASE_SEP: string = '\n';

/** 把 preferences 里那一串拆成短语数组：去空白、丢空行 */
function splitPhrases(raw: string): string[] {
  const out: string[] = [];
  const parts: string[] = raw.split(PHRASE_SEP);
  for (let i = 0; i < parts.length; i++) {
    const one: string = parts[i].trim();
    if (one.length > 0) {
      out.push(one);
    }
  }
  return out;
}

/**
 * 会话列表行要显示的那一行小字：最后一条消息 + 时间。
 *
 * 服务端给的原始数据很脏（`name` 里带换行和未读数、`preview` 里混着时间和「在线」
 * 之类的状态字），所以解析结果单独存一份、按好友名对齐 —— 列表本人仍然只用
 * status 里的好友名单，读不到预览时整行退化成「只有名字」。
 */
interface FriendSummary {
  name: string;
  preview: string;
  time: string;
}

/** 时间戳长这样才算时间：18:24 / 昨天 / 星期三 */
const TIME_TOKEN: RegExp = new RegExp('^(\\d{1,2}:\\d{2}|昨天|星期[一二三四五六日天]|周[一二三四五六日天])$');
/** 未读数的样子：纯数字 */
const UNREAD_TOKEN: RegExp = new RegExp('^\\d{1,3}$');
/** 会话行里混进来的状态字，不该当成「最后一条消息」显示 */
const STATUS_WORDS: string[] = ['在线', '离线', '对方正在输入', '已读', '未读'];
/** 会话预览最短重读间隔：这一笔要和推送轮询抢浏览器，没必要每轮 status 都敲一次 */
const SUMMARY_MIN_INTERVAL_MS: number = 120000;

/**
 * 设置页正在编辑哪一项。
 *
 * 设置页原来是「行里的灰字直接就是输入框」，看着省一层跳转，但在手表上有个硬伤：
 * `TextInput` 是**一按下就抢焦点、就弹键盘**的，而圆屏上手势滚动必然从某一行起手 ——
 * 想往下滑，结果滑到一半手指压进了输入框，键盘弹起来把整页顶掉。
 * 区分「点」和「滑」在输入框内部是做不到的，所以只能让滚动区里根本没有输入框：
 * 平时是纯文字（外观和演示页那行灰字一模一样），点一下才进独立的编辑页。
 */
const FIELD_NONE: number = 0;
const FIELD_ENDPOINT: number = 1;
const FIELD_TOKEN: number = 2;

@Entry
@Component
struct Index {
  // ---- 圆屏几何：由 onAreaChange 实测根容器尺寸后整体替换（而不是改字段） ----
  @State geo: WatchGeometry = new WatchGeometry(233, 233);

  // ---- 配置与连接状态 ----
  @State needConfig: boolean = false;
  @State booting: boolean = true;
  @State bootText: string = '正在连接电脑…';
  @State ready: boolean = false;
  /** 连接确实失败（而不是「还在连」）—— 决定加载页是转圈还是给出错误和出口 */
  @State bootFailed: boolean = false;
  /** 连上过、后来又断了。列表页的状态点变红，用户才有「不是卡住而是断了」的判断 */
  @State linkLost: boolean = false;
  @State formEndpoint: string = '';
  @State formToken: string = '';
  /**
   * 设置页正在编辑哪一项（FIELD_NONE = 都没在编辑）。
   *
   * 字段行本身只是纯文字，点一下才切到独立的编辑页 —— 原因是 `TextInput` 一按下
   * 就弹键盘，而圆屏上「想滑动」和「想点」起手是同一下，滚动区里只要有输入框，
   * 滑动就一定会误触。详见 FIELD_* 常量处的说明。
   */
  @State editField: number = FIELD_NONE;
  /** 编辑草稿：只有点「完成」才写回，中途返回等于放弃 */
  @State editDraft: string = '';
  /** 编辑页的键盘是否弹着。弹起时要收掉标题，否则输入框会被顶出圆屏 */
  @State editFocused: boolean = false;

  // ---- 数据 ----
  @State friends: string[] = [];
  /** 会话列表行的小字（最后一条消息 / 时间），由 conversations 拉回来 */
  @State summaries: FriendSummary[] = [];
  @State presets: string[] = [];
  /**
   * 快捷短语（可编辑，持久化在 WatchPrefs 的 phrases 键）。
   *
   * 和 `presets` 是两回事：presets 来自电脑端 config.json —— 那是自动发送任务
   * 用到的表情名，手表既改不了也不该改。这里是用户在手表上自己攒的常用回复。
   * 第一次连上时拿 presets 播一次种（省得用户从零开始敲），之后完全以本地为准。
   */
  @State phrases: string[] = [];
  /**
   * 「回复方式」那一屏当前高亮的是哪一项（0 表情 / 1 文字 / 2 快捷短语）。
   *
   * 那一屏没有滚动容器，能用手势驱动的只有「三选一」这一件事，所以专门用一个状态记它：
   * 转表冠换项，智慧手势（捏合）进入当前项 —— 合起来就是穿戴设备那套
   * 「旋转选项 + 捏合确认」。光有捏合没有换项手段的话，用户只能选到第一项。
   */
  @State menuIndex: number = 0;
  /** 表冠切高亮的角度累加器：转满一格才换一项 */
  private menuCrownAccum: number = 0;
  /** 短语输入页正在改第几条；-1 表示新增 */
  @State phraseEditIndex: number = -1;
  /** 短语输入草稿：只有点「完成」才写回，中途返回等于放弃 */
  @State phraseDraft: string = '';
  /** 短语输入页的键盘是否弹着。弹起时要收掉标题，否则输入框会被顶出圆屏 */
  @State phraseFocused: boolean = false;
  /**
   * 编辑页里哪一行正等着二次确认（-1 = 没有）。
   *
   * 手表上没有撤销，而短语是手打出来的 —— 误删一条长句就得重打一遍。
   * 二次确认比弹窗便宜得多：圆屏上弹窗又是一整屏，用户还得再去找按钮。
   */
  @State phrasePendingDelete: number = -1;
  /** 表情库原始数据（服务端 watch_stickers.json 扫出来的） */
  @State watchStickers: WatchSticker[] = [];
  /** 合并去重后的渲染数据：表情库在前，配置里的快捷表情补在后 */
  @State stickerTiles: StickerTile[] = [];
  /**
   * 表情缩略图是否已经到手。
   *
   * 批量取图是「一次往返换整屏图」，所以在它回来之前先别把网格挂上去：网格一挂，
   * 每格都会去要图，而那时暂存区还是空的，于是它们各自退回「一张一次往返」——
   * 恰好把批量省下来的那几十次往返又打回去。宁可先显示一行「正在载入表情…」，
   * 也不让网格在没有字节的情况下开张。
   */
  @State stickerReady: boolean = true;
  /**
   * 表情格的「重挂载代次」。
   *
   * 每开始一次批量取图就加一，并把它拼进 ForEach 的 key —— 让整片网格连同每一格
   * 的 @State（尤其是 `thumbFailed`）一起重建。不这么做的话，链路断开那一刻打开
   * 面板会把十几格一次性记成「这张图取不到」，之后链路恢复、缓存也重建了，
   * 那些格子却因为记账还在，一直是光秃秃的文字。
   */
  @State stickerEpoch: number = 0;
  @State current: string = '';
  @State messages: WatchMessage[] = [];
  /** 乐观回显：已贴到界面但服务端还没确认的消息 */
  @State pending: WatchMessage[] = [];
  @State rev: string = '';
  /** 会话内容正在读（列表还是空的时候才显示，避免每次都把画面切换一次） */
  @State chatLoading: boolean = false;
  /** 读失败的原因。只弹 toast 的话 3 秒就没了，用户看到的是「进去什么都没有」 */
  @State chatError: string = '';
  /** 上一次提示过的会话级错误，用来避免每轮重试都弹一次同样的提示 */
  @State lastSessionError: string = '';

  // ---- 交互状态 ----
  @State draft: string = '';
  @State sheetOpen: boolean = false;
  /** 回复面板当前形态，见 MODE_* 常量 */
  @State sheetMode: string = MODE_MENU;
  /** 触感反馈开关（持久化在 WatchPrefs 的 haptics 键） */
  @State hapticsOn: boolean = true;
  /** 输入框是否正在编辑：键盘弹起时收起表情网格，否则圆屏上卡片必被变形 */
  @State inputFocused: boolean = false;
  @State busy: boolean = false;
  @State inflight: boolean = false;
  @State hidden: boolean = false;
  @State toastText: string = '';
  @State toastKind: string = '';
  @State toastShown: boolean = false;

  private client: BridgeSession = new BridgeSession();
  /** 加载状态是否正在飞，防止重试定时器和用户点击叠成两次 */
  private statusInflight: boolean = false;
  private retryTimerId: number = -1;
  private reconnectTimerId: number = -1;
  /** 连续重连失败次数，决定退避取到哪一档；连上就归零 */
  private reconnectAttempt: number = 0;
  /** 这一轮断线已经提醒过用户了，别每一轮重试都弹一次 */
  private linkNotified: boolean = false;
  private toastTimerId: number = -1;
  private messageScroller: Scroller = new Scroller();
  /**
   * 是否跟随最新一条。
   *
   * 用户本来就在底部时保持 true：来了新消息自动跟下去；他一旦往上翻看旧记录就转
   * false，此后新消息不再把他拽回底部 —— 抬腕翻历史翻到一半被拉走是很讨厌的。
   * 滚回最底下、或自己发一条（force），都会自动恢复跟随。
   */
  private followBottom: boolean = true;
  /** 用来在「收起键盘」时主动结束编辑（TextInput 没有别的办法从代码里失焦） */
  private inputCtl: TextInputController = new TextInputController();
  /** 设置页那个字段编辑框的控制器：提交时用它收键盘 */
  private editCtl: TextInputController = new TextInputController();
  /** 短语输入框的控制器，同上 */
  private phraseCtl: TextInputController = new TextInputController();
  /** 短语是否已播种（内存镜像，真值落在 phrases_ready 键上） */
  private phrasesSeeded: boolean = false;
  /** 上一批缩略图对应的库指纹（见 ensureStickerThumbs），空串表示还没拿过 */
  private thumbStamp: string = '';
  /** 拿那一批时的缓存代次：重连会清缓存，代次一变就必须重新拿 */
  private thumbGeneration: number = -1;
  /** 批量取图正在飞，避免连点「写」发出两笔几百 KB 的请求 */
  private thumbLoading: boolean = false;
  /** 上一次读到会话预览的时刻，用来做最短重读间隔 */
  private summariesAt: number = 0;

  // ============================================================ 生命周期

  aboutToAppear(): void {
    const context: common.Context | undefined = this.getUIContext().getHostContext() as common.Context;
    if (context !== undefined) {
      WatchPrefs.init(context);
    }
    this.formEndpoint = this.loadEndpoint();
    this.formToken = WatchPrefs.getString(KEY_TOKEN, '');
    // 震动开关：默认开。恢复时不震 —— 应用刚打开就抖一下会让人以为出了故障
    this.hapticsOn = WatchPrefs.getBool(KEY_HAPTICS, true);
    Haptics.restore(this.hapticsOn);
    this.loadPhrases();

    // 回调要在第一次连接之前挂上：连接过程中的断开事件也是状态，漏掉就会
    // 出现「界面以为还连着」的假象
    this.client.onPush = (data: WatchPush) => {
      this.applyPush(data);
    };
    this.client.onState = (connected: boolean, detail: string) => {
      this.onLinkState(connected, detail);
    };

    if (!this.client.configure(this.formEndpoint, this.formToken)) {
      this.needConfig = true;
      this.booting = false;
      this.bootText = '请先填写电脑地址和访问令牌';
      return;
    }
    this.loadStatus(false);
  }

  aboutToDisappear(): void {
    // 退出页面时收起焦点激活态（官方要求的配对操作），否则焦点态会悬着
    try {
      this.getUIContext().getFocusController().activate(false);
    } catch (err) {
      hilog.debug(DOMAIN, TAG, '退出焦点激活态失败');
    }
    this.stopRetry();
    this.stopReconnect();
    if (this.toastTimerId >= 0) {
      clearTimeout(this.toastTimerId);
      this.toastTimerId = -1;
    }
    // 退出时主动断开，服务端能立刻把这条会话清掉，不用等心跳超时
    this.fireAndForget(this.client.disconnect(), '断开连接');
  }

  /** 抬腕回到前台：立刻对齐一次，并把订阅切回前台节奏 */
  onPageShow(): void {
    this.hidden = false;
    this.ensureCrownFocus();
    if (!this.client.configured) {
      return;
    }
    // 先探一下链路。熄屏期间定时器可能被冻结，链路已经断了表端却还不知道，
    // 这种情况下方的 syncChat 会卡在 30 秒超时上；探一下就能当场判死，直接走重连。
    this.client.poke();
    if (this.current.length > 0) {
      this.syncChat(false);
    } else {
      this.loadStatus(false);
    }
  }

  /** 切到后台：订阅降频，电脑端就不必每秒去读一次浏览器里的 DOM */
  onPageHide(): void {
    this.hidden = true;
    if (this.current.length > 0 && this.client.connected) {
      this.fireAndForget(this.client.watch(this.current, READ_LIMIT, false, this.rev), '订阅降频');
    }
  }

  // ============================================================ 布局

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.needConfig) {
        this.buildConfig()
      } else if (this.bootFailed) {
        this.buildFail()
      } else if (this.booting) {
        this.buildBoot()
      } else if (this.current.length === 0) {
        this.buildList()
      } else {
        this.buildChat()
      }

      if (this.sheetOpen) {
        this.buildSheet()
      }
      this.buildToast()
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
    // 这里**不要**加 focusable(false)。看着像是「防止根容器抢焦点」，实测是把
    // 整条焦点链打断：dumpLayout 里原本是 root → Stack → Stack → friendsList →
    // ListItem → Row 一串 focused=true（表冠可用的样子），加完只剩 root 一个，
    // 转表冠彻底失灵，连挂在这上面的 onKeyEvent（智慧手势的捏合确认）也收不到。
    // 焦点链上祖先和后代同时标 focused 是常态，不是「谁抢了谁」。
    //
    // 反过来，**这一层就是聊天页上获焦的那个节点**，所以表冠挂在这里：
    //   · 表冠事件只发给获焦组件，而聊天页的 Scroll 拿不到焦点（老问题，见
    //     onCrownScroll 的注释），获焦的正是本层；
    //   · 判断依据不是猜的：同一套「系统下发给获焦组件」的分发机制下，
    //     智慧手势的捏合（下面 onKeyEvent 里那个 KEYCODE_ENTER）在聊天页一直好使 ——
    //     能收到捏合，就说明焦点确实落在本层。
    // 先试过「另铺一个 focusable 的空容器专收表冠」，真机上 requestFocus 不报错、
    // 焦点却拿不到（ArkUI 不把焦点给 hitTestBehavior(None) 的节点），已拆掉。
    .focusable(true)
    .id(CROWN_TARGET_ID)
    .onDigitalCrown((event: CrownEvent) => {
      this.onCrownScroll(event);
    })
    // ---------------------------------------------------------- 手势 1：右滑返回
    // 用 parallelGesture 而不是 gesture：垂直方向要让给内部的滚动容器，
    // 水平这一下并行识别，两边互不抢。判定要求「右滑距离够长」且「横向明显大于
    // 纵向」，斜着划一下不会误退。
    .parallelGesture(
      PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 30 })
        .onActionEnd((event: GestureEvent) => {
          const dx: number = event.offsetX;
          if (dx > 60 && dx > Math.abs(event.offsetY)) {
            this.handleBack();
          }
        })
    )
    // ---------------------------------------------------------- 手势 2：智慧手势
    // 「捏合确认」和「滑动切焦」都要求界面处于焦点激活态（见 requestCrownFocus），
    // 系统识别到互点两下后，就往获焦组件下发 KEYCODE_ENTER，在这里接住即可。
    .onKeyEvent((event: KeyEvent) => {
      if (event.type === KeyType.Down && event.keyCode === KeyCode.KEYCODE_ENTER) {
        this.handlePinch();
      }
    })
    .onAreaChange((oldValue: Area, newValue: Area) => {
      const w: number = Number(newValue.width);
      const h: number = Number(newValue.height);
      if (!Number.isFinite(w) || !Number.isFinite(h) || w <= 0 || h <= 0) {
        return;
      }
      // 只有尺寸真的变了才重建，避免每帧都触发一次状态更新
      if (Math.abs(w - this.geo.w) > 0.5 || Math.abs(h - this.geo.h) > 0.5) {
        this.geo = new WatchGeometry(w, h);
      }
    })
  }

  // ------------------------------------------------------------ 配置页

  // ------------------------------------------------------------ 配置页

  /**
   * 设置页（对应演示页第 8 屏）。
   *
   * 三块内容：电脑地址、连接令牌、震动反馈开关，底部一个「保存并重新连接」。
   * 行样式照演示页：96px 高、圆角 28px、卡片底 #1C1C1E，行内左边「主标题 + 灰色小字」、
   * 右边一个 › —— 灰字那行显示的就是当前值，点一下进编辑页改它。
   *
   * 点进独立编辑页而不是「就地变输入框」是必须的，不是偷懒：`TextInput` 一按下就抢焦点、
   * 就弹键盘，而圆屏上「想往下滑」和「想点这一行」起手是同一下，只要滚动区里存在输入框，
   * 滑动就一定会从某一行起手，键盘当场弹出来把整页顶掉。详见 FIELD_* 常量。
   *
   * 滚动容器铺满整屏、安全区做在内容自己的 padding 里（理由见 Geometry 里
   * 「全屏滚动容器」那段）：这一页内容比一屏高，旧版底边钉在 y=443px 处 ——
   * 那里圆的可用宽度只剩 202px，而内容带还有 331px 宽，两条笔直的切边横在圆里，
   * 看上去就像给整页描了个框。
   */
  @Builder
  buildConfig() {
    // 字段编辑页和设置页互斥，共用同一个页签名
    if (this.editField !== FIELD_NONE) {
      this.buildFieldEditor()
    } else {
      Stack({ alignContent: Alignment.TopStart }) {
        Text('设置')
          .fontSize(this.geo.fsTitle)
          .fontWeight(FontWeight.Bold)
          .fontColor(Palette.t1)
          .width(this.geo.col)
          .textAlign(TextAlign.Center)
          .position({ x: this.geo.colX, y: this.geo.titleTop })
          .zIndex(2)

        // 返回：演示页的设置页只有标题，但真机上少了它，误点齿轮就出不来了
        // （唯一的出口是「保存并重新连接」）。位置用演示页自己的 iconbtn 规格。
        this.headerIcon('back', 0)

        Scroll() {
          Column({ space: this.geo.rowGap }) {
            this.settingField('电脑地址', '电脑IP:8787', FIELD_ENDPOINT)

            this.settingField('连接令牌', '访问令牌', FIELD_TOKEN)

            // 震动反馈开关。整行都可点（手表上先瞄准再去找那个小滑块很难受），
            // 翻转立即持久化，不用点保存。
            Row({ space: this.geo.f(0.03) }) {
              Column({ space: this.geo.f(0.0086) }) {
                Text('震动反馈')
                  .fontSize(this.geo.fsBody)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Palette.t1)
                  .width('100%')
                Text(this.hapticsOn ? '点按与转表冠时轻震' : '已关闭')
                  .fontSize(this.geo.fsSub)
                  .fontColor(Palette.t2)
                  .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              // 开关**内联画在这里**，没有抽成 @Builder。
              //
              // 踩过的坑：`@Builder` 的参数默认按值传递，**参数变化不会引起
              // Builder 内的 UI 刷新**（ArkUI 的明确规则，只有 `$$` 按引用传递才刷新）。
              // 抽成 `hapticSwitch(this.hapticsOn)` 之后，点整行确实翻转了状态、
              // 副标题也变了（那一行直接读 this.hapticsOn，依赖被记下了），
              // 唯独滑块不动 —— 因为 Builder 里读的是那个「传进来的值」，不是状态本身。
              // 写成内联就没有这层隔断：表达式在父组件的 build 里求值，依赖自然挂上。
              Stack({ alignContent: this.hapticsOn ? Alignment.End : Alignment.Start }) {
                Circle()
                  .width(this.geo.switchKnob)
                  .height(this.geo.switchKnob)
                  .fill(Palette.t1)
              }
              .width(this.geo.switchW)
              .height(this.geo.switchH)
              .padding(this.geo.f(0.0172))
              .backgroundColor(this.trackColor(this.hapticsOn))
              .borderRadius(this.geo.switchH / 2)
            }
            .width('100%')
            .constraintSize({ minHeight: this.geo.btnH })
            .padding({
              left: this.geo.padIn,
              right: this.geo.padIn,
              top: this.geo.f(0.043),
              bottom: this.geo.f(0.043)
            })
            .backgroundColor(Palette.card)
            .borderRadius(this.geo.f(0.1202))
            .onClick(() => {
              Haptics.tap();
              this.toggleHaptics(!this.hapticsOn);
            })

            Text('保存并重新连接')
              .fontSize(this.geo.fsList)
              .fontColor(Palette.t1)
              .fontWeight(FontWeight.Medium)
              .textAlign(TextAlign.Center)
              .height(this.geo.btnH)
              .width('100%')
              .backgroundColor(Palette.blue)
              .borderRadius(this.geo.btnH / 2)
              .onClick(() => {
                Haptics.tap();
                this.saveConfig();
              })
          }
          .width('100%')
          // 安全区是内容自己的内边距，不是容器的 —— 容器一有 padding，
          // 那两条边界就钉死在圆里，内容永远滑不过去
          .padding({
            left: this.geo.colX,
            right: this.geo.colX,
            top: this.geo.scrollPadTop,
            bottom: this.geo.scrollPadBottom
          })
        }
        .width(this.geo.w)
        .height(this.geo.h)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .focusable(true)
        .focusOnTouch(true)
        .digitalCrownSensitivity(CrownSensitivity.MEDIUM)
        .id('settingsScroll')
        // Scroll 没有 onScrollIndex（那是 List 的回调），用 onScroll 代替：
        // 滚动过程中会连续触发，靠 Haptics 自己的 40ms 节流压成有节奏的轻震
        .onScroll(() => {
          Haptics.tick();
        })
        .position({ x: 0, y: 0 })

        this.glassBar()
      }
      .width('100%')
      .height('100%')
    }
  }

  /**
   * 字段编辑页。
   *
   * 为什么另开一整屏：手表软键盘是全屏的，弹起来之后圆屏只剩下圆心以上那块弧。
   * 就地编辑时那一行会被键盘顶到看不见的地方，用户一边打字一边看不到自己打了什么。
   * 整屏之后输入框固定在圆心略上方，键盘顶上来它还在原地。
   */
  @Builder
  buildFieldEditor() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 键盘弹起时上半屏同样只剩一条弧，返回钮和标题都得让位
      if (!this.editFocused) {
        Stack() {
          this.iconBack(this.geo.iconGlyph)
        }
        .width(this.geo.iconBtn)
        .height(this.geo.iconBtn)
        .backgroundColor(Palette.card)
        .borderRadius(this.geo.iconBtn / 2)
        .position({ x: this.geo.hdrBtnX, y: this.geo.hdrBtnY })
        .onClick(() => {
          Haptics.tap();
          this.cancelEdit();
        })

        Text(this.editField === FIELD_ENDPOINT ? '电脑地址' : '连接令牌')
          .fontSize(this.geo.fsTitle)
          .fontWeight(FontWeight.Bold)
          .fontColor(Palette.t1)
          .width(this.geo.col)
          .textAlign(TextAlign.Center)
          .position({ x: this.geo.colX, y: this.geo.titleTop })
      }

      Column({ space: this.geo.f(0.04) }) {
        TextInput({
          text: this.editDraft,
          placeholder: this.editField === FIELD_ENDPOINT ? '电脑IP:8787' : '访问令牌',
          controller: this.editCtl
        })
          .type(InputType.Normal)
          .fontSize(this.geo.fsBody)
          // 占位文字的字号必须单独设，否则它按系统默认大小渲染、在这个宽度里被截半句
          .placeholderFont({ size: this.geo.fsBody })
          .fontColor(Palette.t1)
          .placeholderColor(Palette.t3)
          .caretColor(Palette.blue)
          .backgroundColor(Palette.card2)
          .borderRadius(this.geo.ctrlH / 2)
          .height(this.geo.ctrlH)
          .width('100%')
          .id('fieldEditor')
          .onFocus(() => {
            this.editFocused = true;
          })
          .onBlur(() => {
            this.editFocused = false;
          })
          .onChange((value: string) => {
            this.editDraft = value;
          })
          // 键盘上的「完成」等同于点下面那个按钮，省得把手从键盘挪开去够屏幕
          .onSubmit(() => {
            this.commitEdit();
          })

        Text('完成')
          .fontSize(this.geo.fsList)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.t1)
          .textAlign(TextAlign.Center)
          .width('100%')
          .height(this.geo.btnH)
          .backgroundColor(Palette.blue)
          .borderRadius(this.geo.btnH / 2)
          .onClick(() => {
            Haptics.tap();
            this.commitEdit();
          })
      }
      .width(this.geo.col)
      // 摆在圆心略上方：键盘占掉下半屏之后，这一列正好落在剩下的那块弧里
      .position({ x: this.geo.colX, y: this.geo.h / 2 - this.geo.f(0.28) })
    }
    .width('100%')
    .height('100%')
    .onAppear(() => {
      // 进这一页就是为了打字，直接把焦点交给输入框，省掉「再点一下」。
      // 但要等它挂上去：这一帧才开始建，立刻要焦点会找不到 id。
      setTimeout(() => {
        try {
          this.getUIContext().getFocusController().requestFocus('fieldEditor');
        } catch (err) {
          hilog.debug(DOMAIN, TAG, '字段编辑框还没挂上，先不抢焦点');
        }
      }, 80);
    })
  }

  /**
   * 设置页里的一行字段：左边「标题 + 当前值」，右边一个 ›。
   *
   * 这一行里**没有 TextInput** —— 它只是长得像可编辑，点一下才进编辑页。
   * 这是硬伤级的取舍：`TextInput` 一按下就抢焦点弹键盘，而圆屏上想滚动和想点
   * 起手都是同一下，只要滚动区里有输入框，往下滑就一定会从某一行起手。
   * 把输入框搬出滚动区是唯一干净的办法。
   */
  @Builder
  settingField(title: string, placeholder: string, field: number) {
    Row({ space: this.geo.f(0.03) }) {
      Column({ space: this.geo.f(0.0086) }) {
        Text(title)
          .fontSize(this.geo.fsBody)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.t1)
          .width('100%')

        Text(this.fieldValue(field).length > 0 ? this.fieldValue(field) : placeholder)
          .fontSize(this.geo.fsSub)
          // 有值时是正常次级文字，空着才用更淡的占位色 —— 一眼能看出「这项还没填」
          .fontColor(this.fieldValue(field).length > 0 ? Palette.t2 : Palette.t3)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      this.iconChevron(this.geo.iconGlyph)
    }
    .width('100%')
    .constraintSize({ minHeight: this.geo.btnH })
    .padding({
      left: this.geo.padIn,
      right: this.geo.padIn,
      top: this.geo.f(0.043),
      bottom: this.geo.f(0.043)
    })
    .backgroundColor(Palette.card)
    .borderRadius(this.geo.f(0.1202))
    .onClick(() => {
      Haptics.tap();
      this.beginEdit(field);
    })
  }

  /** 字段当前值：设置页那一行灰字显示的就是它 */
  private fieldValue(field: number): string {
    return field === FIELD_ENDPOINT ? this.formEndpoint : this.formToken;
  }

  /** 进字段编辑页：先把当前值灌进草稿，中途返回即放弃 */
  private beginEdit(field: number): void {
    this.editDraft = this.fieldValue(field);
    this.editFocused = false;
    this.editField = field;
  }

  /** 放弃这次编辑 */
  private cancelEdit(): void {
    this.editCtl.stopEditing();
    this.editFocused = false;
    this.editField = FIELD_NONE;
    this.ensureCrownFocus();
  }

  /** 提交这次编辑：只有走到这里才真正写回表单值 */
  private commitEdit(): void {
    const value: string = this.editDraft.trim();
    if (this.editField === FIELD_ENDPOINT) {
      this.formEndpoint = value;
    } else if (this.editField === FIELD_TOKEN) {
      this.formToken = value;
    }
    this.cancelEdit();
  }

  // 自绘的开关（对应演示页 `.sw`：70×40，滑块 32）现在是**内联**写的，不再是一个
  // @Builder —— 这一点踩过坑，见下面那段说明。
  //
  // 不用系统 `Toggle`：它的内部点击处理和整行的 onClick 会打架 ——
  // 用户点滑块，onChange 和整行的 onClick 都触发一次，开关当场又跳回去。
  // 自绘之后点击只由整行接（热区是整行 96px 高，比滑块本身好按得多），
  // 状态完全由 hapticsOn 决定，没有第二条路径。

  /** 开关的轨道底色 / 滑块停靠边 */
  private trackColor(on: boolean): string {
    return on ? Palette.blue : Palette.trackOff;
  }

  /** 翻转震动开关：立即生效并落盘 */
  private toggleHaptics(on: boolean): void {
    if (on === this.hapticsOn) {
      return;
    }
    this.hapticsOn = on;
    WatchPrefs.setBool(KEY_HAPTICS, on);
    // setEnabled 里带一次「开启」的确认震动，关的时候静默
    Haptics.setEnabled(on);
    if (!on) {
      this.showToast('震动已关闭', '');
    }
  }

  // ------------------------------------------------------------ 加载页

  /**
   * 启动页（演示页第 1 屏）：一句状态 + 地址 + 转圈。
   *
   * 顺序照演示页：标题在上、地址居中、转圈最下 —— 转圈是「还在动」的信号，
   * 放在最下面不挡文字。
   */
  @Builder
  buildBoot() {
    Column({ space: this.geo.f(0.094) }) {
      Text('正在连接电脑…')
        .fontSize(this.geo.fsList)
        .fontColor(Palette.t1)
        .textAlign(TextAlign.Center)
        .width(this.geo.col)

      Text(this.client.label.length > 0 ? this.client.label : this.formEndpoint)
        .fontSize(this.geo.fsSub)
        .fontColor(Palette.t2)
        .textAlign(TextAlign.Center)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ left: this.geo.f(0.06), right: this.geo.f(0.06) })
        .width(this.geo.col)

      LoadingProgress()
        .width(this.geo.f(0.24))
        .height(this.geo.f(0.24))
        .color(Palette.blue)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 连接失败页（演示页第 2 屏）。
   *
   * 单独一屏而不是把加载页改个颜色：连不上时**不能再转圈** —— 转圈让人以为还在
   * 加载。这一页必须给出三件事：发生了什么（徽标 + 标题）、为什么（原因自述）、
   * 还能做什么（重试 / 改地址）。原来这一页一个可点的东西都没有，地址一旦填错
   * 就被锁死在转圈里，只能在手表上把应用卸了重装。
   */
  @Builder
  buildFail() {
    Column() {
      Stack() {
        Text('!')
          .fontSize(this.geo.f(0.155))
          .fontWeight(FontWeight.Bold)
          .fontColor(Palette.red)
      }
      .width(this.geo.f(0.309))
      .height(this.geo.f(0.309))
      .backgroundColor(Palette.redSoft)
      .borderRadius(this.geo.f(0.155))
      .border({ width: 2, color: Palette.red })

      Text('连不上电脑')
        .fontSize(this.geo.fsTitle)
        .fontWeight(FontWeight.Bold)
        .fontColor(Palette.t1)
        .margin({ top: this.geo.f(0.043) })

      Text(this.bootText)
        .fontSize(this.geo.fsCaption)
        .fontColor(Palette.t2)
        .lineHeight(this.geo.f(0.116))
        .textAlign(TextAlign.Center)
        .maxLines(4)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ minHeight: this.geo.f(0.232) })
        .margin({ top: this.geo.f(0.026) })
        .padding({ left: this.geo.f(0.05), right: this.geo.f(0.05) })

      Text('重试')
        .fontSize(this.geo.fsBtn)
        .fontWeight(FontWeight.Medium)
        .fontColor(Palette.t1)
        .textAlign(TextAlign.Center)
        .width(this.geo.replyW)
        .height(this.geo.btnH)
        .backgroundColor(Palette.blue)
        .borderRadius(this.geo.btnH / 2)
        .margin({ top: this.geo.f(0.06) })
        .onClick(() => {
          Haptics.tap();
          this.retryBoot();
        })

      Text('修改电脑地址')
        .fontSize(this.geo.fsBody)
        .fontColor(Palette.t1)
        .textAlign(TextAlign.Center)
        .width(this.geo.replyW)
        .height(this.geo.ctrlH)
        .border({ width: 2, color: Palette.line })
        .borderRadius(this.geo.ctrlH / 2)
        .margin({ top: this.geo.f(0.0515) })
        .onClick(() => {
          Haptics.tap();
          this.openConfigFromBoot();
        })
    }
    .width(this.geo.col)
    .position({ x: this.geo.colX, y: this.geo.hdrTop })
    .alignItems(HorizontalAlign.Center)
  }

  /** 失败页的「重试」：清掉失败标记回到加载页，再走一遍 status */
  private retryBoot(): void {
    this.bootFailed = false;
    this.booting = true;
    this.bootText = '正在连接电脑…';
    this.loadStatus(true);
  }

  // ------------------------------------------------------------ 好友列表

  /**
   * 会话列表（对应演示页第 3 屏）。
   *
   * 演示页这一屏的顶栏是「居中大标题 + 一行联网状态」，行本身是 104px 的卡片
   * （头像 64 / 名字 26 / 预览 20 / 时间 18）。这里照做，只在顶上多放两个 64px
   * 圆形图标钮（左「刷」右「设」）—— 演示页那两屏没画它们，但它们是功能入口，
   * 而且用的正是演示页自己的 iconbtn 规格，不妨碍「居中标题」这件事。
   */
  @Builder
  buildList() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column({ space: this.geo.f(0.0086) }) {
        Text('消息')
          .fontSize(this.geo.fsTitle)
          .fontWeight(FontWeight.Bold)
          .fontColor(Palette.t1)
          .width('100%')
          .textAlign(TextAlign.Center)

        Row({ space: this.geo.f(0.0172) }) {
          Circle({ width: this.geo.f(0.043), height: this.geo.f(0.043) })
            .fill(this.statusColor())

          Text(this.statusText())
            .fontSize(this.geo.fsCaption)
            .fontColor(this.statusText() === '已连接电脑' ? Palette.green : Palette.t2)
            .maxLines(1)
        }
        .justifyContent(FlexAlign.Center)
        .width('100%')
      }
      .width(this.geo.col)
      .position({ x: this.geo.colX, y: this.geo.titleTop })
      .zIndex(2)

      // 顶栏两侧的圆形图标钮，位置与演示页的 hdr 一致
      this.headerIcon('refresh', 0)
      this.headerIcon('gear', 1)

      if (this.friends.length === 0) {
        Text('config.json 里还没有配置好友')
          .fontSize(this.geo.fsSub)
          .fontColor(Palette.t2)
          .textAlign(TextAlign.Center)
          .width(this.geo.col)
          .position({ x: this.geo.colX, y: this.geo.colTop })
      } else {
        // 容器铺满整屏，安全区靠**每行自己的外边距**让出来（见文件头「全屏滚动容器」）。
        // 这一点很关键：如果改成给 List 设 padding，那两条边界就钉在容器上，
        // 内容永远滑不进 padding 区 —— 圆里会多出一横一竖两条笔直的切边，
        // 看着就像给列表描了个框。放在行上，留白会跟着列表一起滚走。
        List({ space: this.geo.rowGap }) {
          ForEach(this.friends, (name: string, index: number) => {
            ListItem() {
              FriendRow({
                name: name,
                preview: this.previewOf(name),
                time: this.timeOf(name),
                r: this.geo.r,
                onPick: (picked: string) => {
                  this.openChat(picked);
                }
              })
            }
            .margin({
              left: this.geo.colX,
              right: this.geo.colX,
              top: index === 0 ? this.geo.scrollPadTop : 0,
              bottom: index === this.friends.length - 1 ? this.geo.scrollPadBottom : 0
            })
          }, (name: string) => name)
        }
        .width(this.geo.w)
        .height(this.geo.h)
        .scrollBar(BarState.Off)
        // 表冠事件只发给「当前有焦点」的组件：List 默认就支持表冠滚动，但必须先拿到焦点。
        // 这里不能用 defaultFocus —— 它只在页面首次创建时生效，而本列表是数据回来之后
        // 才建出来的，所以焦点由 ensureCrownFocus() 显式要。
        .focusable(true)
        .focusOnTouch(true)
        .digitalCrownSensitivity(CrownSensitivity.MEDIUM)
        .id('friendsList')
        // 每转过一行给一次轻震：不看屏幕也知道自己滑了几格
        .onScrollIndex(() => {
          Haptics.tick();
        })
        .position({ x: 0, y: 0 })
      }

      this.glassBar()
    }
    .width('100%')
    .height('100%')
  }

  // ============================================================ 图标
  //
  // 顶栏上那两个圆钮用的是**系统符号库**（SymbolGlyph）。走到这一步之前试过两条路，都不行：
  //
  //   1. 打字符（⟳ / ⚙ / ✎）—— 手表自带字体里没有这些字形，直接渲染成空白；
  //   2. 退回用「刷 / 设 / 键」汉字顶上 —— 能显示了，但它是**字**不是图标：
  //      有字重、有自己的左右留白、基线也不在几何中心，塞进圆钮里怎么调都不齐。
  //
  // 系统符号就没这些问题：描边风格和整个 HarmonyOS 一致，
  // 颜色跟着主题走（fontColor 收数组），深浅色都不用换图。
  //
  // 只有系统库里一时没找到对应名字的形状才自己画（返回折线、键盘、行尾 ›），
  // 同样写死在 40×40 参考系里、由 Shape 的 viewPort 缩放到实际尺寸。

  /**
   * 返回：chevron_left。
   *
   * 也必须用系统符号，不能自绘 —— 系统符号的字形里自带一圈留白，同一个 fontSize
   * 下几个图标的视觉重量是对齐的；自己画的折线按图形外框去凑尺寸，和旁边的齿轮
   * （符号）放一起总显得又细又小。
   */
  @Builder
  iconBack(size: number) {
    SymbolGlyph($r('sys.symbol.chevron_left'))
      .fontSize(size)
      .fontColor([Palette.t1])
  }

  /** 键盘：外框 + 两排按键 + 空格条。用在「快捷短语」页右上（点了转去手打） */
  @Builder
  iconKeyboard(size: number) {
    Stack() {
      Rect()
        .width(size * 0.94)
        .height(size * 0.66)
        .radius(size * 0.14)
        .fill(Color.Transparent)
        .stroke(Palette.t1)
        .strokeWidth(size * 0.1)

      Column({ space: size * 0.07 }) {
        Row({ space: size * 0.08 }) {
          Rect().width(size * 0.08).height(size * 0.08).radius(size * 0.02).fill(Palette.t1)
          Rect().width(size * 0.08).height(size * 0.08).radius(size * 0.02).fill(Palette.t1)
          Rect().width(size * 0.08).height(size * 0.08).radius(size * 0.02).fill(Palette.t1)
        }

        Rect().width(size * 0.34).height(size * 0.08).radius(size * 0.03).fill(Palette.t1)
      }
      .justifyContent(FlexAlign.Center)
    }
    .width(size)
    .height(size)
  }

  /**
   * 加号：横竖两笔。用在「添加短语」那一行。
   *
   * 这里用 `Stack` + `Rect` 画，**不用 `Shape` + `Path`** —— 后者在这块表上会整体
   * 偏到左上角去，实测过：把「添加短语」行、删除钮、返回钮三个图标取亮像素重心，
   * × 偏 (-9.2, -9.0)px、＋ 偏 (-1.5, -5.4)px，而同一行的系统符号返回箭头只偏 0.2px。
   * 也就是说 `Shape` 里那个 `viewPort` 的坐标映射并不是把 40×40 等比铺到 size×size 上，
   * 自绘图形既缩不准也居不中（第一版还因此小了一圈）。
   *
   * 换成 Stack + Rect 之后没有第二套坐标系：Rect 的宽高就是它画出来的大小，
   * Stack 默认居中，size 传多少、图形就是多大、就在正中。
   * 两笔的圆角取厚度的一半，端头是圆的，和系统符号的笔头一致。
   */
  @Builder
  iconPlus(size: number) {
    Stack() {
      Rect()
        .width(size)
        .height(size * 0.12)
        .radius(size * 0.06)
        .fill(Palette.t1)
      Rect()
        .width(size * 0.12)
        .height(size)
        .radius(size * 0.06)
        .fill(Palette.t1)
    }
    .width(size)
    .height(size)
  }

  /**
   * 叉：两条 45° 的短棒。用在管理页的删除钮上。画法同 iconPlus。
   *
   * 棒长取 size，转 45° 之后可见范围是 size/√2 ≈ 0.71×size —— 和在 64px 圆钮里
   * 那个约 0.7 占比的系统符号（齿轮 / 刷新）是一个视觉重量。
   */
  @Builder
  iconClose(size: number) {
    Stack() {
      Rect()
        .width(size)
        .height(size * 0.12)
        .radius(size * 0.06)
        .fill(Palette.t1)
        .rotate({ angle: 45 })
      Rect()
        .width(size)
        .height(size * 0.12)
        .radius(size * 0.06)
        .fill(Palette.t1)
        .rotate({ angle: -45 })
    }
    .width(size)
    .height(size)
  }

  /**
   * 顶栏的毛玻璃底。
   *
   * 滚动容器铺满整屏之后，内容是能滚到屏幕最上沿的 —— 滑上去的卡片会直接压在标题
   * 和返回钮上，两行字叠在一起互相穿帮。给它垫一层毛玻璃：背后的内容被糊掉，
   * 标题始终清楚，又不像纯黑底那样把「上面还有内容」这件事彻底藏死。
   *
   * 高度取到内容带上沿（colTop）：正好是内容被允许进入的最上界，再高就是白糊一片。
   * zIndex 取 1 —— 在滚动容器（0）之上、标题和按钮（2）之下。
   */
  @Builder
  glassBar() {
    // 主体：模糊 + 压暗。
    //
    // 这里没有用 `backgroundBlurStyle(BlurStyle.XXX)` —— 那几个预设材质自己带一层
    // 亮度，深色界面下整条会泛出灰白（实测顶栏直接变成一条浅灰带，白字压上去
    // 反而更难认）。改成自己给参数：radius 是模糊半径，brightness 把背后的内容
    // 压下去，color 是叠在模糊结果上的底色 —— 三个量都在手上，才能既保住「背后
    // 有东西在动」的层次感，又确保标题始终是最亮的那一层。
    Column() {
    }
    .width('100%')
    .height(this.geo.colTop)
    .position({ x: 0, y: 0 })
    .backgroundEffect({
      radius: 16,
      saturation: 0.9,
      // brightness 压得越狠标题越清楚，但压过头整条就变成一块纯灰/纯黑，
      // 「毛玻璃」也就没了 —— 0.55 + 半透明底是这两件事的平衡点
      brightness: 0.55,
      color: '#7A000000'
    })
    .hitTestBehavior(HitTestMode.None)
    .zIndex(1)

    // 下沿柔化：模糊层的底边是一条笔直的硬线，在圆里看得很清楚。
    // 单独叠一小条从「同色」到透明的渐变，把这条线化进内容里 ——
    // 起点用和上面一样的 #7A000000，两层的接缝才看不出来。
    Column() {
    }
    .width('100%')
    .height(this.geo.f(0.13))
    .position({ x: 0, y: this.geo.colTop - this.geo.f(0.13) })
    .linearGradient({
      angle: 180,
      colors: [[0x7A000000, 0.0], [0x00000000, 1.0]]
    })
    .hitTestBehavior(HitTestMode.None)
    .zIndex(1)
  }

  /**
   * 行尾的 ›：改用系统符号 chevron_right。
   *
   * 自绘那版小得离谱：`Shape` 的 viewPort 是 40×40，而折线只占 16→25（横向 9 个单位），
   * 于是传进去的 size 是「画布」不是「图形」—— fsSub（约 20px）的 size 实际只画出
   * 4.5px 的箭头，行尾看上去就是一个小点。
   *
   * 换系统符号之后，尺寸由 fontSize 直接说了算，字形和 chevron_left（返回）、齿轮、
   * 刷新是同一套，描边粗细与留白自动对齐。字号取 iconGlyph 而不是 fsSub ——
   * 它的实心高度只有 fontSize 的六成左右，按 fsSub 传仍然偏小；
   * iconGlyph 出来和顶栏返回钮里那个箭头一般大，行尾的引导感才够。
   */
  @Builder
  iconChevron(size: number) {
    SymbolGlyph($r('sys.symbol.chevron_right'))
      .fontSize(size)
      .fontColor([Palette.t3])
  }

  /**
   * 顶栏上的圆形图标钮（对应演示页 `.iconbtn`：64px 圆、卡片底）。
   *
   * 只接受字符串参数 —— @Builder 传函数时 ArkTS 的求值时机不好把握，
   * 用 kind 在内部派发更稳。
   */
  @Builder
  headerIcon(kind: string, side: number) {
    Stack() {
      if (kind === 'gear') {
        // 设置：gearshape_fill。系统符号库的图形，颜色跟主题走（fontColor 收数组）
        SymbolGlyph($r('sys.symbol.gearshape_fill'))
          .fontSize(this.geo.iconGlyph)
          .fontColor([Palette.t1])
      } else if (kind === 'back') {
        this.iconBack(this.geo.iconGlyph)
      } else {
        // 刷新：arrow_clockwise
        SymbolGlyph($r('sys.symbol.arrow_clockwise'))
          .fontSize(this.geo.iconGlyph)
          .fontColor([Palette.t1])
      }
    }
    .width(this.geo.iconBtn)
    .height(this.geo.iconBtn)
    .backgroundColor(Palette.card)
    .borderRadius(this.geo.iconBtn / 2)
    .position({
      x: side === 0 ? this.geo.hdrBtnX : this.geo.w - this.geo.hdrBtnX - this.geo.iconBtn,
      y: this.geo.hdrBtnY
    })
    // 必须在滚动容器之上。列表/滚动区现在是铺满整屏的，Stack 里虽然这个钮声明在前面
    // （本该在下层），但它下面那层会吃掉整个屏幕的触摸 —— 结果就是按钮看得见、点不着。
    .zIndex(2)
    .onClick(() => {
      Haptics.tap();
      if (kind === 'refresh') {
        // 在聊天页点刷新是重读当前会话，在列表页才是重新校验连接
        if (this.current.length > 0) {
          this.refreshChat();
        } else {
          this.loadStatus(true);
        }
      } else if (kind === 'gear') {
        this.openSettings();
      } else {
        this.closeSettings();
      }
    })
  }

  /** 从设置页回到列表：直接把保存过的值重新连一遍即可 */
  private closeSettings(): void {
    this.needConfig = false;
    this.booting = this.friends.length === 0;
    this.bootFailed = false;
    this.loadStatus(false);
  }

  /** 顶部那一行联网状态的字 */
  private statusText(): string {
    if (this.needConfig || this.bootFailed) {
      return '未连接';
    }
    if (this.linkLost) {
      return '连接已断开';
    }
    return '已连接电脑';
  }

  // ------------------------------------------------------------ 聊天页

  /**
   * 聊天页（对应演示页第 4 屏）。
   *
   * 顶栏是「左边一个 64px 返回圆钮 + 居中会话名」（演示页 `.s-chat .hdr`），
   * 不再是旧版那条把三样东西塞进去的胶囊 —— 胶囊两端被圆割线切掉之后，
   * 标题实际可用的宽度只剩一半，长一点的会话名必然被截。
   */
  @Builder
  buildChat() {
    Stack({ alignContent: Alignment.TopStart }) {
      this.chatHeader(this.current, 'refresh')

      // 这里用 Scroll + Column，而不是 List。
      //
      // 不是随意换的：华为对穿戴设备表冠的官方说明里写着 ——
      // **List 响应表冠的前提是「ListItem 里有子组件获焦」**，List 自身的 focusable
      // 不算数，它只是个容器。而同一个页面的 Scroll 可以自己持焦。
      //
      // 实测对照很干净：本页的 List 无论怎么 requestFocus（外部定时器、onAppear、
      // 给 ListItem 设 focusable、给气泡设 focusable）都拿不到焦点，dumpLayout 里
      // 一直是 focused=false；而设置页的 Scroll 一次就拿到了。
      //
      // 放弃 List 的代价是失去懒加载，但聊天一次只读 30 条（READ_LIMIT），
      // 整列一次性建出来毫无压力；换来的是「转表冠真的能动」。
      // 必须把 scroller 传进去：下面那句「从最新一条开始」是靠
      // messageScroller.scrollEdge(Edge.Bottom) 实现的，不传就是一个空转的 Scroller。
      Scroll(this.messageScroller) {
        Column({ space: this.geo.f(0.028) }) {
          ForEach(this.visibleMessages(), (item: WatchMessage, index: number) => {
            MessageBubble({
              message: item,
              r: this.geo.r
            })
              .margin({
                left: this.geo.colX,
                right: this.geo.colX,
                top: index === 0 ? this.geo.scrollPadTop : 0,
                bottom: index === this.visibleMessages().length - 1 ? this.geo.chatPadBottom : 0
              })
          }, (item: WatchMessage, index: number) => `${index}-${item.side}-${item.type}-${item.time}-${item.text}`)
        }
        .width('100%')
        // 内容长高时补滚一次：表情图是异步解码的，解码完列高还会再长一截，
        // 只靠数据落地那一拍滚不到真正的底部。
        // 只认「高度变大」—— 滚动本身也会让 onAreaChange 触发（组件位置变了），
        // 不看高度差的话就成了「一边滚一边被拽回底部」，用户根本翻不上去。
        .onAreaChange((oldValue: Area, newValue: Area) => {
          const before: number = Number(oldValue.height);
          const after: number = Number(newValue.height);
          if (!Number.isFinite(before) || !Number.isFinite(after)) {
            return;
          }
          if (after - before > 0.5 && this.followBottom) {
            this.scrollMessagesToBottom();
          }
        })
      }
      .width(this.geo.w)
      .height(this.geo.h)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      // 表冠**不挂在这个 Scroll 上**：它拿不到焦点，表冠事件到不了它这儿。
      // 表冠挂在根容器上，见那里的 onDigitalCrown 与 onCrownScroll。
      // focusOnTouch 关掉：手指碰一下就把焦点从接收器挪到 Scroll 上的话，表冠会跟着失焦，
      // 表现成「碰过聊天记录之后表冠就不灵了」——这种时灵时不灵最难排查。
      // focusable 留着不碍事：万一接收器某台设备上要不到焦点，它还是条退路。
      .focusable(true)
      .focusOnTouch(false)
      .digitalCrownSensitivity(CrownSensitivity.MEDIUM)
      .id('chatList')
      // 自己挂上来的这一拍就把焦点要过来 —— 和外部定时器相比，这是唯一
      // 「一定已经挂载」的时刻。官方 FAQ 也点名了这种情况：可滑动组件位于
      // if/else 条件渲染里时，条件切换后父容器不会自动把焦点交给重建出来的子组件。
      .onAppear(() => {
        setTimeout(() => {
          try {
            this.getUIContext().getFocusController().requestFocus('chatList');
          } catch (err) {
            hilog.debug(DOMAIN, TAG, '聊天列表尚未进入焦点树');
          }
        }, 30);
      })
      .onScroll(() => {
        Haptics.tick();
      })
      // 手滚到哪儿就以哪儿为准：停在底部=继续跟随，翻上去=别再打扰
      .onScrollStop(() => {
        this.followBottom = this.isAtBottom();
      })
      .position({ x: 0, y: 0 })

      this.glassBar()

      // 列表空着的时候必须自己说明原因。原来这里什么都不画，加上失败只弹 3 秒 toast，
      // 结果就是「进了聊天页但看不到任何聊天记录」。
      if (this.visibleMessages().length === 0) {
        Text(this.emptyChatHint())
          .fontSize(this.geo.fsSub)
          .fontColor(this.chatError.length > 0 ? Palette.red : Palette.t2)
          .textAlign(TextAlign.Center)
          .maxLines(3)
          .width(this.geo.col)
          .position({ x: this.geo.colX, y: this.geo.h / 2 - this.geo.f(0.16) })
          .onClick(() => {
            Haptics.tap();
            this.refreshChat();
          })
      }

      // 圆屏下沿唯一方便点按的区域：圆心正下方的胶囊。
      // 旧版这里是 93px 的圆钮，圆钮的视觉面积只有外接矩形的一半左右，点空率高；
      // 换成 300×88px 的全宽胶囊之后按下去是「一整条」，左右都留有余量。
      Text('回复')
        .fontSize(this.geo.fsBtn)
        .fontWeight(FontWeight.Medium)
        .fontColor(Palette.t1)
        .textAlign(TextAlign.Center)
        .width(this.geo.replyW)
        .height(this.geo.ctrlH)
        // 发送中用变暗表示，而不是换一个字符：'…' / '✎' 这类符号在本机字体里没有字形，
        // 换字符等于让图标时有时无
        .backgroundColor(Palette.blue)
        .opacity(this.busy ? 0.6 : 1)
        .borderRadius(this.geo.ctrlH / 2)
        .position({ x: this.geo.cx(this.geo.replyW), y: this.geo.replyTop })
        .onClick(() => {
          Haptics.tap();
          this.openComposer();
        })
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 聊天页 / 面板页共用的顶栏：左圆钮 + 居中标题 + 右圆钮。
   *
   * 宽度取屏宽减去两侧各 56px（演示页 `.back{left:56px}` / `.sync{right:56px}`），
   * 这样两个钮正好落在圆屏上沿那段弧线以内、标题在圆心线上真居中。
   * action 传空串表示没有右侧动作，此时右侧留同宽占位，标题才不会偏。
   */
  @Builder
  chatHeader(title: string, action: string) {
    Row() {
      Stack() {
        this.iconBack(this.geo.iconGlyph)
      }
      .width(this.geo.iconBtn)
      .height(this.geo.iconBtn)
      .backgroundColor(Palette.card)
      .borderRadius(this.geo.iconBtn / 2)
      .onClick(() => {
        Haptics.tap();
        // 面板打开着的时候返回是「退回上一形态」，否则是「回到会话列表」
        if (this.sheetOpen) {
          this.composerBack();
        } else {
          this.backToList();
        }
      })

      Text(title)
        .fontSize(this.geo.fsList)
        .fontWeight(FontWeight.Medium)
        .fontColor(Palette.t1)
        .layoutWeight(1)
        .textAlign(TextAlign.Center)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ left: this.geo.f(0.02), right: this.geo.f(0.02) })

      if (action.length > 0) {
        Stack() {
          if (action === 'kbd') {
            this.iconKeyboard(this.geo.iconGlyph)
          } else {
            SymbolGlyph($r('sys.symbol.arrow_clockwise'))
              .fontSize(this.geo.iconGlyph)
              .fontColor([Palette.t1])
          }
        }
        .width(this.geo.iconBtn)
        .height(this.geo.iconBtn)
        .backgroundColor(Palette.card)
        .borderRadius(this.geo.iconBtn / 2)
        .onClick(() => {
          Haptics.tap();
          if (action === 'sync') {
            this.syncStickersNow();
          } else if (action === 'refresh') {
            // 聊天页的刷新 = 重读当前会话；表情页的刷新 = 重扫电脑端表情库
            this.refreshChat();
          } else {
            this.openMode(MODE_TEXT);
          }
        })
      } else {
        // 占位：右侧没有按钮时也留出同样宽度，标题才是真正居中的
        Stack() {
        }
        .width(this.geo.iconBtn)
        .height(this.geo.iconBtn)
      }
    }
    .width(this.geo.w - this.geo.hdrBtnX * 2)
    .height(this.geo.iconBtn)
    .position({ x: this.geo.hdrBtnX, y: this.geo.hdrBtnY })
    // 同 headerIcon：滚动区铺满整屏，这一行不加就把下层按钮全挡住
    .zIndex(2)
  }

  /** 手动同步表情库：踢一脚电脑端重扫，再把整批缩略图重新拿一遍 */
  private syncStickersNow(): void {
    this.fireAndForget(this.client.syncStickers(), '同步表情库');
    this.fireAndForget(this.ensureStickerThumbs(), '载入表情缩略图');
    this.showToast('正在同步表情…', '');
  }

  // ------------------------------------------------------------ 回复面板（整屏）

  /**
   * 回复面板。
   *
   * 旧版是一张居中卡片，把「输入框 + 表情网格 + 取消」全挤在里面 —— 圆屏上卡片
   * 一高，四角就被圆的弧线切掉，键盘弹起时更只能收掉一半内容。改成整屏之后每个
   * 形态都有完整一屏：先选「表情 / 文字 / 快捷短语」，再各自进下一屏，和演示页一致。
   */
  @Builder
  buildSheet() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 全屏不透明底：压在聊天页之上，避免后面的消息透出来干扰。
      //
      // 「下滑关闭」挂在这一层**底**上，不挂面板根容器。原来挂在根上时它会和里面的
      // 滚动容器抢同一次垂直拖拽：对照很清楚 —— 会话列表页那个 List 滑得动，面板里
      // 结构一模一样的短语 List 却滑不动，差别就是外面套了这层手势。挂到底上之后两者
      // 彻底分家：手指落在列表上，黑底不在这一次触摸的响应链里，列表照常滚；手指落在
      // 空白处（回复方式那一屏的四周）才是关面板。
      Column() {
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#000000')
      .gesture(
        PanGesture({ fingers: 1, direction: PanDirection.Vertical, distance: 24 })
          .onActionEnd((event: GestureEvent) => {
            if (event.offsetY > 70 && Math.abs(event.offsetX) < 70) {
              this.closeComposer();
            }
          })
      )

      if (this.sheetMode === MODE_MENU) {
        this.buildReplyMenu()
      } else if (this.sheetMode === MODE_STICKERS) {
        this.buildStickerPage()
      } else if (this.sheetMode === MODE_PHRASES) {
        this.buildPhrasePage()
      } else if (this.sheetMode === MODE_PHRASE_EDIT) {
        this.buildPhraseEditPage()
      } else if (this.sheetMode === MODE_PHRASE_INPUT) {
        this.buildPhraseInputPage()
      } else {
        this.buildTextPage()
      }
    }
    .width('100%')
    .height('100%')
    // 「下滑关闭」不挂在这一层：它会把里面滚动容器的垂直拖拽一起吃掉，
    // 见 buildSheet 里黑底那一层的注释。
    .onAppear(() => {
      this.ensureCrownFocus();
    })
  }

  /** 第一屏：怎么回（对应演示页第 5 屏） */
  @Builder
  buildReplyMenu() {
    this.chatHeader(`回复 ${this.current}`, '')

    Column({ space: this.geo.rowGap }) {
      this.replyOption(0, '表情', '表', this.stickerSubtitle(), Palette.brand, Palette.brandSoft)
      this.replyOption(1, '文字', '文', '全屏键盘输入', Palette.blue, Palette.blueSoft)

      Text('快捷短语')
        .fontSize(this.geo.fsList)
        .fontColor(Palette.t1)
        .textAlign(TextAlign.Center)
        .width(this.geo.replyW)
        .height(this.geo.ctrlH)
        .borderRadius(this.geo.ctrlH / 2)
        // 这一项本来就是幽灵胶囊（2px 描边），「高亮」就是把这圈描边换成主色
        .border({
          width: 2,
          color: this.menuIndex === 2 ? Palette.blue : Palette.line
        })
        .onClick(() => {
          Haptics.tap();
          this.openMode(MODE_PHRASES);
        })
    }
    .alignItems(HorizontalAlign.Center)
    .width(this.geo.col)
    // 三块内容（2 张 104px 卡 + 1 个 88px 胶囊 + 两处 10px 间距）合计 316px。
    // 起点取 120px（演示页就是 120）而不是内容带默认的 128 —— 差这 8px 时最下面那个
    // 胶囊的两端正好落在圆割线以内，再多就露切角了。
    .position({ x: this.geo.colX, y: this.geo.colTop - this.geo.f(0.0343) })
  }

  /** 回复方式的一张卡：图标底 + 主标题 + 副标题，整行都是热区 */
  @Builder
  replyOption(index: number, label: string, icon: string, sub: string, tint: string, tintBg: string) {
    Row({ space: this.geo.f(0.0687) }) {
      Stack() {
        Text(icon)
          .fontSize(this.geo.fsTitle)
          .fontWeight(FontWeight.Medium)
          .fontColor(tint)
      }
      .width(this.geo.avatar)
      .height(this.geo.avatar)
      .backgroundColor(tintBg)
      .borderRadius(this.geo.f(0.094))

      Column({ space: this.geo.f(0.0086) }) {
        Text(label)
          .fontSize(this.geo.fsBtn)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.t1)
          .width('100%')
        Text(sub)
          .fontSize(this.geo.fsSub)
          .fontColor(Palette.t2)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height(this.geo.row)
    .padding({ left: this.geo.f(0.086), right: this.geo.f(0.086) })
    .backgroundColor(Palette.card)
    .borderRadius(this.geo.f(0.1373))
    // 高亮描边读的是 this.menuIndex（不是入参 index）—— 入参是常量，只有成员变量变化
    // 才会让这一层重绘。非高亮时用卡片本色，视觉上就是「没有描边」。
    .border({
      width: 2,
      color: this.menuIndex === index ? Palette.blue : Palette.card
    })
    .onClick(() => {
      Haptics.tap();
      this.openMode(label === '表情' ? MODE_STICKERS : MODE_TEXT);
    })
  }


  private stickerSubtitle(): string {
    if (this.stickerTiles.length === 0) {
      return '还没有表情';
    }
    return this.stickerReady ? `${this.stickerTiles.length} 个 · 已同步` : '正在载入…';
  }

  /** 第二屏：表情网格（对应演示页第 6 屏） */
  @Builder
  buildStickerPage() {
    this.chatHeader('选择表情', 'sync')

    if (this.stickerTiles.length === 0) {
      Text('还没有表情：在电脑上跑一次\nscripts/scan_stickers.py')
        .fontSize(this.geo.fsSub)
        .fontColor(Palette.t2)
        .textAlign(TextAlign.Center)
        .width(this.geo.col)
        .position({ x: this.geo.colX, y: this.geo.h / 2 - this.geo.f(0.1) })
    } else if (!this.stickerReady) {
      // 批量字节没到手之前不挂网格：网格一挂就会逐格去要图，那正是要避开的
      // 「一张一次往返」。宁可先显示一行字，也不让网格在没有字节的情况下开张。
      Text('正在载入表情…')
        .fontSize(this.geo.fsSub)
        .fontColor(Palette.t2)
        .textAlign(TextAlign.Center)
        .width(this.geo.col)
        .position({ x: this.geo.colX, y: this.geo.h / 2 - this.geo.f(0.06) })
    } else {
      Scroll() {
        // 这里**不能**用 `Flex({ wrap: Wrap })`：wrap 的 Flex 在 Scroll 里撑不开高度，
        // 换行出来的第二行往后既排不进可滚动高度、也滚不出来 —— 表现就是「表情看着
        // 有一大片，用手指怎么拨都不动」。自己按每行 STICKERS_PER_ROW 个切成 Row 之后，
        // 高度是 Column 逐行累加出来的真高度，和聊天页 / 设置页那几个能滚的 Scroll
        // 是同一种结构。最后一行不满时由 Row 的 justifyContent 居中，观感与原来一致。
        Column() {
          ForEach(this.stickerRows(), (row: StickerTile[], rowIndex: number) => {
            Row() {
              ForEach(row, (tile: StickerTile) => {
                StickerCell({
                  tile: tile,
                  r: this.geo.r,
                  onPick: (value: string, label: string) => {
                    this.sendSticker(value, label);
                  }
                })
              },
                // key 里带上重挂载代次：每重新拉一次整批缩略图就整体重建，
                // 让那些在断线期间被记成「取不到」的格子有机会重来一遍
                (tile: StickerTile) => `${this.stickerEpoch}-${tile.key}`)
            }
            .justifyContent(FlexAlign.Center)
          }, (row: StickerTile[], rowIndex: number) => `${this.stickerEpoch}-row${rowIndex}`)
        }
        .width('100%')
        // 安全区做成内容自己的内边距，容器则铺满整屏 ——
        // 这样网格滑到上下两端时是「从圆弧下钻出去」，而不是被容器的矩形边切一刀
        .padding({
          left: this.geo.colX,
          right: this.geo.colX,
          top: this.geo.scrollPadTop,
          bottom: this.geo.scrollPadBottom
        })
      }
      .width(this.geo.w)
      .height(this.geo.h)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .focusable(true)
      .focusOnTouch(true)
      .digitalCrownSensitivity(CrownSensitivity.MEDIUM)
      .id('stickerGrid')
      .onScroll(() => {
        Haptics.tick();
      })
      .position({ x: 0, y: 0 })

      this.glassBar()
    }
  }

  /**
   * 第三屏：快捷短语（点一下就发出去，对应演示页第 7 屏）。
   *
   * 列表来源是**手表本地的 phrases**，不是电脑端 config.json 里的 presets ——
   * 那一份是自动发送任务的表情名，只读；用户要的是能自己加/改/删的常用回复。
   * 首次连上时用 presets 播一次种，详见 phrases 字段。
   *
   * 「编辑」放在列表末尾单独一行，而不是塞进顶栏：顶栏右侧那个圆钮已经是
   * 「用键盘输入」了，64px 的圆里挤两个动作必然误触。
   */
  @Builder
  buildPhrasePage() {
    this.chatHeader('快捷短语', 'kbd')

    if (this.phrases.length === 0) {
      Column({ space: this.geo.f(0.05) }) {
        Text('还没有快捷短语')
          .fontSize(this.geo.fsSub)
          .fontColor(Palette.t2)
          .textAlign(TextAlign.Center)
          .maxLines(2)
          .width('100%')
        Text('添加短语')
          .fontSize(this.geo.fsList)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.t1)
          .textAlign(TextAlign.Center)
          .width(this.geo.replyW)
          .height(this.geo.btnH)
          .backgroundColor(Palette.blue)
          .borderRadius(this.geo.btnH / 2)
          .onClick(() => {
            Haptics.tap();
            this.beginPhraseEdit(-1);
          })
      }
      .width(this.geo.col)
      .alignItems(HorizontalAlign.Center)
      .position({ x: this.geo.colX, y: this.geo.h / 2 - this.geo.f(0.3) })
    } else {
      List({ space: this.geo.rowGap }) {
        ForEach(this.phrases, (phrase: string, index: number) => {
          ListItem() {
            Text(phrase)
              .fontSize(this.geo.fsList)
              .fontColor(Palette.t1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .height(this.geo.ctrlH)
              .textAlign(TextAlign.Center)
              .backgroundColor(Palette.card)
              .borderRadius(this.geo.f(0.1202))
              .onClick(() => {
                Haptics.tap();
                this.sendPhrase(phrase);
              })
          }
          .margin({
            left: this.geo.colX,
            right: this.geo.colX,
            top: index === 0 ? this.geo.scrollPadTop : 0
          })
        }, (phrase: string, index: number) => `${index}-${phrase}`)

        // 管理入口。样式刻意比上面那些短语行「轻」——底色是卡片、文字是次级色、
        // 左对齐带 ›，一眼能分出「这是设置项不是短语」，免得当成一条回复点出去。
        ListItem() {
          Row() {
            Text('编辑短语')
              .fontSize(this.geo.fsList)
              .fontColor(Palette.t2)
              .layoutWeight(1)

            this.iconChevron(this.geo.iconGlyph)
          }
          .width('100%')
          .height(this.geo.ctrlH)
          .padding({
            left: this.geo.padIn,
            right: this.geo.padIn
          })
          .backgroundColor(Palette.card)
          .borderRadius(this.geo.f(0.1202))
          .onClick(() => {
            Haptics.tap();
            this.openMode(MODE_PHRASE_EDIT);
          })
        }
        .margin({
          left: this.geo.colX,
          right: this.geo.colX,
          bottom: this.geo.scrollPadBottom
        })
      }
      .width(this.geo.w)
      .height(this.geo.h)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .focusable(true)
      .focusOnTouch(true)
      .digitalCrownSensitivity(CrownSensitivity.MEDIUM)
      .id('phraseList')
      .onScrollIndex(() => {
        Haptics.tick();
      })
      .position({ x: 0, y: 0 })

      this.glassBar()
    }
  }

  /**
   * 短语管理页：增、改、删。
   *
   * 每一行左边是正文（点一下进输入页改它），右边一个 × 删；「添加短语」钉在最前面，
   * 而不是跟在末尾 —— 短语一多，末尾就要滑到最后才够得着，而它恰恰是这一页
   * 用得最频繁的那一下。
   *
   * 这一页所有内容**左对齐**，而且左右内边距取同一个值（rowPadX + 0.0172r）——
   * 和设置页那几行是一个口径。第一版把「添加短语」居中、正文也居中，
   * 结果一行里三个元素各对各的轴：正文漂在中间、加号悬在左侧、× 又贴着右边，
   * 看上去就是「图标位置全都不对」。
   */
  @Builder
  buildPhraseEditPage() {
    this.chatHeader('编辑短语', '')

    List({ space: this.geo.rowGap }) {
      ListItem() {
        Row({ space: this.geo.f(0.03) }) {
          this.iconPlus(this.geo.fsList)
          Text('添加短语')
            .fontSize(this.geo.fsList)
            .fontWeight(FontWeight.Medium)
            .fontColor(Palette.t1)
        }
        .width('100%')
        .height(this.geo.ctrlH)
        // Row 默认就是 Start + 垂直居中，这里只补左右内边距
        .padding({
          left: this.geo.padIn,
          right: this.geo.f(0.02)
        })
        .backgroundColor(Palette.blueSoft)
        .borderRadius(this.geo.f(0.1202))
        .onClick(() => {
          Haptics.tap();
          this.beginPhraseEdit(-1);
        })
      }
      .margin({
        left: this.geo.colX,
        right: this.geo.colX,
        top: this.geo.scrollPadTop
      })

      ForEach(this.phrases, (phrase: string, index: number) => {
        ListItem() {
          this.phraseEditRow(phrase, index)
        }
        .margin({
          left: this.geo.colX,
          right: this.geo.colX,
          bottom: index === this.phrases.length - 1 ? this.geo.scrollPadBottom : 0
        })
      }, (phrase: string, index: number) => `${index}-${phrase}`)
    }
    .width(this.geo.w)
    .height(this.geo.h)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .focusable(true)
    .focusOnTouch(true)
    .digitalCrownSensitivity(CrownSensitivity.MEDIUM)
    .id('phraseEditList')
    .onScrollIndex(() => {
      Haptics.tick();
    })
    .position({ x: 0, y: 0 })

    this.glassBar()
  }

  /**
   * 管理页里的一行：正文区（点击改）+ 删除钮（两下才真删）。
   *
   * 正文左对齐，且左边距和 × 的右边距都取 padIn —— 和设置页同一个口径，
   * 这样「正文左沿」和「图标右沿」在整页上是两条笔直的竖线。
   */
  @Builder
  phraseEditRow(phrase: string, index: number) {
    Row() {
      Row() {
        Text(phrase)
          .fontSize(this.geo.fsList)
          .fontColor(this.phrasePendingDelete === index ? Palette.red : Palette.t1)
          .textAlign(TextAlign.Start)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .height('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: this.geo.padIn, right: this.geo.f(0.02) })
      .onClick(() => {
        Haptics.tap();
        this.beginPhraseEdit(index);
      })

      // 删除钮做成实心圆：手指落点明确，也把「这一下是另一件事」和点正文区分开。
      // 待确认时整颗变红、里面换成「删」字 —— 这时右边那句提示已经说明白了。
      Stack() {
        if (this.phrasePendingDelete === index) {
          Text('删')
            .fontSize(this.geo.fsSub)
            .fontWeight(FontWeight.Medium)
            .fontColor(Palette.t1)
        } else {
          this.iconClose(this.geo.iconGlyph)
        }
      }
      .width(this.geo.iconBtn)
      .height(this.geo.iconBtn)
      .backgroundColor(this.phrasePendingDelete === index ? Palette.red : Palette.card2)
      .borderRadius(this.geo.iconBtn / 2)
      .margin({ right: this.geo.padIn })
      .onClick(() => {
        this.togglePhraseDelete(index);
      })
    }
    .width('100%')
    .height(this.geo.ctrlH)
    .backgroundColor(Palette.card)
    .borderRadius(this.geo.f(0.1202))
  }

  /**
   * 短语输入页（加一条或改一条）。
   *
   * 和设置页的字段编辑页同一套路数：整屏 + 输入框固定在圆心略上方。
   * 理由是手表的软键盘全屏，就地编辑的话那一行必然被顶到看不见的地方。
   */
  @Builder
  buildPhraseInputPage() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (!this.phraseFocused) {
        Stack() {
          this.iconBack(this.geo.iconGlyph)
        }
        .width(this.geo.iconBtn)
        .height(this.geo.iconBtn)
        .backgroundColor(Palette.card)
        .borderRadius(this.geo.iconBtn / 2)
        .position({ x: this.geo.hdrBtnX, y: this.geo.hdrBtnY })
        .onClick(() => {
          Haptics.tap();
          this.cancelPhraseEdit();
        })

        Text(this.phraseEditIndex >= 0 ? '编辑短语' : '添加短语')
          .fontSize(this.geo.fsTitle)
          .fontWeight(FontWeight.Bold)
          .fontColor(Palette.t1)
          .width(this.geo.col)
          .textAlign(TextAlign.Center)
          .position({ x: this.geo.colX, y: this.geo.titleTop })
      }

      Column({ space: this.geo.f(0.04) }) {
        TextInput({
          text: this.phraseDraft,
          placeholder: '输入短语内容',
          controller: this.phraseCtl
        })
          .type(InputType.Normal)
          .fontSize(this.geo.fsBody)
          // 占位文字的字号必须单独设，否则它按系统默认大小渲染、在这个宽度里被截半句
          .placeholderFont({ size: this.geo.fsBody })
          .fontColor(Palette.t1)
          .placeholderColor(Palette.t3)
          .caretColor(Palette.blue)
          .backgroundColor(Palette.card2)
          .borderRadius(this.geo.ctrlH / 2)
          .height(this.geo.ctrlH)
          .width('100%')
          .id('phraseInput')
          .onFocus(() => {
            this.phraseFocused = true;
          })
          .onBlur(() => {
            this.phraseFocused = false;
          })
          .onChange((value: string) => {
            this.phraseDraft = value;
          })
          // 键盘上的「完成」等同于点下面那个按钮，省得把手从键盘挪开去够屏幕
          .onSubmit(() => {
            this.commitPhraseEdit();
          })

        Text('完成')
          .fontSize(this.geo.fsList)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.t1)
          .textAlign(TextAlign.Center)
          .width('100%')
          .height(this.geo.btnH)
          .backgroundColor(Palette.blue)
          .borderRadius(this.geo.btnH / 2)
          .onClick(() => {
            Haptics.tap();
            this.commitPhraseEdit();
          })
      }
      .width(this.geo.col)
      // 摆在圆心略上方：键盘占掉下半屏之后，这一列正好落在剩下的那块弧里
      .position({ x: this.geo.colX, y: this.geo.h / 2 - this.geo.f(0.28) })
    }
    .width('100%')
    .height('100%')
    .onAppear(() => {
      // 进这一页就是为了打字，直接把焦点交给输入框，省掉「再点一下」
      setTimeout(() => {
        try {
          this.getUIContext().getFocusController().requestFocus('phraseInput');
        } catch (err) {
          hilog.debug(DOMAIN, TAG, '短语输入框还没挂上，先不抢焦点');
        }
      }, 80);
    })
  }

  /** 第四屏：键盘输入（演示页里对应「文字」那一支） */
  @Builder
  buildTextPage() {
    // 键盘弹起时圆屏只剩上半屏，标题必须收掉，否则输入框会被顶出屏幕
    if (!this.inputFocused) {
      this.chatHeader(`回复 ${this.current}`, '')
    }

    Column({ space: this.geo.f(0.04) }) {
      Row({ space: this.geo.f(0.035) }) {
        TextInput({ text: this.draft, placeholder: '输入消息', controller: this.inputCtl })
          .type(InputType.Normal)
          .fontSize(this.geo.fsBody)
          // 占位文字的字号得单独设：只写 fontSize 的话它按系统默认大小渲染，
          // 在这个宽度的输入框里会被截掉一半
          .placeholderFont({ size: this.geo.fsBody })
          .fontColor(Palette.t1)
          .placeholderColor(Palette.t3)
          .caretColor(Palette.blue)
          .backgroundColor(Palette.card2)
          .borderRadius(this.geo.ctrlH / 2)
          .height(this.geo.ctrlH)
          .layoutWeight(1)
          .onFocus(() => {
            this.inputFocused = true;
          })
          .onBlur(() => {
            this.inputFocused = false;
          })
          .onChange((value: string) => {
            this.draft = value;
          })

        Text('发送')
          .fontSize(this.geo.fsBody)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.t1)
          .textAlign(TextAlign.Center)
          .width(this.geo.f(0.6))
          .height(this.geo.ctrlH)
          .backgroundColor(Palette.blue)
          .borderRadius(this.geo.ctrlH / 2)
          .onClick(() => {
            Haptics.tap();
            this.sendText();
          })
      }
      .width('100%')

      Text(this.inputFocused ? '收起键盘' : '取消')
        .fontSize(this.geo.fsBody)
        .fontColor(Palette.t1)
        .textAlign(TextAlign.Center)
        .width('100%')
        .height(this.geo.ctrlH)
        .backgroundColor(Palette.card2)
        .borderRadius(this.geo.ctrlH / 2)
        .onClick(() => {
          Haptics.tap();
          // 键盘开着时先收键盘，用户才有办法回到「回复方式」（返回键在标题栏里）
          if (this.inputFocused) {
            this.inputCtl.stopEditing();
            return;
          }
          this.closeComposer();
        })
    }
    .width(this.geo.col)
    .position({ x: this.geo.colX, y: this.geo.h / 2 - this.geo.f(0.26) })
  }

  /** 切换面板形态。菜单/短语/表情之间来回切都走这里，顺带把表冠焦点搬到新列表上 */
  private openMode(mode: string): void {
    this.sheetMode = mode;
    if (mode !== MODE_TEXT) {
      this.inputFocused = false;
    }
    if (mode === MODE_MENU) {
      // 回到「回复方式」那一屏，高亮从第一项重新开始
      this.menuIndex = 0;
      this.menuCrownAccum = 0;
    }
    if (mode === MODE_STICKERS) {
      this.fireAndForget(this.client.syncStickers(), '同步表情库');
      this.fireAndForget(this.ensureStickerThumbs(), '载入表情缩略图');
    }
    this.ensureCrownFocus();
  }

  /**
   * 面板里的返回。
   *
   * 第一屏就直接关掉；短语那两层各有各的上一层 —— 输入页退回管理页、管理页退回
   * 短语页。不能一律跳回第一屏：用户手打了半句再按返回，本来只想放弃这一次输入，
   * 结果整个面板都关了。
   */
  private composerBack(): void {
    if (this.sheetMode === MODE_MENU) {
      this.closeComposer();
      return;
    }
    if (this.sheetMode === MODE_PHRASE_INPUT) {
      this.cancelPhraseEdit();
      return;
    }
    if (this.sheetMode === MODE_PHRASE_EDIT) {
      this.phrasePendingDelete = -1;
      this.openMode(MODE_PHRASES);
      return;
    }
    this.inputFocused = false;
    this.openMode(MODE_MENU);
  }

  // ------------------------------------------------------------ 提示条

  @Builder
  buildToast() {
    if (this.toastShown) {
      Text(this.toastText)
        .fontSize(this.geo.fsSub)
        .fontColor(this.toastKind === 'error' ? Palette.red : Palette.t1)
        .textAlign(TextAlign.Center)
        .maxLines(2)
        .width(this.geo.col)
        .padding({
          left: this.geo.f(0.09),
          right: this.geo.f(0.09),
          top: this.geo.f(0.05),
          bottom: this.geo.f(0.05)
        })
        .backgroundColor(this.toastBackground())
        .borderRadius(this.geo.f(0.1))
        .position({ x: this.geo.colX, y: this.geo.h / 2 + this.geo.f(0.34) })
    }
  }

  /** 打开设置页（列表页顶栏右侧的「设」） */
  private openSettings(): void {
    this.stopRetry();
    this.stopReconnect();
    this.formEndpoint = WatchPrefs.getString(KEY_ENDPOINT, this.formEndpoint);
    this.formToken = WatchPrefs.getString(KEY_TOKEN, this.formToken);
    this.hapticsOn = WatchPrefs.getBool(KEY_HAPTICS, this.hapticsOn);
    this.needConfig = true;
    this.booting = false;
    this.ensureCrownFocus();
  }

  // ============================================================ 状态与数据

  private visibleMessages(): WatchMessage[] {
    if (this.pending.length === 0) {
      return this.messages;
    }
    return this.messages.concat(this.pending);
  }

  /**
   * 聊天页列表为空时页面上显示什么。
   *
   * 「在读」「读失败了」「这会话真的没消息」原本长得一模一样（都是一片黑），
   * 失败还只弹一个 3 秒就消失的 toast，所以看上去就是「进去了但没有聊天记录」。
   */
  private emptyChatHint(): string {
    if (this.chatError.length > 0) {
      return `${this.chatError}\n点一下重试`;
    }
    if (!this.client.connected) {
      return '正在重新连接电脑…';
    }
    if (this.chatLoading) {
      return '正在读取聊天记录…';
    }
    return '这个会话还没有消息';
  }

  /** 列表页的状态点：绿=就绪、红=断线、黄=会话没起来 */
  private statusColor(): string {
    if (this.linkLost) {
      return '#F87171';
    }
    return this.ready ? '#34D399' : '#FBBF24';
  }

  /**
   * 取出电脑地址。
   *
   * 旧版本存的是完整 URL（http://ip:8787），这里顺手迁移一次 —— 在手表上
   * 重新敲一遍 IP 是这整个应用里最难受的操作，能自动推出来就不该让用户动手。
   */
  private loadEndpoint(): string {
    const saved: string = WatchPrefs.getString(KEY_ENDPOINT, '');
    if (saved.length > 0) {
      return saved;
    }
    const legacy: string = WatchPrefs.getString(KEY_LEGACY_BASE_URL, '');
    if (legacy.length === 0) {
      return '';
    }
    const parsed: Endpoint | null = parseEndpoint(legacy);
    if (parsed === null) {
      return '';
    }
    WatchPrefs.setString(KEY_ENDPOINT, parsed.label);
    return parsed.label;
  }

  /**
   * 连接。先按加密握手；只有「握手本身走不通」时才用明文重试一次。
   *
   * 这个回退是给服务端 `--crypto auto` 准备的逃生舱：手表端的加密框架在不同
   * 系统版本上行为并不一致，真在设备上撞到问题时，用户唯一的补救办法就是重装应用。
   * 服务端默认是 gcm 模式，那种模式下明文握手会被立刻拒绝，所以这个回退不会削弱
   * 默认配置的安全性。令牌错、网络不通都不在回退范围内 —— 换明文也解决不了。
   */
  private async connectWithFallback(): Promise<void> {
    try {
      await this.client.connect(true);
    } catch (err) {
      const e = asBridgeError(err, KIND_NETWORK);
      if (!ALLOW_PLAIN_FALLBACK || e.kind === KIND_TOKEN || e.kind === KIND_NETWORK) {
        throw e;
      }
      hilog.warn(DOMAIN, TAG, '加密握手失败（%{public}s），改用明文重试', e.message);
      await this.client.connect(false);
    }
  }

  private async loadStatus(userTriggered: boolean): Promise<void> {
    if (!this.client.configured) {
      this.needConfig = true;
      this.booting = false;
      this.bootFailed = false;
      return;
    }
    if (this.statusInflight) {
      return;
    }
    this.statusInflight = true;
    // 已有好友列表时不要退回加载页，列表直接可用，后台静默刷新
    if (this.friends.length === 0) {
      this.booting = true;
      this.bootText = '正在连接电脑…';
    }
    try {
      await this.connectWithFallback();
      const status: WatchStatus = await this.client.status();
      const friends: string[] | undefined = status.friends;
      const presets: string[] | undefined = status.presets;
      const library: WatchSticker[] | undefined = status.watch_stickers;
      this.friends = friends === undefined ? [] : friends;
      this.presets = presets === undefined ? [] : presets;
      // 第一次连上（本地还没有短语）时用 presets 播一次种
      this.seedPhrases(this.presets);
      this.watchStickers = library === undefined ? [] : library;
      this.stickerTiles = this.buildTiles();
      this.fireAndForget(this.ensureStickerThumbs(), '预取表情缩略图');
      this.ready = status.ready;
      this.linkLost = false;
      if (status.ready) {
        this.booting = false;
        this.bootFailed = false;
        this.needConfig = false;
        this.ensureCrownFocus();
        // 会话预览是「锦上添花」：列表已经用 friends 出来了，这一笔读不回来就只是
        // 行里少一行小字，绝不该拖慢或挡住列表
        this.fireAndForget(this.loadSummaries(userTriggered), '读取会话预览');
        if (userTriggered) {
          this.showToast('已刷新', 'ok');
        }
      } else {
        // 服务端明确报了错（抖音会话起不来、浏览器窗口被关掉之类）就没必要一直转圈等下去；
        // 没带 error 才是真的「还在启动」，那种情况继续转圈 + 自动重试是对的
        const error: string | undefined = status.error;
        const text: string = error === undefined ? '抖音会话正在启动，请稍候' : error;
        this.bootText = text;
        // 会话报错时提示一次。重试是每 4 秒一轮，不去重的话手表明明已经在列表页，
        // 还会被同一个提示反复打断
        if (error === undefined || error.length === 0) {
          this.lastSessionError = '';
        } else if (error !== this.lastSessionError) {
          this.lastSessionError = error;
          this.showToast(error, 'error');
        }
        this.bootFailed = error !== undefined && error.length > 0;
        this.booting = this.friends.length === 0;
        this.retryStatusLater();
      }
    } catch (err) {
      const e = asBridgeError(err, KIND_NETWORK);
      this.ready = false;
      if (e.kind === KIND_TOKEN) {
        this.booting = false;
        this.bootFailed = false;
        this.needConfig = true;
        this.showToast(e.message, 'error');
        return;
      }
      // 网络层失败 / 地址指到了别的服务：停在错误态并给出「重新填写」的出口，
      // 但重试不停 —— 电脑上服务晚一步起来时仍能自动连上
      this.bootText = e.message;
      this.bootFailed = true;
      this.booting = true;
      this.needConfig = false;
      this.linkLost = this.friends.length > 0;
      this.retryStatusLater();
    } finally {
      this.statusInflight = false;
    }
  }

  private retryStatusLater(): void {
    this.stopRetry();
    this.retryTimerId = setTimeout(() => {
      this.retryTimerId = -1;
      this.loadStatus(false);
    }, RETRY_MS);
  }

  // ------------------------------------------------------------ 会话预览

  /**
   * 读一次电脑端左侧会话列表，给列表行补上「最后一条消息 + 时间」。
   *
   * 好友名单本身来自 status，所以这一笔失败完全不影响列表能不能用 —— 拿不到就
   * 整行只显示名字。两分钟以内不重复读：这一笔要和推送轮询抢浏览器，没必要每次
   * status 重试都去敲一次。
   */
  private async loadSummaries(force: boolean): Promise<void> {
    if (this.hidden || !this.client.connected) {
      return;
    }
    if (!force && this.summaries.length > 0 && Date.now() - this.summariesAt < SUMMARY_MIN_INTERVAL_MS) {
      return;
    }
    try {
      const data: WatchConversations = await this.client.conversations(this.friends.length + 6);
      const items: WatchConversation[] = data.items === undefined ? [] : data.items;
      this.summaries = Index.parseConversations(items, this.friends);
      this.summariesAt = Date.now();
    } catch (err) {
      const e = asBridgeError(err, KIND_NETWORK);
      hilog.debug(DOMAIN, TAG, '读会话预览失败（不影响列表）：%{public}s', e.message);
    }
  }

  /**
   * 把电脑端那堆脏数据整理成「好友名 → 一行小字」。
   *
   * 脏在哪儿：抖音的会话行是嵌套 DOM，服务端按 class 前缀取的时候会把外层和内层
   * 各取一遍，于是同一行出现三四次，而且 `name` 里带着换行和未读数
   * （`"小陈\n58\n17:42"`）、`preview` 里混着未读数、时间和「在线」这类状态字。
   * 所以这里做三件事：按第一行截断取真名、把未读数/时间从 token 里挑出去、
   * 同一个好友只留预览最长的那一条。
   */
  private static parseConversations(items: WatchConversation[], friends: string[]): FriendSummary[] {
    const out: FriendSummary[] = [];
    for (const item of items) {
      const raw: string = item.name === undefined ? '' : item.name;
      const rawName: string = raw.length > 0 ? raw.split('\n')[0].trim() : '';
      if (rawName.length === 0) {
        continue;
      }
      let friend: string = '';
      for (const candidate of friends) {
        if (candidate === rawName || candidate.startsWith(rawName) || rawName.startsWith(candidate)) {
          friend = candidate;
          break;
        }
      }
      if (friend.length === 0) {
        continue;
      }
      const tokens: string[] = (item.preview === undefined ? '' : item.preview).split(' ');
      let time: string = '';
      const rest: string[] = [];
      for (const token of tokens) {
        const word: string = token.trim();
        if (word.length === 0 || STATUS_WORDS.includes(word)) {
          continue;
        }
        if (time.length === 0 && TIME_TOKEN.test(word)) {
          time = word;
          continue;
        }
        // 时间前面那个纯数字就是未读数，不要它
        if (time.length === 0 && rest.length === 0 && UNREAD_TOKEN.test(word)) {
          continue;
        }
        rest.push(word);
      }
      const preview: string = rest.join(' ');
      const existing: number = Index.indexOfSummary(out, friend);
      if (existing < 0) {
        out.push({ name: friend, preview: preview, time: time });
      } else if (out[existing].preview.length < preview.length) {
        out[existing] = { name: friend, preview: preview, time: time };
      }
    }
    return out;
  }

  private static indexOfSummary(list: FriendSummary[], name: string): number {
    for (let i = 0; i < list.length; i++) {
      if (list[i].name === name) {
        return i;
      }
    }
    return -1;
  }

  private previewOf(name: string): string {
    for (const item of this.summaries) {
      if (item.name === name) {
        return item.preview;
      }
    }
    return '';
  }

  private timeOf(name: string): string {
    for (const item of this.summaries) {
      if (item.name === name) {
        return item.time;
      }
    }
    return '';
  }

  private stopRetry(): void {
    if (this.retryTimerId >= 0) {
      clearTimeout(this.retryTimerId);
      this.retryTimerId = -1;
    }
  }

  // ------------------------------------------------------------ 连接恢复

  private onLinkState(connected: boolean, detail: string): void {
    if (connected) {
      this.linkLost = false;
      this.reconnectAttempt = 0;
      this.linkNotified = false;
      return;
    }
    if (this.needConfig) {
      return;
    }
    this.linkLost = true;
    // 这里不弹提示。链路掉一下再自己接上（熄屏、Wi-Fi 重连）是常态，
    // 每次都弹一下会让手表一直在震动的其实都是无害的事。真的接不回来
    // 的时候由 reconnect() 报 —— 那时用户才需要知道。
    this.scheduleReconnect();
  }

  private scheduleReconnect(): void {
    if (this.reconnectTimerId >= 0) {
      return;
    }
    const index: number = Math.min(this.reconnectAttempt, RECONNECT_STEPS_MS.length - 1);
    const delay: number = RECONNECT_STEPS_MS[index];
    this.reconnectAttempt++;
    this.reconnectTimerId = setTimeout(() => {
      this.reconnectTimerId = -1;
      this.reconnect();
    }, delay);
  }

  private stopReconnect(): void {
    if (this.reconnectTimerId >= 0) {
      clearTimeout(this.reconnectTimerId);
      this.reconnectTimerId = -1;
    }
  }

  private async reconnect(): Promise<void> {
    if (!this.client.configured) {
      return;
    }
    if (this.client.connected) {
      this.reconnectAttempt = 0;
      this.afterReconnect();
      return;
    }
    try {
      await this.connectWithFallback();
      this.afterReconnect();
    } catch (err) {
      const e = asBridgeError(err, KIND_NETWORK);
      if (e.kind === KIND_TOKEN) {
        this.needConfig = true;
        this.booting = false;
        this.showToast(e.message, 'error');
        return;
      }
      // 电脑端服务晚一步起来是常态，头几次安静地接着试；两轮都接不回来才提醒
      // 一句 —— 那时候用户大概率需要去电脑上看看服务还在不在
      if (this.reconnectAttempt >= 2 && !this.linkNotified) {
        this.linkNotified = true;
        this.showToast('连不上电脑，正在重试…', 'error');
      }
      this.scheduleReconnect();
    }
  }

  /**
   * 重连成功之后把状态接回来。
   *
   * 订阅是挂在连接上的（服务端每条连接记一份），断线重连后那边并不知道手表还在看
   * 哪个会话，所以必须重新订阅一次；否则界面看着正常，实际上再也不会有推送进来。
   */
  private afterReconnect(): void {
    this.linkLost = false;
    if (this.current.length > 0) {
      this.syncChat(false);
    } else {
      this.loadStatus(false);
    }
  }

  // ------------------------------------------------------------ 会话数据

  /**
   * 把当前会话「连上 + 读一次 + 订阅」这一整条做完。
   *
   * 三个动作必须按顺序走：没连上读不了，读完才有 rev 可以当订阅基准
   * （基准不对服务端会紧跟着推一份一模一样的内容过来）。
   */
  private async syncChat(showErrors: boolean): Promise<void> {
    const name: string = this.current;
    if (name.length === 0 || !this.client.configured) {
      return;
    }
    try {
      await this.connectWithFallback();
    } catch (err) {
      const e = asBridgeError(err, KIND_NETWORK);
      if (e.kind === KIND_TOKEN) {
        this.needConfig = true;
        this.booting = false;
        this.showToast(e.message, 'error');
        return;
      }
      this.linkLost = true;
      this.scheduleReconnect();
      if (showErrors) {
        this.showToast(e.message, 'error');
      }
      return;
    }

    await this.loadMessages(showErrors);
    if (this.current !== name || !this.client.connected) {
      return;
    }
    try {
      await this.client.watch(name, READ_LIMIT, !this.hidden, this.rev);
    } catch (err) {
      // 订阅失败不影响已经显示出来的聊天内容：下一次同步还会再来一遍
      const e = asBridgeError(err, KIND_NETWORK);
      hilog.debug(DOMAIN, TAG, '订阅失败: %{public}s', e.message);
    }
    // 消息回填会重建列表项，焦点多半在那一刻被带着丢掉了 —— 数据真正落定之后再要一次。
    // 少了这一步，进聊天页的表现就是「内容有了，但表冠转不动任何东西」。
    if (this.current === name) {
      this.ensureCrownFocus();
    }
  }

  private async loadMessages(showErrors: boolean): Promise<void> {
    const name: string = this.current;
    if (name.length === 0 || this.inflight) {
      return;
    }
    this.inflight = true;
    // 列表已经有内容时不显示「读取中」 —— 每次同步都闪一下很难看
    if (this.messages.length === 0 && this.pending.length === 0) {
      this.chatLoading = true;
    }
    try {
      const data: WatchMessages = await this.client.messages(name, READ_LIMIT, this.rev);
      if (this.current !== name) {
        return;
      }
      this.chatError = '';
      // 内容没变：连列表都不重建，已解码的表情图原样保留
      if (data.unchanged !== true) {
        this.rev = data.rev;
        this.messages = data.messages;
        this.prefetchMedia();
        this.followLatest(false);
      }
    } catch (err) {
      if (this.current === name) {
        const e = asBridgeError(err, KIND_NETWORK);
        // 空列表时把原因留在页面上。原来只弹 toast，3 秒后消失，
        // 用户看到的就是「进了聊天页但没有任何聊天记录」。
        if (this.messages.length === 0 && this.pending.length === 0) {
          this.chatError = e.message;
        }
        if (showErrors) {
          this.showToast(e.message, 'error');
        }
        if (!this.client.connected) {
          this.scheduleReconnect();
        }
      }
    } finally {
      this.inflight = false;
      this.chatLoading = false;
    }
  }

  /** 电脑端推来的更新：op=status 是状态推送（表情库在电脑上重扫过），其余是新消息 */
  private applyPush(data: WatchPush): void {
    if (data.op === 'status') {
      this.applyStatusPush(data);
      return;
    }
    const friend: string = data.friend !== undefined ? data.friend : '';
    if (friend.length > 0 && friend !== this.current) {
      return;
    }
    // 发送过程中不接推送：发送的应答会带回一份完整列表，这里再用推送刷一次
    // 会让自己刚发的那条短暂出现两遍
    if (this.busy) {
      return;
    }
    const list: WatchMessage[] | undefined = data.messages;
    if (list === undefined || list.length === 0) {
      return;
    }
    const rev: string = data.rev !== undefined ? data.rev : '';
    if (rev.length > 0) {
      this.rev = rev;
    }
    this.chatError = '';
    this.messages = list;
    this.prefetchMedia();
    this.followLatest(false);
    // 对方发来新消息时轻震一下：手表多半在手腕上没被盯着看，
    // 这一下比屏幕上多出一行气泡更有用
    Haptics.tap();
  }

  /**
   * 电脑端推来的状态更新：表情库重扫过（watch_stickers.json 变了），
   * 在这里把新表情接进网格。内容没变就不重建 —— 免得已解码的表情图白丢。
   */
  private applyStatusPush(data: WatchPush): void {
    hilog.info(DOMAIN, TAG, '收到状态推送（表情库可能更新了）');
    const friends: string[] | undefined = data.friends;
    const presets: string[] | undefined = data.presets;
    if (friends !== undefined && friends.length > 0) {
      this.friends = friends;
    }
    if (presets !== undefined) {
      this.presets = presets;
      this.seedPhrases(presets);
    }
    const library: WatchSticker[] | undefined = data.watch_stickers;
    if (library === undefined) {
      return;
    }
    // 指纹对比：库里一条没变就没必要动网格
    const fresh: string = library.map((s: WatchSticker): string => `${s.id}:${s.has_thumb ? 1 : 0}`).join('|');
    const current: string =
      this.watchStickers.map((s: WatchSticker): string => `${s.id}:${s.has_thumb ? 1 : 0}`).join('|');
    if (fresh === current) {
      hilog.info(DOMAIN, TAG, '表情库内容没变（%{public}d 项），跳过刷新', library.length);
      return;
    }
    this.watchStickers = library;
    this.stickerTiles = this.buildTiles();
    // 库变了 → 指纹变了，下一句会重新把整批缩略图拿一遍（新的那几张就在这里进来）
    this.fireAndForget(this.ensureStickerThumbs(), '预取表情缩略图');
    hilog.info(DOMAIN, TAG, '表情库已刷新：%{public}d 项', library.length);
    this.showToast('表情已更新', 'ok');
  }

  // ============================================================ 会话操作

  private openChat(name: string): void {
    this.closeComposer();
    this.current = name;
    // 每次进会话都从最新一条看起（上一个会话里翻到哪儿，与这个会话无关）
    this.followBottom = true;
    this.rev = '';
    this.messages = [];
    this.pending = [];
    this.chatError = '';
    this.chatLoading = true;
    this.syncChat(true);
    this.ensureCrownFocus();
  }

  private backToList(): void {
    const wasChat: boolean = this.current.length > 0;
    this.closeComposer();
    this.current = '';
    this.messages = [];
    this.pending = [];
    this.rev = '';
    this.chatError = '';
    this.chatLoading = false;
    if (wasChat) {
      // 服务端会因此停掉推送线程 —— 不看的时候不该继续读浏览器
      this.fireAndForget(this.client.unwatch(), '取消订阅');
    }
    this.ensureCrownFocus();
  }

  /**
   * 返回上一层：页面内的右滑、手表物理返回键、系统返回手势都汇到这里。
   *
   * 这个应用只有一个页面（没有 router 路由栈），系统返回默认是把 Ability 退掉 ——
   * 用户在聊天页滑一下想回会话列表，结果整个应用没了。所以层级只能自己做。
   * 返回 true 表示「我处理了」，系统不用再往下走；false 放行（会话列表页是最外层，
   * 那一层的「返回」本来就该是回表盘）。
   */
  private handleBack(): boolean {
    if (this.sheetOpen) {
      this.composerBack();
      return true;
    }
    if (this.needConfig) {
      // 字段编辑页先退回设置页，和面板里的层级是同一回事：
      // 别让「放弃这一次输入」变成「一步跳回会话列表」
      if (this.editField !== FIELD_NONE) {
        this.cancelEdit();
      } else {
        this.closeSettings();
      }
      return true;
    }
    if (this.current.length > 0) {
      this.backToList();
      return true;
    }
    return false;
  }

  onBackPress(): boolean {
    return this.handleBack();
  }

  /**
   * 智慧手势的「捏合确认」：拇指食指互点两下。
   *
   * 系统识别到这个手势后，会往当前获焦的组件下发一个 KEYCODE_ENTER 的按键事件
   * （见根容器上的 onKeyEvent），所以这一下等价于「当前页面最想要的那个动作」：
   *   聊天页 → 开始回复（不必去够屏底那条胶囊，单手最需要的就是它）
   *   回复面板 → 退回上一层
   *   会话列表 → 重新拉一次
   * 带键盘的两种页面不抢：那里的 ENTER 是输入法的事。
   */
  private handlePinch(): void {
    if (this.needConfig) {
      return;
    }
    if (this.sheetOpen) {
      if (this.sheetMode === MODE_MENU) {
        // 回复方式那一屏：捏合 = 进入当前高亮的那一项。
        // 这一屏捏合**不是**「退回」—— 它是三选一，退由右滑 / 返回键负责。
        // 没有这一段的话，捏合会一路走到 composerBack() 把整个面板关掉，
        // 表现就是「用智慧手势选不了表情 / 文字 / 快捷短语」。
        if (this.menuIndex === 0) {
          this.openMode(MODE_STICKERS);
        } else if (this.menuIndex === 1) {
          this.openMode(MODE_TEXT);
        } else {
          this.openMode(MODE_PHRASES);
        }
        return;
      }
      if (this.sheetMode === MODE_TEXT) {
        return;
      }
      this.composerBack();
      return;
    }
    if (this.current.length > 0) {
      this.openComposer();
      return;
    }
    this.loadStatus(true);
  }

  private refreshChat(): void {
    if (this.current.length === 0) {
      return;
    }
    // 清掉 rev 强制服务端重发一份，用户点刷新就是要看到「确实重新读了」
    this.rev = '';
    this.syncChat(true);
  }

  private openComposer(): void {
    if (this.current.length === 0) {
      return;
    }
    if (this.busy) {
      Haptics.warn();
      this.showToast('正在发送上一条，请稍候', '');
      return;
    }
    this.inputFocused = false;
    // 每次打开都从「怎么回」这一屏开始，不要停在上一轮的形态上
    this.sheetMode = MODE_MENU;
    this.sheetOpen = true;
    // 打开面板这一下顺手做两件事：请电脑端立刻重扫一次表情面板（手机上刚收藏的
    // 表情要马上出现，不能等那个「只在用户不看聊天页时才跑」的自动刷新），
    // 以及把整批缩略图一次拿到手。
    this.fireAndForget(this.client.syncStickers(), '同步表情库');
    this.fireAndForget(this.ensureStickerThumbs(), '载入表情缩略图');
    this.ensureCrownFocus();
  }

  private closeComposer(): void {
    this.inputFocused = false;
    this.sheetOpen = false;
    this.sheetMode = MODE_MENU;
    this.ensureCrownFocus();
  }

  private sendText(): void {
    if (this.busy) {
      Haptics.warn();
      this.showToast('正在发送上一条，请稍候', '');
      return;
    }
    const text: string = this.draft.trim();
    if (text.length === 0) {
      Haptics.warn();
      this.showToast('先输入内容', '');
      return;
    }
    this.draft = '';
    this.closeComposer();
    this.deliver(text, '');
  }

  // ------------------------------------------------------------ 快捷短语

  /**
   * 从本地读短语。
   *
   * 没播过种就先不读 —— 这时 phrases 是空的，界面会显示「还没有快捷短语」，
   * 等 status 里的 presets 回来播一次种就填上了。不这么做的话，第一次装的应用
   * 会显示「一条都没有」，而其实电脑端配置里有现成的一批。
   */
  private loadPhrases(): void {
    this.phrasesSeeded = WatchPrefs.getBool(KEY_PHRASES_READY, false);
    if (!this.phrasesSeeded) {
      return;
    }
    this.phrases = splitPhrases(WatchPrefs.getString(KEY_PHRASES, ''));
  }

  /** 首次拿到服务端 presets 时播一次种，之后本地说了算 */
  private seedPhrases(presets: string[]): void {
    if (this.phrasesSeeded || presets.length === 0) {
      return;
    }
    this.phrases = presets.slice();
    this.persistPhrases();
  }

  /**
   * 落盘。
   *
   * 每次增删改都立刻写，不做「退出时统一保存」—— 短语是用户一个字一个字敲出来的，
   * 因为一次没保存而丢掉，代价远大于多写几次盘（preferences 是本地写，不贵）。
   */
  private persistPhrases(): void {
    WatchPrefs.setString(KEY_PHRASES, this.phrases.join(PHRASE_SEP));
    WatchPrefs.setBool(KEY_PHRASES_READY, true);
    this.phrasesSeeded = true;
  }

  /** 进短语输入页。index < 0 表示新增 */
  private beginPhraseEdit(index: number): void {
    this.phraseEditIndex = index;
    this.phraseDraft = index >= 0 && index < this.phrases.length ? this.phrases[index] : '';
    this.phraseFocused = false;
    this.phrasePendingDelete = -1;
    this.sheetMode = MODE_PHRASE_INPUT;
  }

  /** 放弃这次输入，退回管理页 */
  private cancelPhraseEdit(): void {
    this.phraseCtl.stopEditing();
    this.phraseFocused = false;
    this.phraseEditIndex = -1;
    this.phraseDraft = '';
    this.openMode(MODE_PHRASE_EDIT);
  }

  /** 提交：新增就追加，编辑就替换原位 */
  private commitPhraseEdit(): void {
    const value: string = this.phraseDraft.trim();
    if (value.length === 0) {
      this.showToast('短语不能为空', 'error');
      return;
    }
    const index: number = this.phraseEditIndex;
    // 重名的两条在界面上长得一模一样，用户点哪个都分不清；直接挡掉
    let clash: number = -1;
    for (let i = 0; i < this.phrases.length; i++) {
      if (this.phrases[i] === value) {
        clash = i;
        break;
      }
    }
    if (clash >= 0 && clash !== index) {
      this.showToast('这条短语已经有了', 'error');
      return;
    }
    const editing: boolean = index >= 0 && index < this.phrases.length;
    if (editing) {
      this.phrases[index] = value;
    } else {
      this.phrases.push(value);
    }
    // 换一次引用：ForEach 按数组身份判断要不要重排，原地改元素它看不见
    this.phrases = this.phrases.slice();
    this.persistPhrases();
    this.phraseCtl.stopEditing();
    this.phraseFocused = false;
    this.phraseEditIndex = -1;
    this.phraseDraft = '';
    this.openMode(MODE_PHRASE_EDIT);
    this.showToast(editing ? '已保存' : '已添加', 'ok');
  }

  /**
   * 删除走两步：第一下只是把这一行标红（右边那颗钮变成「删」），再点一下才真删。
   * 状态由 phrasePendingDelete 记着，点别的行或退出去都会自动清掉。
   */
  private togglePhraseDelete(index: number): void {
    if (this.phrasePendingDelete !== index) {
      this.phrasePendingDelete = index;
      Haptics.warn();
      return;
    }
    const gone: string = this.phrases[index];
    this.phrases.splice(index, 1);
    this.phrases = this.phrases.slice();
    this.phrasePendingDelete = -1;
    this.persistPhrases();
    this.showToast(`已删除「${gone}」`, 'ok');
  }

  /** 点快捷短语即发 */
  private sendPhrase(phrase: string): void {
    if (this.busy) {
      Haptics.warn();
      this.showToast('正在发送上一条，请稍候', '');
      return;
    }
    this.closeComposer();
    this.deliver(phrase, '');
  }

  /**
   * 点表情格发送。
   *
   * `value` 发给服务端（有图的表情是 id），`label` 只用于本地乐观回显 ——
   * 两者刻意分开，见 StickerCell.onPick。
   */
  private sendSticker(value: string, label: string): void {
    if (this.busy) {
      Haptics.warn();
      this.showToast('正在发送上一条，请稍候', '');
      return;
    }
    this.closeComposer();
    this.deliver('', value, label);
  }

  private async deliver(text: string, sticker: string, stickerLabel: string = ''): Promise<void> {
    const name: string = this.current;
    if (name.length === 0 || this.busy) {
      return;
    }
    this.busy = true;

    // 乐观回显：立刻把自己的消息贴在底部，不用等服务端往返
    const shown: string = stickerLabel.length > 0 ? stickerLabel : sticker;
    const optimistic: WatchMessage = {
      key: '',
      side: 'me',
      type: text.length > 0 ? 'text' : 'sticker',
      text: text.length > 0 ? text : shown,
      time: '',
      media: null
    };
    this.pending = this.pending.concat([optimistic]);
    // 自己发的必须跟下去：发完就该看见自己那条，哪怕刚才正在翻旧记录
    this.followLatest(true);
    this.showToast('发送中…', '');

    try {
      const result: WatchSendResult = await this.client.sendMessage(name, text, sticker);
      this.pending = [];
      if (this.current !== name) {
        return;
      }
      const sent: WatchMessage[] | undefined = result.messages;
      if (sent !== undefined && sent.length > 0) {
        // 服务端已经回传最新列表，省掉一次 messages 往返
        this.rev = result.rev === undefined ? '' : result.rev;
        this.messages = sent;
        this.followLatest(true);
      } else {
        await this.loadMessages(false);
      }
      this.showToast('已发送', 'ok');
    } catch (err) {
      this.pending = [];
      const e = asBridgeError(err, KIND_NETWORK);
      this.showToast(e.message, 'error');
      if (!this.client.connected) {
        this.scheduleReconnect();
      }
    } finally {
      this.busy = false;
    }
  }

  private async saveConfig(): Promise<void> {
    const endpoint: string = this.formEndpoint.trim();
    const token: string = this.formToken.trim();
    if (!this.client.configure(endpoint, token)) {
      this.showToast('地址要形如 192.168.1.5:8787，令牌不能为空', 'error');
      return;
    }
    // 存归一化之后的地址，下次进来看到的和实际使用的一致
    const label: string = this.client.label;
    this.formEndpoint = label;
    WatchPrefs.setString(KEY_ENDPOINT, label);
    WatchPrefs.setString(KEY_TOKEN, token);

    this.stopRetry();
    this.stopReconnect();
    // 地址可能已经换了，旧连接必须断掉，否则会拿着新地址配着旧链路
    this.fireAndForget(this.client.disconnect(), '切换地址');

    this.needConfig = false;
    this.booting = true;
    // 新的一次尝试：先回到转圈态，别把上一次的错误钉在屏幕上
    this.bootFailed = false;
    this.linkLost = false;
    this.lastSessionError = '';
    this.friends = [];
    this.presets = [];
    this.phrasePendingDelete = -1;
    this.watchStickers = [];
    this.stickerTiles = [];
    this.current = '';
    this.messages = [];
    this.pending = [];
    this.rev = '';
    this.loadStatus(false);
  }

  /**
   * 从加载页退回配置页 —— 加载页上唯一的出口。
   *
   * 表单内容不动：它存的就是刚才那一次失败尝试，多数时候用户只需要改一个字符，
   * 清空重填反而更麻烦。同时掐掉自动重试，免得他正在改地址时后台还在打旧地址。
   */
  private openConfigFromBoot(): void {
    this.stopRetry();
    this.stopReconnect();
    this.needConfig = true;
    this.booting = false;
    this.bootFailed = false;
  }

  // ============================================================ 杂项

  /**
   * 不关心结果的后台请求。失败只留一行日志，界面已经有更直接的反馈了
   * （连接断了会走 onState，发送失败会弹 toast）。
   */
  private fireAndForget(task: Promise<void>, label: string): void {
    task.then(() => {
    }, (err: Object) => {
      const e = asBridgeError(err, KIND_NETWORK);
      hilog.debug(DOMAIN, TAG, '%{public}s 未成功: %{public}s', label, e.message);
    });
  }

  /**
   * 把焦点交给当前页面上的那个滚动容器 —— 表冠只会把事件发给有焦点的组件。
   *
   * 不能用 defaultFocus 顶替：它只在页面首次创建时生效，而这里的列表是数据回来
   * 之后才建出来的，早就过了那个时机，焦点会一直留在根节点上，转表冠毫无反应
   * （实测 dumpLayout 里 List 的 focused 就是 false）。
   */
  private ensureCrownFocus(): void {
    let id: string = '';
    if (this.needConfig) {
      // 字段编辑页开着的时候不能抢：那一页要的是**键盘焦点**，
      // 把焦点夺回滚动容器的话，用户一进编辑页就得再点一下输入框才能打字
      if (this.editField !== FIELD_NONE) {
        return;
      }
      id = 'settingsScroll';
    } else if (this.sheetOpen) {
      // 面板的每个形态各有自己的滚动容器，焦点必须跟着形态走
      if (this.sheetMode === MODE_STICKERS) {
        id = 'stickerGrid';
      } else if (this.sheetMode === MODE_PHRASES) {
        id = 'phraseList';
      } else if (this.sheetMode === MODE_PHRASE_EDIT) {
        id = 'phraseEditList';
      } else if (this.sheetMode === MODE_PHRASE_INPUT) {
        // 输入页要的是**键盘焦点**，把焦点夺回滚动容器的话用户一进来就得再点一下
        return;
      }
    } else if (!this.booting) {
      // 聊天页要的不是 chatList（那个 Scroll 拿不到焦点），而是根容器自己 ——
      // 表冠挂在它上面，见 onCrownScroll
      id = this.current.length > 0 ? CROWN_TARGET_ID : 'friendsList';
    }
    if (id.length === 0) {
      return;
    }
    this.requestCrownFocus(id, 0);
  }

  /**
   * 真要焦点：容器的挂载、焦点树的刷新、数据回填各占一拍，一次要不来就再敲一次门。
   *
   * 这一版的 `requestFocus` 不给返回值（返回 void），所以没法当场知道成没成 ——
   * 而实测里失败的样子恰恰是「没报错，但焦点没过去」（dumpLayout 里 focused=false）。
   * 与其猜这个时机，不如多设几次：重复把焦点设给同一个组件是幂等的，没有副作用，
   * 而漏掉一次的表现却是「表冠整页转不动」。
   */
  private requestCrownFocus(id: string, attempt: number): void {
    setTimeout(() => {
      // 先打开「焦点激活态」。穿戴设备上，旋转表冠和智慧手势都以组件获焦为前提，
      // 而这个前提本身以激活态为前提 —— 不打开的话 requestFocus 会静默失败：
      // 不抛错、onFocus 不触发、dumpLayout 里 focused 一直是 false。
      // 单独包一层 try：万一某台设备不支持，也不能连累下面的 requestFocus。
      try {
        this.getUIContext().getFocusController().activate(true, false);
      } catch (err) {
        hilog.debug(DOMAIN, TAG, '该设备不支持焦点激活态');
      }
      try {
        this.getUIContext().getFocusController().requestFocus(id);
        hilog.info(DOMAIN, TAG, '表冠焦点 -> %{public}s（第 %{public}d 次）', id, attempt + 1);
      } catch (err) {
        hilog.debug(DOMAIN, TAG, '请求 %{public}s 焦点抛异常（组件可能已销毁）', id);
        return;
      }
      if (attempt < 2) {
        this.requestCrownFocus(id, attempt + 1);
      }
    }, attempt === 0 ? 60 : 240);
  }

  /**
   * 表冠转了一下 —— 换算成滚动量，交给聊天列（挂在根容器的 onDigitalCrown 上）。
   *
   * 为什么不让 Scroll 自己响应表冠：官方文档写得很明确，表冠事件只发给**获焦**组件，
   * 连 Scroll/List 这些「默认支持表冠滚动」的组件也要先自己拿到焦点。而聊天页的 Scroll
   * 拿不到 —— `requestFocus('chatList')`、`defaultFocus`、`focusOnTouch`、给气泡加
   * `focusable` 全试过，dumpLayout 里 focused 一直是 false。会话列表页的 List 之所以
   * 能用表冠，是因为它的 ListItem 里有可获焦的子组件；聊天列的子项（消息气泡）一个都
   * 不可获焦，没有可依托的节点，那套办法在这一页不通。
   *
   * 所以改成「根容器收事件 + 自己 scrollBy」：根容器本来就是这一页获焦的那个节点
   * （见 build() 里的注释），拿到 degree 直接换算成滚动量。手指滚动完全不受影响 ——
   * Scroll 那套原生滚动照旧走触摸，两边不共用一条路。
   *
   * 只在聊天页生效：会话列表 / 设置 / 表情网格 / 短语列表各自有焦点、走系统默认那条路，
   * 这里两个 if 把它们挡在外面，免得同一次旋转被滚两遍。
   */
  private onCrownScroll(event: CrownEvent): void {
    if (this.current.length === 0) {
      return;
    }
    if (this.sheetOpen) {
      // 「回复方式」那一屏没有滚动容器，表冠在那里专职切高亮；
      // 面板的其它形态各有自己的滚动容器，表冠交给它们走系统默认那条路。
      if (this.sheetMode === MODE_MENU) {
        this.crownMoveMenu(event);
      }
      return;
    }
    // BEGIN 那一拍还没有位移，只有 UPDATE/END 带得动。
    // 这一行 INFO 是留给真机排查的：转表冠时日志里出现它 = 事件确实到了这一层，
    // 之后再没有滚动就只可能是 scrollBy 那边的问题，不用再从焦点查起。
    if (event.action === CrownAction.BEGIN) {
      hilog.info(DOMAIN, TAG, '表冠开始转动（聊天页）');
      return;
    }
    let delta: number = event.degree * CROWN_PX_PER_DEGREE;
    if (!Number.isFinite(delta) || delta === 0) {
      return;
    }
    if (delta > CROWN_STEP_MAX) {
      delta = CROWN_STEP_MAX;
    } else if (delta < -CROWN_STEP_MAX) {
      delta = -CROWN_STEP_MAX;
    }
    // 往上翻（去看更早的消息）就先退出「跟随最新」，否则下一条推送会把用户拽回底部。
    // 往下翻不用管：onScrollStop 会用 isAtEnd() 把姿态重新算一遍。
    if (delta < 0) {
      this.followBottom = false;
    }
    try {
      // degree > 0 是顺时针；顺时针往下（看更新的消息），和系统自己的表冠滚动同一个方向感。
      // scrollBy 的 dy 为正表示下滑，见官方示例 scrollBy(0, 150) 的注释。
      this.messageScroller.scrollBy(0, delta);
    } catch (err) {
      hilog.debug(DOMAIN, TAG, '聊天列尚未挂载，表冠滚动丢弃');
    }
  }

  /**
   * 表冠在「回复方式」那一屏上换高亮。
   *
   * 累加角度、转满一格才走一项：表冠每一次回调的角度是连续的小量，直接用会把一次
   * 「转半圈」判成几十次换项，用户看到的就是高亮一路窜到底。累加器只在 BEGIN 复位，
   * 所以一次连续旋转跨过好几格时也是逐项走的。
   */
  private crownMoveMenu(event: CrownEvent): void {
    if (event.action === CrownAction.BEGIN) {
      this.menuCrownAccum = 0;
      return;
    }
    const degree: number = event.degree;
    if (!Number.isFinite(degree) || degree === 0) {
      return;
    }
    this.menuCrownAccum += degree;
    while (this.menuCrownAccum >= MENU_CROWN_STEP) {
      this.menuCrownAccum -= MENU_CROWN_STEP;
      this.moveMenuIndex(1);
    }
    while (this.menuCrownAccum <= -MENU_CROWN_STEP) {
      this.menuCrownAccum += MENU_CROWN_STEP;
      this.moveMenuIndex(-1);
    }
  }

  /**
   * 换高亮项。到两端就停住（不绕回）—— 从「快捷短语」再往下跳回「表情」不好预期，
   * 而这一屏一共就三项，停住比循环更容易记住自己在哪。
   */
  private moveMenuIndex(delta: number): void {
    const next: number = this.menuIndex + delta;
    if (next < 0 || next > MENU_ITEM_COUNT - 1 || next === this.menuIndex) {
      return;
    }
    this.menuIndex = next;
    Haptics.tick();
  }

  /**
   * 把表情库和配置里的快捷表情合并成一份渲染数据。
   *
   * 顺序有讲究：表情库在前（有图，好认），配置里的快捷表情补在后面。
   * 按名字去重 —— 库里已经有「续火花」的图时，不该再冒出一个纯文字的「续火花」。
   */
  // ============================================================ 表情缩略图

  /**
   * 把整库表情缩略图一次拿到手。
   *
   * 原来这里是「低优先级逐个预热」：一屏十几格同时挂载、各自去要图，服务端取图池
   * 被占满，图就一格一格往外蹦。而手表这侧的往返实测 74ms 上下，七十张就是好几百次
   * 往返 —— 预热只是把「用户看见的等待」挪到了后台，总时长没变。
   *
   * 改成服务端一次把整库塞过来（op=sticker_thumbs），去程只有一笔，回来的是
   * 几百 KB 字节，本地解码每张 5~15ms。用户滑到面板时图已经在缓存里了。
   *
   * 三个「什么时候不必再拿」的判据，任意一个不满足就重新拿：
   *   - 库指纹没变（同一批 id、同样的有无缩略图）；
   *   - 缓存代次没变（重连会清缓存，代次一变旧字节就没了）；
   *   - 没在飞（连点「写」不该打出两笔）。
   */
  private async ensureStickerThumbs(): Promise<void> {
    const ids: string[] = [];
    for (const tile of this.stickerTiles) {
      if (tile.hasThumb && tile.id.length > 0) {
        ids.push(tile.id);
      }
    }
    if (ids.length === 0) {
      return;
    }
    const stamp: string = ids.join(',');
    const generation: number = ImageCache.instance.generation;
    if (this.thumbLoading || (stamp === this.thumbStamp && generation === this.thumbGeneration)) {
      return;
    }
    this.thumbLoading = true;
    this.stickerReady = false;
    // 重挂载整片网格 + 忘掉「这张图取不到」的记账。
    // 链路恰好断着的时候打开面板，十几格会一起被记成失败；之后链路恢复了，
    // 那些格子却因为记账和 @State 都还在，一直是光秃秃的文字 ——
    // 表现就是「表情包加载不出来，怎么刷都是空的」。开跑前先给它们一次机会。
    this.stickerEpoch++;
    ImageCache.instance.dropFailed('sticker');
    const started: number = Date.now();
    try {
      const batch: StickerThumbBatch = await this.client.fetchStickerThumbs(STICKER_PX);
      const stored: number = ImageCache.instance.prime('sticker', STICKER_PX, batch.items);
      this.thumbStamp = stamp;
      this.thumbGeneration = generation;
      hilog.info(DOMAIN, TAG, '表情缩略图整批到手：%{public}d 张，用时 %{public}dms',
        stored, Date.now() - started);
    } catch (err) {
      // 拿不到就让网格按老路走（每格自己取图）。**指纹不记** —— 记下就等于「这条路
      // 必然失败」被当成结论缓存起来，之后每次开面板都直接放弃批量、退回逐张。
      // 多花一笔失败的往返，换「下一次能自己好起来」，值得。
      const e = asBridgeError(err, KIND_NETWORK);
      hilog.warn(DOMAIN, TAG, '批量取表情缩略图失败，退回逐张：%{public}s', e.message);
    } finally {
      this.thumbLoading = false;
      this.stickerReady = true;
      // 网格是这一帧才挂上去的，表冠焦点得再要一次 —— 上面那一次要的时候它还不存在
      if (this.sheetOpen) {
        this.ensureCrownFocus();
      }
    }
  }

  /**
   * 后台预热当前会话最新的几张图。
   *
   * 从末尾往回取：列表底部才是用户正在看的地方，上面那些等翻回去时再取也来得及。
   */
  private prefetchMedia(): void {
    const keys: string[] = [];
    for (let i = this.messages.length - 1; i >= 0 && keys.length < PREFETCH_MEDIA; i--) {
      const media: string | null = this.messages[i].media;
      if (media !== null && media.length > 0) {
        keys.push(media);
      }
    }
    ImageCache.instance.prefetch('media', keys, MEDIA_PX);
  }

  private buildTiles(): StickerTile[] {
    const tiles: StickerTile[] = [];
    const seen: string[] = [];

    for (const item of this.watchStickers) {
      // 按 **id**（内容派生）去重，不是按 name：自建表情的 name 是「第几栏第几个」，
      // 电脑端插进一个新收藏时旧名字会串位，按 name 去重会把新表情整个丢掉。
      if (item.id.length === 0 || seen.includes(item.id)) {
        continue;
      }
      seen.push(item.id);
      tiles.push({
        key: item.id,
        id: item.id,
        name: item.name,
        label: item.label.length > 0 ? item.label : item.name,
        hasThumb: item.has_thumb
      });
    }

    // 快捷短语（config.json 的 presets）不再混进表情网格 —— 它们自己有一屏
    // （回复面板的第三屏）。混在一起时纯文字格和表情格长得一样，用户分不清
    // 点下去会发出什么，而且「表情」这个词在两边含义不同。
    return tiles;
  }

  /**
   * 把表情格切成「每行 STICKERS_PER_ROW 个」。
   *
   * 换掉 Flex(wrap) 的原因是它在 Scroll 里量不出真高度（详见 buildStickerPage 里的注释），
   * 自己切行之后 Column 的高度是实打实累加出来的。不满一行的那一组照样交给 Row 居中。
   */
  private stickerRows(): StickerTile[][] {
    const rows: StickerTile[][] = [];
    let row: StickerTile[] = [];
    for (const tile of this.stickerTiles) {
      row.push(tile);
      if (row.length === STICKERS_PER_ROW) {
        rows.push(row);
        row = [];
      }
    }
    if (row.length > 0) {
      rows.push(row);
    }
    return rows;
  }

  /**
   * 去看最新的一条（这一页默认的姿态）。
   *
   * 不是无脑滚：用户正往上翻历史时来了新消息，把他拽回底部最招人烦。
   * force 只给两种情况 —— 自己刚发了消息、刚进这个会话。
   */
  private followLatest(force: boolean): void {
    if (this.current.length === 0) {
      return;
    }
    // followBottom 是「内容变化之前」记下的姿态 —— 新消息插进来之后，它是唯一还
    // 有效的依据（那时再查 isAtEnd() 已经晚了：内容刚变长，它必然说「不在底部」）。
    // 补这一次实查是为了兜住「内容本来就不足一屏」：那种情况根本没有滚动，
    // onScrollStop 不会触发，followBottom 未必被刷新过。
    if (!force && !this.followBottom && !this.isAtBottom()) {
      return;
    }
    this.scrollMessagesToBottom();
  }

  /** 现在是否停在最底部。拿不准时按「在底部」处理 —— 宁可多滚一次，别停在半路 */
  private isAtBottom(): boolean {
    try {
      return this.messageScroller.isAtEnd();
    } catch (err) {
      hilog.debug(DOMAIN, TAG, '聊天列尚未挂载，无法判断是否在底部');
      return true;
    }
  }

  /**
   * 滚到最新一条。
   *
   * 补两拍再滚不是保守，是必须：数据刚到的那一刻列高还没算完，表情图又还在
   * 异步解码，一次 scrollEdge 只会停在「上一帧的底部」。滚到底是瞬时的、
   * 幂等的，多滚两次用户看不出来，少滚一次却是「进会话看到的是几十条前」。
   */
  private scrollMessagesToBottom(): void {
    const delays: number[] = [16, 64, 180];
    for (const delay of delays) {
      setTimeout(() => {
        try {
          this.messageScroller.scrollEdge(Edge.Bottom);
        } catch (err) {
          hilog.debug(DOMAIN, TAG, '聊天列尚未挂载，跳过滚动');
        }
      }, delay);
    }
  }

  private showToast(message: string, kind: string): void {
    if (message.length === 0) {
      return;
    }
    // 提示和震动绑在一起：这样「谁该震、谁不该震」只有一处判断，
    // 不会出现「弹了错但没震」或者反过来。'发送中…' 这类的 kind 是空串，不震。
    if (kind === 'error') {
      Haptics.warn();
    } else if (kind === 'ok') {
      Haptics.success();
    }
    this.toastText = message;
    this.toastKind = kind;
    this.toastShown = true;
    if (this.toastTimerId >= 0) {
      clearTimeout(this.toastTimerId);
    }
    this.toastTimerId = setTimeout(() => {
      this.toastShown = false;
      this.toastTimerId = -1;
    }, 3200);
  }

  private toastBackground(): string {
    if (this.toastKind === 'error') {
      return Palette.toastErr;
    }
    if (this.toastKind === 'ok') {
      return Palette.toastOk;
    }
    return Palette.toast;
  }
}

/**
 * 圆屏几何：所有尺寸都从表盘半径 r 推导，和 ui-demo/index.html 里那套 CSS 一一对应。
 *
 * 为什么这么做：圆形屏幕上「四角是物理不存在的区域」，所以不能沿用方形布局的
 * padding 思维。可靠的做法是几何约束 ——
 *
 *     半径 r，圆心到边缘距离 > r 的像素看不见
 *     内接正方形边长 = 2r / √2 ≈ r × 1.414
 *     竖向一律以 50% 为基准做偏移，这样即使视口不是正方形，整套布局仍围绕圆心居中
 *
 * 内容列宽取多少不是美学问题，是能不能塞进圆里的问题。判据是「行」而不是「内容带」：
 * 列宽 1.42r 时行的水平半宽 0.71r，那么行落在圆心下方 dy 处时，四角必须满足
 *
 *     √(0.71² + dy²) < 1        →   dy < 0.704r
 *
 * 也就是行不能掉到圆心下方 0.704r 之外。内容带下沿取 0.72r，略超一点点 —— 超出的是
 * 最后一行被圆切掉的角，而列表末尾本来就该「划上来才看得到」（演示页同样如此）。
 *
 * 这是「尽量撑满」与「不被切角」的平衡点。再放宽就要动行的位置或高度，动了就会
 * 在列表首尾两行上露白边或切角 —— 所以想调大请连行高一起重算，别只改 col。
 *
 * 尺寸基准：华为 WATCH 5 屏幕 466×466 px，换算成 ArkUI 的 vp 正好是 233×233
 * （ratio 2），所以 r ≈ 116.5vp。这里不写死 233，而是由页面用 onAreaChange
 * 实测根容器尺寸后调用构造器，模拟器 / 其它圆屏手表都能自适应。
 *
 * 换算口径（全项目唯一口径）：**演示页里的 px ÷ 233 = 这里的系数**。
 * （466px = 233vp = 2r，所以 px ÷ 233 就是「占几个 r」。）
 */
export class WatchGeometry {
  /** 根容器宽（vp） */
  w: number;
  /** 根容器高（vp） */
  h: number;
  /** 表盘半径 */
  r: number;

  /** 内容列宽：撑满圆屏的上限，推导见文件头 */
  col: number;
  /** 内容带上沿 */
  bandTop: number;
  /** 内容带高度 */
  bandH: number;
  /** 内容带顶部内边距，让内容从顶栏下方开始 */
  bandPadTop: number;
  /** 内容带底部内边距（聊天页给「回复」胶囊留净空） */
  bandPadBottom: number;

  // ------------------------------------------------------------ 顶栏
  //
  // 演示页有两套顶栏，位置不同，这里各留一个基元：
  //   列表页 / 设置页：居中大标题（30px），从 52px 开始
  //   聊天页 / 面板页：左返回钮 + 居中标题，从 44px 开始

  /** 聊天/面板顶栏的上沿：演示页 44px */
  hdrTop: number;
  /** 列表/设置页标题的上沿：演示页 52px（= 旧版胶囊的位置） */
  titleTop: number;
  /** 顶栏圆形图标钮的左边距：演示页 56px */
  hdrBtnX: number;
  /** 顶栏圆形图标钮的上沿：演示页 48px（比顶栏上沿低 4px） */
  hdrBtnY: number;
  /** 顶栏高度：演示页 64–72px */
  hdrH: number;

  /** 旧版顶部信息胶囊的宽度（当前界面已不用胶囊，保留给需要整条底的场景） */
  pillW: number;
  pillH: number;
  pillTop: number;
  /** 圆形图标钮直径：演示页 64px */
  iconBtn: number;
  /** 圆钮里那个图形本身的边长：约占钮的 52%，四周留出的才是可点的安全边 */
  iconGlyph: number;

  // ---- 尺寸基元：全部与 ui-demo/index.html 里的 px 一一对应（系数 = px / 233）----

  /** 会话行 / 回复方式卡片高度：demo 104px */
  row: number;
  /** 行与行的间距：demo 10px */
  rowGap: number;
  /** 行内头像 / 图标底：demo 64px */
  avatar: number;
  /** 行内左右内边距：demo 16–20px */
  rowPadX: number;
  /**
   * 行内**内容**的左右内边距（= rowPadX + 0.0172r，约 20px）。
   *
   * 单独留一个基元是因为它必须**左右一致**：设置页、短语管理页上每一行的正文、行尾
   * 图标都以它为基准。第一版在短语行里左边写 rowPadX+0.0172r、右边直接给 rowPadX，
   * 两边的差有 4px —— 单看一行不明显，几行叠起来图标就不在一条竖线上。
   */
  get padIn(): number {
    return this.rowPadX + this.f(0.0172);
  }

  /** 表情格边长：demo 100px（3 列 ×100 + 2×10 间距 = 320px，正好收进 331px 内容列） */
  cell: number;
  /** 表情格之间的间距：demo 10px */
  cellGap: number;
  /** 表情格内的缩略图：demo 60px */
  cellImg: number;
  /** 表情格标签字号：demo 16px（规范下限） */
  fsCell: number;

  /** 次级控件高度（短语行、回复菜单里的胶囊、输入框）：demo 88px */
  ctrlH: number;
  /** 主操作高度（重试 / 保存 / 会话卡）：demo 96px */
  btnH: number;
  /** 拉杆宽度，同 col */
  get btnW(): number {
    return this.col;
  }

  /** 聊天页底部「回复」胶囊宽度：demo 300px */
  replyW: number;
  /** 该胶囊的上沿：演示页把它放在距屏底 34px 处 */
  replyTop: number;

  /** 自绘开关：demo 70×40px */
  switchW: number;
  switchH: number;
  /** 开关滑块直径 */
  switchKnob: number;

  /** 页面大标题（消息 / 设置）：demo 30px */
  fsTitle: number;
  /** 主按钮文字 / 卡片主标题：demo 28px */
  fsBtn: number;
  /** 列表主文字 / 顶栏标题：demo 26px */
  fsList: number;
  /** 正文/气泡字：demo 24px */
  fsBody: number;
  /** 次要文字（行内说明、副标题）：demo 20px */
  fsSub: number;
  /** 说明文字，也是圆屏可读下限：demo 18px */
  fsCaption: number;

  constructor(w: number, h: number) {
    const r: number = Math.min(w, h) / 2;
    this.w = w;
    this.h = h;
    this.r = r;

    this.col = r * 1.42;
    this.bandTop = h / 2 - r * 0.7;
    this.bandH = r * 1.42;
    // 内容带起点 = 演示页的 128px：
    //   bandTop + bandPadTop = h/2 - 0.7r + 0.25r = h/2 - 0.45r = 64.1vp ≈ 128px ✓
    // 顶栏（标题 30px + 状态行 18px）到 114px 结束，还留 14px 净空。
    this.bandPadTop = r * 0.25;
    // 聊天页底部要留出「回复」胶囊的位置。胶囊上沿在 h - 34px - 88px = 344px，
    // 内容带下沿必须收回它上面：0.7r - 0.32r = 0.38r → 400px 附近，安全。
    this.bandPadBottom = r * 0.32;

    this.hdrTop = h / 2 - r * 0.8112;
    this.titleTop = h / 2 - r * 0.777;
    this.hdrBtnX = r * 0.2403;
    this.hdrBtnY = h / 2 - r * 0.79;
    this.hdrH = r * 0.309;

    this.pillW = r * 1.36;
    this.pillH = r * 0.38;
    this.pillTop = this.titleTop;
    this.iconBtn = r * 0.2747;
    this.iconGlyph = this.iconBtn * 0.52;

    this.row = r * 0.4464;
    this.rowGap = r * 0.0429;
    this.avatar = r * 0.2747;
    this.rowPadX = r * 0.0687;

    this.cell = r * 0.4292;
    this.cellGap = r * 0.0429;
    this.cellImg = r * 0.2575;
    this.fsCell = r * 0.0687;

    this.ctrlH = r * 0.3777;
    this.btnH = r * 0.412;

    this.replyW = r * 1.2876;
    this.replyTop = h - r * 0.1459 - this.ctrlH;

    this.switchW = r * 0.3004;
    this.switchH = r * 0.1717;
    this.switchKnob = r * 0.1373;

    this.fsTitle = r * 0.1288;
    this.fsBtn = r * 0.1202;
    this.fsList = r * 0.1116;
    this.fsBody = r * 0.1030;
    this.fsSub = r * 0.0858;
    this.fsCaption = r * 0.0773;
  }

  /** 字号/间距统一按半径比例取：f(0.107) 在 WATCH 5 上约等于 12.5vp */
  f(ratio: number): number {
    return this.r * ratio;
  }

  /** 把宽度为 width 的元素水平居中 */
  cx(width: number): number {
    return (this.w - width) / 2;
  }

  /** 内容列左沿 */
  get colX(): number {
    return this.cx(this.col);
  }

  /** 内容带起点（列顶 + 顶部内边距），各页面的第一行都从这里开始 */
  get colTop(): number {
    return this.bandTop + this.bandPadTop;
  }

  // ------------------------------------------------------------ 全屏滚动容器
  //
  // 圆屏上「滚动容器本身就是矩形」这件事会直接暴露出来：容器一有明确的上下边界，
  // 内容滑到边界处就被水平切断，圆里能看见一条笔直的切线，看上去像给列表加了边框。
  // 旧版每个列表都按「内容带」的高度摆（底边落在 400–443px），切线正好横在圆内，
  // 所以底部总像被削掉一块。
  //
  // 解法不是裁得更圆一点，而是**让容器永远比屏幕大**：滚动容器铺满整屏，
  // 上下两端都在圆外，切线落在肉眼看不到的地方；内容靠内边距停在安全区里。
  //
  // 安全区判据同内容列宽：圆在纵向偏移 dy 处的可用全宽 = 2√(r² - dy²)，
  // 要求它 ≥ 列宽 1.42r：

  //     √(r² - dy²) ≥ 0.71r   →   dy ≤ r·√(1 - 0.71²) = 0.704r        ← 行能完整露出的极限

  /**
   * 全屏滚动容器的顶部内边距：让第一行仍从演示页的 128px 起。
   * （= colTop，单独留个名字是因为它的语义是「容器的 padding」而不是「内容的坐标」）
   */
  get scrollPadTop(): number {
    return this.colTop;
  }

  /** 最后一行完整露出的下沿（圆心下方 0.704r） */
  get rowBottomFull(): number {
    return this.h / 2 + this.r * 0.704;
  }

  /**
   * 全屏滚动容器的底部内边距：把最后一行停在 `rowBottomFull`，
   * 停在再往下就只剩被圆弧切掉的两个角了。
   */
  get scrollPadBottom(): number {
    return this.h - this.rowBottomFull;
  }

  /**
   * 聊天页滚动容器的底部内边距：得给圆心下方那颗「回复」胶囊让出整条净空，
   * 否则滚到底时最后一条消息会被胶囊压住。
   */
  get chatPadBottom(): number {
    return this.h - this.replyTop;
  }
}

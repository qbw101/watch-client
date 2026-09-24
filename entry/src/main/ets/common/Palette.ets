/**
 * 表盘内的配色。
 *
 * 数值直接取自 ui-demo/index.html 的 CSS 变量（`--w-*`），不再各处手写魔法色值 ——
 * 演示页是这套界面的唯一基准，色号散落在十几个 build 里就没法核对「和演示页一致」。
 *
 * 深色底是 OLED 省电 + 穿戴规范的要求，主色是鸿蒙蓝，品牌红只作点缀
 * （头像底、表情入口），不再当主按钮底色：红底在白字上的对比度不如蓝，
 * 而且圆屏上红块面积一大就像报错。
 */
export class Palette {
  /** 页面底（演示页 #000）. OLED 纯黑，熄屏像素不发光 */
  static readonly bg: string = '#000000';
  /** 卡片 / 列表行 */
  static readonly card: string = '#1C1C1E';
  /** 次级卡片：对方气泡、表情格里的图底 */
  static readonly card2: string = '#2C2C2E';
  /** 描边（ghost 胶囊的边） */
  static readonly line: string = '#38383A';

  /** 主色：我方气泡、主按钮、开关打开态 */
  static readonly blue: string = '#0A84FF';
  /** 成功 / 在线状态点 */
  static readonly green: string = '#32D74B';
  /** 错误 */
  static readonly red: string = '#FF453A';
  /** 提醒 */
  static readonly orange: string = '#FF9F0A';
  /** 品牌红：只做点缀 */
  static readonly brand: string = '#FE2C55';

  /** 正文白 */
  static readonly t1: string = '#FFFFFF';
  /** 次要文字：白 62%。写 ARGB 而不是 rgba()，ArkUI 的 #AARRGGBB 才是稳妥写法 */
  static readonly t2: string = '#9EFFFFFF';
  /** 说明文字：白 38% */
  static readonly t3: string = '#61FFFFFF';

  /** 错误徽标的底：品牌红 16% 透明 */
  static readonly redSoft: string = '#29FF453A';
  /** 表情入口图标底：品牌红 20% */
  static readonly brandSoft: string = '#33FE2C55';
  /** 文字入口图标底：鸿蒙蓝 20% */
  static readonly blueSoft: string = '#330A84FF';
  /** 提示条底（灰） */
  static readonly toast: string = '#1F2630';
  /** 提示条底（成功） */
  static readonly toastOk: string = '#10281F';
  /** 提示条底（错误） */
  static readonly toastErr: string = '#3A1420';
  /** 开关关闭态的轨道 */
  static readonly trackOff: string = '#39414F';
}

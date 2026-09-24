/**
 * 单条消息气泡（对应 ui-demo/index.html 的 `.bub`）。
 *
 * 圆屏约束：气泡最大宽度取 272px（r × 1.167），比内容列宽（331px）再收一圈，
 * 这样长文本换行后左右两侧仍留有余量，不会顶到圆的弧线外。
 *
 * 图片不再交给 `Image(url)` 去加载 —— 链路是裸 TCP，没有 URL 可给。这里改成
 * 从 ImageCache 取解码好的 PixelMap，见 service/ImageCache.ets。
 *
 * 演示页里聊天页不显示逐条时间（只有气泡本身），所以这里也不再往每个气泡上面
 * 挂一行时间戳；协议里真正的「时间分隔」消息（type=time）仍居中显示。
 */
import { image } from '@kit.ImageKit';

import { Palette } from '../common/Palette';
import { WatchMessage } from '../common/Types';
import { ImageCache, MEDIA_PX } from '../service/ImageCache';

@Component
export struct MessageBubble {
  /** 由父组件传入，字段名与 WatchMessage 一致 */
  message: WatchMessage = { key: '', side: 'them', type: 'text', text: '', time: '', media: null };
  r: number = 116.5;

  /** 解码好的图；null 表示还在取或取不到 */
  @State pixelMap: image.PixelMap | null = null;
  /** 图确定取不到（没这张图 / 解码失败），退回文字占位 */
  @State mediaFailed: boolean = false;

  aboutToAppear(): void {
    this.loadMedia();
  }

  private isMe(): boolean {
    return this.message.side === 'me';
  }

  private mediaKey(): string {
    const media: string | null = this.message.media;
    return media === null ? '' : media;
  }

  /**
   * 这条消息是不是「本来就该有图」。
   *
   * 用它而不是用 media 是否为空来决定占位方块：抖音的表情消息在 CDN 地址还没
   * 解析出来时 media 就是空的，那时候如果按「没有图」渲染成一行文字，等地址
   * 回来整个气泡会突然撑大，列表滚动位置跟着跳。
   */
  private wantsImage(): boolean {
    return this.message.type === 'sticker' || this.message.type === 'image';
  }

  private async loadMedia(): Promise<void> {
    const key: string = this.mediaKey();
    if (key.length === 0) {
      return;
    }
    const cached: image.PixelMap | null = ImageCache.instance.peek('media', key, MEDIA_PX);
    if (cached !== null) {
      this.pixelMap = cached;
      return;
    }
    const map: image.PixelMap | null = await ImageCache.instance.load('media', key, MEDIA_PX);
    // 取图期间用户可能已经滚走、这条气泡被销毁了；此时赋值是空操作
    if (map === null) {
      this.mediaFailed = true;
      return;
    }
    this.pixelMap = map;
  }

  /** 表情/图片气泡的边长。演示页是 96px（r × 0.412） */
  private boxSize(): number {
    return this.r * 0.412;
  }

  private label(): string {
    if (this.message.type === 'text') {
      return this.message.text;
    }
    if (this.message.type === 'sticker') {
      return this.message.text.length > 0 ? `[${this.message.text}]` : '[表情]';
    }
    return '[图片]';
  }

  @Builder
  mediaBubble() {
    Column({ space: this.r * 0.0172 }) {
      if (this.pixelMap !== null) {
        Image(this.pixelMap)
          // 尺寸写死：图片是异步解出来的，高度早定下来滚动位置才不会被顶走
          .width(this.r * 0.30)
          .height(this.r * 0.30)
          .objectFit(ImageFit.Contain)
          .draggable(false)
      } else {
        // 还在取图 / 取不到：先把位置占住，图和文字的切换就不会让列表跳动
        Text(this.mediaFailed ? this.label() : '')
          .fontSize(this.r * 0.072)
          .fontColor(this.isMe() ? Palette.t1 : Palette.t2)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center)
          .width(this.r * 0.30)
          .height(this.r * 0.30)
      }

      // 表情气泡下方带名字（演示页 .bub.stk .cap）：重名严重的表情只能靠它区分
      if (this.message.type === 'sticker' && this.message.text.length > 0) {
        Text(this.message.text)
          .fontSize(this.r * 0.0687)
          .fontColor(this.isMe() ? Palette.t1 : Palette.t2)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Center)
      }
    }
    .justifyContent(FlexAlign.Center)
    .width(this.boxSize())
    .height(this.boxSize())
    .padding(this.r * 0.0215)
    .backgroundColor(this.isMe() ? Palette.blue : Palette.card2)
    .borderRadius(this.r * 0.103)
  }

  build() {
    Column() {
      if (this.message.type === 'time') {
        // 时间分隔：居中的一行小字，不加底 —— 演示页的聊天页里没有这个东西，
        // 做得越轻越好，不要抢气泡的注意力
        Text(this.message.text)
          .fontSize(this.r * 0.0773)
          .fontColor(Palette.t3)
          .width('100%')
          .textAlign(TextAlign.Center)
      } else if (this.wantsImage()) {
        Row() {
          this.mediaBubble()
        }
        .width('100%')
        .justifyContent(this.isMe() ? FlexAlign.End : FlexAlign.Start)
      } else {
        Row() {
          Text(this.label())
            .fontSize(this.r * 0.1030)
            .fontColor(Palette.t1)
            .lineHeight(this.r * 0.1391)
        }
        .constraintSize({ maxWidth: this.r * 1.167 })
        .padding({
          left: this.r * 0.0687,
          right: this.r * 0.0687,
          top: this.r * 0.0515,
          bottom: this.r * 0.0515
        })
        .backgroundColor(this.isMe() ? Palette.blue : Palette.card2)
        // 靠自己这一侧的角削平一点，做出「这段话是谁说的」的方向感，
        // 光靠颜色在深色底上分得不够快（演示页里的 10px 小圆角）
        .borderRadius(this.isMe()
          ? { topLeft: this.r * 0.1202, topRight: this.r * 0.1202, bottomLeft: this.r * 0.1202, bottomRight: this.r * 0.0429 }
          : { topLeft: this.r * 0.1202, topRight: this.r * 0.1202, bottomLeft: this.r * 0.0429, bottomRight: this.r * 0.1202 })
      }
    }
    .alignItems(this.isMe() ? HorizontalAlign.End : HorizontalAlign.Start)
    .width('100%')
  }
}

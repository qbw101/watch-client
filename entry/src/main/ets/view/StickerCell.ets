/**
 * 表情网格里的一格（对应 ui-demo/index.html 的 `.cell`）。
 *
 * 单独做成组件是为了拿到自己的 @State —— 缩略图要逐个异步解码，而 @Builder 里
 * 没有可以存解码结果的地方（页面级的那一个数组做不到「一格一状态」）。
 *
 * 有缩略图就显示图：抖音表情重名严重（一堆都叫「表情」），纯文字根本分不清。
 * 图挂了或本来就没有（扫描时发现多个表情共用一张图，那是雪碧图或占位图）就退化成
 * 纯文字格 —— 显示一张错的脸比只显示文字更糟。
 *
 * 尺寸照演示页：格 100px / 圆角 26px / 卡片底 #1C1C1E，格内缩略图 60px / 圆角 18px /
 * 底 #2C2C2E，标签 16px。三列 3×100 + 2×10 = 320px，正好收进 331px 的内容列。
 */
import { image } from '@kit.ImageKit';

import { Haptics } from '../common/Haptics';
import { Palette } from '../common/Palette';
import { StickerTile } from '../common/Types';
import { ImageCache, STICKER_PX } from '../service/ImageCache';

@Component
export struct StickerCell {
  tile: StickerTile = { key: '', id: '', name: '', label: '', hasThumb: false };
  /** 表盘半径，尺寸全部按它取比例（与 WatchGeometry.f 同源） */
  r: number = 116.5;
  /**
   * 点中这一格。
   *
   * 两个参数是分开的：`value` 是**发给服务端的定位值**（有图的表情给 id），
   * `label` 是给用户看的显示名。早先只传一个，于是乐观回显那一条把 id 原样
   * 摆了出来（`tab1:xxx`）—— 发出去没错，但自己看着莫名其妙。
   */
  onPick: (value: string, label: string) => void = () => {
  };

  @State pixelMap: image.PixelMap | null = null;
  /** 这张图确认取不到，之后不再重试 */
  @State thumbFailed: boolean = false;

  aboutToAppear(): void {
    this.loadThumb();
  }

  private async loadThumb(): Promise<void> {
    if (!this.tile.hasThumb || this.tile.id.length === 0) {
      return;
    }
    const cached: image.PixelMap | null = ImageCache.instance.peek('sticker', this.tile.id, STICKER_PX);
    if (cached !== null) {
      this.pixelMap = cached;
      return;
    }
    const map: image.PixelMap | null = await ImageCache.instance.load('sticker', this.tile.id, STICKER_PX);
    if (map === null) {
      this.thumbFailed = true;
      return;
    }
    this.pixelMap = map;
  }

  private showImage(): boolean {
    return this.pixelMap !== null;
  }

  build() {
    Column({ space: this.r * 0.0172 }) {
      if (this.showImage()) {
        Image(this.pixelMap)
          .width(this.r * 0.2575)
          .height(this.r * 0.2575)
          .objectFit(ImageFit.Contain)
          .draggable(false)
      } else if (this.tile.hasThumb && !this.thumbFailed) {
        // 还在解码：占住和图一样大的位置，免得解码完成后整片网格重排
        Stack() {
        }
        .width(this.r * 0.2575)
        .height(this.r * 0.2575)
        .backgroundColor(Palette.card2)
        .borderRadius(this.r * 0.0773)
      }

      Text(this.tile.label)
        .fontSize(this.r * 0.0687)
        .fontColor(Palette.t2)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .width('100%')
    }
    .justifyContent(FlexAlign.Center)
    .width(this.r * 0.4292)
    .height(this.r * 0.4292)
    .padding(this.r * 0.03)
    // 5px 外边距 × 2 = 演示页里 10px 的格间距
    .margin(this.r * 0.0215)
    .backgroundColor(Palette.card)
    .borderRadius(this.r * 0.1116)
    .onClick(() => {
      Haptics.tap();
      // 有图的表情发 **id**（库里按内容派生的稳定标识），不发表面上的名字：
      // 自建/收藏表情的 name 是「第几栏第几个」，电脑端重扫一次就会跟着顺序变，
      // 而 id 认的是图本身 —— 服务端 by_ref 也是先按 id 找。没有 id 的快捷表情
      // 才退回用名字（它本来就是配置里的名字）。
      const value: string = this.tile.id.length > 0 ? this.tile.id : this.tile.name;
      this.onPick(value, this.tile.label);
    })
  }
}

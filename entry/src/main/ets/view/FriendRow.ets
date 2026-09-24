/**
 * 会话列表的一行（对应 ui-demo/index.html 的 `.conv`）。
 *
 * 尺寸全部照演示页：高 104px、圆角 32px、卡片底 #1C1C1E、头像 64px、名字 26px、
 * 预览 20px、时间 18px 顶对齐。比旧版（96px 胶囊 + 描边）更高更「实」——
 * 466px 的表盘上，96px 只相当于指甲盖的一半，再挤进头像和名字，误触概率很高；
 * 104px 同时满足华为穿戴「常规行 ≥88px」的建议，代价是可视行数少半行。
 *
 * 预览与时间可能为空（电脑端的会话列表读不到时），那时整行只显示名字，
 * 名字仍然垂直居中 —— 不留一个空白的第二行。
 */
import { Haptics } from '../common/Haptics';
import { Palette } from '../common/Palette';

@Component
export struct FriendRow {
  name: string = '';
  /** 最后一条消息的预览，读不到时为空串 */
  preview: string = '';
  /** 最后一条消息的时间，读不到时为空串 */
  time: string = '';
  /** 表盘半径，尺寸全部按它取比例（与 WatchGeometry 同源） */
  r: number = 116.5;
  /** 由父组件注入的点击回调 */
  onPick: (name: string) => void = (name: string) => {
  };

  private initial(): string {
    if (this.name.length === 0) {
      return '?';
    }
    return this.name.substring(0, 1);
  }

  build() {
    Row({ space: this.r * 0.06 }) {
      Stack() {
        Text(this.initial())
          .fontSize(this.r * 0.1202)
          .fontWeight(FontWeight.Medium)
          .fontColor('#07090C')
      }
      .width(this.r * 0.2747)
      .height(this.r * 0.2747)
      .backgroundColor(Palette.brand)
      .borderRadius(this.r * 0.1373)

      Column({ space: this.r * 0.0129 }) {
        Text(this.name)
          .fontSize(this.r * 0.1116)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.t1)
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        if (this.preview.length > 0) {
          Text(this.preview)
            .fontSize(this.r * 0.0858)
            .fontColor(Palette.t2)
            .width('100%')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (this.time.length > 0) {
        // 时间在演示页里是顶对齐（含 24px 上边距），和最上面那行名字同高
        Text(this.time)
          .fontSize(this.r * 0.0773)
          .fontColor(Palette.t3)
          .margin({ top: this.r * 0.103 })
      }
    }
    .width('100%')
    .height(this.r * 0.4464)
    .padding({ left: this.r * 0.0687, right: this.r * 0.0687 })
    .backgroundColor(Palette.card)
    .borderRadius(this.r * 0.1373)
    .onClick(() => {
      Haptics.tap();
      this.onPick(this.name);
    })
  }
}

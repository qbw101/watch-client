/**
 * 触感反馈（轻微震动）。
 *
 * 圆屏手表的可点区域本来就小，点中了没有反馈、点空了也看不出来，用户只能靠
 * 眼睛盯着屏幕确认 —— 加一层轻震动，手指就知道「这一下生效了」。
 *
 * 四档强度刻意拉开距离，别让用户分不清发生了什么：
 *   tick    转表冠滑过一项（最轻，可以一连串地响）
 *   tap     点到按钮/行（标准）
 *   success 成功（发送完成、刷新完成）
 *   warn    失败（连不上、发送失败）
 *
 * 两个必须自己兜住的坑：
 *
 * 1. `startVibration` 是异步的，前一次还没结束就调下一次会直接抛错。转表冠时
 *    一秒能滑过十几项，所以这里按时间戳做节流，并且把 Promise 的 reject 全部
 *    吞掉 —— 震动失败绝不该冒到界面上来。
 * 2. `usage` 在部分设备/系统版本上不受支持（报 801 Capability not supported）。
 *    首次碰到就降级成 'unknown' 重试，此后一直用降级值，不再反复试错。
 *
 * 震动开关存在 WatchPrefs 里（键 `haptics`），默认开。手表上打字很痛苦，所以
 * 这个开关放在设置页第一屏，翻转即时生效、不用点保存。
 */
import { vibrator } from '@kit.SensorServiceKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'WatchHaptics';

/** 各档持续时间（毫秒）。都在 50ms 以内，是「轻震」不是「提醒」 */
const TICK_MS: number = 8;
const TAP_MS: number = 15;
const SUCCESS_MS: number = 25;
const WARN_MS: number = 45;

/**
 * 两次震动之间的最小间隔。
 * 转表冠时事件比这个密得多，靠它把一串事件压成有节奏的「哒哒」声，
 * 而不是糊成一片长震（糊成一片反而像故障）。
 */
const MIN_GAP_MS: number = 40;

export class Haptics {
  /** 用户开关；由 load() 从持久化里恢复，toggle 时即时生效 */
  private static enabled: boolean = true;
  private static lastFiredAt: number = 0;
  /** usage 已降级过，不再重试首选值 */
  private static degraded: boolean = false;
  private static usage: vibrator.Usage = 'physicalFeedback';
  /** 设备确实不支持震动（801/201），此后一个字节的调用都不发 */
  private static unsupported: boolean = false;

  static isEnabled(): boolean {
    return Haptics.enabled;
  }

  /** 启动时从持久化里恢复开关。不震 —— 应用一打开就抖一下会让人以为出了问题 */
  static restore(on: boolean): void {
    Haptics.enabled = on;
  }

  static setEnabled(on: boolean): void {
    Haptics.enabled = on;
    if (on) {
      // 开启时立刻震一下：用户在设置页按下开关，手指马上知道「现在有反馈了」
      Haptics.lastFiredAt = 0;
      Haptics.success();
    }
  }

  /** 转表冠滑过一项 */
  static tick(): void {
    Haptics.fire(TICK_MS);
  }

  /** 点到按钮、行、表情格 */
  static tap(): void {
    Haptics.fire(TAP_MS);
  }

  /** 操作成功 */
  static success(): void {
    Haptics.fire(SUCCESS_MS);
  }

  /** 操作失败 */
  static warn(): void {
    Haptics.fire(WARN_MS);
  }

  private static fire(duration: number): void {
    if (!Haptics.enabled || Haptics.unsupported) {
      return;
    }
    const now: number = Date.now();
    if (now - Haptics.lastFiredAt < MIN_GAP_MS) {
      return;
    }
    Haptics.lastFiredAt = now;

    // 对象字面量先落到有类型的常量上：ArkTS 严格模式不接受裸字面量直接当实参
    const effect: vibrator.VibrateTime = { type: 'time', duration: duration };
    const attribute: vibrator.VibrateAttribute = { id: 0, usage: Haptics.usage };
    try {
      vibrator.startVibration(effect, attribute).then(() => {
      }, (err: BusinessError) => {
        Haptics.onFailed(err, duration);
      });
    } catch (err) {
      const e = err as BusinessError;
      hilog.debug(DOMAIN, TAG, '震动调用异常: %{public}s', JSON.stringify(e));
    }
  }

  private static onFailed(err: BusinessError, duration: number): void {
    const code: number = err.code;
    if (code === 801 && !Haptics.degraded) {
      // 这台设备不认这个 usage → 降级重试一次，之后一直用降级值
      Haptics.degraded = true;
      Haptics.usage = 'unknown';
      Haptics.lastFiredAt = 0;
      Haptics.fire(duration);
      return;
    }
    if (code === 801 || code === 201 || code === 14600101) {
      // 没有马达，或者权限被拒。整机静默，别每次都去撞一遍
      Haptics.unsupported = true;
      hilog.warn(DOMAIN, TAG, '设备不支持震动（code=%{public}d），已关闭触感反馈', code);
      return;
    }
    hilog.debug(DOMAIN, TAG, '震动失败（%{public}d）：%{public}s', code, err.message);
  }
}

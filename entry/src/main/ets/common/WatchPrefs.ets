/**
 * 手表本地的少量配置持久化（电脑地址 + 访问令牌）。
 *
 * 用 @kit.ArkData 的 preferences：数据落在应用沙箱里，卸载即清，
 * 不涉及任何权限申请。页面和 EntryAbility 都通过这个静态类访问，
 * 避免到处传 Context。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'WatchPrefs';
const STORE_NAME: string = 'watch_bridge';

/** 电脑地址，形如 192.168.1.5:8787（裸 TCP，没有协议头） */
export const KEY_ENDPOINT: string = 'endpoint';
export const KEY_TOKEN: string = 'token';
/**
 * 触感反馈（轻微震动）开关。
 *
 * 默认开着：没有震动反馈时用户只能盯着屏幕确认有没有点中，圆屏本来就小，
 * 相比之下震动是更轻的负担。不想要的人在设置页第一屏就能关掉。
 */
export const KEY_HAPTICS: string = 'haptics';
/**
 * 旧版本存的键名，值是完整 URL（http://ip:8787）。
 *
 * 留着是为了做一次性迁移：手表上打字太难，让用户为了升级应用重新敲一遍 IP
 * 是无法接受的。迁移逻辑在 pages/Index.ets 的 aboutToAppear 里，迁完就不再读它。
 */
export const KEY_LEGACY_BASE_URL: string = 'base_url';
/**
 * 快捷短语。**换行分隔**，不存 JSON —— 短语本来就是单行的，用不着再套一层解析，
 * 也就没有「JSON.parse 在严格模式下返回 Object 怎么转成 string[]」这一串麻烦。
 */
export const KEY_PHRASES: string = 'phrases';
/**
 * 短语是否已经从服务端 presets 播过种。
 *
 * 为什么要单独记一位：播种只做一次。不做标记的话，用户删掉某条短语，
 * 下一次 status 回来又被 presets 灌回去，界面上看起来就是「删不掉」。
 */
export const KEY_PHRASES_READY: string = 'phrases_ready';

export class WatchPrefs {
  private static store: preferences.Preferences | null = null;

  /** 幂等，重复调用只有第一次生效 */
  static init(context: common.Context): void {
    if (WatchPrefs.store !== null) {
      return;
    }
    try {
      const options: preferences.Options = { name: STORE_NAME };
      WatchPrefs.store = preferences.getPreferencesSync(context, options);
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, '打开 preferences 失败: %{public}s', JSON.stringify(e));
    }
  }

  static getString(key: string, fallback: string): string {
    const store: preferences.Preferences | null = WatchPrefs.store;
    if (store === null) {
      return fallback;
    }
    try {
      const value: preferences.ValueType = store.getSync(key, fallback);
      return typeof value === 'string' ? value : fallback;
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, '读取 %{public}s 失败: %{public}s', key, JSON.stringify(e));
      return fallback;
    }
  }

  static setString(key: string, value: string): void {
    const store: preferences.Preferences | null = WatchPrefs.store;
    if (store === null) {
      return;
    }
    try {
      store.putSync(key, value);
      WatchPrefs.flushQuietly(store, key);
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, '写入 %{public}s 失败: %{public}s', key, JSON.stringify(e));
    }
  }

  /** 布尔配置。读失败一律回落到 fallback，界面不该因为一次读盘失败就变样 */
  static getBool(key: string, fallback: boolean): boolean {
    const store: preferences.Preferences | null = WatchPrefs.store;
    if (store === null) {
      return fallback;
    }
    try {
      const value: preferences.ValueType = store.getSync(key, fallback);
      return typeof value === 'boolean' ? value : fallback;
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, '读取 %{public}s 失败: %{public}s', key, JSON.stringify(e));
      return fallback;
    }
  }

  static setBool(key: string, value: boolean): void {
    const store: preferences.Preferences | null = WatchPrefs.store;
    if (store === null) {
      return;
    }
    try {
      store.putSync(key, value);
      WatchPrefs.flushQuietly(store, key);
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, '写入 %{public}s 失败: %{public}s', key, JSON.stringify(e));
    }
  }

  /**
   * flush 是异步落盘，不阻塞 UI；失败最多丢一次配置，下次写会重试。
   * 抽出来是因为「开关」这类配置改动频繁，每次都要写一遍 catch 太啰嗦。
   */
  private static flushQuietly(store: preferences.Preferences, key: string): void {
    store.flush().then(() => {
    }).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, '落盘 %{public}s 失败: %{public}s', key, JSON.stringify(err));
    });
  }
}

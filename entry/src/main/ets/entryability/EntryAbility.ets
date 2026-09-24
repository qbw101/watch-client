import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

import { WatchPrefs } from '../common/WatchPrefs';
import { runCryptoDiag } from '../service/CryptoDiag';

const DOMAIN: number = 0x0001;
const TAG: string = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // preferences 需要一个 Context，Ability 是拿上下文最稳的地方；
    // 这里初始化一次，页面里就不用再传 Context 了。
    WatchPrefs.init(this.context);
    // 加密自检：把 HKDF / GCM 的中间值打到 hilog，用来和 Python 侧逐字节比对。
    // 不碰网络也不碰配置，放在启动流程里最省事；定位完链路问题就摘掉。
    runCryptoDiag().catch((err: Error) => {
      hilog.error(DOMAIN, TAG, '加密自检异常: %{public}s', err.message);
    });
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, '加载首页失败: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, '首页已加载');
    });
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'Ability 销毁');
  }
}

# 抖音手表助手 · 华为 WATCH 5 客户端

> English: [README.en.md](README.en.md)

在华为手表上收发抖音私信的原生客户端。ArkTS + ArkUI 写的 HarmonyOS 穿戴应用，
圆屏适配，支持旋转表冠与智慧手势。链路是**自研的二进制帧协议**（不是 HTTP），
直连电脑上的配套服务端 [`watch-bridge`](https://github.com/qbw101/watch-bridge)。

**手表不直接连抖音**：所有抖音操作都由电脑上的常驻浏览器完成，手表只是一个
省电、交互顺手的手柄。所以两边必须在同一 Wi-Fi，且电脑上那个服务窗口与浏览器窗口
都要开着。

## 目录

- [能做什么](#能做什么)
- [架构](#架构)
- [前置条件](#前置条件)
- [构建与装机](#构建与装机)
- [首次使用](#首次使用)
- [圆屏适配](#圆屏适配)
- [表冠与手势](#表冠与手势)
- [链路协议](#链路协议)
- [排错](#排错)
- [工程结构](#工程结构)
- [已知边界](#已知边界)
- [免责声明](#免责声明)
- [许可证](#许可证)

## 能做什么

| 功能 | 说明 |
| --- | --- |
| 会话列表 | 显示哪些会话由服务端 `config.json` 决定；顶部胶囊显示就绪状态 |
| 读消息 | 打开会话即订阅服务端推送，内容变化才传输，不轮询 |
| 发文字 | 卡片式输入（圆屏贴底横排输入框会被裁成窄缝，所以做成居中弹层） |
| 发原生表情 | 表情网格，含在抖音里自己收藏的自建表情 |
| 快捷短语 | 本地保存的常用语，一键填入 |
| 设置 | 电脑地址、访问令牌、震动反馈开关 |
| 表冠滚动 | 列表与聊天记录都可用旋转表冠滚动 |
| 智慧手势 | 捏合确认；回复面板内为「表冠切高亮 + 捏合进入」 |

## 架构

```
┌──────────────────────────────┐
│ 华为 WATCH 5（本工程，ArkTS）  │
│  裸 TCP 长连接 + 二进制帧      │
│  X25519 握手 + AES-256-GCM    │
└───────────────┬──────────────┘
                │ 局域网 TCP（默认 8787）
┌───────────────▼──────────────┐
│ 电脑：watch-bridge            │
│  scripts/watch_server.py      │
│    └─ bridge/tcp_server.py    │
│         └─ 常驻 Chromium ──► 抖音私信页
└──────────────────────────────┘
```

为什么不用 HTTP：穿透服务商按应用协议判定，走 HTTP 隧道要备案域名或只能用境外节点；
自研二进制帧在服务商侧看不出 HTTP 特征，可以走内地节点。另外长连接天然支持服务端
主动推送，省掉手表上那套 2 秒轮询（每次轮询都要重建连接、带一整套请求头，而绝大部分
结果都是「什么都没变」，白唤醒无线电是手表续航的隐形杀手）。

## 前置条件

| 项 | 说明 |
| --- | --- |
| DevEco Studio | 5.1.0 Release 或更高（Watch 5 的 wearable 工程模板从这个版本起齐全） |
| 华为开发者账号 | 需实名认证；DevEco 里登录后可用「自动签名」，不必手工做证书 |
| HarmonyOS SDK | API 12 以上，本工程按 `6.0.0(20)` 配置 |
| 手表 | HUAWEI WATCH 5，切到**全能模式**（超长续航模式下装不了应用） |
| 网络 | 手表与电脑同一 Wi-Fi |
| 配套服务端 | [`watch-bridge`](https://github.com/qbw101/watch-bridge)，手表端单独跑不起来 |

> 本工程的 `build-profile.json5` 里签名材料是**本机路径**，换电脑后需要重新做一次
> 自动签名（见下节）。没配签名的产物是 `-unsigned.hap`，真机一律装不上
> （错误码 `9568320 / no signature file`）。

## 构建与装机

### 手表端准备（只需做一次）

1. 手表上按上键 → **设置** → 点设备名称 → **关于手表**
2. 找到**软件版本**，**连续快速点击 7 次**，出现「您正处于开发者模式！」
3. 返回 → **设置 → 系统 → 开发者选项**，打开 **HDC 调试** 与 **Wi-Fi 调试**
   （Wi-Fi 调试会显示一个形如 `192.168.1.23:44322` 的地址，记下来）
4. 建议同时把自动熄屏时间调长 —— **Wi-Fi 调试在熄屏后会断开**

### 用 DevEco Studio

**顺序不能颠倒**：自动签名会把「当前已连接设备的 UDID」写进 Profile，
所以必须**先连上手表，再配签名**。

1. DevEco Studio → **File → Open** 选本目录，等首次 Sync 完成
2. **Tools → IP Connection** 填手表的 `IP:端口` 连接（手表会弹「信任设备」）
3. 顶部设备下拉里确认能看到手表。**看不到就先解决连接，别往下走**
4. **File → Project Structure → Project → Signing Configs**
   - 勾选 **Automatically generate signature**（HarmonyOS 工程要同时勾 **Support HarmonyOS**）
   - 未登录会提示 **Sign In**：用已实名认证的华为账号登录
   - 授权回来后几项材料路径会被自动填上 → **Apply → OK**
5. **Build → Clean Project**，然后 **Run 'entry'**

### 用命令行

```bash
unset NODE_OPTIONS                       # 见下方「排错」：某些环境的 shim 会崩掉构建
export DEVECO_SDK_HOME="<DevEco 安装目录>/sdk"

"<DevEco 安装目录>/tools/hvigor/bin/hvigorw.bat" \
  --mode module -p product=default -p module=entry@default assembleHap --no-daemon
```

打包前顺手跑一次 `tools/check_project.py` —— hvigor 打包**不看 `.gitignore`**，
`entry/src` 下有什么就塞什么。调试脚本留下的 `.ets.bak` 备份会一起进包
（实测让产物虚胖了 400KB），而备份是改动**之前**的原文，可能带着当时还没脱敏的内容。

产物在 `entry/build/default/outputs/default/`。**文件名里有 `unsigned` 就是没签上**，
装了必报 `9568320`。装机：

```bash
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
```

签名是否真的生效，可以看 `SignHap` 那一步耗时：真签了是 2 秒级，
`1 ms` 就是空转（日志里会紧跟一句 `No signingConfig found for product default`）。

## 首次使用

先在电脑上启动服务端（见 [`watch-bridge`](https://github.com/qbw101/watch-bridge) 的说明）。首次启动会
自动打开一个本机配置页，上面写着**电脑地址**和**访问令牌**。

手表上打开「抖音助手」：

| 字段 | 填什么 |
| --- | --- |
| 电脑地址 | `192.168.1.10:8787`（不写端口则默认 8787；`http://` 开头也照收） |
| 访问令牌 | 配置页上那串（首次启动自动生成，8 位十六进制） |

两项都会存进手表本地（`preferences`），下次打开直接用。要改的话点列表页右上角的**设**。

地址栏很宽容：端口可省略，`http://` / `tcp://` 前缀会被丢掉，结尾的路径与查询串、
斜杠也一并忽略 —— 从浏览器地址栏复制粘贴过来不会报「格式不对」。

## 圆屏适配

WATCH 5 是 **466×466 px = 233×233 vp** 的圆屏，四角是物理不存在的区域。
本工程不靠 padding 猜，用几何约束（`entry/src/main/ets/common/Geometry.ets`）：

```
半径 r，到圆心距离 > r 的像素看不见
内容列宽能取多大，判据是「行」而不是「内容带」：
  行高 r×0.37，最高到圆心上方 r×0.51，最低到 r×0.545
  极值点 √(0.71² + 0.545²) = 0.896r < r  →  列宽 1.42r 时仍完整落在圆内
```

| 元素 | 公式 | WATCH 5 上 |
| --- | --- | --- |
| 内容列宽 | `r × 1.42` | 165 vp |
| 顶部胶囊 | `r × 1.36` × `r × 0.285` | 158 × 33 |
| 内容带 | 上沿 `50% - r×0.70`，高 `r × 1.42` | y35~200 |
| 圆形按钮 | 直径 `r × 0.40`，上沿 `50% + r×0.575` | 47，y183 |
| 正文字号 | `r × 0.105` | 12.2 vp |

两个容易踩回去的坑：

- **胶囊比内容列窄是故意的**。胶囊顶边离圆心 `r×0.775`，那里圆只剩 `1.264r` 宽，
  取 `1.36r` 意味着两端各被切掉约 5.6 vp（圆头本身是弧线，切掉的就是弧线，看不出来）。
- **列宽与内容带高度互相牵制**：列宽要到 `1.42r`，内容带就不能超过约 `1.42r` 高，
  否则四角出圆。改其中一个请连另一个一起重算。

`r` 不写死 233：页面用 `onAreaChange` 实测根容器尺寸后整体替换 `WatchGeometry`，
所以模拟器（不同分辨率）与其它圆屏手表也能直接跑。

**调整尺寸只改 `Geometry.ets` 里的系数，不要在页面里散写魔法数字。**

## 表冠与手势

### 表冠

表冠事件**只发给当前获焦的组件**（API 18+，仅 Wearable 设备支持）：

```ts
SomeComponent()
  .focusable(true)
  .id('someId')
  .digitalCrownSensitivity(CrownSensitivity.MEDIUM)
  .onDigitalCrown((event: CrownEvent) => { /* event.degree 是相对旋转角度 */ })
```

关键约束与踩坑：

| 事项 | 结论 |
| --- | --- |
| 分发对象 | 只发给**获焦组件**。`List` / `Scroll` / `Grid` / `Slider` / `Swiper` 等默认支持表冠滚动，但必须先获焦 |
| 别用 `defaultFocus(true)` | 它只在「页面首次创建」时生效；本工程的列表是数据回来之后才建出来的，早过了那个时机。要在列表出现时显式 `focusController.requestFocus(id)` |
| 焦点激活态 | `getFocusController().activate(true, false)` 是 `requestFocus` 生效的前提，否则静默失败 |
| 聊天页的特殊处理 | 聊天页的消息气泡全不可获焦，`Scroll` 自己拿不到焦点。所以表冠挂在**根容器**上，由它接事件再调 `scroller.scrollBy()` |
| `hitTestBehavior(None)` 的坑 | 这种节点**拿不到焦点**。想用「另铺一个全屏空容器专收表冠」的办法行不通 |
| 别给根容器 `focusable(false)` | 会把焦点链打断，表冠与智慧手势全废 |

判断有没有接上，看 `uitest dumpLayout` 里那个节点的 `focused` 是不是 `true` 就够了，
不必真的去转表冠。

### 智慧手势

捏合确认的机制是：系统给**获焦组件**下发一个 `KEYCODE_ENTER`(2054)。所以可选项
必须是可获焦的，或者由接住事件的根容器代为处理。

回复面板用的是穿戴设备的标准交互 —— **表冠切高亮 + 捏合确认**：

| 操作 | 行为 |
| --- | --- |
| 打开回复面板 | 默认高亮「表情」，并复位到顶 |
| 转表冠 | 在三项之间切换高亮（转满固定角度换一项，因为表冠是连续量） |
| 捏合 | 进入当前高亮的那一项 |
| 已在子页捏合 | 退回上一层 |

### 返回与关闭

| 手势 | 行为 |
| --- | --- |
| 从屏幕左侧右滑 | 返回上一层（根容器 `parallelGesture` 上的水平 `PanGesture`） |
| 回复面板第一屏下滑 | 关闭面板（手势挂在背后那层全屏黑底上） |

## 链路协议

见 [`watch-bridge` 的协议说明](https://github.com/qbw101/watch-bridge#链路协议)。摘要：

- 帧头固定 8 字节，大端：载荷长度(4) / 帧类型(1) / 请求 id(2) / 标志(1)
- 类型：`HELLO` `REQ` `RES` `IMAGE` `PING` `PONG`
- 载荷在加密通道上再套一层 AEAD（X25519 密钥交换 + AES-256-GCM），帧头保持明文
- TCP 是字节流：**绝不能假设「一次回调 = 一帧」**，所有收到的数据都要先丢进
  `FrameParser` 攒着按帧切（粘包、半包都在那里被吃掉）
- 加密必须**串行**：nonce 由方向前缀 + 计数器构成，并发发送会撞 nonce

手表端实现分布在 `service/` 下：`BridgeLink`（连接与重连）、`WireCrypto`（握手与
AEAD）、`BridgeSession`（把帧封装成 `status()` / `messages()` / `sendMessage()` 等
可调用方法）、`ImageCache`（缩略图缓存）、`CryptoDiag`（握手失败时的诊断）。

## 排错

| 现象 | 原因 / 处理 |
| --- | --- |
| `Install Failed: code:9568320 error: no signature file` | 没配签名。按「构建与装机」走一遍。**关键顺序：先连手表，再点自动签名** |
| 自动签名勾了但产物还是 `-unsigned.hap` | 签名没落到 target 上。检查根 `build-profile.json5` 的 `products[0]` 有没有 `"signingConfig": "default"` |
| 自动签名一直转圈或失败 | 依次排查：① 电脑系统时间与北京时间不一致；② 华为账号未实名认证；③ 网络到不了华为服务器 |
| 换了手表/新设备后装不上 | Profile 里没有新设备的 UDID。**先把新设备连上**，再重新勾一次自动签名 |
| 构建直接崩、报错看不出所以然 | 环境里若有 `NODE_OPTIONS`（常见于各种 safe-delete shim），会让 hvigor 崩掉，长得像它自己的 bug。`unset NODE_OPTIONS` 再构建 |
| 「连不上电脑」 | 电脑上服务没启动，或不在同一网段。先在电脑上看服务窗口还在不在 |
| 「找不到电脑：检查地址里的 IP 是否写对」 | IP 变了就点列表页的**设**重填 |
| 「令牌无效，请重新填写」 | 令牌对不上。以**服务端配置页**上那份为准（服务端 `artifacts/watch_token.txt` 里也同步了一份） |
| 提示 Windows 防火墙拦截 | 首次运行放行 python.exe 的专用网络访问，否则手表连不进来 |
| 调试连一会儿就断 | Wi-Fi 调试在熄屏后会断开。熄屏后 `hdc list targets` 会变成 `[Empty]`、所有命令报 `need connect-key`（**退出码仍是 0**），先 `hdc shell power-shell wakeup` 点亮屏幕再 `hdc tconn <IP:端口>` 恢复 |
| 转表冠没反应 | 表冠事件只发给获焦组件，见「表冠与手势」。自查：`uitest dumpLayout` 看那个节点的 `focused` |
| 圆形按钮是个纯色圆点、没有图标 | 图标用的是汉字或系统符号。本机字体不全，别用 `✎` / `⟳` / `⚙` 这类符号，渲染出来是空白 |
| 输入框占位文字被截成半句 | `TextInput` 的占位文字要单独设 `.placeholderFont({ size })`，只写 `.fontSize()` 它仍按系统默认大小渲染 |
| 点输入框后满屏都是键盘 | 手表软键盘是全屏的。此时卡片会自动收起标题与表情网格，只留输入框和按钮 |
| 进了聊天页看不到记录 | 看列表区文字：`正在读取聊天记录…` 是在读、带「点一下重试」的是读失败、`这个会话还没有消息` 才是真没有 |
| 发送要等好几秒 | 正常。服务端要盯住气泡等确认（最小 2 秒观察窗口），这是防「假成功」的正确性保证 |
| 表情格子里图全是空的 | 先在电脑浏览器验证服务端的取图接口能返回图片；打不开说明那一项本来就没有缩略图 |

## 工程结构

```
watch-client/
├── AppScope/
│   ├── app.json5                       bundleName / 版本 / 图标
│   └── resources/base/media/app_icon.png
├── build-profile.json5                 compatible/target SDK、签名配置
├── entry/src/main/
│   ├── module.json5                    deviceTypes: ["wearable"]、INTERNET / VIBRATE 权限
│   ├── ets/
│   │   ├── common/
│   │   │   ├── Protocol.ets            帧编解码 + 流式分帧
│   │   │   ├── Endpoint.ets            「地址[:端口]」的解析与宽容处理
│   │   │   ├── Geometry.ets            圆屏几何（所有尺寸的唯一来源）
│   │   │   ├── Palette.ets             配色（所有颜色色值的唯一来源）
│   │   │   ├── Haptics.ets             轻震反馈
│   │   │   ├── Types.ets               与服务端 JSON 对应的数据模型
│   │   │   └── WatchPrefs.ets          地址 / 令牌 / 开关的持久化
│   │   ├── service/
│   │   │   ├── BridgeLink.ets          TCP 连接、重连、心跳
│   │   │   ├── WireCrypto.ets          X25519 握手 + AES-256-GCM
│   │   │   ├── BridgeSession.ets       把帧封装成可调用的业务方法
│   │   │   ├── ImageCache.ets          表情缩略图缓存
│   │   │   ├── CryptoDiag.ets          握手失败的诊断信息
│   │   │   └── BridgeError.ets         错误类型与用户可读文案
│   │   ├── view/                       消息气泡 / 好友行 / 表情格
│   │   ├── entryability/EntryAbility.ets
│   │   └── pages/Index.ets             主页面：配置 / 加载 / 列表 / 聊天 / 发送卡片
│   └── resources/
├── tools/                              开发期辅助脚本（见下）
├── ui-demo/index.html                  纯 HTML 设计稿（改 UI 前先在这里对尺寸）
└── attic/                              早期实现留档（HTTP 版客户端、旧图标）
```

`tools/` 下的辅助脚本：

| 脚本 | 用途 |
| --- | --- |
| `check_project.py` | 工程静态预检：资源引用、页面路径、括号配对 |
| `make_icons.py` | 生成图标 PNG（纯标准库，不需要 Pillow） |
| `shot.sh` / `tap.sh` | 真机走查：截图 + 控件树，一次抓一对 |
| `flat.py` | 把控件树压成一行行文本，方便看层级 |
| `measure_icon.py` | 量截图里图标的亮像素重心，判断自绘图形有没有画歪 |
| `tcp_probe.py` | 从电脑直接打桥接服务，验证协议实现 |

`shot.sh` / `tap.sh` 需要一个「手表地址」，优先读 `tools/.device`（本机文件，不进版本库），
其次读环境变量 `WATCH_DEV`，都没有就用脚本里的示例值。本机用一次性写入：

```bash
echo "192.168.1.23:43235" > tools/.device
```

> ⚠️ 走查时**不要用 `uitest uiInput drag` / `swipe` 驱动 UI**：实测它会掺进点击事件，
> 可能误触界面上的按钮（甚至误删数据）。要验证滚动，优先用方向键 —— 获焦的滚动
> 容器会响应 `uiInput keyEvent`；或者请人手动操作。

## 已知边界

| 边界 | 说明 |
| --- | --- |
| 依赖配套服务端 | 手表端不能独立运行，必须有 `watch-bridge` 在跑 |
| 会话数量 | 由服务端 `config.json` 勾选决定，勾得多列表就长 |
| 消息图片按需降采样 | 服务端压到配置的边长再下发，越大越慢 |
| 自建表情靠序号定位 | 抖音面板里自建表情没有名字，只能按「第几栏第几个」定位；抖音那边增删表情会让序号漂移，需要重新扫描 |
| 表冠灵敏度是常量 | 每度滚动的像素数写死在 `Index.ets` 的常量里，可调 |
| 明文 HTTP 已废弃 | 旧版走 HTTP，现已在 `attic/http-v0/` 留档，不再维护 |
| hvigor 不看 `.gitignore` | `entry/src` 下的一切文件都会被打进 HAP，调试脚本留下的 `.ets.bak` 备份也不例外。打包前跑 `tools/check_project.py` 可拦下 |

## 免责声明

- 本工程仅供**个人学习与研究**使用。请勿用于商业用途，也请勿用于任何违反抖音用户协议或服务条款的场景。
- 通过自动化手段操作抖音账号存在被风控、功能受限乃至封禁的风险，请在使用前自行评估并自行承担后果。
- 使用本工程所产生的一切后果（包括但不限于账号损失、数据丢失、法律纠纷）由使用者自行承担，作者不承担任何责任。
- 请遵守所在地法律法规。本工程不提供任何形式的担保。

## 许可证

本工程以 [GNU General Public License v3.0](LICENSE) 发布，版权归 仇博文 (qbw) 所有。

```
Douyin Watch Client  Copyright (C) 2026  仇博文 (qbw)
```

这意味着你可以自由地使用、修改、分发本工程，但**基于本工程的衍生作品必须同样以 GPL-3.0 开源**，并保留原始版权声明。本工程不提供任何担保。

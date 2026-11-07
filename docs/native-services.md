# 本机服务接入设计（日历 / 提醒 / 健康 / 运动 …）

本文是**设计方案，尚未实现**。目标是让引擎和插件能用上 iPhone 自己的数据——日程、提醒、健康、运动、位置——这样智能体才可能成为个人助理，而不只是一个装在手机上的编码工具。

范围：能力清单、授权模型、实现路线、安全边界的真实强度、合规风险、分期落地。界面细节按 `docs/design/README.md` 的规矩另出稿。

---

## 1. 为什么这件事值得做，以及它改变了什么

现在的工具集都是"对文件和命令动手"。接入本机服务后智能体才拿到**关于你的事实**：今天有什么会、昨晚睡了多久、下周三是否有空。这是"编码 Agent"到"个人助理"的分界。

但它同时把这个 App 从「只碰自己沙盒」变成「碰用户最私密的数据」，而且：

- 智能体读到的内容**会发给模型服务商**（默认 DeepSeek）。日程标题、参会人、健康指标都算。
- 第三方插件**在本机以用户的权限运行，并且可以联网**（`PRIVACY.md` 已经这么写了）。
- 写操作有真实后果：删掉一个日历事件、改掉一个提醒，没有撤销。

所以这件事的难点不在调 API，在于**授权模型要立得住**，以及 `PRIVACY.md`、`PrivacyInfo.xcprivacy`、系统弹窗上的用途描述三者要跟上。

同类产品 OpenMinis 已经把这条路走通了，它的设计、分类标准和踩过的坑都值得对照——见 §9。

---

## 2. 先回答一个前置问题：DSH 支不支持第三方插件的权限控制？

**不支持。现在没有，也不可能靠引擎自己长出来。** 查证结论（引擎 `@deepseek-ai/dsh@0.2.1-rc.4`）：

| 维度 | 现状 |
|---|---|
| 插件形态 | npm 包（bundle），通过 `pluginManager.installBundle` 用 pnpm 装进 profile，向 cordis 注册一行插件 |
| 运行隔离 | **没有**。插件是纯 JS，和引擎跑在同一个 Worker、同一个 isolate 里，可以 `require('node:fs')`、`fetch`、读 `~/.credentials.yaml`、`process._linkedBinding('dsh_git')` |
| 能力声明 | **没有**。package.json 里没有 permissions / capabilities 字段，装之前无法知道它要什么 |
| 现成的权限概念 | 有两个，但都不是"插件权限"：<br>① `permissionPresets`（`read-only` / `workspace-write` / `full-access`）是**会话**的沙盒模式 + 审批策略，管的是文件和命令；<br>② `ctx.approval.request()` 是**一次性工具审批**，粒度是「某个 agent 的某次工具调用」，只有「允许一次 / 拒绝」，没有「总是允许」 |
| 插件身份可否识别 | 诚实的能，不诚实的不能。见 §2.1、§2.2 实测 |

也就是说：**既没有隔离，也没有可信的身份**。这决定了整个设计的性质——

> 能建的是一层**授权网关**：让用户知道这个 App 能碰哪些本机数据、随时能关、事后能查。它**不是**防恶意插件的沙箱，也**不能**区分"本体在用"还是"某个插件在用"。

这不是推卸。真正的护栏只有两处，都不在 JS 里：**iOS 的系统权限**，和**原生侧对写操作的当次确认**（§5.3）。

### 2.1 调用方归因：实测结论

cordis 的 service tracker 把服务方法里的 `this.ctx` 换成**调用方**的 context（`tracker.property === 'ctx'`，见 cordis `createTraceable`），所以服务内部能知道是谁在调它。拿 `@deepseek-ai/cordis` 实跑验证过，结果如下：

| 调用方 | `fiber.name` | `fiber.runtime.name` | fiber 链 |
|---|---|---|---|
| 引擎本体（根 context） | `root` | *undefined* | `[root, (anon)]` |
| 第三方插件直接调 | `dsh-plugin-foo` | `dsh-plugin-foo` | `[dsh-plugin-foo, (anon)]` |
| 插件加载的子插件调 | `foo-internal-child` | `foo-internal-child` | `[foo-internal-child, dsh-plugin-bar, ✗]` |

插件 `apply` 执行期间和之后（定时器回调里）结果一致，归因本身是稳定的。三个坑：

1. **根 fiber 没有 `runtime.name`**，只有 `fiber.name === 'root'`。想识别本体就得用 `fiber.name`。
2. **只取直接 fiber 名不够**。插件内部再 `ctx.plugin(...)` 时，拿到的是内部子插件名，不是那个 npm 包。
3. **`fiber.parent` 遍历会抛**。cordis 对未声明 inject 的属性访问报 `cannot get property "parent" without inject`，链走到某一层就断。必须 try/catch，且不能假设能走到根。

### 2.2 为什么不能按「谁」授权：一行就穿了

归因能分辨诚实的调用方，但**挡不住不诚实的**。同样实跑验证，拿三种手段去冒充引擎本体：

| 插件的写法 | `fiber.name` | 是否 === 本体的 fiber 对象 | 结果 |
|---|---|---|---|
| `ctx.iosNative.read()`（老实调用） | `dsh-plugin-evil` | no | 识别为插件 |
| `ctx.iosNative[Symbol.for('cordis.original')].read()` | `IosNative` | no | 识别为服务自己，非本体 |
| **`ctx.root.iosNative.read()`** | **`root`** | **YES** | **与本体真实调用完全同一** |

第三行是致命的：`ctx.root` 是 cordis 带文档注释的公开 API（"The root context of the application"），插件把 `ctx.` 换成 `ctx.root.` 就拿到了和引擎本体**同一个 fiber 对象**。不是"归因看起来像"，是真的分辨不出来——没有任何字段能区分。

**所以调用方身份不能当授权依据。** 一个"本体免授权、插件要授权"的设计，拦得住的只有不打算绕的插件；它给用户的是虚假的安全感，还要为此维护两条路径。

结论：**把本体和插件看成同一类调用方**。身份降级为**审计标签**（标明自报、不可信），授权主体改成「能力」本身——见 §4。

---

## 3. 能接什么，代价是什么

iOS 这些都是系统框架，和「控制其他 App」（做不到）不是一回事，技术上都可行。按「助理价值 ÷ 代价」排：

| 能力 | 框架 | Info.plist / 能力 | 代价与坑 | 建议 |
|---|---|---|---|---|
| **日历读写** | EventKit | `NSCalendarsFullAccessUsageDescription` | **读必须 full access**，而 full access 同时给了写（见 §4.0）。授权前 fetch 过的话，授权后要 `EKEventStore.reset()` | **第一期** |
| **提醒读写** | EventKit | `NSRemindersFullAccessUsageDescription` | 同上。和 DSH 自己的 todo / `dsh-schedule` 职责要划清（见 §4.4） | **第一期** |
| **本地通知** | UserNotifications | 无用途描述，只需运行期请求 | 最便宜的"提醒我"实现，不碰提醒 App | **第一期** |
| **运动 / 步数** | CoreMotion | `NSMotionUsageDescription` | `CMPedometer` 只给最近 7 天，再往前要 HealthKit | 第二期 |
| **健康读** | HealthKit | HealthKit capability（entitlement）+ `NSHealthShareUsageDescription` | **合规最重，见 §6.1**。读权限状态查不到（Apple 故意不给，防推断），只能"读到空"当没授权。逐类型授权 | 第二期，**要先决定做不做** |
| **位置** | CoreLocation | `NSLocationWhenInUseUsageDescription` | 粗/精粒度两档。后台定位别碰 | 第二期 |
| **通讯录读** | Contacts | `NSContactsUsageDescription` | 隐私敏感度高于日历（牵涉第三人），而且会被发给模型 | 第三期，谨慎 |
| **照片库** | PhotoKit | `NSPhotoLibraryUsageDescription` | 相机附件已有；照片库用系统 picker 比给智能体读权限更合适 | 用 picker，不要权限 |
| **健康写** | HealthKit | `NSHealthUpdateUsageDescription` | 写健康数据责任太大，且"不得写入虚假数据"是硬条款 | **不做** |
| **屏幕使用时间** | DeviceActivity | 需特批 entitlement | 家长控制专用，申请门槛高 | 不做 |

### 3.1 别漏了不需要隐私权限的那一批

上表全是要用户授权的。但对"个人助理"来说，有一批能力**不碰个人数据、不需要任何权限弹窗**，价值却不低——OpenMinis 把它们单独归类且永不设门（§9.2）：

| 能力 | 框架 | 权限成本 |
|---|---|---|
| 本地通知 / 闹钟 | UserNotifications / AlarmKit | 通知要运行期请求一次；AlarmKit 在 iOS 26 起要 `NSAlarmKitUsageDescription` |
| 天气 | WeatherKit | 无用户权限（需 Apple Developer 的 WeatherKit 配额） |
| 地图 / 打开 URL | MapKit / `UIApplication.open` | 无 |
| 朗读 / 语音合成 | AVSpeechSynthesizer | 无 |
| 设备信息（电量、型号、存储） | UIDevice 等 | 无 |
| 图像识别 / 自然语言 | Vision / NaturalLanguage | 无（纯本地计算） |

这批应该**优先做**：零授权成本、零合规风险、不需要本文的任何授权机制，而"提醒我 20 分钟后出门"、"今天要带伞吗"恰恰是助理最高频的请求。放进一期或单独一期都行。

另外两个和"助理"直接相关、但不属于本文的方向，先记一笔：

- **App Intents / 快捷指令**：把 dsh 暴露给 Siri 和快捷指令，是反方向（别人调我们）。价值很高，独立做。
- **HealthKit 后台投递**（`HKObserverQuery` + `enableBackgroundDelivery`）：数据变化时唤起智能体。等健康读稳定后再谈。

---

## 4. 授权模型

### 4.0 一个必须先知道的硬事实：iOS 的日历权限没有"只读"

iOS 17 起 EventKit 的权限是两档，**都不是只读**：

| 档位 | 能做什么 | 用途描述 key |
|---|---|---|
| write-only | 只能创建事件，**读不到任何东西**，连自己刚创建的也读不到 | `NSCalendarsWriteOnlyAccessUsageDescription` |
| full access | 读 + 写 + 删 | `NSCalendarsFullAccessUsageDescription` |

所以**要读就必须 full access，而 full access 同时把写和删也给了**。这条决定了下面整个模型：系统层面没有"让它看但不让它改"这个档，这件事只能由应用层自己兜。

（另有一个不需要任何权限的写入路径：`EKEventEditViewController`。见 §4.2。）

### 4.1 一层：iOS 系统权限就是唯一的门

决定：**系统权限给了之后，引擎本体和第三方插件直接可用，应用层不再设授权门。**

```
iOS 系统权限  →  授给宿主 App，一次，系统弹窗
                  给了之后：本体和插件都直接能用，不分调用方
                  要撤销：设置 → 隐私与安全性 → 日历 → Fish Pocket
```

理由：

- §2.2 已经证明按调用方授权守不住（`ctx.root` 一行就穿），所以插件专属的门本来就是假的。
- 合并之后剩下的"全 App 能力开关"**和系统权限重合了**。用户在系统弹窗上同意的就是"Fish Pocket 可以读我的日历"，App 里再放一个开关，是让他为同一件事表态两次——多数人会觉得是 bug，而不是保护。
- 省下 `CapabilityStore`、授权 sheet、开关页，第一期小到能在真机上尽快验证通道。

**代价，说清楚：**

| 丢了什么 | 实际影响 |
|---|---|
| App 内的一键关闭 | 要去系统设置关。好处是那里关掉是真关掉（系统级），比我们自己的开关更可信 |
| 读写分档 | 系统层面本来就没有（§4.0）。读写之分只能靠应用层——见 §4.2 |
| 插件可用性的事前决策点 | 只剩"装不装这个插件"。所以安装页的警告必须加重，见 §4.1.1 |

这个决定有参照：同类产品 OpenMinis 的权限档位默认值就是"不问直接用"（§9.1）。

**不可逆性要记一笔**：一旦发布成"插件无门槛可用"，以后再加门就是破坏性变更（已装的插件会突然失效）。便宜的保险是**现在就把形状留好**——所有调用都过 addon 里的同一个分发器，分发器里留一个 policy 判断点，一期恒定放行。将来要收紧，改那一处，不动任何调用方。

那个判断点的形状**按三档设计**，不要设计成布尔开关：`bypass`（默认）/ `askOnce`（本会话内问一次）/ `notAllowed`。这是 OpenMinis 的档位（§9.2），比开关实用——`askOnce` 读写都适用，而且用户收紧时不必在"全开"和"全关"之间二选一。一期只实现 `bypass` 这一档的行为，但判定函数的签名和存储键按三档来。

### 4.1.1 唯一的事前决策点：插件安装页

去掉应用层的门之后，用户能守住的边界只剩一个：**装不装这个插件**。所以这一处的文案必须加重。

现在插件安装确认的文案是「插件在本机以你的权限运行。请确认你信任它的来源」（`docs/webui/settings-plugins.md` 的 `installTrust`）。接入本机服务后补成：

> 插件在本机以你的权限运行，**包括你已授权的本机数据（日历、提醒…）**。请确认你信任它的来源。

这不是形式。它是整条链上唯一一次用户能在"代码进来之前"说不的机会。

### 4.2 能力（scope）划分

```
calendar.read          calendar.write
reminders.read         reminders.write
notifications.post
motion.read
health.read.<type>     # steps / sleep / heartRate / workout / bodyMass …逐类型
location.read.coarse   location.read.precise
contacts.read
```

这些**不再是授权单位**（授权只有系统权限那一层），而是：

- addon 分发器的分发单位，和工具的分组；
- §4.1 那个"留好形状"的 policy 判断点将来要认的键；
- 审计记录里的字段。

命名仍按读写分开，因为读写在应用层要区别对待（§4.3），而且健康要逐类型（"读健康"太粗，步数和心率不是一个量级）。

### 4.3 读写之分只能靠应用层，而写有三个方案

§4.0 说了：系统给的是 full access，读写一起来。所以"智能体能看我的日程但不会乱改"这件事，系统不管，只能我们自己兜。三条路：

| 方案 | 强度 | 代价 |
|---|---|---|
| **① 不提供写工具** | 一期的做法。引擎侧只注册读工具，没有写的入口 | 只防误用，不防恶意——插件能直连 addon（所以 addon 的能力白名单必须拦住未实现的写） |
| **② `EKEventEditViewController`** | **最强，且免费**。弹系统原生的事件编辑器、预填内容，用户点"添加"才落库。插件无法替用户点，不可伪造 | 只适合**新建**。改和删现有事件不适用（而且要先读到它）。批量会弹很多次 |
| **③ 原生一次性 grant** | 强。Swift 侧弹自己的确认框 → 签发一次性、绑定这次操作摘要、短时效的 grant，密钥只在原生侧 | 要自己做确认 UI；批量需要合成一次确认 |

②是这次查文档时的意外收获：`EKEventEditViewController` **完全不需要日历权限**就能让用户创建事件。对"帮我把周三下午两点的产品评审加上"这种最常见的助理场景，它同时解决了确认和权限两件事，而且用户看到的是系统界面，可信度最高。

倾向：**新建走②，改/删走③，一期只做读所以都不急**。确认框的信息层次见下。

### 4.3.1 确认框：把可信信息放主位

框里有两种信息，强度完全不同：

- **操作内容**不可伪造——它就是即将执行的东西（"在『工作』日历新建：周三 14:00 产品评审"）。
- **调用方**可伪造（§2.2）。

所以操作内容是主体、大字、完整列出；调用方只作辅助行，措辞不能暗示它验证过。写「来自：插件 foo（自报）」，不要写「插件 foo 请求」。

### 4.4 和引擎已有机制的关系

- **会话权限预设**：`read-only` 会话不得使用任何 `*.write` 能力，`workspace-write` 同样（本机服务不在工作区内）。只有 `full-access` 会话 + 已授权 + 当次确认，写操作才成立。实现上在 `tools/pre-execute` 里拦，或 `ctx.tools.restrict()` 直接把写工具从该会话的工具表里摘掉。
- **提醒 vs todo vs schedule**：三者不要互相同步，职责分开说清楚——DSH 的 todo 是**本轮任务清单**（给模型看的），`dsh-schedule` 是**定时触发 dsh 自己**，系统提醒是**给用户看的待办**。智能体可以把 todo 写成系统提醒，但不做双向同步（会打架）。
- **`when` 条件注册（引擎 0.2.2 新增）**：`ctx.tools.register(definition, { when })` 可以按步决定一个工具是否参与。将来做权限收紧时值得用上——没有系统权限时让工具**根本不出现在模型的工具表里**，比现在"工具总在、调用才报错"干净，也省掉模型一次无效调用和一轮解释。它不能替代 addon 里的判定（插件可以绕过 JS 层直连 addon），是模型侧的补充。
- **审批 UI**：写操作的确认**不复用**引擎已有的 `approval/request` waterfall，有两个原因。一是粒度：它只能说"工具 X 请求越权执行"，表达不了"要在『工作』日历新建周三 14:00 的产品评审"这种操作摘要，而摘要恰恰是确认框里唯一可信的信息（§4.3.1）。二是强度：它的决策结果回到 JS 侧，插件可以不等审批直接调 addon——**决策必须留在原生侧**才算护栏。所以写确认由 addon 同步等 `NativeBridge.swift` 的回调，不经 JS。

---

## 5. 实现路线

### 5.1 走 native addon（曾推荐 waterfall，被引擎的 allowlist 否掉了）

| | 做法 | 结论 |
|---|---|---|
| **A** | **native addon（ObjC），像 `dsh_git` / `dsh_image` 一样静态链进 App，引擎 `process._linkedBinding('dsh_ios_native')`** | **采用。** 同进程直连，与现有 addon 一致，有现成脚手架。**OpenMinis 走的也是这条** |
| B | Swift 起本地 HTTP 服务，引擎 `fetch` 调 | 备选。全 Swift 好写 UI，但要新开端口和认证，还反了现有方向（现在 Swift 是客户端） |
| C | 走已有的 `$events` waterfall：引擎发请求事件，Swift 执行并回结果 | **走不通**，见下 |

**C 为什么走不通**（查证 `@deepseek-ai/dsh@0.2.1-rc.4`）：

转发给客户端的 Host 事件是一张**硬编码 allowlist**——`dsh-api-remotes/lib/index.js` 里的 `API_REMOTE_FORWARDED_EVENTS`，注释写明它是"这个 allowlist 唯一的家"，`approval/request` 和 `user-questions/request` 都在里面。而 Gateway 只接受**唯一一个** Remote Event source。所以：

- 想加自己的 waterfall 事件 → 只能改引擎文件 → **`CONTRIBUTING.md` 明令禁止**（"不改引擎文件"）。
- 复用 `approval/request` → 只能返回 `allowed-once | rejected`，拿不到数据。
- 复用 `user-questions/request` → 语义是问用户问题，在原生界面会渲染成提问卡。
- 插件自己的 **stream RPC** 不受 allowlist 限制（`session/follow` 就是这么做的），但要用 TC39 装饰器声明，而我们的插件是无构建步骤的 `.mjs`，Node 24 不支持装饰器语法。

**选 A 的理由**（除了"C 不可行"）：

1. **不依赖原生客户端在线**。这是比 C 更强的地方：agent 在后台跑任务时想发一条通知，addon 直接就能发；C 则要求 Swift 的 WebSocket 还连着。
2. 不碰引擎的任何内部机制，不会因引擎升级而坏。
3. 脚手架齐全：`native/` 下已有三个 addon，`project.yml`、构建脚本、`process._linkedBinding` 的取用方式（`engine/runtime/git/binding.mjs`）都是现成样板。

**A 的两个代价，以及怎么处理：**

- **要写 ObjC。** 不可避免。`native/image/image.c` 是现成的 N-API 样板，照它的结构写 `.m`。
- **需要 UI 的操作怎么办**（授权弹窗、写确认）：addon 和 Swift 在同一个进程，ObjC 可以 `dispatch_async` 到主队列调用 Swift 的 `@objc` 单例，Swift 弹 UI，再用 N-API 的 ThreadSafeFunction 把结果送回 JS。**决策仍然留在 Swift**，所以 §5.3 的写侧强边界不受影响——JS 伪造不出 Swift 的确认结果，因为 addon 等的是 Swift 的回调。
- 由此得到一条**硬性实现约束**：**addon 的写操作 API 必须自带确认，不许提供绕过确认的变体。** `_linkedBinding` 对任何 JS 都可见，插件可以直接调 addon；这没问题（按 §4.1 的模型，它拿到的权限和老实调用一样），但前提是 addon 里没有一个"免确认写入"的后门。

### 5.2 组件

**引擎侧**（新增，放 `engine/plugins/ios-native/`，照 `plugins/sandbox-ios` 的写法）

```
engine/plugins/ios-native/
  index.mjs        # ✅ cordis 插件：注册 ctx.iosNative 服务 + 工具
  binding.mjs      # ✅ 取 process._linkedBinding('dsh_ios_native')，照 runtime/git/binding.mjs
  tools.mjs        # ✅ 各能力的 defineTool（零期三个，多了再拆成 tools/）
  caller.mjs       # ⬜ 归因，只为审计打标签（不参与判定，见 §2.2）——二期随审计一起做
```

（✅ = 零期已落地，⬜ = 待建。）

- 服务 `ctx.iosNative`：第三方插件 `ctx.inject(['iosNative'])` 后可用。
- 工具：给引擎本体用的那套（`device_info`、`notify`、`speak`、`calendar_list` …）。
- 在 `engine/ios.patch.yml` 的 `insert` 里加一行挂上。
- addon 不在（桌面开发机）时 `binding()` 返回 null，插件就不注册工具——和 `git` 在没有 addon 时"根本不是一个命令"一致。

**原生侧**

```
native/ios-native/
  dsh_ios_native.h          # ✅ 入口与各 caps_*.m 之间的内部接口
  DshNativeCapabilities.h   # ✅ 能力表的只读视图，给 Swift 用（不含 node_api.h）
  ios_native.m              # ✅ N-API 入口、能力表、分发、policy 判断点、TSFN 回复
  caps_device.m             # ✅ UIDevice：型号、系统版本、电量、低电量、热状态、存储
  caps_notify.m             # ✅ UNUserNotificationCenter：本地通知
  caps_speak.m              # ✅ AVSpeechSynthesizer：朗读
  caps_calendar.m           # ⬜ EventKit（一期）
  NativeBridge.swift        # ⬜ @objc 单例：需要 UI 的操作在主线程做（授权、写确认）

app/DshIOS/
  DshIOS-Bridging-Header.h      # ✅ 让 SwiftUI 读得到上面那张表
  Views/NativeCapabilitiesView.swift  # ✅ 设置 →「本机能力」：清单 + 系统授权状态
  Native/NativeAudit.swift      # ⬜ 每次调用记一条，用户可查
```

**能力清单只有一张表。** 设置页列的、N-API 分发用的、判定一次调用合不合法的，都是 `ios_native.m` 里那个 `CAPABILITIES` 数组：`DshNativeCapabilityList()` 是它的只读视图，经 bridging header 给 Swift。界面不许自己维护一份拷贝——两份清单迟早对不上，而对不上的那条缝就是绕过（§9.3）。页面的中文名和说明按能力 id 查，**查不到就显示 id**，所以原生加了能力而忘了加文案，页面会少个名字，但不会漏掉这项能力。

零期的 Swift 只有这一页：三个能力本身都不需要 UI。`NativeBridge.swift` 是一期（日历授权、写确认）才需要的那座桥。

**数据流**（以第三方插件读日历为例）

```
调用方（本体工具或第三方插件，走同一条路）
  ctx.iosNative.calendar.list({from, to})
  └─ caller.mjs：尽力归因 → callerClaim（只打标签，不判定）
  └─ binding().invoke('calendar.read', 'list', args, callerClaim)
       └─ addon（同进程，任意线程）
            ├─ 能力判定键 == 分发键，同一张表（§9.3 的教训）
            ├─ 系统权限 notDetermined → dispatch 到主线程请求（系统弹窗，文案来自 Info.plist）
            ├─ 系统权限 denied → 回 need-system-permission
            │                     （引擎转人话让智能体说出来；App 内给跳转入口）
            ├─ policy 判断点 ——— 一期恒定 bypass，是 §4.1 留的收紧位置（三档形状）
            ├─ 写操作 → dispatch 到 NativeBridge.swift 弹确认，等回调
            └─ 执行 EventKit → 记一条审计 → ThreadSafeFunction 回结果
  └─ 调用方拿到结果
```

一期没有我们自己的授权 sheet——系统弹窗就是全部。所以**那次弹窗的文案（Info.plist）承担了全部告知责任**，见 §6.2。

两个实现细节：授权前若已 fetch 过，拿到权限后要 `EKEventStore.reset()` 才读得到数据；系统权限一个 App **一生只弹一次**，拒绝后不再弹，只能引导去设置——所以别在用户还不知道发生什么的时候触发它。

### 5.3 安全边界的真实强度（必须讲清楚）

| 场景 | 实际强度 |
|---|---|
| 没给系统权限 | **挡住**，iOS 挡的，最硬的一道 |
| 用户想收回 | **能**，去系统设置关。系统级撤销，比我们自己的开关更可信 |
| 给了权限后，插件读日历 | **不拦**，这就是本方案的明确语义：权限给的是这个 App，含它装的任何插件。事前靠安装页警告（§4.1.1），事后靠审计（§5.4） |
| 插件冒充本体 | **不适用**。没有"本体专属"的权限可冒充，§2.2 那个攻击失去了目标 |
| 插件绕过 JS 网关 | **绕得过，但无所谓**。`_linkedBinding('dsh_ios_native')` 对任何 JS 可见，插件可以直连 addon——拿到的权限和老实调用完全一样（§4.1 的模型不按调用方分）。前提是 addon 里没有免确认的写后门 |
| 插件写/删日历（一期） | 引擎侧不注册写工具，但插件能直连 addon。**所以 addon 的能力白名单一期就要有**——不是授权门，是"没实现的操作一律不执行" |
| 插件写/删日历（二期起） | **挡住**。新建走 `EKEventEditViewController`（用户在系统界面上点"添加"才落库，插件替不了他点）；改删走一次性 grant（§4.3） |

一句话：**读的门就是 iOS 那一道，写的门在原生侧每次确认**。读侧不再假装有应用层粒度，省下的复杂度换成了"把唯一那次系统弹窗和唯一那个事前决策点做好"。

要做到按调用方的真隔离，得把第三方插件挪进独立 Worker / isolate 并代理它的全部 `ctx` 访问——`ctx.root` 这类逃逸口也得一并堵掉。那是引擎级改造，不在本文范围；如果 README 路线图里的「完善第三方插件支持」要往下做，这值得单列一项。

### 5.4 审计存哪

没有授权记录要存了（授权状态由 iOS 持有，`EKEventStore.authorizationStatus` 随时能问）。只剩审计：

```
audit: { capability, op, callerClaim, at, summary? }   # callerClaim = 自报的调用方，不可信
```

存原生侧（`UserDefaults` 够用，不含秘密）。**不要存引擎侧**：引擎侧的文件，插件自己就能改。

`callerClaim` 这个名字是故意的——在代码里就能看出它不可信，别让后来的人拿它做判定。审计是环形缓冲（留最近若干条，不是日志系统），写操作连操作摘要一起留，这样用户事后能看出"那个会议是谁删的"。

去掉能力开关之后，审计是用户**唯一**能看到"这个 App 碰了我哪些数据"的地方，所以它从"锦上添花"升级成了必要项。

---

## 6. 合规

### 6.1 HealthKit：能接，但要想清楚告知

Apple 对 HealthKit 数据有硬条款：不得用于广告或基于使用的数据挖掘，不得未经用户同意披露给第三方，不得写入虚假数据。

而这个 App 的事实是：**智能体读到的东西会发给模型服务商；第三方插件能联网。** 这两条和上面的条款撞得很正。

**但有参照说明这条路能走通**：OpenMinis 把 HealthKit **读和写都做了**（写的用例就是"拍一张饭的照片，把营养数据写进 Apple Health"）（§9.1）。所以下面这节原本的"建议一期不做"要降级为"**可以做，但要清楚自己在接什么**"——难的不是能不能接，是数据流向的告知。

如果要做健康读：

粒度上有个好消息：**HealthKit 的授权本来就是系统做的、逐类型的**，用户在系统界面上逐项勾选。这已经是比我们自己能做的任何开关都好的粒度，所以健康不需要应用层开关。

坏消息是"不让插件读健康"这件事**做不到**——理由和 §2.2 一样，应用层的调用方区分守不住。所以这是个二选一：

| 选项 | 含义 |
|---|---|
| **A. 不接 HealthKit** | 建议的第一期做法。日历 + 提醒 + 本地通知已经能撑起助理的主要场景，合规风险低一个量级 |
| **B. 接，并接受插件也能读** | 那么用途描述和 `PRIVACY.md` 必须写明这一点，让用户在系统弹窗前就知道 |

还有第三条路值得考虑：**C. 健康走"用户主动分享"，不做成工具。** 由用户在 App 里主动把健康摘要作为上下文发给智能体（像现在的相机附件那样——用户主动拍照，而不是智能体随时能开相机），引擎侧**不导出**健康服务、不注册健康工具。插件没有调用入口，智能体也不能主动查。代价是"昨晚睡得怎么样"这种主动询问要用户自己点一下。

无论走哪条，这几件照做：

- `NSHealthShareUsageDescription` 必须明说「这些数据会发给你选择的模型服务商」，不能只说"用于回答你的问题"（同 §6.2.1）。
- `PRIVACY.md` 要加一节讲健康数据的流向。

**建议：一期按 A（先把日历跑通），之后 B 和 C 都成立——B 有 OpenMinis 作参照，C 更稳。** 不再把健康当成"风险太大别碰"，而是"决定好告知方式再碰"。

### 6.2 清单与文案要同步改的地方

| 文件 | 改什么 |
|---|---|
| `app/project.yml` | 每个能力的 `NS*UsageDescription`；HealthKit 还要 capability / entitlement 和 `HealthKit.framework` |
| `app/DshIOS/PrivacyInfo.xcprivacy` | 现在 `NSPrivacyCollectedDataTypes` 是空的。日历/健康/位置/通讯录都属于要申报的类型（即使不离开设备，"发给模型服务商"也算 third-party 流向，要按实际情况申报） |
| `PRIVACY.md` | 新增一节：本机数据怎么被读、流向哪里、怎么撤销 |
| `engine/skills/ios-environment/SKILL.md` | 智能体靠它判断自己能做什么。新增能力必须同步，否则模型不知道有这些工具（`CONTRIBUTING.md` 已有此约定） |
| `docs/webui/parity.md` | 这是官方 Web 没有的能力，属于本项目自有扩展，在"有意与官方不同"里记一条 |
| `docs/webui/settings-plugins.md` | `installTrust` 文案按 §4.1.1 改 |

### 6.2.1 用途描述是唯一的告知渠道，所以文案是正事

一期没有我们自己的授权 sheet（§4.1），系统弹窗就是全部。那条弹窗上显示的就是 Info.plist 里的用途描述——它同时要满足两件事：**写得准确**，**用户据此作出知情决定**。

写「用于日历功能」会被打回，而且什么都没告知。草稿：

```
NSCalendarsFullAccessUsageDescription
  让智能体按你的要求查看和安排日程。为回答你的问题，相关日程内容会
  随对话发送给你选择的模型服务商。

NSRemindersFullAccessUsageDescription
  让智能体按你的要求查看和创建提醒。为回答你的问题，相关提醒内容会
  随对话发送给你选择的模型服务商。
```

**第二句是个产品选择，不是硬性要求**——这点要说清楚。OpenMinis 的同类文案只写了"让 AI agent 代你查询日程、查看空闲、创建事件"（句式统一为 *…so the AI agent can … on your behalf*），**没有提数据会发给模型服务商**（§9.1）。

所以：不写也行。写它的理由是另一个——这个 App 的数据流向和普通日历 App 不一样，用户有权在点"允许"之前知道，而不是去读没人会看的隐私政策。倾向保留第二句，但这是取舍，不是硬性要求。

（我们的文案要自己写，不照抄 OpenMinis 的——它是 GPL。）

（`NSCalendarsUsageDescription` 这个旧 key 只有链接 iOS 10–16 的 App 才需要；本项目 deployment target 是 17.0，不用加。）

---

## 7. 分期

| 期 | 内容 | 产出 |
|---|---|---|
| **零期** ✅ | 通道 + 不要权限的那批 | addon 骨架（N-API 入口、能力表、policy 判断点、ThreadSafeFunction 回复）、引擎插件与 `binding.mjs`、`device_info` / `notify` / `speak` 三个工具、设置 →「本机能力」页、`project.yml` 接入、SKILL.md 同步。**不碰任何授权机制**，用最低风险把整条链跑通 |
| **一期** | 日历读 | `caps_calendar.m`（读）、系统权限请求与被拒引导 + deep link、Info.plist 文案、`calendar_list` 工具、绕过测试（§9.3）、四份文档同步 |
| **二期** | 写 + 审计 | 新建走 `EKEventEditViewController`、改删走一次性 grant、审计记录与查看页 |
| **三期** | 提醒 + 本地通知 | `reminders.*`、`notifications.post`，与 todo / schedule 的职责划分写进 SKILL.md |
| **四期** | 插件可用 | 导出 `ctx.iosNative`、`caller.mjs` 归因打标签、安装页警告按 §4.1.1 改 |
| **五期**（待定） | 健康 / 运动 / 位置 | 先过 §6.1 的决定 |

去掉应用层授权后，一、四期都明显变轻：一期不用做 `CapabilityStore` 和授权 sheet；四期不再是"搭一套插件授权体系"，只是**把服务导出 + 改一句安装页文案**——插件和本体走的本来就是同一条路。

一期做完就能验证最关键的假设：**Node 线程发起 → Swift 执行 → 系统弹窗 → 结果回到智能体**这条链在真机上通不通。模拟器能过不代表真机能过（`CONTRIBUTING.md` 的既有教训）。

### 7.1 零期验证情况（2026-11-06，模拟器）

在 iPhone 17 Pro 模拟器（iOS 26.4）上把整条链跑通了：**引擎 Node 线程 → addon → iOS 框架 → 结果回到 JS**。

**验证过：**

| 项 | 结果 |
|---|---|
| addon 注册 | `process._linkedBinding('dsh_ios_native')` 拿到对象，`capabilities()` 返回三项能力 |
| 插件加载 | `pluginInventory/list` 里 `plugins/ios-native/index.mjs` 为 `enabled: true, phase: active` |
| `device.info` | 返回真实数据（iPhone、iOS 26.4、10 核、16.4 GB 可用、thermalState 0） |
| `speak.say` | 返回 `{speaking:true, characters:6}`，TSFN 回调路径通 |
| `notify.schedule` | 首次调用弹出系统通知授权弹窗（截图确认），授权后返回 id 与投递时间 |
| **能力表拦截** | `device.wipe` → "capability 'device' has no operation 'wipe'"；`healthkit.read` → "unknown capability 'healthkit'"。§9.3 要的那道闸两个方向都生效 |
| 引擎测试 | 106 项，0 失败（24 跳过）；合并 main 升级引擎到 0.2.2 后复跑 115 项，0 失败 |
| 设置 →「本机能力」 | 列出三项（清单来自 addon 的表），通知那行实时显示系统授权状态（截图确认为「已允许」） |

**没验证：**

- **真机**。模拟器不报电量（`batteryLevel` 返回 null，代码按未知处理），真机才有真值；通知投递、语音输出的实际效果也只有真机能确认。
- 通知**真正送达**（只验证了排程成功，没等 60 秒看横幅）。
- 朗读的**声音**（模拟器音频未核）。
- 这些工具**被模型调用**的完整回合（验证走的是 addon 直调，没有发真实对话）。
- 能力页的**「已关闭」状态**：`simctl privacy` 不支持 notifications，撤销不了通知授权，所以这一档只有代码逻辑，没实跑过。

**过程中发现的两个坑**（与本次改动无关，但会绊到下一个人）：

- `DSH_IOS_DEBUG` 在这次的 Debug 构建里没生效，`CONTRIBUTING.md` 说的 `<data>/debug/*.mjs` 调试通道没运行。绕过办法是 `SIMCTL_CHILD_DSH_IOS_DEBUG=1 xcrun simctl launch …`，但那次也没跑起来，原因未追。最后是直接改模拟器上已安装 bundle 里的 JS 加 `console.log` 验证的（`ctx.logger.info` 不进 `engine.log`，只有 `console.*` 经 main.mjs 的 stdout tee 落盘）。
- 授权弹窗未响应时被 `--terminate-running-process` 打断，会让后续请求直接拿到"已拒绝"。验证授权流程时别反复重启。

顺序上有一点要注意：**四期（插件可用）可以提前到任何时候**，因为它不依赖二期的写机制。如果想早点让插件生态动起来，一期完就能接四期；写操作的确认机制慢慢做。

---

## 8. 还需要定的事

1. **要不要先做零期**：§3.1 那批零权限能力（通知 / 闹钟 / 天气 / 朗读）先上，用最低风险把通道跑通。倾向：要。
2. **写操作第一版用哪个方案**：§4.3 的②（`EKEventEditViewController`，只能新建）够不够？还是一上来就做③（一次性 grant，改删也能管）。
3. **健康走哪条路**：§6.1 的 A（不接）、B（接，接受插件也能读，有 OpenMinis 作参照）还是 C（只做用户主动分享，不出工具）。
4. **用途描述要不要写"数据会发给模型服务商"**：§6.2.1——不是硬性要求（OpenMinis 就没写），是产品价值观选择。倾向：写。
5. **批量写的确认粒度**："把这周的会都挪到下午"要不要合成一次确认，列出全部变更？（倾向：要，单个 grant 绑定整批摘要）
6. **四期要不要提前**：一期完就让插件可用，还是等写机制齐了再开。

已经定了的：

- ~~第三方插件要不要单独授权~~ ——§2.2 证明"只给本体"技术上不成立（`ctx.root` 一行就穿），不是可选项。
- ~~App 内要不要能力开关~~ ——不要。系统权限就是唯一的门（§4.1）。代价和保险都记在那一节里，其中**addon 分发器里的 policy 判断点一期就要留**（按三档形状），否则将来收紧是破坏性变更。

---

## 9. 参考实现：OpenMinis

[OpenMinis](https://github.com/OpenMinis/OpenMinis)（iOS + Android，**GPL-3.0**）是同类产品里走得最远的：on-device agent，iSH 沙盒里跑 Alpine Linux，把 Health / Calendar / Reminders / Contacts / HomeKit / Clipboard / Location 等以工具形式交给 agent，**已经公开发布**。

> **许可证**：GPL-3.0，本项目是 MIT。按 `CONTRIBUTING.md` 的规矩，**只看思路，不拷代码**（文案也不抄）。下面是设计结论和可借鉴的教训，实现要自己写。

### 9.1 它印证了什么

| 我们的结论 | 它的做法 |
|---|---|
| 按能力授权，不按调用方（§2.2、§4.1） | 按 **offload 命令名**授权（`apple-healthkit`、`apple-calendar`…）。没有"本体 vs 插件"的概念 |
| 系统权限给了之后直接能用（§4.1） | 权限档位存 `UserDefaults`，读不到就是 `0`，而 `0 == bypass`——**默认就是不问直接用** |
| 原生侧是唯一执行点（§5.1 路线 A） | 所有 offload 由 native 分发，沙盒里的代码到不了框架 |
| 健康数据可以接 | HealthKit **读 + 写**都做了 |

### 9.2 它比我们的方案多出来的三个设计

**① 三档而不是开关。** `bypass` / `askOnce` / `notAllowed`，默认 `bypass`。
`askOnce` 是**按会话**授权：准过一次，这个会话内不再问，换会话重新问（没有会话上下文时落到一个 global 桶）。等待用户回答有 30 秒超时，**超时按拒绝**。

这比我们现在的"读无门、写每次确认"更细，而且 `askOnce` 同时适用于读和写。值得直接采纳：我们 §4.1 留的那个 policy 判断点，**形状就按这三档设计**，一期固定在 `bypass`，设置页以后再放出来——这样放出来时不用改任何调用方。

**② 按"是否碰个人数据"分类，只有碰的才给开关。**

- *privacy*（7 项，设置里可配）：healthkit / calendar / reminders / photos / location / homekit / clipboard
- *media*、*system*（13 项，永远 bypass，不进设置）：speak / speech / player / media / device / notification / alarm / open / maps / weather / nlp / vision

标准干净，直接可用：**不碰个人数据的能力不要给用户开关**，否则设置页会爆。顺带提醒我们 §3 漏了一批便宜又有用的东西——通知、闹钟、天气、地图、打开 URL、朗读，对"个人助理"价值不低，而且**不需要任何隐私权限**。

**③ 拒绝时给 agent 的是可操作的人话 + deep link。**
不是 `EPERM`，而是一句"用户关闭了 X，去设置 > 权限打开"外加一个 `minis://settings/permissions` 链接，agent 可以直接转述给用户点。我们有 `dsh://` scheme，照这个思路做。

### 9.3 最值得记的一条教训（它的 GH#242）

它的权限门曾被**一行路径**绕过：

- 门按 argv[0] 的**原始字符串**匹配命令名；
- 而 guest kernel 按 **basename** 分发（`strrchr`）；
- 于是 `/usr/local/bin/apple-healthkit` 在门那里匹配不到任何命令 → 返回 nil → 调用方把 nil 读成"这不是 offload 命令"→ **不检查直接放行**；kernel 照样按 basename 分发执行。
- 实机验证过：那个路径下是个 **0 字节占位文件**，却返回了真实的剪贴板 JSON——只可能是 native 分发干的。`Not Allowed` 也照样穿。

修复是让门用 kernel 的同一条规则。注释里那句话值得抄在墙上：

> 两套匹配规则 over 一个决定，一定会再次漂移。

**对我们的直接约束**，写进实现要求：

1. **能力判定用的键，必须就是分发用的那个键**，一张表，不许两张。
2. **检查点必须是唯一执行点**。addon 里碰 EventKit 的代码只有一处入口，不许为了方便再开一个"内部直调"的函数。
3. **要有测试钉住两个方向**：每种合法写法都被识别；不相关的名字不会因为"包含"注册名而继承它的权限。

它也诚实记下了没关掉的面：`sh -c '…'`、`env …`、脚本、子进程——这些情况命令名不出现在 argv[0]，门看不见。**我们的 addon 没有"命令名"这层间接**（收到的是结构化的能力 + 操作，不是一个要解析的 shell 字符串），所以这类拼写绕过从一开始就不存在——这是 addon 方案相对它那套 offload 命令的一个好处。

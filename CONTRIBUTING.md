# 参与贡献

欢迎提 issue 和 PR，中文或英文都可以。较大的改动请先开 issue 讨论方向。

## 开始之前

构建和运行见 [README](README.md#快速开始)。提交 PR 前请运行测试，首次运行要先构建 git addon：

```bash
scripts/build-git-addon.sh
```

```bash
(cd engine && npm ci && npm test)
```

测试在宿主机的 Node 24 上运行，git 测试会用系统的 git 对照输出。

iOS 部分的改动请至少在模拟器上跑一遍，并在 PR 里写明测过什么、没测什么。模拟器能创建进程而真机不能，涉及进程的改动要确认走的是模拟层，不能只看模拟器结果。

## 调试

- 引擎日志在 App 容器的 `Library/Application Support/dsh-ios/root/home/dsh/.ios/engine.log`。
- Debug 构建里，把导出 `default` 函数的 `*.mjs` 放进容器的 `Library/Application Support/dsh-ios/root/home/dsh/.ios/debug/`，引擎会执行它并写出 `*.mjs.out`。
- Debug 构建可以用 `-dshOpen drawer|workbench|approval|timeline|settings|plugins|store|schedules|signin|support` 直接打开页面。

## 约定

- **不改引擎文件：** 执行层只通过 cordis 服务替换（`ctx.subprocess`、`ctx.sandbox`）和 Node 层模拟适配，不改 `node_modules` 里的文件。
- **钉死依赖：** 依赖版本写死在 `engine/package.json` 和 `scripts/fetch-nodejs-mobile.sh` 里，后者带 sha256 校验。
- **git 输出和真 git 一致：** 改 `engine/runtime/git` 时，在 `engine/test/git/*.json` 里加场景，用宿主机 git 对照。
- **同步环境说明：** 执行层能用的命令有变化时，同步改 `engine/skills/ios-environment/SKILL.md`，Agent 靠它判断能做什么。
- **只移植能力：** 对齐官方 Web UI 时移植的是能力，不是网页的样子，交互按 iOS 习惯设计。取舍见 `docs/webui/parity.md`。

## 界面语言

原生界面用中文写，翻译放在 String Catalog [`app/Shared/Localizable.xcstrings`](app/Shared/Localizable.xcstrings) 里，源语言是 `zh-Hans`。目前有中文和英文，跟随系统语言，也可以在 App 设置页的「语言」里单独选，重启 App 后生效。它和系统「设置 → Fish Pocket → 语言」写的是同一个设置，系统那一项只在系统语言列表里有两种以上语言时才出现。加语言时同步在 `AppLanguage.choices` 里加上它。都不匹配时显示英文。

- **写界面文字：** 代码里直接写中文。`Text("设置")`、`Button("取消")` 这类 SwiftUI 字面量会自动进 Catalog；先存成 `String` 再显示的文字要写成 `String(localized: "…")`，不然不会被翻译。
- **只翻界面：** 日志、注释和发给 Agent 的提示词不翻译。
- **专业名词跟官方走：** 插件、审批、计划模式、子智能体这类名词，以及和官方 Web UI 意思相同的句子，优先用官方 Web UI 的译法。官方词典在 `@deepseek-ai/dsh-client-ui-*` 各包的 `lib/client.js` 里（MIT），已有 zh、en、ja、es、fr、de、ru、pt 八种。
- **引擎给的文字不用翻：** 插件说明、配置项描述这类 `{en, zh, …}` 文字按界面语言取（`AppLanguage`），没有对应语言时用英文。
- **定时任务的规则描述**（「每天 9:00」这类）是从官方 `dsh-client-ui-schedule` 移植的词典，在 `app/DshIOS/Views/ScheduleCron.swift` 的 `ScheduleText` 里，不在 Catalog 中。

**加一种语言：**

1. 在 `app/project.yml` 的 `CFBundleLocalizations` 里加上语言代码（如 `es`），再运行 `xcodegen generate`。
2. 在 `Localizable.xcstrings` 和 `app/DshIOS/InfoPlist.xcstrings` 里给每条字符串加这个语言的译文，`state` 写 `translated`。Catalog 是 JSON，没有 Xcode 也能编辑。
3. 在 `ScheduleText` 里照 `en` 加一张这个语言的表，内容取官方 `dsh-client-ui-schedule` 里同名的词条。
4. 运行 `node scripts/strings-coverage.mjs es` 查漏翻的字符串。

在 Xcode 里构建后，新写的界面文字会自动出现在 Catalog 里。不用 Xcode 时，在 Mac 上可以运行 `scripts/sync-strings.sh` 同步。

## 许可证

提交贡献即表示你同意以 [MIT](LICENSE) 协议授权你的贡献，并确认你有权这样做。

- **不要拷贝 AGPL 或 GPL 代码**，比如 DSH Go。需要参考时只看思路和协议，自己实现。
- **libgit2 只能原样链接**，不改它的源码。需要的行为放在 `native/git` 或构建参数里。
- 引入新依赖或第三方代码时，同步更新 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 隐私

提交前请确认没有带上密钥、token、个人邮箱、本机绝对路径、内网地址或设备标识。日志和截图也一样。

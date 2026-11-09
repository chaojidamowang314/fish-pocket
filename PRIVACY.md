# 隐私政策 / Privacy Policy

生效日期 / Effective: 2026-11-05

[中文](#中文) · [English](#english)

## 中文

Fish Pocket 是独立的开源社区项目，与深度求索（DeepSeek）不存在隶属、合作、授权或背书关系。

**我们不收集你的数据。** 开发者不运营任何服务器，收不到你的对话、文件、账号或使用情况。App 里没有广告、分析或第三方追踪 SDK，官方客户端的会话日志上传、消息评价、反馈和使用分析在这个版本里都已关闭。

### 保存在你设备上的内容

会话、工作区文件、设置和模型服务商的凭证都只保存在你的设备上。删除 App 会删除这些内容。

小组件要显示的会话标题、状态和当前工作区名称，由 App 写进设备上 App 与小组件共用的存储空间，同样不会离开设备。设备锁定时标题会被打码，也可以在 设置 → 小组件 里关掉标题。

你授权过的本机数据（日历、提醒事项）不会被 App 另存一份，每次用到都是现读。增、删、改默认直接执行，不会每次问你——想让它每次停下来问，或者干脆设成只读，都在侧边栏的「本机能力」里按项设置。App 只在本机留一份使用记录：哪项能力、什么操作、什么时候、调用方自报的名字，最近若干条，可以在同一页里查看和清空。

### 会发送到第三方的内容

以下连接都是你使用相应功能时才发生，数据直接发给对方，不经过我们：

- **模型服务商：** 你发送的消息、附件，以及智能体为回答你而读取的文件内容、命令输出和本机数据（你授权之后的日历、提醒事项，以及机型电量这类设备状态），都会发给你选择的模型服务商（默认是 DeepSeek，也可以配置其他服务商）。使用 DeepSeek 官方服务时，请求还带有 App 在本机生成的匿名 ID 和会话 ID。这些数据如何处理，由服务商的隐私政策决定。
- **DeepSeek 账号：** 选择账号登录时，登录在 DeepSeek 的官方页面完成，App 读不到你的账号和密码，只保存授权令牌用于调用模型和查询余额。
- **插件：** 打开插件市场时，App 会访问索引源里列出的地址，默认是 `api.dshfind.com`，并从索引指定的地址加载插件图标，目前是 GitHub。查看插件说明时会访问 npm 文件 CDN 或插件的代码仓库，安装插件时会访问 npm 仓库。这些请求不含你的对话或文件，但对方能看到你的 IP 地址。已安装的插件和智能体运行的命令可以按你的操作访问网络。
- **内置浏览器：** 你访问的网站会收到常规的网络请求。
- **更新检查：** App 会向 Apple 和 GitHub 查询最新版本，请求里不含你的个人信息。

### 儿童

本 App 不面向 13 岁以下的儿童。

### 政策变更与联系方式

政策变更会更新在这个页面。如有问题，请在 [GitHub](https://github.com/imsai-sh/fish-pocket/issues) 上提问。

## English

Fish Pocket is an independent open-source community project. It is not affiliated with, authorized by or endorsed by DeepSeek.

**We do not collect your data.** The developer runs no servers and receives none of your conversations, files, account details or usage information. The app contains no advertising, analytics or third-party tracking SDKs, and the official client's session log upload, message ratings, feedback and usage analytics are turned off in this build.

### What stays on your device

Sessions, workspace files, settings and model provider credentials are stored only on your device. Deleting the app deletes this data.

For the widgets, the app writes session titles, their status and the current workspace name to storage on your device shared by the app and its widgets; this also never leaves the device. Titles are hidden while the device is locked, and you can turn them off in Settings → Widgets.

Device data you have allowed (Calendar, Reminders) is never copied into the app’s own storage; it is read fresh each time it is used. Adding, changing and deleting go ahead without asking by default; you can set any capability to ask every time, or to read-only, under Device capabilities in the sidebar. The app keeps one local record of that use — which capability, which operation, when, and the name the caller gave for itself — for the most recent entries only. You can read and clear it on the same screen.

### What is sent to third parties

These connections happen only when you use the related feature, and the data goes directly to that party, not through us:

- **Model providers:** Your messages and attachments, along with file contents, command output and device data the agent reads to answer you (your Calendar and Reminders once you have allowed them, and device state such as model and battery), are sent to the model provider you choose (DeepSeek by default, and other providers can be configured). Requests to DeepSeek's official service also carry an anonymous ID generated on your device and a session ID. How this data is handled is governed by the provider's privacy policy.
- **DeepSeek account:** If you sign in with an account, sign-in happens on DeepSeek's own page. The app cannot read your credentials and stores only an authorization token used to call models and check your balance.
- **Plugins:** Opening the plugin market contacts the addresses in your index sources, `api.dshfind.com` by default, and loads plugin icons from the addresses the index gives, currently GitHub. Viewing a plugin's documentation contacts npm file CDNs or the plugin's repository, and installing a plugin contacts the npm registry. These requests do not contain your conversations or files, but those services can see your IP address. Installed plugins and commands run by the agent can access the network as you direct them.
- **Built-in browser:** Websites you visit receive ordinary network requests.
- **Update check:** The app asks Apple and GitHub for the latest version. These requests contain no personal information.

### Children

This app is not directed at children under 13.

### Changes and contact

Changes to this policy are posted on this page. For questions, open an issue on [GitHub](https://github.com/imsai-sh/fish-pocket/issues).

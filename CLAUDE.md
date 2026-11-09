# Fish Pocket 开发说明

## 「新功能」弹窗：每次发版怎么更新内容

用户升级后第一次打开 App，会弹出一个「新功能」页面；设置 → 关于 → 新功能 也能再看。内容全部写在 `app/DshIOS/Core/WhatsNew.swift` 的 `releases` 里，弹出逻辑不用改。

### 加内容

`releases` 按从新到旧排列，新条目加在最前面。

- **新版本**：加一条 `Release(version: "1.2.0", features: [...])`。`version` 要和 `app/project.yml` 里的 `MARKETING_VERSION` 一致。App 还没到这个版本时条目不会显示，所以可以提前写。
- **同一版本的后续 build 又加了功能**（比如 TestFlight）：再加一条 `Release(version: "1.1.0", build: 20, features: [...])`。`build` 写第一个带这些内容、实际打包用的 build 号，`features` 里只写这次新增的。
- **只修 bug 的版本**：不加条目，也就不会弹。

每条 `Feature` 由三部分组成：一个 SF Symbol、一句标题、一行说明。只写用户能感知到的亮点，一次 3～5 条，不要写成修复列表。

### 文案翻译

标题和说明先写中文，然后：

1. 跑 `scripts/sync-strings.sh`，把新文案同步进 `app/Shared/Localizable.xcstrings`。
2. 给新词条补上 `en`、`es` 翻译。
3. 跑 `node scripts/strings-coverage.mjs`，确认各语言都是全覆盖。

同步脚本有时会顺带改动其他旧词条，提交前看一下 diff，只保留这次自己加的部分。

### 弹出规则（已经实现，了解即可）

- 新装用户不弹。从 1.0.x 升级的老用户靠本地已有的设置识别，会弹。
- 同一个版本、同一个 build 只弹一次。决定弹出的那一刻就记为已看过，用户点「继续」、点 ✕、下滑关掉或直接杀掉 App，都不会再弹。
- 升级到某个版本时，这个版本下所有没看过的条目会合并成一次显示。
- 只有看过这个版本之后，后续 build 又加了条目，才会再弹，而且只弹新增的部分。这时版本胶囊里带上 build 号，比如「版本 1.1 (20)」，表明是新 build 的内容，不会让人以为是重复提醒。

### 注意

- 已经发出去的条目，不要改它的 `version` 或 `build`，否则看过的人可能会再弹一次，或者有人会漏看。
- 本地自测用 Debug 版的启动参数：`-dshVersion 1.1.0 -dshBuild 20` 让 App 当成这个版本和 build 运行；`-dshOpen whatsnew` 直接打开弹窗。这些参数只在 Debug 版里生效。

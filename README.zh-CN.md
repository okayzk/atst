<div align="center">

<img src="Resources/AppIconSource.png" alt="atst" width="128" height="128" />

# atst

**a(i)-text-select-translate** — macOS 菜单栏轻量翻译工具

`a`(i) · `t`ext · `s`elect · `t`ranslate

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)](#要求)
[![Version](https://img.shields.io/badge/version-v0.5.0-blue)](https://github.com/okayzk/atst/releases/latest)
[![License](https://img.shields.io/badge/license-Apache--2.0-orange)](./LICENSE)

按下快捷键，立刻得到翻译。内置 Google + Microsoft + DeepL 接口**开箱即用**；配置自己的 AI 模型后还能解锁词典级释义、IPA 音标和智能解释。

[English](./README.md) · [安装](#安装) · [使用](#使用) · [功能](#功能)

</div>

---

## 亮点

- ⚡ **一键划词翻译** — 在 macOS 任何应用里选中文本，按 `⌥D`，~200ms 出结果；`Esc` 关闭
- 🔁 **反向翻译** — 选中的文本已经是目标语言时，自动改译成第二目标语言（默认中英互译）
- ⌨️ **手动输入翻译** — 没选中文字时按 `⌥D` 会出现输入框，输入 / 粘贴即可；翻译后原文保留在译文上方，点一下就能重新编辑再翻
- 🖼️ **截图翻译** — 按 `⌥S` 框选区域即可翻译。默认走本地 Vision OCR（快 + 隐私 + 免费）；OCR 找不到文字时自动 fallback 到 AI 视觉
- 🔀 **多源并列对照** — Google、Microsoft 和 DeepL 结果显示在上方，AI 结果在下方；每条结果都能单独切换服务或折叠
- 🧠 **AI 词典模式** — 单词查询能返回多个义项、IPA 音标、用法解释
- 📖 **查词** — 单词和固定搭配显示独立词典卡片，包含英美音标和发音播放、分组释义、双语例句和相关词组；主源为有道，macOS 内置词典作为离线兜底，词典命中时默认跳过翻译
- 📌 **固定为便签** — 把翻译结果钉成悬浮便签；便签保留单条结果的切换、折叠和原文编辑，也能取消固定回到普通浮窗
- 💾 **本地缓存** — 重复查询命中 JSON 缓存，按 provider 分别缓存，TTL 和容量上限可配
- 🫧 **原生 Liquid Glass** — 支持的 macOS 26+ 环境会让翻译浮窗和固定便签使用 Liquid Glass；旧系统自动回退到原来的材质
- 🪶 **体积小** — DMG 约 2 MB，安装后约 4 MB。纯 Swift/AppKit，无 Electron / Web 视图
- 🌐 **双语界面** — 根据系统语言自动切换中文 / 英文，也支持手动指定
- 🆓 **零配置即用** — 不填 API key 也能用（内置 Google + Microsoft + DeepL）；想要更丰富的输出再接 OpenAI 兼容接口

---

## 截图

<details>
<summary>点击展开</summary>

<br />

![翻译浮窗](docs/screenshots/tooltip-1.png)

![翻译浮窗](docs/screenshots/tooltip-2.png)

![设置页](docs/screenshots/settings.png)

</details>

---

## 安装

### 下载最新版本

1. 在 [Releases 页面](https://github.com/okayzk/atst/releases) 下载最新的 `atst.dmg`
2. 打开 DMG，把 **atst** 拖到 `应用程序` 文件夹
3. 启动 atst — 菜单栏右上角会出现 **`atst`** 字样
4. 首次启动时 atst 会请求 **辅助功能** 权限——没有它全局快捷键无法工作。点 **打开系统设置**，在 隐私与安全性 → 辅助功能 里打开 atst。错过了对话框？点菜单栏的 atst 字样，用权限行右侧的齿轮按钮
5. 可选：在通用设置里打开 **登录时自动启动**

> **提示**：因为 atst 还没拿 Apple 开发者签名，首次启动可能提示"无法打开，因为它来自身份不明的开发者"。右键应用 → **打开** → **仍要打开**，或一次性运行 `xattr -d com.apple.quarantine /Applications/atst.app` 即可。每个版本都会重新签名，升级后 macOS 可能再次要求授权辅助功能。

### 从源码构建

需要 **macOS 14+** 和 **Swift 5.9+**（Xcode 15 或 Command Line Tools）。

```bash
git clone https://github.com/okayzk/atst.git
cd atst

# 快速调试运行
swift run atst

# 打包成 .app（带图标 / Info.plist / 代码签名）
bash Scripts/build-app.sh
open .build/atst.app

# 打包成 DMG 安装包
bash Scripts/build-dmg.sh
open .build/atst.dmg
```

---

## 使用

### 快捷键

| 快捷键 | 动作 |
|---|---|
| `⌥D` | 翻译当前选中的文本；没选中文字时打开输入框 |
| `⌥S` | 截图选区并翻译其中文字 |
| `Esc` | 关闭浮窗 |

两个翻译快捷键都能在 **设置 → 快捷键** 里改。

### 翻译浮窗

header 显示检测到的源语言和目标语言（例如 `英语 → 简体中文`）。下方是一段或两段内容：

- **上方 — API 翻译结果**（Google / Microsoft / DeepL）：快、免费、无需 key；每行都能在标题处切换到其他已启用服务，或折叠隐藏
- **下方 — AI 翻译结果**（如果启用）：包含多义、音标、技术术语解释等丰富信息

每行右侧有独立的复制按钮。整个浮窗 **拖动 header 可以移动位置**；按 `Esc` 或点击外部关闭。点击 header 的 📌 图标可以固定成便签。便签保留同样的切换、折叠和原文编辑控件；标题栏的取消固定按钮会把它变回普通浮窗，× 则直接关闭。

每条结果的标题右侧还有一个 **切换按钮**（列出当前未使用的其他已启用服务）和一个 **折叠箭头**。折叠只是隐藏该行，不会重新翻译。

某个翻译源连续失败 3 次（网络被墙、接口挂了）后，它那一行会折叠成一行小字并带一个 **停用** 按钮，不再每次刷红。

### 词典卡片

英文单词或短固定搭配（最多 4 个词）会在 API 结果上方显示词典卡片，包含带播放按钮的英美音标、按词性分组的释义、双语例句、常用词组和相关词。主源是有道免 key 网页词典；失败时会回退到 macOS 内置的「牛津英汉汉英词典」（仅单词）。默认情况下词典命中会替代该次查询的 API/AI 结果；关闭查词设置里的「有词典释义时不调用翻译」后，词典和翻译结果会同时显示。点音标旁的喇叭即可播放发音：有道有音频时用有道，否则用系统 `en-GB` / `en-US` 语音。

### PopClip 扩展

仓库在 [`PopClip-plugin/`](PopClip-plugin/) 里附带了一个 [PopClip](https://www.popclip.app/) 扩展：选中文本后点 PopClip 栏里的 **atst**，翻译浮窗会在鼠标位置打开。

1. 先安装打包好的 atst `.app`（`atst://` URL scheme 声明在 app bundle 里，`swift run` 不会注册）。
2. 双击 `PopClip-plugin/atst.popclipext`，按 PopClip 提示安装。本地未签名构建如果被 PopClip 拦截，先执行 `defaults write com.pilotmoon.popclip LoadUnsignedExtensions -bool YES`。
3. 确认 atst 里至少启用了一个翻译 provider。

扩展只负责打开 `atst://translate?text=<选中文本>`；atst 复用原有的划词翻译流程（多 provider、缓存、反向翻译）。打包和图标重新生成见 [`PopClip-plugin/README.md`](PopClip-plugin/README.md)。

### 反向翻译

选中的文本已经是目标语言时，atst 会改译成 **第二目标语言**——目标是中文时，选中中文照样能得到英文。两个语言都在通用设置里选。

### 翻译方式设置

点击菜单栏的 **`atst`** 字样打开设置面板。

通用页放目标语言 / 第二目标语言、登录自启动、快捷键、截图 OCR 和缓存选项，以及三个翻译方式开关：

- ☑️ **API 翻译**（默认开启）— Google + Microsoft + DeepL，零配置
- ☐ **AI 翻译**（默认关闭）— OpenAI 兼容接口，在 AI 子页配置 base URL / key / model
- ☑️ **查词**（默认开启）— 为单词和短固定搭配显示词典卡片，主源有道，macOS 系统词典作为离线兜底

API 子页每个 provider 名称后都有一个可达性圆点，打开页面时自动检测；AI 子页 Timeout 下方的 **测试** 按钮会发一条极小请求，按钮文字旁显示检测结果。

API 子页还有可选的 **回退** 开关：某个 provider 失败或不可达时，自动把其余已启用的 API 服务加入同一次翻译；失败的 provider 仍会显示错误，不会被隐藏。

**查词** 子页显示来源状态、macOS 词典的测试按钮、**手动下载** 指引（打开 Dictionary.app 并列出安装「牛津英汉汉英词典」的步骤）、1–4 个词的查词上限，以及默认开启的 **有词典释义时不调用翻译** 开关。

**默认翻译服务**用来选择每次新翻译实际调用的服务，可多选；未勾选的服务仍可在单条结果的标题菜单里随时切换。

#### AI 配置（可选）

进入 **AI 翻译** 子页：

- **Base URL** — 任何 OpenAI 兼容接口，例如 `https://api.openai.com/v1`、`http://localhost:11434/v1`（Ollama）、`https://generativelanguage.googleapis.com/v1beta/openai/`（Gemini OpenAI 兼容层）
- **API Key** — 本地保存在 `~/Library/Preferences/dev.local.atst.plist`
- **翻译模型** — 划词翻译用的模型名（如 `gpt-4o-mini`、`qwen2.5:7b`）
- **截图模型** — Vision OCR 关闭时用的视觉模型（如 `gpt-4o`、`claude-3.5-sonnet`）
- **超时** — 单次 AI 请求的空闲等待上限（Google / Microsoft 固定 15 秒，DeepL 20 秒）
- **音标** — 给单词查询追加 IPA
- **智能注释** — 添加词典风格的释义块（习语、专有名词定义等）
- **翻译提示词** — 系统提示词和智能注释提示词完全可编辑

#### 截图 OCR 设置

通用页 **截图** 区域控制 `⌥S` 的行为：

- ☑️ **使用 Vision OCR**（默认开启）— 用 macOS Vision 在本地识别文字（**完全不需要 AI**），再交给翻译 provider
- ☐ 关闭 **Vision OCR** — 直接把截图发给 AI 视觉模型

下方的 chip 行可以增删识别语言。默认：简体中文 + 英文 + 日文。

---

## 功能

### 翻译 provider 对比

| Provider | 需要 key | 免费 | 流式 | 多义 | 音标 | 智能解释 |
|---|---|---|---|---|---|---|
| Google（内置） | ❌ | ✅ | — | ❌ | ❌ | ❌ |
| Microsoft（内置） | ❌ | ✅ | — | ❌ | ❌ | ❌ |
| DeepL（内置） | ❌ | ✅（单次 1500 字符） | — | ❌ | ❌ | ❌ |
| OpenAI 兼容 | ✅ | 看接口 | ✅ | ✅ | ✅ | ✅ |

### 其他细节

- **智能浮窗定位** — Web 风格的 flip 算法；浮窗永远不会被推到屏幕外，也不会盖住你选中的内容
- **词典卡片** — 英文单词和短固定搭配显示英美音标、发音、分组释义和双语例句；默认命中词典时跳过 API/AI 翻译，查词设置页管理来源、系统词典下载指引和词数上限
- **自适应玻璃表面** — macOS 26+ 与 Swift 6.2+ 构建下使用原生 Liquid Glass；更早的 macOS 继续使用 AppKit `NSVisualEffectView` toolTip 材质
- **缓存统计** — 显示缓存条目数和占用磁盘大小，一键清空
- **无法翻译识别** — 专有名词 / 品牌名 / 拼写错误会标识 🔘 并跳过缓存
- **外观** — 自动 / 浅色 / 深色，全局生效

---

## 系统要求

- macOS **14.0**（Sonoma）及以上
- **Apple Silicon** — 发布的 DMG 只编了 arm64。Intel Mac 请从源码构建（见上文）
- 本地缓存占用几 MB 磁盘
- AI 功能：任何 OpenAI 兼容接口（付费或本地 LLM 均可）

---

## 隐私

- atst 是 **纯本地应用**。无遥测、无埋点、无崩溃上报。
- 翻译时只有你触发的那段文字会发送给你启用的翻译源（Google / Microsoft / DeepL / 你的 AI 接口）；启用查词时，单词或短语也会发送到有道。macOS 系统词典查询完全在本机完成。浮窗 header 的语言识别和反向翻译判断都在本机完成。
- 翻译之外的网络请求：每次启动向 `api.github.com` 查一次新版本（最多 4 小时一次）；按下快捷键修饰键时向已启用的翻译源发一个很小的连接预热请求；有单词/短语查词时向有道发一次词典请求；点击发音按钮时向有道发一次音频请求。
- 翻译缓存保存在 `~/Library/Caches/dev.local.atst/translations.json`，词典缓存保存在同目录的 `dictionary.json`，设置保存在 `~/Library/Preferences/dev.local.atst.plist`，随时可删除。
- 诊断日志写在 `/tmp/atst.log`，里面包含被翻译文本的开头几个字，随时可删。

---

## 排障

- **快捷键没反应** — 辅助功能未授权（点菜单栏的 atst 字样，权限行会是橙点），或者别的 App 开了 macOS 安全键盘输入（1Password 自动填充、Terminal 的 Secure Keyboard Entry、密码输入框获得焦点）；这种情况下设置面板会显示警告。
- **截图翻译没结果** — 先看屏幕录制权限，再打开 `/tmp/atst-last-screenshot.png` 看实际截到了什么。
- **报 bug** — 附上 `/tmp/atst.log`（超过 ~1 MB 会轮转到 `/tmp/atst.old.log`）。
- **脚本化配置 AI** — 这些环境变量会在单次运行中覆盖保存的设置：`ATST_AI_BASE_URL`、`ATST_API_KEY`、`ATST_TEXT_MODEL`、`ATST_SCREENSHOT_MODEL`、`ATST_TARGET_LANGUAGE`。

---

## License

Apache 2.0 — 详见 [LICENSE](./LICENSE)。

## 致谢

- macOS [Vision framework](https://developer.apple.com/documentation/vision) 提供 OCR 能力
- OpenAI Chat Completions 协议 —— 几乎所有现代 LLM 接口都兼容
- **原项目** — [atst](https://github.com/itaober/atst) 由 [@itaober](https://github.com/itaober) 开发；本仓库是在其基础上的二次开发，原始架构和核心翻译流程归原作者所有。
- 使用 [DeepSeek](https://www.deepseek.com/) 辅助开发。

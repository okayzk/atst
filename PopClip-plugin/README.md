# atst PopClip 扩展

选中文本后，在 PopClip 里点一下 **atst**，即可把文本交给 [atst](https://github.com/okayzk/atst) 翻译，浮窗会出现在鼠标附近。

## 工作方式

PopClip 的 URL Action 会把选中文本填入模板并自动做 URL 编码，然后打开：

```
atst://translate?text=<URL-encoded selection>
```

atst 通过 Info.plist 中注册的 `CFBundleURLTypes`（scheme：`atst`）接收该 URL，复用现有的划词翻译流程（同样的多 provider、缓存、反向翻译与浮窗 UI）。这个 scheme 只在打包后的 `.app` 中生效，`swift run` 不会注册它。

## 安装

1. 安装 atst 的 `.app` 版本（从 DMG 拖进「应用程序」，或本地执行 `bash Scripts/build-app.sh` 后打开 `.build/atst.app`）。
2. 双击 `atst.popclipext`，按 PopClip 的提示安装扩展。
   - 扩展未签名时 PopClip 会显示安全警告。本地开发可先执行
     `defaults write com.pilotmoon.popclip LoadUnsignedExtensions -bool YES`，
     再双击安装。
3. 打开 atst，确认至少启用了一个翻译 provider。

## 目录结构

```
PopClip-plugin/
├── atst.popclipext/
│   ├── Config.yaml   # PopClip 扩展配置
│   └── icon.png      # 512×512 单色图标
├── make-icon.swift   # 重新生成 icon.png
└── package.sh        # 打包成 atst.popclipextz
```

## 开发

```bash
# 重新生成图标
swift PopClip-plugin/make-icon.swift

# 打包成可分发的 .popclipextz
bash PopClip-plugin/package.sh
```

修改 `Config.yaml` 或图标后，需要重新安装扩展：在 PopClip 中删除旧扩展，再双击 `.popclipext`。

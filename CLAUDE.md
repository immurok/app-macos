# app-macos/（macOS App）

从根 `CLAUDE.md` 拆出，只在处理 `app-macos/` 下的文件时加载。项目全局约定见 `../CLAUDE.md`。

## App 部署
**重要**：复制编译产物到 App bundle 时，必须使用 Info.plist 中 `CFBundleExecutable` 指定的名称：

```bash
# 正确 ✓ - 可执行文件名必须是 "immurok"（与 Info.plist 一致）
cp .build/release/immurokApp immurok.app/Contents/MacOS/immurok

# 错误 ✗ - 保留原名会导致启动旧版本
cp .build/release/immurokApp immurok.app/Contents/MacOS/immurokApp
```

## PAM 模块 (macOS)
```bash
cd app-macos/pam
make                         # 编译 pam_immurok.so
sudo cp pam_immurok.so /usr/local/lib/pam/   # /usr/lib 受 SIP 保护不可写
```

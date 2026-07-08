# AuthProbe.app — 密码框检测测试工具

在不同 Mac / macOS 版本上验证:当 **Passwords.app 解锁** 或 **App Store 付款认证** 出现时,
immurok 能否用 **Accessibility** 精确定位到密码输入框(`AXSecureTextField`)。只用辅助功能权限,
不需要屏幕录制 / OCR。

## 构建

```bash
./build-app.sh
```

产物 `AuthProbe.app` 是通用二进制(Intel + Apple Silicon 都能跑),ad-hoc 签名。

## 在测试机上运行

1. 把 `AuthProbe.app` 拷到目标 Mac。
2. 首次打开若被 Gatekeeper 拦(“无法验证开发者”):**右键 → 打开**,或先执行
   `xattr -dr com.apple.quarantine /路径/AuthProbe.app`。
3. 首次运行会请求辅助功能权限 → 到 **系统设置 ▸ 隐私与安全性 ▸ 辅助功能** 勾选 **AuthProbe**,
   然后**重启本程序**。
4. 窗口显示“监控中”后:
   - 打开 **Passwords**(锁定状态)触发解锁,或
   - 打开 **App Store** 点某个 app 的“购买/获取”,走到输密码那步,或
   - **Safari** 点开某网站登录框、触发密码 AutoFill 的 sign in 窗口(焦点进入密码框即会被捕获)。
5. 检测到即弹对话框,报告:
   - ✅ 精确检测到密码框 / ⚠️ 有认证界面但无密码框(可能 Touch ID) / ❌ 没检测到
   - 密码框是否聚焦、认证 sheet、按钮、上下文文字
   - 也可随时点窗口里的 **“立即检测”** 强制出一次报告。
6. **Cmd+Q** 退出(菜单 也有“退出 AuthProbe”);关闭窗口即退出。

## 注入测试

窗口第二行有:**注入字符串输入框**(默认 `helloworld`,可填真实密码)+ 两个按钮。
先点进目标密码框让工具捕获,再操作。

**已知结论(2026-07-07,Mac mini / 无 Touch ID)**:方法A(AX 直接设值)在
App Store / Passwords / Safari **三种密码框全部成功**;方法B(CGEvent 合成键击)被 SEI 拦。
→ **纯软件即可注入,不需要 HID 硬件。**

### 按钮一:「注入(A:AX / B:键击)」
- **方法A**:`AXUIElementSetAttributeValue(kAXValue)`——不经键盘、不受 SEI 影响,立即执行。
- **方法B**:CGEvent 合成键击——3 秒倒计时,**请立刻点回密码框保持聚焦**再发送。
- 看框里是否出现注入的字符串,弹窗给出 A/B 各自结果 + SEI 状态。

### 按钮二:「注入并提交(AX)」——验证“真能认证”
AX 设值后,再用 **AX 直接提交**(`field.AXConfirm` + 按窗口默认按钮 Sign In/Install/解锁),
**全程不走键盘、不受 SEI 影响**。用来端到端验证:
- 在输入框填**真实密码** → 触发对应认证界面并点进密码框 → 点“注入并提交(AX)”。
- **关键看:是否真的认证通过 / 登录成功**。
  - 通过 → AX 注入的是“真实值”,能端到端认证 ✅
  - 框里有字但登录失败 → 值没真正生效(**Safari 网页多半是没触发 `input` 事件**,重点验证项)

> immurok 设备是真实 BLE HID 键盘,输入走系统 HID 栈、SEI 视为合法,与本工具测的“软件注入”
> 是两条不同的路。既然软件路(AX)已跑通,硬件路可作 fallback。

### 按钮三:「App Store 一键流程」——多步向导全自动
App Store 购买认证是向导式(确认页 → 密码页 → 登录),三处卡点全部 **AX 自动化,不用键盘**:
1. **Install**:按确认 sheet 的 `kAXDefaultButton`(`AXPress`)→ 进密码页。
2. **聚焦密码框**:设 `kAXFocused=true`,失败则合成鼠标点击其中心(鼠标不被 SEI 拦)。
3. **注入**:`AXSetValue(kAXValue)`。
4. **Sign In**:按密码页的 `kAXDefaultButton`(`AXPress`)。

步骤间自动轮询等待下一元素出现。用法:在输入框填(真实)密码 → App Store 里对某 app 点获取/购买、
出现确认框后点本按钮。**⚠️ 会真实点击 Install/Sign In,请用免费 app 测试**,否则会真的购买。

## 要收集的结论

对每台设备/系统记录:**系统版本 + 有无 Touch ID + Passwords/App Store 各自能否 ✅ 检测到密码框**。
重点关注**有 Touch ID 的 Mac**——那里可能先弹 AX 不可见的生物识别 sheet,是当前未验证的边界。

## 签名说明

- 本地跑 / 测试**不需要** Developer ID 或公证。辅助功能是 TCC 权限(手动勾),不是签名 entitlement。
- ad-hoc 签名即可工作;换机器各授权一次。改代码重编后 cdhash 变,可能需要重新勾一次辅助功能。

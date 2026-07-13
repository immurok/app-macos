import Foundation

/// Manages app localization with built-in and external JSON support
class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    @Published private(set) var currentLanguage: String
    private var strings: [String: String] = [:]

    /// Supported languages with display names
    /// Only languages with available translations (built-in or JSON files)
    static let supportedLanguages: [(code: String, name: String)] = [
        ("zh-Hans", "简体中文"),
        ("zh-Hant", "繁體中文"),
        ("en", "English"),
        ("ja", "日本語"),
        ("fr", "Français"),
        ("es", "Español"),
        ("pt", "Português"),
        ("ru", "Русский"),
    ]

    private init() {
        // Load saved language or detect system language
        if let saved = UserDefaults.standard.string(forKey: "immurok.language") {
            currentLanguage = saved
        } else {
            currentLanguage = Self.detectSystemLanguage()
        }
        loadStrings()
    }

    /// Detect system language and map to supported language
    private static func detectSystemLanguage() -> String {
        let preferred = Locale.preferredLanguages.first ?? "en"

        if preferred.hasPrefix("zh-Hans") || preferred.hasPrefix("zh-CN") {
            return "zh-Hans"
        } else if preferred.hasPrefix("zh-Hant") || preferred.hasPrefix("zh-TW") || preferred.hasPrefix("zh-HK") {
            return "zh-Hant"
        } else if preferred.hasPrefix("ja") {
            return "ja"
        } else if preferred.hasPrefix("fr") {
            return "fr"
        } else if preferred.hasPrefix("es") {
            return "es"
        } else if preferred.hasPrefix("pt") {
            return "pt"
        } else if preferred.hasPrefix("ru") {
            return "ru"
        }

        return "en"
    }

    /// Change current language
    func setLanguage(_ code: String) {
        guard Self.supportedLanguages.contains(where: { $0.code == code }) else { return }
        currentLanguage = code
        UserDefaults.standard.set(code, forKey: "immurok.language")
        loadStrings()
    }

    /// Get localized string for key
    func string(_ key: String) -> String {
        return strings[key] ?? key
    }

    /// Load strings for current language
    private func loadStrings() {
        // First try to load from external JSON file
        if let externalStrings = loadExternalJSON() {
            strings = externalStrings
            NSLog("Loaded external localization for %@", currentLanguage)
            return
        }

        // Fall back to built-in strings
        switch currentLanguage {
        case "zh-Hans":
            strings = Self.zhHansStrings
        case "zh-Hant":
            strings = Self.zhHantStrings
        case "en":
            strings = Self.enStrings
        default:
            // For unsupported languages, try external JSON or fall back to English
            strings = Self.enStrings
        }
        NSLog("Loaded built-in localization for %@", currentLanguage)
    }

    /// Load localization from external JSON file (user directory) or bundled JSON
    private func loadExternalJSON() -> [String: String]? {
        // First try user's custom localization directory
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let externalPath = homeDir
            .appendingPathComponent(".immurok/localization")
            .appendingPathComponent("\(currentLanguage).json")

        if FileManager.default.fileExists(atPath: externalPath.path) {
            if let dict = loadJSON(from: externalPath) {
                NSLog("Loaded user localization for %@", currentLanguage)
                return dict
            }
        }

        // Then try bundled JSON in app Resources
        if let bundlePath = Bundle.main.url(forResource: currentLanguage, withExtension: "json", subdirectory: "Localization") {
            if let dict = loadJSON(from: bundlePath) {
                NSLog("Loaded bundled localization for %@", currentLanguage)
                return dict
            }
        }

        return nil
    }

    /// Load and parse JSON file
    private func loadJSON(from url: URL) -> [String: String]? {
        do {
            let data = try Data(contentsOf: url)
            let dict = try JSONDecoder().decode([String: String].self, from: data)
            return dict
        } catch {
            NSLog("Failed to load localization from %@: %@", url.path, error.localizedDescription)
            return nil
        }
    }

    // MARK: - Built-in Strings

    /// Simplified Chinese (完整)
    static let zhHansStrings: [String: String] = [
        // App
        "app.name": "immurok",
        "app.settings": "immurok 设置",
        "app.version": "版本 4.0",
        "app.description": "macOS 蓝牙指纹认证系统",
        "firmware.version": "固件 %@",

        // Menu
        "menu.settings": "设置...",
        "menu.quit": "退出",
        "menu.connected": "已连接",
        "menu.disconnected": "未连接",
        "menu.status.ok": "状态正常",
        "menu.status.error": "状态异常",
        "menu.authrepair": "指纹授权需修复",

        // Tabs
        "tab.device": "设备",
        "tab.keys": "密钥",
        "tab.permissions": "功能",
        "tab.status": "状态",
        "tab.about": "关于",

        // Firmware update
        "fwupdate.title": "固件",
        "fwupdate.current": "当前版本",
        "fwupdate.check": "检查更新",
        "fwupdate.available": "有新版本 %@",
        "fwupdate.upToDate": "已是最新版本",
        "fwupdate.upgrade": "立即升级",
        "fwupdate.confirm.title": "升级固件到 %@？",
        "fwupdate.confirm.message": "升级预计 1-2 分钟，期间设备与指纹功能不可用。请保持设备在附近。",
        "fwupdate.progress.pushing": "正在推送 %@…",
        "fwupdate.progress.waiting": "设备重启中，等待重连…",
        "fwupdate.success": "已升级到 %@",
        "fwupdate.error.check": "检查更新失败，请稍后重试",
        "fwupdate.error.download": "固件下载失败，请检查网络",
        "fwupdate.error.bridge": "桥接固件包缺失",
        "fwupdate.error.notconnected": "设备未连接",
        "fwupdate.error.battery": "设备电量不足 30%，请先充电",
        "fwupdate.error.busy": "设备忙，请稍后再试",
        "fwupdate.error.verify": "固件包校验失败，请重试或联系支持",
        "fwupdate.error.rejected": "设备拒绝该固件（可能为版本回滚保护）",
        "fwupdate.error.transfer": "传输中断，请重试",
        "fwupdate.error.reconnect": "设备未在预期时间内重连，请检查设备后重试",
        "fwupdate.error.generic": "升级失败，请重试",
        "fwupdate.telemetry.toggle": "发送匿名使用统计",
        "fwupdate.telemetry.hint": "仅升级流程的匿名事件（版本号、阶段、耗时），不含任何个人或设备身份数据",
        "fwupdate.telemetry.tip": "允许匿名使用统计",
        "fwupdate.mandatory": "当前固件版本过旧，必须升级后才能正常使用",
        "fwupdate.window.subtitle": "检查并安装设备固件更新",
        "fwupdate.progress.downloading": "正在下载固件…",
        "fwupdate.menu.available": "有固件新版本",
        "firmware.notify.body": "固件有新版本 %@，可从菜单栏「固件」升级",
        "firmware.notify.subtitle": "点开菜单栏 immurok 图标升级",
        "firmware.done.body": "固件已升级到 %@",
        "firmware.done.subtitle": "升级完成",

        // Keys
        "keys.system": "系统密钥",
        "keys.ssh": "SSH/GIT",
        "keys.api": "API",
        "keys.otp": "OTP",
        "keys.name": "名称",
        "keys.action": "设置",
        "keys.delete": "删除",
        "keys.empty": "暂无条目",
        "keys.add": "添加",
        "keys.add.name": "名称",
        "keys.add.key": "密钥",
        "keys.add.service": "服务名",
        "keys.add.secret": "密钥",
        "keys.confirm.delete": "确定删除「%@」？",
        "keys.loading": "正在加载...",
        "keys.loading.progress": "正在读取 %d/%d",
        "keys.add.failed": "添加失败",
        "keys.edit": "编辑",
        "keys.edit.failed": "编辑失败",
        "keys.save": "保存",
        "keys.delete.failed": "删除失败",
        "keys.busy.auth": "设备忙：其他认证或密钥操作进行中，请稍后重试",
        "keys.add.invalid": "输入数据无效",
        "keys.adding": "正在写入...",
        "keys.deleting": "正在删除...",
        "keys.cancel": "取消",
        "keys.import": "导入",
        "keys.export": "导出",
        "keys.import.confirm": "确认导入",
        "keys.import.count": "将导入 %d 条 OTP 条目",
        "keys.import.done": "已导入 %d 条",
        "keys.importing.progress": "正在导入 %d/%d",
        "keys.import.exceeds.title": "超出容量上限",
        "keys.import.exceeds.message": "无法导入 %1$d 条：剩余可用 %2$d 条（最大 %3$d 条）。请先删除一些条目再试。",
        "keys.import.failed": "导入失败",
        "keys.import.unknown.format": "无法识别的文件格式。请使用 CSV (otpauth:// 一行一条) 或 andOTP JSON 备份。",
        "keys.import.skipped": "（%d 条跳过：仅支持标准 TOTP / HMAC-SHA1 / 6 位 / 30 秒）",
        "keys.import.all.skipped": "%d 条全部被跳过：仅支持标准 TOTP / HMAC-SHA1 / 6 位 / 30 秒。",
        "keys.full": "已达上限，请先删除一些条目",
        "keys.exporting": "正在导出...",
        "keys.manage": "管理",
        "keys.done": "完成",
        "keys.selectAll": "全选",
        "keys.deselectAll": "取消全选",
        "keys.deleteSelected": "删除 (%d)",
        "keys.deleting.progress": "正在删除 %d/%d",

        // SSH Agent
        "ssh.generate": "生成密钥",
        "ssh.import": "导入密钥",
        "ssh.copy.pubkey": "复制公钥",
        "ssh.copy.agent": "复制 Agent 路径",
        "ssh.fingerprint": "指纹",
        "ssh.agent.status": "SSH Agent",
        "ssh.generate.success": "密钥已生成",
        "ssh.import.success": "密钥已导入",
        "ssh.import.failed": "导入失败",
        "ssh.sign.failed": "签名失败",
        "ssh.copied": "已复制",
        "ssh.git.config": "Git 签名配置",

        // Device
        "battery.refresh.tooltip": "点击刷新电量",
        // Auth-request HUD overlay (shown for sudo / screen-unlock / agent triggered auth)
        "auth.overlay.waiting": "请求授权",
        "auth.overlay.subtitle.touch": "请按指纹确认 · 关闭即拒绝",
        "auth.overlay.waiting.secret": "请求读取密钥",
        "auth.overlay.subtitle.touch.secret": "Agent 在访问你的密钥 · 按指纹确认 / 关闭拒绝",
        "auth.overlay.retrying": "请重试，剩余 %d 次",
        "auth.overlay.approved": "已授权",
        "auth.overlay.denied": "已拒绝",
        "auth.overlay.timedout": "授权超时",
        "auth.overlay.detail": "%@ · 用户 %@ · %d 秒内按指纹",
        "auth.overlay.detail.short": "%@ · 用户 %@",
        "auth.overlay.svc.unlock": "屏幕解锁",
        "auth.overlay.svc.authgui": "系统授权",
        "auth.overlay.reject": "拒绝",
        "auth.overlay.reject.tooltip": "拒绝此次授权 — 直接终止命令",
        "device.connected": "已连接",
        "device.disconnected": "未连接",
        "device.connected.name": "已连接：%@",
        "device.connection.status": "连接状态",
        "device.security.pairing": "安全配对",
        "device.id": "设备 ID: %@...",
        "device.not.paired": "未配对",
        "device.paired": "已配对",
        "device.paired.suffix": "已配对 (%@)",
        "device.pairing": "配对中...",
        "device.pair": "配对",
        "device.reset.pairing": "重置配对",
        "device.not.paired.hint": "设备未配对。请点击「配对」并按下设备上的按钮。",
        "device.not.verified": "设备验证失败，敏感操作已禁用",

        // Pairing
        "pairing.title": "安全配对",
        "pairing.status.paired": "已配对",
        "pairing.status.unpaired": "未配对",
        "pairing.start": "配对",
        "pairing.in.progress": "ECDH 密钥交换中...",
        "pairing.press.button": "请按下设备按钮确认配对...",
        "pairing.reconfirm.title": "重新配对",
        "pairing.reconfirm.message": "重新配对需要重新配置锁屏密码，是否继续？",
        "pairing.success": "配对成功",
        "pairing.success.message": "设备已成功配对。",
        "pairing.success.set.password": "配对成功！请设置锁屏密码以启用自动解锁。",
        "pairing.failed": "配对失败",
        "pairing.failed.message": "配对超时或被拒绝。请重试。",
        "pairing.cannot": "无法配对",
        "pairing.connect.first": "请确保设备已连接。",
        "pairing.timeout": "配对超时，请在 30 秒内按下设备按钮确认",
        "pairing.timeout.short": "配对超时，请按下设备按钮确认",
        "pairing.other.host": "设备已与其他主机配对。\n\n请长按设备按钮 5 秒进行出厂重置，然后重试。",
        "pairing.failed.code": "配对失败 (0x%@)",
        "pairing.already.paired": "设备已与本机配对。如需重新配对，请先点击「解除配对」。",
        "pairing.needs.reset": "设备仍有指纹模板，请先恢复出厂设置后再配对。",
        "pairing.cancelled": "配对已取消（用户长按设备按钮）。",
        "pairing.stale.local.title": "检测到旧配对数据",
        "pairing.stale.local.message": "本机仍保留上一次配对的密钥和锁屏密码，但当前设备已不再配对（可能更换或已重置）。\n\n继续将清除本地数据，然后与当前设备重新配对。",
        "pairing.stale.local.continue": "清除并配对",

        // Unpair
        "unpair.title": "解除配对",
        "unpair.message": "这只会清除本机保存的配对数据和锁屏密码，不会影响设备本身。\n\n如需将设备与其他主机配对，请在解除后长按设备按钮 5 秒以上恢复出厂设置。",
        "unpair.confirm": "解除配对",
        "unpair.done": "已解除配对",
        "unpair.done.message": "本机配对数据已清除。\n\n如需重新配对其他主机，请长按设备按钮 5 秒以上恢复设备出厂状态。",

        // Fingerprint
        "fingerprint.management": "指纹管理",
        "fingerprint.title": "immurok 指纹",
        "fingerprint.description": "immurok 可让你使用指纹来解锁 Mac 以及进行 sudo 授权。",
        "fingerprint.count": "已录入 %d 个指纹（最多 5 个）",
        "fingerprint.add": "添加指纹",
        "fingerprint.finger": "手指 %d",
        "fingerprint.test": "测试指纹识别",
        "fingerprint.test.prompt": "请触摸指纹传感器...",
        "fingerprint.test.success": "识别成功！",
        "fingerprint.test.failed": "识别失败或超时",
        "fingerprint.test.not.connected": "设备未连接",
        "fingerprint.delete": "删除指纹",
        "fingerprint.delete.confirm": "确定要删除「手指 %d」吗？",
        "fingerprint.delete.failed": "删除失败",
        "fingerprint.delete.failed.message": "无法删除指纹。",
        "fingerprint.loading": "正在访问设备获取指纹信息……",
        "fingerprint.verify.required": "请用已录入的手指验证身份",
        "gate.attempt.remaining": "识别失败，还剩 %d 次机会",
        "gate.processing": "验证通过，正在处理…",

        // Enrollment
        "enroll.verify.fingerprint": "请用已录入的手指验证身份，再开始新指纹录入",
        "enroll.phase.center": "第一阶段：录入中心",
        "enroll.phase.edge": "第二阶段：录入边缘",
        "enroll.hint.center": "请将手指中心按在传感器上",
        "enroll.hint.edge": "请稍微偏移手指，录入边缘部位",
        "enroll.place.finger": "请将手指放在传感器上...",
        "enroll.captured": "已捕获 (%d/%d)",
        "enroll.step.center.first": "指肚正中按压",
        "enroll.step.center.keep": "保持正中按压",
        "enroll.step.left.first": "稍向左偏 5–10°",
        "enroll.step.left.keep": "保持左偏",
        "enroll.step.right.first": "稍向右偏 5–10°",
        "enroll.step.right.keep": "保持右偏",
        "enroll.step.up": "稍向指尖方向偏",
        "enroll.step.down": "稍向手腕方向偏",
        "enroll.step.center.again": "回到正中，再按一次",
        "enroll.lift.finger": "请抬起手指，然后再次按下...",
        "enroll.adjust.angle": "请稍微调整手指角度，再次按下...",
        "enroll.adjust.overlap": "重合太多，请换个位置再按",
        "enroll.processing": "正在处理...",
        "enroll.success": "成功",
        "enroll.success.message": "指纹录入成功！",
        "enroll.failed": "录入失败",
        "enroll.failed.message": "指纹录入失败，请重试。",
        "enroll.failed.start": "无法启动录入，请检查设备连接。",
        "enroll.in.progress": "正在录入，请按设备 LED 指示操作...",

        // Permissions
        "permission.screen.unlock": "屏幕解锁",
        "permission.screen.unlock.hint": "指纹匹配后自动输入密码解锁屏幕",
        "permission.screen.unlock.sound": "解锁音效",
        "permission.screen.unlock.sound.silent": "静音",
        "permission.screen.lock": "屏幕锁定",
        "permission.screen.lock.hint": "长按指纹传感器约 2 秒触发锁屏",
        "permission.sudo.hint": "通过 PAM 模块用指纹替代 sudo 密码输入",
        "permission.unlock.password": "解锁密码",
        "permission.configured": "已配置",
        "permission.configure": "配置",
        "permission.modify": "修改",
        "permission.sudo": "终端 sudo 授权",
        "permission.authorization": "界面认证授权",
        "permission.authorization.hint": "用于系统设置、App Store 等场景",
        "permission.authorization.repair": "修复",
        "notify.authrepair.title": "指纹授权需修复",
        "notify.authrepair.body": "系统升级后指纹授权配置被重置,点击 immurok 设置修复",
        "permission.ssh.agent": "SSH Agent",
        "permission.ssh.agent.hint": "提供 SSH 密钥签名服务（~/.immurok/agent.sock）",
        "permission.cli": "imk CLI",
        "permission.cli.hint": "允许 imk 命令行工具读取密钥（~/.immurok/cli.sock）",
        "permission.quickfill": "快速填充",
        "permission.quickfill.hint": "全局热键呼出浮动面板，快速搜索并填充密钥",
        "permission.hotkey.recording": "按下快捷键…",
        "permission.section.system": "系统",
        "permission.section.autofill": "密码自动填充",
        "permission.section.devtools": "开发者工具",
        "permission.appstore": "App Store",
        "permission.appstore.hint": "购买/安装时用指纹自动输入 Apple ID 密码",
        "permission.appstore.needpassword": "需先配置 Apple ID 密码",
        "permission.appstore.configure": "配置 Apple ID 密码",
        "permission.appstore.configure.hint": "该密码仅存于本机钥匙串，用于 App Store 认证时自动填充",
        "permission.appstore.field": "Apple ID 密码",
        "permission.passwords": "Passwords 密码 App",
        "permission.passwords.hint": "解锁密码 App 时用指纹自动输入登录密码",

        // Common
        "common.cancel": "取消",
        "common.save": "保存",

        // Quick Fill
        "quickfill.search.placeholder": "搜索密钥...",
        "quickfill.syncing": "正在同步数据...",
        "quickfill.loading": "加载中...",
        "quickfill.empty": "没有密钥",
        "quickfill.no.match": "无匹配结果",
        "quickfill.verify.fingerprint": "请验证指纹",
        "quickfill.error.not.connected": "设备未连接",
        "quickfill.error.fingerprint.denied": "指纹验证失败",
        "quickfill.error.not.found": "密钥未找到",
        "quickfill.error.read.failed": "读取失败",
        "quickfill.error.empty": "密钥为空",

        // Password
        "password.title": "配置解锁密码",
        "password.message": "输入你的 Mac 登录密码，用于屏幕解锁：",
        "password.placeholder": "密码",
        "password.confirm.placeholder": "确认密码",
        "password.save": "保存",
        "password.saved": "已保存",
        "password.saved.message": "密码已保存。",
        "password.error.empty": "密码不能为空。",
        "password.error.mismatch": "两次输入的密码不一致。",
        "password.error.save": "保存密码失败：%@",
        "password.need.pair.first": "请先完成设备配对，再设置锁屏密码。",

        // Alerts
        "alert.error": "错误",
        "alert.cancel": "取消",
        "alert.continue": "继续",
        "alert.delete": "删除",
        "alert.install": "安装",
        "alert.enable": "启用",
        "alert.authorize": "授权",

        // Permissions Alerts
        "alert.need.accessibility": "需要辅助功能权限",
        "alert.need.accessibility.message": "屏幕解锁功能需要辅助功能权限来模拟键盘输入。\n\n请先在系统设置中授予权限。",
        "alert.go.settings": "前往设置",
        "alert.need.pam": "需要安装 PAM 模块",
        "alert.need.pam.sudo": "sudo 授权功能需要先安装 PAM 模块。",
        "alert.need.pam.auth": "认证授权功能需要先安装 PAM 模块。",
        "alert.need.pam.reinstall": "PAM 模块未安装，请重新运行 immurok 安装包。",
        "alert.install.failed": "安装失败",
        "alert.enable.failed": "启用失败",
        "alert.disable.failed": "禁用失败",

        // Status
        "status.device.connection": "设备连接",
        "status.security.pairing": "安全配对",
        "status.fingerprint.count": "指纹数量",
        "status.unlock.password": "解锁密码",
        "status.accessibility": "辅助功能",
        "status.pam.module": "PAM 模块",
        "status.sudo.auth": "sudo 授权",
        "status.auto.start": "开机自启",
        "status.waiting.device": "等待设备连接...",
        "status.tap.pair": "点击「配对」完成设备配对",
        "status.tap.enroll": "点击「录入」添加指纹",
        "status.tap.configure": "点击「配置」设置解锁密码",
        "status.tap.authorize": "点击「授权」开启辅助功能",
        "status.all.ready": "一切就绪，触摸指纹即可认证",

        // Setup Wizard
        "wizard.title": "immurok 设置向导",
        "wizard.subtitle": "首次使用需要完成以下配置",
        "wizard.step": "步骤 %d/%d",
        "wizard.prev": "上一步",
        "wizard.next": "下一步",
        "wizard.done": "完成",
        "wizard.welcome": "欢迎使用 immurok",
        "wizard.intro": "immurok 是一个 macOS 蓝牙指纹认证系统，可以用于：",
        "wizard.feature.unlock": "解锁屏幕",
        "wizard.feature.sudo": "sudo 命令授权",
        "wizard.feature.system": "系统设置授权",
        "wizard.intro.next": "接下来需要完成一些配置才能正常使用。",
        "wizard.pam.title": "PAM 模块",
        "wizard.pam.installed": "PAM 模块已安装",
        "wizard.pam.location": "模块位置：/usr/local/lib/pam/pam_immurok.so",
        "wizard.pam.needpkg": "PAM 模块未安装",
        "wizard.pam.needpkg.hint": "请重新运行 immurok 安装包（immurok_install.pkg）来安装 PAM 模块。",
        "wizard.accessibility.title": "辅助功能权限",
        "wizard.accessibility.granted": "辅助功能权限已授予",
        "wizard.accessibility.description": "immurok 需要辅助功能权限来模拟键盘输入，用于自动解锁屏幕。",
        "wizard.accessibility.steps": "授权步骤：",
        "wizard.accessibility.step1": "1. 点击「授权」打开系统设置",
        "wizard.accessibility.step2": "2. 在列表中找到 immurok",
        "wizard.accessibility.step3": "3. 勾选启用",
        "wizard.complete.title": "设置完成",
        "wizard.complete.message": "immurok 已准备就绪！",
        "wizard.complete.pam": "PAM 模块",
        "wizard.complete.accessibility": "辅助功能权限",
        "wizard.complete.hint": "你可以在设置中开启「用于 sudo 授权」来使用指纹进行 sudo 认证。",

        // Features
        "feature.unlock.mac": "使用 immurok 解锁 Mac",
        "feature.sudo": "将 immurok 用于 sudo 授权",
        "feature.system.auth": "将 immurok 用于系统设置授权",

        // About
        "about.uninstall": "卸载 immurok",
        "about.uninstall.confirm": "确认卸载",
        "about.uninstall.message": "这将移除 PAM 模块、sudo 配置和所有用户数据。App 本身需要手动删除。",
        "about.uninstall.done": "卸载完成",
        "about.uninstall.done.message": "PAM 模块和用户数据已移除。\n\n请手动将 immurok.app 移到废纸篓完成卸载。",
        "about.uninstall.failed": "卸载失败",

        // Test
        "test.title": "测试认证",
        "test.device.not.connected": "设备未连接",
        "test.connect.first": "请先连接设备。",
        "test.prompt": "请触摸指纹传感器...",
        "test.success": "成功",
        "test.success.message": "认证验证成功！",
        "test.failed": "失败",
        "test.failed.message": "超时或设备错误。",

        // Errors
        "error.device.not.connected": "设备未连接",
        "error.communication.failed": "通信失败",
        "error.save.pairing.failed": "保存配对数据失败",
        "error.unknown": "未知错误",
        "error.user.cancelled": "用户取消了操作",
        "error.cannot.create.script": "无法创建 AppleScript",
        "error.command.failed": "命令执行失败",
        "error.pam.source.not.found": "找不到 PAM 模块源文件：%@",
        "error.install.failed": "安装失败",
        "error.config.failed": "配置失败",
        "error.cannot.remove.sudo": "无法移除 sudo 配置：%@",
        "error.cannot.remove.pam": "无法移除 PAM 模块：%@",
        "error.need.pam.first": "请先安装 PAM 模块",

        // Notifications
        "notification.need.accessibility": "请在系统设置中授予辅助功能权限",
        "notification.cannot.unlock": "无法解锁屏幕",

        // Bluetooth
        "bluetooth.denied": "蓝牙权限被拒绝",
        "bluetooth.off": "蓝牙已关闭",
        "bluetooth.unsupported": "设备不支持蓝牙",
        "bluetooth.denied.title": "需要蓝牙权限",
        "bluetooth.denied.message": "immurok 需要蓝牙权限才能连接指纹设备。\n\n请前往「系统设置 → 隐私与安全性 → 蓝牙」启用权限。",
        "bluetooth.off.message": "请打开蓝牙以连接 immurok 设备。",
        "bluetooth.open.settings": "打开系统设置",

        // Settings
        "settings.language": "语言",
    ]

    /// Traditional Chinese (完整)
    static let zhHantStrings: [String: String] = [
        // App
        "app.name": "immurok",
        "app.settings": "immurok 設定",
        "app.version": "版本 4.0",
        "app.description": "macOS 藍牙指紋認證系統",
        "firmware.version": "韌體 %@",

        // Menu
        "menu.settings": "設定...",
        "menu.quit": "結束",
        "menu.connected": "已連接",
        "menu.disconnected": "未連接",
        "menu.status.ok": "狀態正常",
        "menu.status.error": "狀態異常",
        "menu.authrepair": "指紋授權需修復",

        // Tabs
        "tab.device": "裝置",
        "tab.keys": "密鑰",
        "tab.permissions": "功能",
        "tab.status": "狀態",
        "tab.about": "關於",

        // Firmware update
        "fwupdate.title": "韌體",
        "fwupdate.current": "目前版本",
        "fwupdate.check": "檢查更新",
        "fwupdate.available": "有新版本 %@",
        "fwupdate.upToDate": "已是最新版本",
        "fwupdate.upgrade": "立即升級",
        "fwupdate.confirm.title": "升級韌體到 %@？",
        "fwupdate.confirm.message": "升級預計 1-2 分鐘，期間裝置與指紋功能不可用。請保持裝置在附近。",
        "fwupdate.progress.pushing": "正在推送 %@…",
        "fwupdate.progress.waiting": "裝置重啟中，等待重連…",
        "fwupdate.success": "已升級到 %@",
        "fwupdate.error.check": "檢查更新失敗，請稍後重試",
        "fwupdate.error.download": "韌體下載失敗，請檢查網路",
        "fwupdate.error.bridge": "橋接韌體包缺失",
        "fwupdate.error.notconnected": "裝置未連接",
        "fwupdate.error.battery": "裝置電量不足 30%，請先充電",
        "fwupdate.error.busy": "裝置忙碌，請稍後再試",
        "fwupdate.error.verify": "韌體包校驗失敗，請重試或聯絡支援",
        "fwupdate.error.rejected": "裝置拒絕該韌體（可能為版本回滾保護）",
        "fwupdate.error.transfer": "傳輸中斷，請重試",
        "fwupdate.error.reconnect": "裝置未在預期時間內重連，請檢查裝置後重試",
        "fwupdate.error.generic": "升級失敗，請重試",
        "fwupdate.telemetry.toggle": "傳送匿名使用統計",
        "fwupdate.telemetry.hint": "僅升級流程的匿名事件（版本號、階段、耗時），不含任何個人或裝置身分資料",
        "fwupdate.telemetry.tip": "允許匿名使用統計",
        "fwupdate.mandatory": "目前韌體版本過舊，必須升級後才能正常使用",
        "fwupdate.window.subtitle": "檢查並安裝裝置韌體更新",
        "fwupdate.progress.downloading": "正在下載韌體…",
        "fwupdate.menu.available": "有韌體新版本",
        "firmware.notify.body": "韌體有新版本 %@，可從選單列「韌體」升級",
        "firmware.notify.subtitle": "點開選單列 immurok 圖示升級",
        "firmware.done.body": "韌體已升級到 %@",
        "firmware.done.subtitle": "升級完成",

        // Keys
        "keys.system": "系統密鑰",
        "keys.ssh": "SSH/GIT",
        "keys.api": "API",
        "keys.otp": "OTP",
        "keys.name": "名稱",
        "keys.action": "設定",
        "keys.delete": "刪除",
        "keys.empty": "暫無條目",
        "keys.add": "新增",
        "keys.add.name": "名稱",
        "keys.add.key": "密鑰",
        "keys.add.service": "服務名",
        "keys.add.secret": "密鑰",
        "keys.confirm.delete": "確定刪除「%@」？",
        "keys.loading": "正在載入...",
        "keys.loading.progress": "正在讀取 %d/%d",
        "keys.add.failed": "新增失敗",
        "keys.edit": "編輯",
        "keys.edit.failed": "編輯失敗",
        "keys.save": "儲存",
        "keys.delete.failed": "刪除失敗",
        "keys.busy.auth": "裝置忙碌：其他認證或金鑰操作進行中，請稍後重試",
        "keys.add.invalid": "輸入資料無效",
        "keys.adding": "正在寫入...",
        "keys.deleting": "正在刪除...",
        "keys.cancel": "取消",
        "keys.import": "匯入",
        "keys.export": "匯出",
        "keys.import.confirm": "確認匯入",
        "keys.import.count": "將匯入 %d 條 OTP 條目",
        "keys.import.done": "已匯入 %d 條",
        "keys.import.exceeds.title": "超出容量上限",
        "keys.import.exceeds.message": "無法匯入 %1$d 條：剩餘可用 %2$d 條（最大 %3$d 條）。請先刪除一些條目再試。",
        "keys.import.failed": "匯入失敗",
        "keys.import.unknown.format": "無法識別的檔案格式。請使用 CSV (otpauth:// 一行一條) 或 andOTP JSON 備份。",
        "keys.import.skipped": "（%d 條跳過：僅支援標準 TOTP / HMAC-SHA1 / 6 位 / 30 秒）",
        "keys.import.all.skipped": "%d 條全部被跳過：僅支援標準 TOTP / HMAC-SHA1 / 6 位 / 30 秒。",
        "keys.full": "已達上限，請先刪除一些條目",
        "keys.importing.progress": "正在匯入 %d/%d",
        "keys.exporting": "正在匯出...",
        "keys.manage": "管理",
        "keys.done": "完成",
        "keys.selectAll": "全選",
        "keys.deselectAll": "取消全選",
        "keys.deleteSelected": "刪除 (%d)",
        "keys.deleting.progress": "正在刪除 %d/%d",

        // SSH Agent
        "ssh.generate": "產生密鑰",
        "ssh.import": "匯入密鑰",
        "ssh.copy.pubkey": "複製公鑰",
        "ssh.copy.agent": "複製 Agent 路徑",
        "ssh.fingerprint": "指紋",
        "ssh.agent.status": "SSH Agent",
        "ssh.generate.success": "密鑰已產生",
        "ssh.import.failed": "匯入失敗",
        "ssh.import.success": "密鑰已匯入",
        "ssh.sign.failed": "簽名失敗",
        "ssh.copied": "已複製",
        "ssh.git.config": "Git 簽名設定",

        // Device
        "battery.refresh.tooltip": "點擊刷新電量",
        "auth.overlay.waiting": "請求授權",
        "auth.overlay.subtitle.touch": "請按指紋確認 · 關閉即拒絕",
        "auth.overlay.waiting.secret": "請求讀取密鑰",
        "auth.overlay.subtitle.touch.secret": "Agent 在存取你的密鑰 · 按指紋確認 / 關閉拒絕",
        "auth.overlay.retrying": "請重試，剩餘 %d 次",
        "auth.overlay.approved": "已授權",
        "auth.overlay.denied": "已拒絕",
        "auth.overlay.timedout": "授權逾時",
        "auth.overlay.detail": "%@ · 使用者 %@ · %d 秒內按指紋",
        "auth.overlay.detail.short": "%@ · 使用者 %@",
        "auth.overlay.svc.unlock": "螢幕解鎖",
        "auth.overlay.svc.authgui": "系統授權",
        "auth.overlay.reject": "拒絕",
        "auth.overlay.reject.tooltip": "拒絕此次授權 — 直接終止指令",
        "device.connected": "已連接",
        "device.disconnected": "未連接",
        "device.connected.name": "已連接：%@",
        "device.connection.status": "連接狀態",
        "device.security.pairing": "安全配對",
        "device.id": "裝置 ID: %@...",
        "device.not.paired": "未配對",
        "device.paired": "已配對",
        "device.paired.suffix": "已配對 (%@)",
        "device.pairing": "配對中...",
        "device.pair": "配對",
        "device.reset.pairing": "重置配對",
        "device.not.paired.hint": "裝置未配對。請點擊「配對」並按下裝置上的按鈕。",

        // Pairing
        "pairing.title": "安全配對",
        "pairing.status.paired": "已配對",
        "pairing.status.unpaired": "未配對",
        "pairing.start": "配對",
        "pairing.in.progress": "ECDH 金鑰交換中...",
        "pairing.press.button": "請按下裝置按鈕確認配對...",
        "pairing.reconfirm.title": "重新配對",
        "pairing.reconfirm.message": "重新配對需要重新設定鎖屏密碼，是否繼續？",
        "pairing.success": "配對成功",
        "pairing.success.message": "裝置已成功配對。",
        "pairing.success.set.password": "配對成功！請設定鎖屏密碼以啟用自動解鎖。",
        "pairing.failed": "配對失敗",
        "pairing.failed.message": "配對逾時或被拒絕。請重試。",
        "pairing.cannot": "無法配對",
        "pairing.connect.first": "請確保裝置已連接。",
        "pairing.timeout": "配對逾時，請在 30 秒內按下裝置按鈕確認",
        "pairing.timeout.short": "配對逾時，請按下裝置按鈕確認",
        "pairing.other.host": "裝置已與其他主機配對。\n\n請長按裝置按鈕 5 秒進行出廠重置，然後重試。",
        "pairing.failed.code": "配對失敗 (0x%@)",
        "pairing.already.paired": "裝置已與本機配對。如需重新配對，請先點擊「解除配對」。",
        "pairing.needs.reset": "裝置仍有指紋資料，請先恢復出廠設定後再配對。",
        "pairing.cancelled": "配對已取消（使用者長按裝置按鈕）。",
        "pairing.stale.local.title": "偵測到舊配對資料",
        "pairing.stale.local.message": "本機仍保留上一次配對的金鑰和鎖屏密碼，但目前裝置已不再配對（可能更換或已重置）。\n\n繼續將清除本機資料，然後與目前裝置重新配對。",
        "pairing.stale.local.continue": "清除並配對",

        // Unpair
        "unpair.title": "解除配對",
        "unpair.message": "這只會清除本機儲存的配對資料和鎖屏密碼，不會影響裝置本身。\n\n若要將裝置與其他主機配對，請在解除後長按裝置按鈕 5 秒以上恢復出廠設定。",
        "unpair.confirm": "解除配對",
        "unpair.done": "已解除配對",
        "unpair.done.message": "本機配對資料已清除。\n\n若要重新配對其他主機，請長按裝置按鈕 5 秒以上恢復裝置出廠狀態。",

        // Fingerprint
        "fingerprint.management": "指紋管理",
        "fingerprint.title": "immurok 指紋",
        "fingerprint.description": "immurok 可讓你使用指紋來解鎖 Mac 以及進行 sudo 授權。",
        "fingerprint.count": "已錄入 %d 個指紋（最多 5 個）",
        "fingerprint.add": "新增指紋",
        "fingerprint.finger": "手指 %d",
        "fingerprint.test": "測試指紋辨識",
        "fingerprint.test.prompt": "請觸摸指紋感測器...",
        "fingerprint.test.success": "辨識成功！",
        "fingerprint.test.failed": "辨識失敗或逾時",
        "fingerprint.test.not.connected": "裝置未連線",
        "fingerprint.delete": "刪除指紋",
        "fingerprint.delete.confirm": "確定要刪除「手指 %d」嗎？",
        "fingerprint.delete.failed": "刪除失敗",
        "fingerprint.delete.failed.message": "無法刪除指紋。",
        "fingerprint.loading": "正在訪問設備取得指紋資訊……",
        "fingerprint.verify.required": "請用已錄入的手指驗證身分",
        "gate.attempt.remaining": "辨識失敗，還剩 %d 次機會",
        "gate.processing": "驗證通過，正在處理…",

        // Enrollment
        "enroll.verify.fingerprint": "請用已錄入的手指驗證身分，再開始新指紋錄入",
        "enroll.phase.center": "第一階段：錄入中心",
        "enroll.phase.edge": "第二階段：錄入邊緣",
        "enroll.hint.center": "請將手指中心按在感測器上",
        "enroll.hint.edge": "請稍微偏移手指，錄入邊緣部位",
        "enroll.place.finger": "請將手指放在感測器上...",
        "enroll.captured": "已擷取 (%d/%d)",
        "enroll.step.center.first": "指腹正中按壓",
        "enroll.step.center.keep": "保持正中按壓",
        "enroll.step.left.first": "稍向左偏 5–10°",
        "enroll.step.left.keep": "保持左偏",
        "enroll.step.right.first": "稍向右偏 5–10°",
        "enroll.step.right.keep": "保持右偏",
        "enroll.step.up": "稍向指尖方向偏",
        "enroll.step.down": "稍向手腕方向偏",
        "enroll.step.center.again": "回到正中，再按一次",
        "enroll.lift.finger": "請抬起手指，然後再次按下...",
        "enroll.adjust.angle": "請稍微調整手指角度，再次按下...",
        "enroll.adjust.overlap": "重合太多，請換個位置再按",
        "enroll.processing": "正在處理...",
        "enroll.success": "成功",
        "enroll.success.message": "指紋錄入成功！",
        "enroll.failed": "錄入失敗",
        "enroll.failed.message": "指紋錄入失敗，請重試。",
        "enroll.failed.start": "無法啟動錄入，請檢查裝置連接。",
        "enroll.in.progress": "正在錄入，請按裝置 LED 指示操作...",

        // Permissions
        "permission.screen.unlock": "螢幕解鎖",
        "permission.screen.unlock.hint": "指紋匹配後自動輸入密碼解鎖螢幕",
        "permission.screen.unlock.sound": "解鎖音效",
        "permission.screen.unlock.sound.silent": "靜音",
        "permission.screen.lock": "螢幕鎖定",
        "permission.screen.lock.hint": "長按指紋感應器約 2 秒觸發鎖屏",
        "permission.sudo.hint": "透過 PAM 模組用指紋替代 sudo 密碼輸入",
        "permission.unlock.password": "解鎖密碼",
        "permission.configured": "已設定",
        "permission.configure": "設定",
        "permission.modify": "修改",
        "permission.sudo": "終端機 sudo 授權",
        "permission.authorization": "介面認證授權",
        "permission.authorization.hint": "用於系統設定、App Store 等場景",
        "permission.authorization.repair": "修復",
        "notify.authrepair.title": "指紋授權需修復",
        "notify.authrepair.body": "系統升級後指紋授權設定被重置,點擊 immurok 設定修復",
        "permission.ssh.agent": "SSH Agent",
        "permission.ssh.agent.hint": "提供 SSH 密鑰簽名服務（~/.immurok/agent.sock）",
        "permission.cli": "imk CLI",
        "permission.cli.hint": "允許 imk 命令列工具讀取密鑰（~/.immurok/cli.sock）",
        "permission.quickfill": "快速填充",
        "permission.quickfill.hint": "全域熱鍵呼出浮動面板，快速搜尋並填充密鑰",
        "permission.hotkey.recording": "按下快捷鍵…",
        "permission.section.system": "系統",
        "permission.section.autofill": "密碼自動填充",
        "permission.section.devtools": "開發者工具",
        "permission.appstore": "App Store",
        "permission.appstore.hint": "購買/安裝時用指紋自動輸入 Apple ID 密碼",
        "permission.appstore.needpassword": "需先配置 Apple ID 密碼",
        "permission.appstore.configure": "配置 Apple ID 密碼",
        "permission.appstore.configure.hint": "該密碼僅存於本機鑰匙串，用於 App Store 認證時自動填充",
        "permission.appstore.field": "Apple ID 密碼",
        "permission.passwords": "Passwords 密碼 App",
        "permission.passwords.hint": "解鎖密碼 App 時用指紋自動輸入登入密碼",

        // Common
        "common.cancel": "取消",
        "common.save": "儲存",

        // Quick Fill
        "quickfill.search.placeholder": "搜尋密鑰...",
        "quickfill.syncing": "正在同步資料...",
        "quickfill.loading": "載入中...",
        "quickfill.empty": "沒有密鑰",
        "quickfill.no.match": "無匹配結果",
        "quickfill.verify.fingerprint": "請驗證指紋",
        "quickfill.error.not.connected": "裝置未連接",
        "quickfill.error.fingerprint.denied": "指紋驗證失敗",
        "quickfill.error.not.found": "密鑰未找到",
        "quickfill.error.read.failed": "讀取失敗",
        "quickfill.error.empty": "密鑰為空",

        // Password
        "password.title": "設定解鎖密碼",
        "password.message": "輸入你的 Mac 登入密碼，用於螢幕解鎖：",
        "password.placeholder": "密碼",
        "password.confirm.placeholder": "確認密碼",
        "password.save": "儲存",
        "password.saved": "已儲存",
        "password.saved.message": "密碼已儲存。",
        "password.error.empty": "密碼不能為空。",
        "password.error.mismatch": "兩次輸入的密碼不一致。",
        "password.error.save": "儲存密碼失敗：%@",
        "password.need.pair.first": "請先完成裝置配對，再設定鎖屏密碼。",

        // Alerts
        "alert.error": "錯誤",
        "alert.cancel": "取消",
        "alert.continue": "繼續",
        "alert.delete": "刪除",
        "alert.install": "安裝",
        "alert.enable": "啟用",
        "alert.authorize": "授權",

        // Permissions Alerts
        "alert.need.accessibility": "需要輔助使用權限",
        "alert.need.accessibility.message": "螢幕解鎖功能需要輔助使用權限來模擬鍵盤輸入。\n\n請先在系統設定中授予權限。",
        "alert.go.settings": "前往設定",
        "alert.need.pam": "需要安裝 PAM 模組",
        "alert.need.pam.sudo": "sudo 授權功能需要先安裝 PAM 模組。",
        "alert.need.pam.auth": "認證授權功能需要先安裝 PAM 模組。",
        "alert.need.pam.reinstall": "PAM 模組未安裝，請重新執行 immurok 安裝套件。",
        "alert.install.failed": "安裝失敗",
        "alert.enable.failed": "啟用失敗",
        "alert.disable.failed": "停用失敗",

        // Status
        "status.device.connection": "裝置連接",
        "status.security.pairing": "安全配對",
        "status.fingerprint.count": "指紋數量",
        "status.unlock.password": "解鎖密碼",
        "status.accessibility": "輔助使用",
        "status.pam.module": "PAM 模組",
        "status.sudo.auth": "sudo 授權",
        "status.auto.start": "開機自動啟動",
        "status.waiting.device": "等待裝置連接...",
        "status.tap.pair": "點擊「配對」完成裝置配對",
        "status.tap.enroll": "點擊「錄入」新增指紋",
        "status.tap.configure": "點擊「設定」設定解鎖密碼",
        "status.tap.authorize": "點擊「授權」開啟輔助使用",
        "status.all.ready": "一切就緒，觸摸指紋即可認證",

        // Setup Wizard
        "wizard.title": "immurok 設定精靈",
        "wizard.subtitle": "首次使用需要完成以下設定",
        "wizard.step": "步驟 %d/%d",
        "wizard.prev": "上一步",
        "wizard.next": "下一步",
        "wizard.done": "完成",
        "wizard.welcome": "歡迎使用 immurok",
        "wizard.intro": "immurok 是一個 macOS 藍牙指紋認證系統，可以用於：",
        "wizard.feature.unlock": "解鎖螢幕",
        "wizard.feature.sudo": "sudo 命令授權",
        "wizard.feature.system": "系統設定授權",
        "wizard.intro.next": "接下來需要完成一些設定才能正常使用。",
        "wizard.pam.title": "PAM 模組",
        "wizard.pam.installed": "PAM 模組已安裝",
        "wizard.pam.location": "模組位置：/usr/local/lib/pam/pam_immurok.so",
        "wizard.pam.needpkg": "PAM 模組未安裝",
        "wizard.pam.needpkg.hint": "請重新執行 immurok 安裝套件（immurok_install.pkg）來安裝 PAM 模組。",
        "wizard.accessibility.title": "輔助使用權限",
        "wizard.accessibility.granted": "輔助使用權限已授予",
        "wizard.accessibility.description": "immurok 需要輔助使用權限來模擬鍵盤輸入，用於自動解鎖螢幕。",
        "wizard.accessibility.steps": "授權步驟：",
        "wizard.accessibility.step1": "1. 點擊「授權」打開系統設定",
        "wizard.accessibility.step2": "2. 在列表中找到 immurok",
        "wizard.accessibility.step3": "3. 勾選啟用",
        "wizard.complete.title": "設定完成",
        "wizard.complete.message": "immurok 已準備就緒！",
        "wizard.complete.pam": "PAM 模組",
        "wizard.complete.accessibility": "輔助使用權限",
        "wizard.complete.hint": "你可以在設定中開啟「用於 sudo 授權」來使用指紋進行 sudo 認證。",

        // Features
        "feature.unlock.mac": "使用 immurok 解鎖 Mac",
        "feature.sudo": "將 immurok 用於 sudo 授權",
        "feature.system.auth": "將 immurok 用於系統設定授權",

        // About
        "about.uninstall": "解除安裝 immurok",
        "about.uninstall.confirm": "確認解除安裝",
        "about.uninstall.message": "這將移除 PAM 模組、sudo 設定和所有使用者資料。App 本身需要手動刪除。",
        "about.uninstall.done": "解除安裝完成",
        "about.uninstall.done.message": "PAM 模組和使用者資料已移除。\n\n請手動將 immurok.app 移到垃圾桶完成解除安裝。",
        "about.uninstall.failed": "解除安裝失敗",

        // Test
        "test.title": "測試認證",
        "test.device.not.connected": "裝置未連接",
        "test.connect.first": "請先連接裝置。",
        "test.prompt": "請觸摸指紋感測器...",
        "test.success": "成功",
        "test.success.message": "認證驗證成功！",
        "test.failed": "失敗",
        "test.failed.message": "逾時或裝置錯誤。",

        // Errors
        "error.device.not.connected": "裝置未連接",
        "error.communication.failed": "通訊失敗",
        "error.save.pairing.failed": "儲存配對資料失敗",
        "error.unknown": "未知錯誤",
        "error.user.cancelled": "使用者取消了操作",
        "error.cannot.create.script": "無法建立 AppleScript",
        "error.command.failed": "命令執行失敗",
        "error.pam.source.not.found": "找不到 PAM 模組來源檔案：%@",
        "error.install.failed": "安裝失敗",
        "error.config.failed": "設定失敗",
        "error.cannot.remove.sudo": "無法移除 sudo 設定：%@",
        "error.cannot.remove.pam": "無法移除 PAM 模組：%@",
        "error.need.pam.first": "請先安裝 PAM 模組",

        // Notifications
        "notification.need.accessibility": "請在系統設定中授予輔助使用權限",
        "notification.cannot.unlock": "無法解鎖螢幕",

        // Bluetooth
        "bluetooth.denied": "藍牙權限被拒絕",
        "bluetooth.off": "藍牙已關閉",
        "bluetooth.unsupported": "裝置不支援藍牙",
        "bluetooth.denied.title": "需要藍牙權限",
        "bluetooth.denied.message": "immurok 需要藍牙權限才能連接指紋裝置。\n\n請前往「系統設定 → 隱私權與安全性 → 藍牙」啟用權限。",
        "bluetooth.off.message": "請開啟藍牙以連接 immurok 裝置。",
        "bluetooth.open.settings": "開啟系統設定",

        // Settings
        "settings.language": "語言",
    ]

    /// English (完整)
    static let enStrings: [String: String] = [
        // App
        "app.name": "immurok",
        "app.settings": "immurok Settings",
        "app.version": "Version 4.0",
        "app.description": "macOS Bluetooth Fingerprint Authentication",
        "firmware.version": "Firmware %@",

        // Menu
        "menu.settings": "Settings...",
        "menu.quit": "Quit",
        "menu.connected": "Connected",
        "menu.disconnected": "Disconnected",
        "menu.status.ok": "Status OK",
        "menu.status.error": "Status Error",
        "menu.authrepair": "Fingerprint auth needs repair",
        "notify.authrepair.title": "Fingerprint auth needs repair",
        "notify.authrepair.body": "A system update reset fingerprint auth config. Open immurok to repair.",
        "permission.authorization.repair": "Repair",

        // Tabs
        "tab.device": "Device",
        "tab.keys": "Keys",
        "tab.permissions": "Features",
        "tab.status": "Status",
        "tab.about": "About",

        // Firmware update
        "fwupdate.title": "Firmware",
        "fwupdate.current": "Current Version",
        "fwupdate.check": "Check for Updates",
        "fwupdate.available": "Version %@ available",
        "fwupdate.upToDate": "Up to date",
        "fwupdate.upgrade": "Update Now",
        "fwupdate.confirm.title": "Update firmware to %@?",
        "fwupdate.confirm.message": "The update takes 1-2 minutes. The device and fingerprint features will be unavailable. Keep the device nearby.",
        "fwupdate.progress.pushing": "Pushing %@…",
        "fwupdate.progress.waiting": "Device rebooting, waiting to reconnect…",
        "fwupdate.success": "Updated to %@",
        "fwupdate.error.check": "Update check failed, try again later",
        "fwupdate.error.download": "Firmware download failed, check your network",
        "fwupdate.error.bridge": "Bridge firmware package missing",
        "fwupdate.error.notconnected": "Device not connected",
        "fwupdate.error.battery": "Device battery below 30%, charge it first",
        "fwupdate.error.busy": "Device busy, try again later",
        "fwupdate.error.verify": "Firmware verification failed, retry or contact support",
        "fwupdate.error.rejected": "Device rejected this firmware (rollback protection)",
        "fwupdate.error.transfer": "Transfer interrupted, please retry",
        "fwupdate.error.reconnect": "Device did not reconnect in time, check the device and retry",
        "fwupdate.error.generic": "Update failed, please retry",
        "fwupdate.telemetry.toggle": "Send anonymous usage statistics",
        "fwupdate.telemetry.hint": "Only anonymous update-flow events (versions, stage, duration). No personal or device identity data.",
        "fwupdate.telemetry.tip": "allow anonymous usage statistics",
        "fwupdate.mandatory": "Your firmware is too old — you must update it to keep using the device",
        "fwupdate.window.subtitle": "Check and install device firmware updates",
        "fwupdate.progress.downloading": "Downloading firmware\u{2026}",
        "fwupdate.menu.available": "Firmware update available",
        "firmware.notify.body": "Firmware %@ is available — update from the menu bar \u{201C}Firmware\u{201D}",
        "firmware.notify.subtitle": "Open the immurok menu bar icon to update",
        "firmware.done.body": "Firmware updated to %@",
        "firmware.done.subtitle": "Update complete",

        // Keys
        "keys.system": "System",
        "keys.ssh": "SSH/GIT",
        "keys.api": "API",
        "keys.otp": "OTP",
        "keys.name": "Name",
        "keys.action": "Settings",
        "keys.delete": "Delete",
        "keys.empty": "No entries",
        "keys.add": "Add",
        "keys.add.name": "Name",
        "keys.add.key": "Key",
        "keys.add.service": "Service",
        "keys.add.secret": "Secret",
        "keys.confirm.delete": "Delete \"%@\"?",
        "keys.loading": "Loading...",
        "keys.loading.progress": "Reading %d/%d",
        "keys.add.failed": "Add failed",
        "keys.edit": "Edit",
        "keys.edit.failed": "Edit failed",
        "keys.save": "Save",
        "keys.delete.failed": "Delete failed",
        "keys.busy.auth": "Device busy: another authentication or key operation is in progress — try again shortly",
        "keys.add.invalid": "Invalid input data",
        "keys.adding": "Writing...",
        "keys.deleting": "Deleting...",
        "keys.cancel": "Cancel",
        "keys.import": "Import",
        "keys.export": "Export",
        "keys.import.confirm": "Confirm Import",
        "keys.import.count": "Will import %d OTP entries",
        "keys.import.done": "Imported %d entries",
        "keys.import.exceeds.title": "Exceeds Capacity",
        "keys.import.exceeds.message": "Cannot import %1$d entries: only %2$d slots remaining (max %3$d). Delete some entries first.",
        "keys.import.failed": "Import Failed",
        "keys.import.unknown.format": "Unrecognized file format. Use CSV (one otpauth:// per line) or andOTP JSON backup.",
        "keys.import.skipped": "(%d skipped: only standard TOTP / HMAC-SHA1 / 6-digit / 30s supported)",
        "keys.import.all.skipped": "All %d entries skipped: only standard TOTP / HMAC-SHA1 / 6-digit / 30s supported.",
        "keys.full": "At capacity — delete some entries first",
        "keys.importing.progress": "Importing %d/%d",
        "keys.exporting": "Exporting...",
        "keys.manage": "Manage",
        "keys.done": "Done",
        "keys.selectAll": "Select All",
        "keys.deselectAll": "Deselect All",
        "keys.deleteSelected": "Delete (%d)",
        "keys.deleting.progress": "Deleting %d/%d",

        // SSH Agent
        "ssh.generate": "Generate Key",
        "ssh.import": "Import Key",
        "ssh.copy.pubkey": "Copy Public Key",
        "ssh.copy.agent": "Copy Agent Path",
        "ssh.fingerprint": "Fingerprint",
        "ssh.agent.status": "SSH Agent",
        "ssh.generate.success": "Key Generated",
        "ssh.import.failed": "Import Failed",
        "ssh.import.success": "Key Imported",
        "ssh.sign.failed": "Sign Failed",
        "ssh.copied": "Copied",
        "ssh.git.config": "Git Signing Config",

        // Device
        "battery.refresh.tooltip": "Click to refresh battery level",
        "auth.overlay.waiting": "Authorization Required",
        "auth.overlay.subtitle.touch": "Touch fingerprint to confirm · close to reject",
        "auth.overlay.waiting.secret": "Secret Access Requested",
        "auth.overlay.subtitle.touch.secret": "Agent is reading a secret · touch to allow / close to deny",
        "auth.overlay.retrying": "Try again — %d attempt(s) left",
        "auth.overlay.approved": "Authorized",
        "auth.overlay.denied": "Denied",
        "auth.overlay.timedout": "Auth timed out",
        "auth.overlay.detail": "%@ · user %@ · touch within %d s",
        "auth.overlay.detail.short": "%@ · user %@",
        "auth.overlay.svc.unlock": "Screen Unlock",
        "auth.overlay.svc.authgui": "System Auth",
        "auth.overlay.reject": "Reject",
        "auth.overlay.reject.tooltip": "Reject — kill the command outright",
        "device.connected": "Connected",
        "device.disconnected": "Disconnected",
        "device.connected.name": "Connected: %@",
        "device.connection.status": "Connection Status",
        "device.security.pairing": "Security Pairing",
        "device.id": "Device ID: %@...",
        "device.not.paired": "Not Paired",
        "device.paired": "Paired",
        "device.paired.suffix": "Paired (%@)",
        "device.pairing": "Pairing...",
        "device.pair": "Pair",
        "device.reset.pairing": "Reset Pairing",
        "device.not.paired.hint": "Device not paired. Click \"Pair\" and press the button on the device.",

        // Pairing
        "pairing.title": "Secure Pairing",
        "pairing.status.paired": "Paired",
        "pairing.status.unpaired": "Not Paired",
        "pairing.start": "Pair",
        "pairing.in.progress": "ECDH key exchange...",
        "pairing.press.button": "Press the device button to confirm pairing...",
        "pairing.reconfirm.title": "Re-pair",
        "pairing.reconfirm.message": "Re-pairing requires reconfiguring the unlock password. Continue?",
        "pairing.success": "Pairing Successful",
        "pairing.success.message": "Device has been paired successfully.",
        "pairing.success.set.password": "Pairing successful! Please set the unlock password to enable auto-unlock.",
        "pairing.failed": "Pairing Failed",
        "pairing.failed.message": "Pairing timed out or was rejected. Please try again.",
        "pairing.cannot": "Cannot Pair",
        "pairing.connect.first": "Please make sure the device is connected.",
        "pairing.timeout": "Pairing timed out. Press the device button within 30 seconds.",
        "pairing.timeout.short": "Pairing timed out. Press the device button to confirm.",
        "pairing.other.host": "Device is paired with another host.\n\nPlease hold the device button for 5 seconds to factory reset, then try again.",
        "pairing.failed.code": "Pairing failed (0x%@)",
        "pairing.already.paired": "Device is already paired with this Mac. Tap \"Unpair\" first if you want to re-pair.",
        "pairing.needs.reset": "Device still has fingerprint templates. Factory reset before pairing.",
        "pairing.cancelled": "Pairing cancelled (user long-pressed the device button).",
        "pairing.stale.local.title": "Stale Pairing Data Detected",
        "pairing.stale.local.message": "This Mac still holds the previous pairing key and lock-screen password, but the current device is no longer paired (likely swapped or reset).\n\nContinue to clear local data and pair with the current device.",
        "pairing.stale.local.continue": "Clear & Pair",

        // Unpair
        "unpair.title": "Unpair",
        "unpair.message": "This will only clear locally stored pairing data and the lock-screen password. The device itself will not be affected.\n\nTo pair the device with another host, hold its button for 5+ seconds afterwards to factory reset it.",
        "unpair.confirm": "Unpair",
        "unpair.done": "Unpaired",
        "unpair.done.message": "Local pairing data has been cleared.\n\nTo pair the device with another host, hold its button for 5+ seconds to factory reset it.",

        // Fingerprint
        "fingerprint.management": "Fingerprint",
        "fingerprint.title": "immurok Fingerprint",
        "fingerprint.description": "immurok lets you use your fingerprint to unlock your Mac and authorize sudo commands.",
        "fingerprint.count": "%d fingerprint(s) enrolled (max 5)",
        "fingerprint.add": "Add Fingerprint",
        "fingerprint.finger": "Finger %d",
        "fingerprint.test": "Test Fingerprint",
        "fingerprint.test.prompt": "Touch the fingerprint sensor...",
        "fingerprint.test.success": "Recognition successful!",
        "fingerprint.test.failed": "Recognition failed or timed out",
        "fingerprint.test.not.connected": "Device not connected",
        "fingerprint.delete": "Delete Fingerprint",
        "fingerprint.delete.confirm": "Are you sure you want to delete \"Finger %d\"?",
        "fingerprint.delete.failed": "Delete Failed",
        "fingerprint.delete.failed.message": "Unable to delete fingerprint.",
        "fingerprint.loading": "Fetching fingerprint info from device...",
        "fingerprint.verify.required": "Verify with an enrolled finger",
        "gate.attempt.remaining": "Failed, %d attempts remaining",
        "gate.processing": "Verified, processing…",

        // Enrollment
        "enroll.verify.fingerprint": "Verify with an enrolled finger before adding a new one",
        "enroll.phase.center": "Phase 1: Center",
        "enroll.phase.edge": "Phase 2: Edges",
        "enroll.hint.center": "Press the center of your finger on the sensor",
        "enroll.hint.edge": "Slightly shift your finger to capture the edges",
        "enroll.place.finger": "Place your finger on the sensor...",
        "enroll.captured": "Captured (%d/%d)",
        "enroll.step.center.first": "Press finger pad on center",
        "enroll.step.center.keep": "Keep pressing center",
        "enroll.step.left.first": "Tilt slightly left 5–10°",
        "enroll.step.left.keep": "Keep tilted left",
        "enroll.step.right.first": "Tilt slightly right 5–10°",
        "enroll.step.right.keep": "Keep tilted right",
        "enroll.step.up": "Shift slightly toward fingertip",
        "enroll.step.down": "Shift slightly toward wrist",
        "enroll.step.center.again": "Back to center, press once more",
        "enroll.lift.finger": "Lift your finger, then press again...",
        "enroll.adjust.angle": "Slightly adjust your finger angle, then press again...",
        "enroll.adjust.overlap": "Too similar — shift your finger and press again",
        "enroll.processing": "Processing...",
        "enroll.success": "Success",
        "enroll.success.message": "Fingerprint enrolled successfully!",
        "enroll.failed": "Enrollment Failed",
        "enroll.failed.message": "Fingerprint enrollment failed. Please try again.",
        "enroll.failed.start": "Unable to start enrollment. Please check device connection.",
        "enroll.in.progress": "Enrolling, follow the device LED...",

        // Permissions
        "permission.screen.unlock": "Screen Unlock",
        "permission.screen.unlock.hint": "Auto-type password to unlock screen on fingerprint match",
        "permission.screen.unlock.sound": "Unlock Sound",
        "permission.screen.unlock.sound.silent": "Silent",
        "permission.screen.lock": "Screen Lock",
        "permission.screen.lock.hint": "Hold finger on sensor ~2s to lock screen",
        "permission.sudo.hint": "Replace sudo password prompt with fingerprint via PAM",
        "permission.unlock.password": "Unlock Password",
        "permission.configured": "Configured",
        "permission.configure": "Configure",
        "permission.modify": "Modify",
        "permission.sudo": "Terminal sudo",
        "permission.authorization": "GUI Authorization",
        "permission.authorization.hint": "For System Settings, App Store, etc.",
        "permission.ssh.agent": "SSH Agent",
        "permission.ssh.agent.hint": "SSH key signing service (~/.immurok/agent.sock)",
        "permission.cli": "imk CLI",
        "permission.cli.hint": "Allow imk CLI to read keys (~/.immurok/cli.sock)",
        "permission.quickfill": "Quick Fill",
        "permission.quickfill.hint": "Global hotkey to open floating panel for quick key search and fill",
        "permission.hotkey.recording": "Press shortcut\u{2026}",
        "permission.section.system": "System",
        "permission.section.autofill": "Password Autofill",
        "permission.section.devtools": "Developer Tools",
        "permission.appstore": "App Store",
        "permission.appstore.hint": "Auto-fill your Apple ID password with your fingerprint during purchases/installs",
        "permission.appstore.needpassword": "Apple ID password not configured yet",
        "permission.appstore.configure": "Configure Apple ID Password",
        "permission.appstore.configure.hint": "This password is stored only in the local Keychain and used to auto-fill App Store authentication",
        "permission.appstore.field": "Apple ID Password",
        "permission.passwords": "Passwords App",
        "permission.passwords.hint": "Auto-fill your login password with your fingerprint when unlocking the Passwords app",

        // Common
        "common.cancel": "Cancel",
        "common.save": "Save",

        // Quick Fill
        "quickfill.search.placeholder": "Search keys...",
        "quickfill.syncing": "Syncing data...",
        "quickfill.loading": "Loading...",
        "quickfill.empty": "No keys",
        "quickfill.no.match": "No matches",
        "quickfill.verify.fingerprint": "Please verify your fingerprint",
        "quickfill.error.not.connected": "Device not connected",
        "quickfill.error.fingerprint.denied": "Fingerprint verification failed",
        "quickfill.error.not.found": "Key not found",
        "quickfill.error.read.failed": "Read failed",
        "quickfill.error.empty": "Key is empty",

        // Password
        "password.title": "Configure Unlock Password",
        "password.message": "Enter your Mac login password for screen unlock:",
        "password.placeholder": "Password",
        "password.confirm.placeholder": "Confirm Password",
        "password.save": "Save",
        "password.saved": "Saved",
        "password.saved.message": "Password has been saved.",
        "password.error.empty": "Password cannot be empty.",
        "password.error.mismatch": "Passwords do not match.",
        "password.error.save": "Failed to save password: %@",
        "password.need.pair.first": "Please pair the device first before setting the unlock password.",

        // Alerts
        "alert.error": "Error",
        "alert.cancel": "Cancel",
        "alert.continue": "Continue",
        "alert.delete": "Delete",
        "alert.install": "Install",
        "alert.enable": "Enable",
        "alert.authorize": "Authorize",

        // Permissions Alerts
        "alert.need.accessibility": "Accessibility Permission Required",
        "alert.need.accessibility.message": "Screen unlock requires accessibility permission to simulate keyboard input.\n\nPlease grant permission in System Settings.",
        "alert.go.settings": "Open Settings",
        "alert.need.pam": "PAM Module Required",
        "alert.need.pam.sudo": "sudo authorization requires the PAM module to be installed first.",
        "alert.need.pam.auth": "Authorization requires the PAM module to be installed first.",
        "alert.need.pam.reinstall": "PAM module is not installed. Please run the immurok installer package again.",
        "alert.install.failed": "Installation Failed",
        "alert.enable.failed": "Enable Failed",
        "alert.disable.failed": "Disable Failed",

        // Status
        "status.device.connection": "Device Connection",
        "status.security.pairing": "Security Pairing",
        "status.fingerprint.count": "Fingerprints",
        "status.unlock.password": "Unlock Password",
        "status.accessibility": "Accessibility",
        "status.pam.module": "PAM Module",
        "status.sudo.auth": "sudo Auth",
        "status.auto.start": "Launch at Login",
        "status.waiting.device": "Waiting for device...",
        "status.tap.pair": "Tap \"Pair\" to pair the device",
        "status.tap.enroll": "Tap \"Enroll\" to add fingerprint",
        "status.tap.configure": "Tap \"Configure\" to set unlock password",
        "status.tap.authorize": "Tap \"Authorize\" to enable accessibility",
        "status.all.ready": "All set! Touch fingerprint to authenticate",

        // Setup Wizard
        "wizard.title": "immurok Setup Wizard",
        "wizard.subtitle": "Complete the following setup for first use",
        "wizard.step": "Step %d/%d",
        "wizard.prev": "Previous",
        "wizard.next": "Next",
        "wizard.done": "Done",
        "wizard.welcome": "Welcome to immurok",
        "wizard.intro": "immurok is a macOS Bluetooth fingerprint authentication system for:",
        "wizard.feature.unlock": "Unlock screen",
        "wizard.feature.sudo": "sudo command authorization",
        "wizard.feature.system": "System Settings authorization",
        "wizard.intro.next": "Some configuration is required before use.",
        "wizard.pam.title": "PAM Module",
        "wizard.pam.installed": "PAM Module Installed",
        "wizard.pam.location": "Location: /usr/local/lib/pam/pam_immurok.so",
        "wizard.pam.needpkg": "PAM Module Not Installed",
        "wizard.pam.needpkg.hint": "Please run the immurok installer package (immurok_install.pkg) to install the PAM module.",
        "wizard.accessibility.title": "Accessibility Permission",
        "wizard.accessibility.granted": "Accessibility Permission Granted",
        "wizard.accessibility.description": "immurok needs accessibility permission to simulate keyboard input for automatic screen unlock.",
        "wizard.accessibility.steps": "Authorization steps:",
        "wizard.accessibility.step1": "1. Click \"Authorize\" to open System Settings",
        "wizard.accessibility.step2": "2. Find immurok in the list",
        "wizard.accessibility.step3": "3. Enable the checkbox",
        "wizard.complete.title": "Setup Complete",
        "wizard.complete.message": "immurok is ready!",
        "wizard.complete.pam": "PAM Module",
        "wizard.complete.accessibility": "Accessibility Permission",
        "wizard.complete.hint": "You can enable \"sudo Authorization\" in settings to use fingerprint for sudo.",

        // Features
        "feature.unlock.mac": "Use immurok to unlock Mac",
        "feature.sudo": "Use immurok for sudo",
        "feature.system.auth": "Use immurok for System Settings",

        // About
        "about.uninstall": "Uninstall immurok",
        "about.uninstall.confirm": "Confirm Uninstall",
        "about.uninstall.message": "This will remove the PAM module, sudo configuration, and all user data. The app itself must be deleted manually.",
        "about.uninstall.done": "Uninstall Complete",
        "about.uninstall.done.message": "PAM module and user data have been removed.\n\nPlease manually move immurok.app to Trash to complete uninstallation.",
        "about.uninstall.failed": "Uninstall Failed",

        // Test
        "test.title": "Test Authentication",
        "test.device.not.connected": "Device Not Connected",
        "test.connect.first": "Please connect the device first.",
        "test.prompt": "Touch the fingerprint sensor...",
        "test.success": "Success",
        "test.success.message": "Authentication verified!",
        "test.failed": "Failed",
        "test.failed.message": "Timeout or device error.",

        // Errors
        "error.device.not.connected": "Device not connected",
        "error.communication.failed": "Communication failed",
        "error.save.pairing.failed": "Failed to save pairing data",
        "error.unknown": "Unknown error",
        "error.user.cancelled": "User cancelled the operation",
        "error.cannot.create.script": "Cannot create AppleScript",
        "error.command.failed": "Command execution failed",
        "error.pam.source.not.found": "PAM module source not found: %@",
        "error.install.failed": "Installation failed",
        "error.config.failed": "Configuration failed",
        "error.cannot.remove.sudo": "Cannot remove sudo config: %@",
        "error.cannot.remove.pam": "Cannot remove PAM module: %@",
        "error.need.pam.first": "Please install PAM module first",

        // Notifications
        "notification.need.accessibility": "Please grant accessibility permission in System Settings",
        "notification.cannot.unlock": "Cannot unlock screen",

        // Bluetooth
        "bluetooth.denied": "Bluetooth Permission Denied",
        "bluetooth.off": "Bluetooth is Off",
        "bluetooth.unsupported": "Bluetooth Not Supported",
        "bluetooth.denied.title": "Bluetooth Permission Required",
        "bluetooth.denied.message": "immurok needs Bluetooth permission to connect to the fingerprint device.\n\nPlease go to System Settings → Privacy & Security → Bluetooth to enable permission.",
        "bluetooth.off.message": "Please turn on Bluetooth to connect to immurok device.",
        "bluetooth.open.settings": "Open System Settings",

        // Settings
        "settings.language": "Language",
    ]
}

// MARK: - Convenience Extension

extension String {
    /// Get localized string
    var localized: String {
        return LocalizationManager.shared.string(self)
    }

    /// Get localized string with format arguments
    func localized(_ args: CVarArg...) -> String {
        let format = LocalizationManager.shared.string(self)
        return String(format: format, arguments: args)
    }
}

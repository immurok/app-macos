import AppKit

/// 设置窗口的标题，带版本号（"immurok app v1.6.8"）。版本取自 Info.plist，
/// 升版本不用改这里。findSettingsWindow 按这个标题找窗口，所以窗口定义
/// （immurokApp.swift）和查找必须共用这一个常量。
let settingsWindowTitle: String = {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    return version.map { "immurok app v\($0)" } ?? "immurok app"
}()

/// Locate the immurok settings window so modal dialogs can be presented as
/// sheets attached to it. Falls back to nil when the window is hidden, in
/// which case callers default to a screen-centered modal.
private func findSettingsWindow() -> NSWindow? {
    NSApp.windows.first {
        $0.isVisible &&
        !$0.isMiniaturized &&
        $0.title == settingsWindowTitle &&
        $0.styleMask.contains(.titled)
    }
}

extension NSAlert {
    /// Drop-in replacement for `runModal()` that presents the alert as a
    /// window-attached sheet on the settings window. Synchronous: pumps the
    /// run loop until the user dismisses, mirroring `runModal()` semantics.
    @discardableResult
    func runModalOverSettings() -> NSApplication.ModalResponse {
        guard let parent = findSettingsWindow() else {
            return runModal()
        }
        beginSheetModal(for: parent) { response in
            NSApp.stopModal(withCode: response)
        }
        return NSApp.runModal(for: parent)
    }
}

extension NSSavePanel {
    /// Drop-in replacement for `runModal()` that presents the panel as a
    /// window-attached sheet on the settings window. Inherited by NSOpenPanel.
    @discardableResult
    func runModalOverSettings() -> NSApplication.ModalResponse {
        guard let parent = findSettingsWindow() else {
            return runModal()
        }
        beginSheetModal(for: parent) { response in
            NSApp.stopModal(withCode: response)
        }
        return NSApp.runModal(for: parent)
    }
}

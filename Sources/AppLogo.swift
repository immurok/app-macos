import SwiftUI

/// immurok 的「石头」logo（Resources/icon.png，模板图，按强调色着色 → 蓝色）。
/// 关于页和设置向导共用；找不到资源时退回 App 图标。
enum AppLogo {
    static var templateImage: NSImage {
        if let url = Bundle.main.url(forResource: "icon", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            img.isTemplate = true
            return img
        }
        return NSApplication.shared.applicationIconImage
    }
}

/// 蓝色 logo 视图，`size` 为边长。
struct AppLogoView: View {
    let size: CGFloat

    var body: some View {
        Image(nsImage: AppLogo.templateImage)
            .resizable()
            .renderingMode(.template)
            .interpolation(.high)
            .frame(width: size, height: size)
            .foregroundColor(.accentColor)
    }
}

/// 蓝牙符号（卢恩字母 ᛒ 的样式）。SF Symbols 没有收录蓝牙标志，自己画。
/// 在 rect 内按比例绘制，用 .stroke 描边。
struct BluetoothGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        // 竖线占满高度，两组斜线各占一半，横向展开约 0.56 宽
        let w = rect.width, h = rect.height
        let cx = rect.midX
        let top = CGPoint(x: cx, y: rect.minY + h * 0.04)
        let bottom = CGPoint(x: cx, y: rect.minY + h * 0.96)
        let right = cx + w * 0.26
        let left = cx - w * 0.26
        var p = Path()
        p.move(to: top)
        p.addLine(to: bottom)
        // 上半：顶点 → 右上折点 → 左下
        p.move(to: top)
        p.addLine(to: CGPoint(x: right, y: rect.minY + h * 0.28))
        p.addLine(to: CGPoint(x: left, y: rect.minY + h * 0.72))
        // 下半：底点 → 右下折点 → 左上
        p.move(to: bottom)
        p.addLine(to: CGPoint(x: right, y: rect.minY + h * 0.72))
        p.addLine(to: CGPoint(x: left, y: rect.minY + h * 0.28))
        return p
    }
}

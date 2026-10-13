//  UIHarness：离屏渲染控制面板，导出 PNG 用于人工核对排版。
//  仅开发自查用，不参与 App 构建（安装器只编译 Sources/*.swift）。
import Cocoa

final class Harness: NSObject, NSApplicationDelegate {
    var prefs: PreferencesWindow!

    func applicationDidFinishLaunching(_ n: Notification) {
        prefs = PreferencesWindow()
        prefs.show()
        // 让异步缩略图有机会加载完再截图
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { self.capture() }
    }

    private func capture() {
        guard let win = NSApp.windows.first(where: { $0.title.contains("控制面板") }),
              let view = win.contentView else {
            print("找不到控制面板窗口"); exit(1)
        }
        view.layoutSubtreeIfNeeded()
        print("contentView frame=\(view.frame) bounds=\(view.bounds) flipped=\(view.isFlipped)")
        print("window frame=\(win.frame) contentRect=\(win.contentLayoutRect)")
        for (i, sub) in view.subviews.enumerated() {
            print("  sub[\(i)] \(type(of: sub)) frame=\(sub.frame)")
            if sub.subviews.count > 0 && i < 3 {
                for (j, inner) in sub.subviews.enumerated() where j < 12 {
                    print("      inner[\(j)] \(type(of: inner)) frame=\(inner.frame) hidden=\(inner.isHidden)")
                }
            }
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            print("无法创建位图"); exit(1)
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("PNG 编码失败"); exit(1)
        }
        let out = URL(fileURLWithPath: CommandLine.arguments.count > 1
                      ? CommandLine.arguments[1] : "/tmp/panel.png")
        try? data.write(to: out)
        print("导出: \(out.path) 尺寸=\(view.bounds.size)")
        exit(0)
    }
}

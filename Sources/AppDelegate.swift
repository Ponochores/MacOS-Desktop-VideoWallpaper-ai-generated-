//  AppDelegate.swift
//  App 骨架：状态栏菜单 + 控制面板 + 播放引擎
//
//  这个 App 是一个「后台代理型 App」（LSUIElement）：
//    · 平时没有 Dock 图标、不进 Cmd+Tab，只在菜单栏留一个 🖼 图标
//    · 点菜单栏图标就能控制一切；需要完整设置时打开控制面板
//    · 不需要任何终端窗口

import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let config = AppConfig.shared
    private let controller = WallpaperController()
    private let preferences = PreferencesWindow()

    private var statusItem: NSStatusItem?
    private var fillMenu: NSMenu?
    private var togglePlayItem: NSMenuItem?
    private var toggleVisibleItem: NSMenuItem?
    private var muteItem: NSMenuItem?
    private var volumeItem: NSMenuItem?
    private var panelObserver: NSObjectProtocol?

    // MARK: 启动

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. 恢复上次的选择（或使用 App 内置的默认视频）
        config.restoreVideoSelection()

        // 2. 起播放引擎：铺满桌面
        preferences.controller = controller
        controller.start()

        // 3. 菜单栏图标 —— 不需要终端窗口的控制入口
        buildStatusItem()

        // 4. 面板状态跟着引擎走
        panelObserver = NotificationCenter.default.addObserver(
            forName: AppConfig.didChangeNotification,
            object: config,
            queue: .main
        ) { [weak self] _ in
            self?.refreshMenuState()
        }
        controller.onStateChange = { [weak self] in
            self?.refreshMenuState()
        }

        // 5. 第一次运行、又找不到任何视频：直接把控制面板摊开让用户选
        if config.videoURL == nil {
            preferences.show()          // show() 内部会把 App 临时切成前台应用
            presentMissingVideoAlert()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let observer = panelObserver { NotificationCenter.default.removeObserver(observer) }
        controller.shutdown()
    }

    /// 关掉所有窗口不退出：壁纸还在跑（退出请用菜单栏里的「退出」）
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 壁纸窗口由屏幕参数自动生成，不需要状态恢复。显式声明以消除系统告警。
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: 拖视频到 App 图标上也能换壁纸

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { Self.isVideoFile($0) }) else { return }
        config.setVideo(url)
        refreshMenuState()
    }

    private static func isVideoFile(_ url: URL) -> Bool {
        ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
    }

    // MARK: 菜单栏

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "photo.on.rectangle.angled",
                                   accessibilityDescription: "视频壁纸")
            button.image?.isTemplate = true
            button.toolTip = "视频壁纸"
        }

        let menu = NSMenu()

        let panel = NSMenuItem(title: "打开控制面板…", action: #selector(openPreferences), keyEquivalent: ",")
        panel.target = self
        menu.addItem(panel)

        let pick = NSMenuItem(title: "更换视频…", action: #selector(pickVideoFromMenu), keyEquivalent: "o")
        pick.target = self
        menu.addItem(pick)

        menu.addItem(.separator())

        // 填充模式：手动开关就放在最显眼的地方
        let fillRoot = NSMenuItem(title: "屏幕填充方式", action: nil, keyEquivalent: "")
        let fillSub = NSMenu()
        for mode in FillMode.allCases {
            let entry = NSMenuItem(title: mode.title, action: #selector(selectFillMode(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = mode.rawValue
            entry.toolTip = mode.detail
            fillSub.addItem(entry)
        }
        fillRoot.submenu = fillSub
        menu.addItem(fillRoot)
        fillMenu = fillSub

        let play = NSMenuItem(title: "暂停播放", action: #selector(togglePlayPause), keyEquivalent: "p")
        play.target = self
        menu.addItem(play)
        togglePlayItem = play

        let visible = NSMenuItem(title: "隐藏桌面壁纸", action: #selector(toggleVisible), keyEquivalent: "h")
        visible.target = self
        menu.addItem(visible)
        toggleVisibleItem = visible

        let mute = NSMenuItem(title: "静音", action: #selector(toggleMute), keyEquivalent: "m")
        mute.target = self
        menu.addItem(mute)
        muteItem = mute

        // 只读显示当前音量；要拖动就进控制面板
        let volume = NSMenuItem(title: "音量 60%", action: #selector(openPreferences), keyEquivalent: "")
        volume.target = self
        menu.addItem(volume)
        volumeItem = volume

        menu.addItem(.separator())

        let about = NSMenuItem(title: "视频壁纸 v2.0", action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)

        let quit = NSMenuItem(title: "退出视频壁纸", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
        refreshMenuState()
    }

    private func refreshMenuState() {
        let mode = config.fillMode
        fillMenu?.items.forEach { $0.state = ($0.representedObject as? String) == mode.rawValue ? .on : .off }
        togglePlayItem?.title = controller.isPlaying ? "暂停播放" : "继续播放"
        muteItem?.state = config.isMuted ? .on : .off
        let percent = Int((config.volume * 100).rounded())
        volumeItem?.title = config.isMuted ? "音量 \(percent)%（已静音，点此调节）" : "音量 \(percent)%"
        preferences.refresh()
    }

    // MARK: 菜单动作

    @objc private func openPreferences() {
        preferences.show()
    }

    @objc private func pickVideoFromMenu() {
        preferences.show()
        preferences.beginPickingVideo()      // 面板起来后直接弹文件选择器，少点一步
    }

    @objc private func selectFillMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = FillMode(rawValue: raw) else { return }
        config.fillMode = mode
        refreshMenuState()
    }

    @objc private func toggleMute() {
        config.isMuted.toggle()
        refreshMenuState()
    }

    @objc private func togglePlayPause() {
        controller.togglePlayPause()
        refreshMenuState()
    }

    /// 临时隐藏/显示壁纸（看电影、演示时有用）
    @objc private func toggleVisible() {
        let hidden = controller.setWindowsHidden(!controller.windowsAreHidden)
        toggleVisibleItem?.title = hidden ? "显示桌面壁纸" : "隐藏桌面壁纸"
    }

    @objc private func quit() {
        controller.shutdown()
        NSApp.terminate(nil)
    }

    // MARK: 找不到视频时的提示

    private func presentMissingVideoAlert() {
        let alert = NSAlert()
        alert.messageText = "还没有可用的壁纸视频"
        alert.informativeText = "点「选择视频…」挑一段本地视频（mp4 / mov / m4v），选中后按「应用」就会立刻铺到桌面上。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }
}

//  WallpaperController.swift
//  壁纸播放引擎
//
//  职责：
//    · 每个显示器一块「桌面图层」，插在桌面图标之下、系统壁纸之上
//    · 所有显示器共用同一个 AVQueuePlayer（只解码一份，多屏不掉帧）
//    · 响应 AppConfig 的变化：换视频 / 换填充模式 / 静音 / 暂停
//    · 显示器插拔、分辨率变化时增量更新窗口（不再全量重建）
//    · 屏幕休眠、锁屏、系统睡眠时自动暂停，唤醒后恢复，避免后台空转耗电

import Cocoa
import AVFoundation

// MARK: - 桌面图层窗口

final class WallpaperWindow: NSWindow {

    let playerView: PlayerView

    init(screen: NSScreen) {
        playerView = PlayerView(frame: NSRect(origin: .zero, size: screen.frame.size))

        super.init(contentRect: screen.frame,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)

        // 关键：不要成为 key window，否则会抢走用户的键盘焦点
        isReleasedWhenClosed = false

        // 层级：比「桌面图标」低 1 层 —— 壁纸在图标下面，图标照常点、照常拖
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)

        // 所有桌面空间都显示，Mission Control 里不参与重排，Cmd+` 也切不到
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        ignoresMouseEvents = true          // 鼠标事件穿透到桌面，右键、框选都正常
        hasShadow = false
        isOpaque = true
        backgroundColor = .black
        isMovable = false
        canHide = false
        animationBehavior = .none          // 换屏时不要淡入淡出动画
        setFrame(screen.frame, display: false)

        contentView = playerView
    }

    /// 跟随显示器位置/分辨率变化
    func move(to screen: NSScreen) {
        setFrame(screen.frame, display: true)
        playerView.needsLayout = true
    }

    func show() { orderFrontRegardless() }   // 不激活 App 也能显示
}

// MARK: - 播放引擎

final class WallpaperController {

    /// 屏幕 → 窗口 的映射，用 CGDirectDisplayID 做键（NSScreen 对象本身会被换掉）
    private var windows: [CGDirectDisplayID: WallpaperWindow] = [:]
    private var player: AVQueuePlayer?
    private var currentItem: AVPlayerItem?
    private var looper: AVPlayerLooper?
    private var observers: [NSObjectProtocol] = []
    private var lockObserver: NSObjectProtocol?
    private var positionTimer: Timer?

    /// 界面上要展示的状态，变化时回调
    var onStateChange: (() -> Void)?

    /// 元数据（分辨率 / 时长）
    private(set) var videoSize: CGSize = .zero
    private(set) var videoDuration: Double = 0

    var isPlaying: Bool { (player?.rate ?? 0) > 0 }

    /// 桌面壁纸当前是否被手动隐藏
    private(set) var windowsAreHidden = false

    // MARK: 生命周期

    func start() {
        observeConfig()
        observeWorkspace()
        rebuildWindows()
        loadVideo()
        startPositionTimer()
    }

    func shutdown() {
        savePositionNow()
        positionTimer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        if let lockObserver = lockObserver {
            DistributedNotificationCenter.default().removeObserver(lockObserver)
            self.lockObserver = nil
        }
        windows.values.forEach { $0.close() }
        windows.removeAll()
        player?.pause()
        player = nil
    }

    // MARK: 显示器

    /// 全量重建：启动时用一次
    private func rebuildWindows() {
        let alive = Set(NSScreen.screens.compactMap { Self.displayID(of: $0) })
        // 关掉已经不存在的
        for (id, window) in windows where !alive.contains(id) {
            window.close()
            windows.removeValue(forKey: id)
        }
        // 补上新增的 / 更新已有的
        for screen in NSScreen.screens { upsertWindow(for: screen) }
    }

    /// 增量更新：显示器热插拔时只动该动的窗口
    private func syncScreens() {
        rebuildWindows()
        bindAllWindows()
    }

    @discardableResult
    private func upsertWindow(for screen: NSScreen) -> WallpaperWindow {
        guard let id = Self.displayID(of: screen) else {
            // 拿不到 displayID 的极端情况：直接建一个临时窗口，保证有画面
            let window = WallpaperWindow(screen: screen)
            window.show()
            return window
        }
        if let existing = windows[id] {
            existing.move(to: screen)
            return existing
        }
        let window = WallpaperWindow(screen: screen)
        window.playerView.applyFillMode(AppConfig.shared.fillMode)
        window.playerView.onMetadataReady = { [weak self] size, duration in
            self?.videoSize = size
            self?.videoDuration = duration
            self?.onStateChange?()
        }
        windows[id] = window
        // 若此刻正处于「隐藏壁纸」状态，新屏幕的窗口也别冒出来
        if !windowsAreHidden { window.show() }
        return window
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    // MARK: 视频加载

    /// 载入当前配置里的视频；换视频时调用
    private func loadVideo() {
        guard let url = AppConfig.shared.videoURL else {
            NSLog("[VideoWallpaper] 还没有选择视频")
            onStateChange?()
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSLog("[VideoWallpaper] 视频文件不存在：\(url.path)")
            onStateChange?()
            return
        }

        // 拆掉旧的，释放解码器
        teardownPlayer()

        let item = AVPlayerItem(url: url)
        // 只在需要时占用网络/磁盘 IO，本地文件影响很小
        item.preferredForwardBufferDuration = 5

        let queuePlayer = AVQueuePlayer()
        queuePlayer.isMuted = AppConfig.shared.isMuted
        queuePlayer.volume = AppConfig.shared.volume     // 静音开着也没关系，音量值先就位
        queuePlayer.actionAtItemEnd = .advance
        // 壁纸不需要音轨处理之外的额外工作，关掉等待网络等无关优化
        queuePlayer.automaticallyWaitsToMinimizeStalling = false

        // AVPlayerLooper 内部维持两个 item 交替，循环处不会黑一下
        looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        player = queuePlayer
        currentItem = item

        bindAllWindows()
        restorePositionIfNeeded(for: url)
        applyPlaybackState()
        onStateChange?()
    }

    private func teardownPlayer() {
        // 先解绑所有图层，再丢引用，确保 looper 与 player 及时释放（否则解码器会残留）
        windows.values.forEach { $0.playerView.unbind() }
        player?.pause()
        player = nil
        currentItem = nil
        looper = nil
    }

    /// 把所有窗口的图层绑到同一个播放器上
    private func bindAllWindows() {
        guard let player = player, let item = currentItem else { return }
        for window in windows.values {
            window.playerView.applyFillMode(AppConfig.shared.fillMode)
            window.playerView.bind(player: player, item: item)
        }
    }

    // MARK: 播放控制

    private func applyPlaybackState() {
        guard let player = player else { return }
        player.isMuted = AppConfig.shared.isMuted
        player.volume = AppConfig.shared.volume
        if AppConfig.shared.isPaused {
            player.pause()
        } else {
            player.play()
        }
        onStateChange?()
    }

    /// 转动音量滑块时的轻量更新：只改音量，不重启播放
    private func applyVolume() {
        player?.volume = AppConfig.shared.volume
        player?.isMuted = AppConfig.shared.isMuted
        onStateChange?()
    }

    /// 当前实际音量（0…1，静音时为 0），给界面显示用
    var effectiveVolume: Float {
        AppConfig.shared.isMuted ? 0 : AppConfig.shared.volume
    }

    func togglePlayPause() {
        AppConfig.shared.isPaused.toggle()
    }

    func pause(reason: String) {
        guard let player = player, player.rate > 0 else { return }
        player.pause()
        NSLog("[VideoWallpaper] 暂停播放：\(reason)")
        onStateChange?()
    }

    func resume(reason: String) {
        guard let player = player, !AppConfig.shared.isPaused else { return }
        player.play()
        NSLog("[VideoWallpaper] 恢复播放：\(reason)")
        onStateChange?()
    }

    /// 隐藏 / 显示整块壁纸。返回操作后的隐藏状态。
    /// 隐藏时把窗口 orderOut 掉，画面不参与合成；继续播放还是停掉由当前设置决定。
    @discardableResult
    func setWindowsHidden(_ hidden: Bool) -> Bool {
        windowsAreHidden = hidden
        for window in windows.values {
            if hidden {
                window.orderOut(nil)
            } else {
                window.orderFrontRegardless()
            }
        }
        onStateChange?()
        return windowsAreHidden
    }

    // MARK: 进度记忆

    private func restorePositionIfNeeded(for url: URL) {
        guard let seconds = AppConfig.shared.savedPosition(for: url),
              let player = player,
              let duration = player.currentItem?.duration.seconds,
              duration.isFinite, seconds < duration - 1 else { return }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func startPositionTimer() {
        // 每 5 秒记一次进度：够用，且几乎不耗电
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.savePositionNow()
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        positionTimer = timer
    }

    private func savePositionNow() {
        guard let url = AppConfig.shared.videoURL,
              let seconds = player?.currentTime().seconds else { return }
        AppConfig.shared.savePosition(seconds, for: url)
    }

    // MARK: 事件

    private func observeConfig() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AppConfig.didChangeNotification,
                                            object: AppConfig.shared,
                                            queue: .main) { [weak self] note in
            guard let self = self,
                  let key = note.userInfo?["key"] as? AppConfig.ChangedKey else { return }
            switch key {
            case .videoURL:
                self.loadVideo()
            case .fillMode:
                // 只改 gravity，不重载视频 —— 切换是全屏即时的
                let mode = AppConfig.shared.fillMode
                self.windows.values.forEach { $0.playerView.applyFillMode(mode) }
                self.onStateChange?()
            case .muted:
                self.applyVolume()
            case .volume:
                self.applyVolume()
            case .paused:
                self.applyPlaybackState()
            case .autoStart, .rememberPosition:
                self.onStateChange?()
            }
        })
    }

    private func observeWorkspace() {
        let center = NotificationCenter.default

        // 显示器插拔 / 改分辨率
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.syncScreens()
        })

        // 屏幕休眠 / 唤醒：休眠时别再解码了
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.pause(reason: "屏幕休眠")
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.resume(reason: "屏幕唤醒")
        })
        // 锁屏 / 切换用户
        observers.append(workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.pause(reason: "锁屏")
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.resume(reason: "解锁")
        })
        // 锁屏的分布式通知：部分机型上比 session 通知更及时
        let distributed = DistributedNotificationCenter.default()
        lockObserver = distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                                               object: nil, queue: .main) { [weak self] _ in
            self?.pause(reason: "屏幕已锁定")
        }
        // 系统睡眠 / 唤醒
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.pause(reason: "系统睡眠")
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.resume(reason: "系统唤醒")
        })
    }
}

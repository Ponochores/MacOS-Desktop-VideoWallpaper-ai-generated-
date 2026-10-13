//  AppConfig.swift
//  视频壁纸 · 配置中心
//
//  设计目标：把「所有开关」收敛到一个可观察的对象里。
//  界面（偏好设置窗口 / 菜单栏）只负责改这里的值，
//  播放层（WallpaperController）只负责响应变化 —— 单向数据流，避免状态打架。

import Cocoa
import AVFoundation

// MARK: - 画面填充模式

/// 视频相对屏幕的填充方式，对应 AVPlayerLayer.videoGravity
enum FillMode: String, CaseIterable {
    /// 铺满：等比放大直到盖住整块屏幕，多出来的部分裁掉（画面最饱满，可能有裁切）
    case fill
    /// 适应：完整显示整段视频，四周留黑边（不裁切，可能有黑边）
    case fit
    /// 拉伸：不保持比例硬拉到屏幕尺寸（一定铺满，但画面会变形）
    case stretch

    /// 中文名，给界面用
    var title: String {
        switch self {
        case .fill:    return "铺满屏幕"
        case .fit:     return "完整适应"
        case .stretch: return "拉伸铺满"
        }
    }

    /// 一句话解释，给界面当副标题用
    var detail: String {
        switch self {
        case .fill:    return "等比放大裁掉多余部分，画面最饱满、不留黑边"
        case .fit:     return "完整显示整段视频，比例不一致时四周留黑边"
        case .stretch: return "强行拉满整屏，比例不一致时画面会变形"
        }
    }

    /// 映射到 AVFoundation 的填充枚举
    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .fill:    return .resizeAspectFill
        case .fit:     return .resizeAspect
        case .stretch: return .resize
        }
    }
}

// MARK: - 配置中心

final class AppConfig {

    /// 全局单例：界面和播放层拿到的是同一份状态
    static let shared = AppConfig()

    /// 配置变化通知（object 为 AppConfig.shared，userInfo["key"] 为 ChangedKey）
    static let didChangeNotification = Notification.Name("VideoWallpaper.configDidChange")

    /// 变化项，方便监听方决定要不要重建播放器
    enum ChangedKey: String {
        case videoURL         // 换了视频文件
        case fillMode         // 换了填充模式（不需要重载视频，改 gravity 即可）
        case muted            // 静音开关
        case volume           // 音量大小
        case paused           // 播放/暂停
        case autoStart        // 开机自启
        case rememberPosition // 记忆播放进度
    }

    private let defaults: UserDefaults

    // UserDefaults 的键名集中管理，避免散落各处拼字符串
    private enum Key {
        static let videoPath        = "videoPath"
        static let fillMode         = "fillMode"
        static let muted            = "muted"
        static let volume           = "volume"
        static let autoStart        = "autoStart"
        static let rememberPosition = "rememberPosition"
        static let position         = "playbackPosition"
        static let positionFile     = "playbackPositionFile"
    }

    private init() {
        // 用 .standard：应用偏好应当存放在以 bundle id 命名的域中，由系统负责管理。
        // 以应用自身的 bundle id 作为 suite 名属于误用，会触发系统告警。
        defaults = .standard
        Self.migrateLegacySuiteIfNeeded(into: defaults)
        defaults.register(defaults: [
            Key.fillMode:         FillMode.fill.rawValue,   // 默认铺满，无黑边
            Key.muted:            true,      // 默认静音，避免壁纸意外出声
            Key.volume:           0.6,       // 音量预置 60%，取消静音即有声
            Key.autoStart:        false,
            Key.rememberPosition: true,
        ])
    }

    /// 将历史上误存于自定义 suite 的配置迁移至 `.standard`。
    ///
    /// 以 bundle id 作为 suite 名会产生一个独立的偏好域。为保证升级用户不丢失配置，
    /// 此处做一次性搬迁：仅当 `.standard` 中尚无本应用的键时执行。
    private static func migrateLegacySuiteIfNeeded(into standard: UserDefaults) {
        let legacySuiteName = "local.vk.wallpaper"

        // 已迁移过，或本就使用 .standard：无需处理
        if standard.object(forKey: Key.fillMode) != nil { return }
        guard let legacy = UserDefaults(suiteName: legacySuiteName) else { return }
        guard legacy.object(forKey: Key.fillMode) != nil else { return }   // 旧域无数据

        let keys = [Key.fillMode, Key.muted, Key.volume, Key.autoStart,
                    Key.rememberPosition, Key.position, Key.positionFile, Key.videoPath]
        var moved = 0
        for key in keys {
            guard let value = legacy.object(forKey: key) else { continue }
            standard.set(value, forKey: key)
            moved += 1
        }
        if moved > 0 {
            NSLog("[VideoWallpaper] 已从旧偏好域迁移 \(moved) 项设置")
        }
    }

    // MARK: 视频源

    /// 当前使用的视频文件；nil 表示还没选过
    private(set) var videoURL: URL? {
        didSet { notify(.videoURL) }
    }

    /// 启动时把上次的选择读回来
    func restoreVideoSelection() {
        if let path = defaults.string(forKey: Key.videoPath) {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                videoURL = url
                return
            }
        }
        // 兜底：App 自带的默认视频（App 包内 Resources/default.mp4）
        if let bundled = Bundle.main.url(forResource: "default", withExtension: "mp4") {
            videoURL = bundled
        }
    }

    /// 手动切换视频源
    func setVideo(_ url: URL) {
        guard url.standardizedFileURL != videoURL?.standardizedFileURL else { return }
        defaults.set(url.path, forKey: Key.videoPath)
        videoURL = url
    }

    // MARK: 填充模式（本次新增的「手动开关」核心）

    var fillMode: FillMode {
        get { FillMode(rawValue: defaults.string(forKey: Key.fillMode) ?? "") ?? .fill }
        set {
            guard newValue != fillMode else { return }
            defaults.set(newValue.rawValue, forKey: Key.fillMode)
            notify(.fillMode)
        }
    }

    // MARK: 播放状态

    /// 静音（壁纸一般都要静音，默认开）
    var isMuted: Bool {
        get { defaults.bool(forKey: Key.muted) }
        set {
            guard newValue != isMuted else { return }
            defaults.set(newValue, forKey: Key.muted)
            notify(.muted)
        }
    }

    /// 手动暂停：暂停后窗口保留但不再解码，省电
    var isPaused: Bool = false {
        didSet {
            guard isPaused != oldValue else { return }
            notify(.paused)
        }
    }

    /// 音量大小 0…1。
    /// 和静音分开存：静音只是「关掉输出」，音量值本身保留，
    /// 这样取消静音时能回到用户上次调好的大小。
    var volume: Float {
        get { Float(defaults.double(forKey: Key.volume)) }
        set {
            let clamped = min(max(newValue, 0), 1)
            guard abs(clamped - volume) > 0.001 else { return }
            defaults.set(Double(clamped), forKey: Key.volume)
            notify(.volume)
        }
    }

    /// 拖动音量滑块时调用：音量生效的同时自动解除静音。
    /// （用户主动去拖音量条，意图就是「我要听见声音」）
    func setVolumeActive(_ value: Float) {
        volume = value
        if isMuted && value > 0 { isMuted = false }
    }

    // MARK: 导入的视频

    /// 导入的视频统一存放在这里，换机器上的原文件位置也不会丢
    static var importedVideosDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("VideoWallpaper/Videos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 这个视频是不是「已导入」的那份拷贝
    func isImported(_ url: URL?) -> Bool {
        guard let url = url else { return false }
        return url.standardizedFileURL.path.hasPrefix(Self.importedVideosDirectory.standardizedFileURL.path)
    }

    /// 正在使用的视频被删掉时，回退到 App 内置视频
    func fallBackToBundledVideo() {
        guard let bundled = Bundle.main.url(forResource: "default", withExtension: "mp4") else {
            videoURL = nil
            return
        }
        defaults.set(bundled.path, forKey: Key.videoPath)
        videoURL = bundled
    }

    // MARK: 启动行为

    /// 记忆播放进度：重启 App 后接着上次的位置播，避免每次都从头开始
    var remembersPosition: Bool {
        get { defaults.bool(forKey: Key.rememberPosition) }
        set {
            guard newValue != remembersPosition else { return }
            defaults.set(newValue, forKey: Key.rememberPosition)
            notify(.rememberPosition)
        }
    }

    /// 开机自启（写 LaunchAgent，不依赖终端）
    var autoStart: Bool {
        get { defaults.bool(forKey: Key.autoStart) }
        set {
            guard newValue != autoStart else { return }
            defaults.set(newValue, forKey: Key.autoStart)
            notify(.autoStart)
        }
    }

    // MARK: 播放进度存档

    /// 记录某个视频的播放位置（秒）
    func savePosition(_ seconds: Double, for url: URL) {
        guard remembersPosition, seconds.isFinite, seconds > 0 else { return }
        defaults.set(seconds, forKey: Key.position)
        defaults.set(url.path, forKey: Key.positionFile)
    }

    /// 取出某个视频上次的播放位置；文件对不上就返回 nil
    func savedPosition(for url: URL) -> Double? {
        guard remembersPosition,
              let path = defaults.string(forKey: Key.positionFile),
              path == url.path else { return nil }
        let seconds = defaults.double(forKey: Key.position)
        return seconds > 0 ? seconds : nil
    }

    func clearSavedPosition() {
        defaults.removeObject(forKey: Key.position)
        defaults.removeObject(forKey: Key.positionFile)
    }

    // MARK: 通知

    private func notify(_ key: ChangedKey) {
        NotificationCenter.default.post(
            name: AppConfig.didChangeNotification,
            object: self,
            userInfo: ["key": key]
        )
    }
}

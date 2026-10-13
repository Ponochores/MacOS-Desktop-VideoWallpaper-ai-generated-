//  PlayerView.swift
//  视频渲染层
//
//  用 AVPlayerLayer 作为 backing layer，视频帧直接进图层树，
//  不经过 CPU 合成，也不需要在 draw(_:) 里做任何事 —— 这是 macOS 上最省电的播放方式。
//
//  这里唯一负责的两件事：
//    1. 让图层始终等于窗口尺寸（窗口变化时不抖动）
//    2. 把 AppConfig.fillMode 翻译成 videoGravity

import Cocoa
import AVFoundation

final class PlayerView: NSView {

    /// KVO 上下文：给一个专属指针，避免和父类的观察者混淆
    private static var kvoContext: UInt8 = 0

    /// 视频渲染图层。多个屏幕各有自己的 PlayerView，
    /// 但它们的 playerLayer.player 指向同一个 AVQueuePlayer，解码只做一份。
    let playerLayer = AVPlayerLayer()

    /// 视频原始尺寸（异步拿到，供界面显示"多少 × 多少"）
    private(set) var naturalSize: CGSize = .zero

    /// 视频总时长（秒），0 表示未知
    private(set) var duration: Double = 0

    /// 元数据就绪后的回调，用来刷新状态面板
    var onMetadataReady: ((CGSize, Double) -> Void)?

    private var lastFillMode: FillMode?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        // 自建根图层：背景纯黑，视频盖在上面
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        root.masksToBounds = true          // 铺满模式裁掉的画面不要溢到别的屏幕
        layer = root
        root.addSublayer(playerLayer)

        playerLayer.videoGravity = FillMode.fill.videoGravity
        playerLayer.backgroundColor = NSColor.black.cgColor

        // 让图层跟随窗口尺寸变化（默认只在初始化时设一次）
        autoresizingMask = [.width, .height]
        applyFillMode(AppConfig.shared.fillMode)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    deinit {
        // 观察者是 KVO 形式注册的，必须显式摘掉，否则会崩
        if let item = observedItem {
            item.removeObserver(self, forKeyPath: #keyPath(AVPlayerItem.status))
        }
    }

    // MARK: 填充模式

    /// 切换填充模式。切换只改 gravity，不需要重载视频，所以是即时的。
    func applyFillMode(_ mode: FillMode) {
        guard mode != lastFillMode else { return }
        lastFillMode = mode

        // 关掉隐式动画，否则切换瞬间会有缩放过渡
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.videoGravity = mode.videoGravity
        CATransaction.commit()
    }

    // MARK: 绑定播放器

    private weak var boundPlayer: AVQueuePlayer?
    private var observedItem: AVPlayerItem?

    /// 绑定（或共用）一个播放器。多个屏幕调用同一个播放器即可，不会重复解码。
    func bind(player: AVQueuePlayer, item: AVPlayerItem) {
        guard boundPlayer !== player else { return }
        boundPlayer = player
        playerLayer.player = player

        if observedItem !== item {
            if let old = observedItem {
                old.removeObserver(self, forKeyPath: #keyPath(AVPlayerItem.status))
            }
            observedItem = item
            item.addObserver(self, forKeyPath: #keyPath(AVPlayerItem.status),
                             options: [.initial, .new],
                             context: &PlayerView.kvoContext)
        }
    }

    /// 解绑（换视频 / 关机时用）
    func unbind() {
        playerLayer.player = nil
        if let old = observedItem {
            old.removeObserver(self, forKeyPath: #keyPath(AVPlayerItem.status))
        }
        observedItem = nil
        boundPlayer = nil
    }

    // MARK: 元数据

    override func observeValue(forKeyPath keyPath: String?,
                               of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        guard keyPath == #keyPath(AVPlayerItem.status),
              let item = object as? AVPlayerItem else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        guard context == &PlayerView.kvoContext else { return }
        guard item.status == .readyToPlay else { return }

        // 尺寸和时长要等 asset 加载完才有值
        let size = item.presentationSize
        let seconds = item.duration.seconds
        naturalSize = size
        duration = seconds.isFinite ? seconds : 0
        onMetadataReady?(naturalSize, duration)
    }

    // MARK: 布局

    override func layout() {
        super.layout()
        syncLayerFrame()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncLayerFrame()
    }

    /// 图层不会自动跟随，必须手动同步；关掉隐式动画避免拖动时画面抖动
    private func syncLayerFrame() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

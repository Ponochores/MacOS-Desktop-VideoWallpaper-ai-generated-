//  PreferencesWindow.swift
//  前端控制窗口（偏好设置面板）
//
//  这是本版本新增的「门面」：所有开关都在这里，不需要再碰终端。
//    · 选择 / 更换视频（原生文件选择器）
//    · 填充模式开关：铺满屏幕 / 完整适应 / 拉伸铺满   ← 本次需求的核心
//    · 静音、暂停、开机自启
//    · 实时预览缩略图 + 视频信息 + 运行状态
//
//  界面用纯 AppKit 手写布局：不依赖 XIB / Storyboard，swiftc 一条命令就能编出 App 包。

import Cocoa
@preconcurrency import AVFoundation
@preconcurrency import ServiceManagement

// MARK: - 卡片容器（圆角背景，视觉分层用）

final class CardView: NSView {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        // 用动态颜色，深浅色模式都好看
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
    }
}

// MARK: - 偏好设置窗口

final class PreferencesWindow: NSObject, NSWindowDelegate {

    /// 由 AppDelegate 注入，用来触发播放引擎的动作
    weak var controller: WallpaperController?

    private var window: NSWindow?
    private var thumbnailView: NSImageView?
    private var titleLabel: NSTextField?
    private var infoLabel: NSTextField?
    private var statusLabel: NSTextField?
    private var applyButton: NSButton?
    private var fillSegment: NSSegmentedControl?
    private var fillDetailLabel: NSTextField?
    private var muteCheck: NSButton?
    private var pauseCheck: NSButton?
    private var autoStartCheck: NSButton?
    private var rememberCheck: NSButton?
    private var volumeSlider: NSSlider?
    private var volumeValueLabel: NSTextField?
    private var importButton: NSButton?
    private var removeImportedButton: NSButton?
    private var busyIndicator: NSProgressIndicator?

    private var pendingVideo: URL?          // 已选但尚未应用的视频
    private var observers: [NSObjectProtocol] = []
    private var isBusy = false              // 导入中：按钮要禁用，避免重复操作

    // 布局常量。高度由下面这些数字推出来，保证窗口正好包住内容、底部不留大片空白。
    private let padding: CGFloat = 22
    private let width: CGFloat = 540
    private let videoCardHeight: CGFloat = 172
    private let fillCardHeight: CGFloat = 118
    private let optionCardHeight: CGFloat = 140
    private let gap: CGFloat = 14

    /// 内容总高 = 上下留白 + 标题区 + 三张卡片 + 卡片间距 + 底部行
    private var windowHeight: CGFloat {
        padding * 2 + 24 + 18 + 18 + gap * 2 + videoCardHeight + fillCardHeight + optionCardHeight + 20
    }

    // MARK: 显示 / 隐藏

    func show() {
        let win = window ?? buildWindow()
        window = win
        refresh()
        // agent 应用平时不在 Dock 里，打开面板时临时切成常规应用，保证能拿到焦点
        NSApp.setActivationPolicy(.regular)
        Self.activateApp()
        win.makeKeyAndOrderFront(nil)
        win.center()
    }

    func windowWillClose(_ notification: Notification) {
        // 关掉面板后回到「小透明」状态：不占 Dock、不进 Cmd+Tab
        NSApp.setActivationPolicy(.accessory)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { true }

    /// 把 App 拉到最前。macOS 14 起推荐无参 activate()，老系统退回旧 API。
    static func activateApp() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: 构建界面

    private func buildWindow() -> NSWindow {
        // fixedSize：面板是固定尺寸的，不希望它被拉伸
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: windowHeight),
                           styleMask: [.titled, .closable, .miniaturizable],
                           backing: .buffered,
                           defer: false)
        win.title = "视频壁纸 · 控制面板"
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.animationBehavior = .documentWindow

        // 先让窗口把尺寸定下来，再按「真实的」内容区高度排版。
        // 如果先塞进去一个比窗口高的 view，再加上 autoresizingMask，
        // 窗口为了适配会等比缩放整个内容视图 —— 结果就是每张卡片都被纵向拉长、
        // 顶部的标题被挤出可视区、底部的按钮被裁掉。
        win.setContentSize(NSSize(width: width, height: windowHeight))
        let contentRect = win.contentLayoutRect
        let contentHeight = contentRect.height
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: contentHeight))
        // 尺寸是算好的，不要参与自动缩放
        content.autoresizingMask = []

        // ---------- 顶部标题 ----------
        let title = NSTextField(labelWithString: "🖥  桌面视频壁纸")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.frame = NSRect(x: padding, y: 0, width: width - padding * 2, height: 24)
        content.addSubview(title)
        titleLabel = title

        let subtitle = NSTextField(labelWithString: "视频铺在桌面图标之下、系统壁纸之上；下面所有开关即时生效。")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: padding, y: 0, width: width - padding * 2, height: 16)
        content.addSubview(subtitle)

        // ---------- 卡片 1：视频源 ----------
        let videoCard = CardView(frame: .zero)
        content.addSubview(videoCard)

        let videoTitle = NSTextField(labelWithString: "1  视频来源")
        videoTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        videoCard.addSubview(videoTitle)

        let thumb = NSImageView(frame: .zero)
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 8
        thumb.layer?.masksToBounds = true
        thumb.layer?.backgroundColor = NSColor.black.cgColor
        videoCard.addSubview(thumb)
        thumbnailView = thumb

        let fileName = NSTextField(labelWithString: "—")
        fileName.font = .systemFont(ofSize: 12)
        fileName.maximumNumberOfLines = 2
        fileName.lineBreakMode = .byTruncatingMiddle
        videoCard.addSubview(fileName)
        infoLabel = fileName                 // 复用：显示文件名 + 尺寸/时长

        let pickButton = NSButton(title: "选择视频…", target: self, action: #selector(pickVideo))
        pickButton.bezelStyle = .rounded
        pickButton.controlSize = .large
        videoCard.addSubview(pickButton)

        let apply = NSButton(title: "应用", target: self, action: #selector(applyVideo))
        apply.bezelStyle = .rounded
        apply.controlSize = .large
        apply.keyEquivalent = "\r"
        apply.isEnabled = false
        videoCard.addSubview(apply)
        applyButton = apply

        // 导入：把视频复制进 App 自己的素材库，原文件删了/挪了都不影响
        let importBtn = NSButton(title: "导入视频…", target: self, action: #selector(importVideo))
        importBtn.bezelStyle = .rounded
        importBtn.controlSize = .large
        importBtn.toolTip = "把视频复制到 App 的素材库（~/资源库/Application Support/VideoWallpaper/Videos）并立即使用"
        videoCard.addSubview(importBtn)
        importButton = importBtn

        // 只有在用素材库里的视频时才显示「移除」
        let removeBtn = NSButton(title: "移除已导入", target: self, action: #selector(removeImportedVideo))
        removeBtn.bezelStyle = .rounded
        removeBtn.controlSize = .small
        removeBtn.isHidden = true
        videoCard.addSubview(removeBtn)
        removeImportedButton = removeBtn

        // ---------- 卡片 2：填充模式（手动开关） ----------
        let fillCard = CardView(frame: .zero)
        content.addSubview(fillCard)

        let fillTitle = NSTextField(labelWithString: "2  屏幕填充方式")
        fillTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        fillCard.addSubview(fillTitle)

        let segment = NSSegmentedControl(labels: FillMode.allCases.map { $0.title },
                                         trackingMode: .selectOne,
                                         target: self,
                                         action: #selector(fillModeChanged(_:)))
        segment.controlSize = .large
        segment.segmentDistribution = .fillEqually
        fillCard.addSubview(segment)
        fillSegment = segment

        let fillDetail = NSTextField(labelWithString: "")
        fillDetail.font = .systemFont(ofSize: 11)
        fillDetail.textColor = .secondaryLabelColor
        fillDetail.lineBreakMode = .byWordWrapping
        fillDetail.maximumNumberOfLines = 2
        fillCard.addSubview(fillDetail)
        fillDetailLabel = fillDetail

        // ---------- 卡片 3：播放与启动 ----------
        let optionCard = CardView(frame: .zero)
        content.addSubview(optionCard)

        let optionTitle = NSTextField(labelWithString: "3  播放与启动")
        optionTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        optionCard.addSubview(optionTitle)

        let mute = NSButton(checkboxWithTitle: "静音播放", target: self, action: #selector(muteChanged(_:)))
        mute.font = .systemFont(ofSize: 13)
        optionCard.addSubview(mute)
        muteCheck = mute

        let pause = NSButton(checkboxWithTitle: "暂停播放（省电）", target: self, action: #selector(pauseChanged(_:)))
        pause.font = .systemFont(ofSize: 13)
        optionCard.addSubview(pause)
        pauseCheck = pause

        let auto = NSButton(checkboxWithTitle: "开机自动启动", target: self, action: #selector(autoStartChanged(_:)))
        auto.font = .systemFont(ofSize: 13)
        optionCard.addSubview(auto)
        autoStartCheck = auto

        let remember = NSButton(checkboxWithTitle: "记住播放进度", target: self, action: #selector(rememberChanged(_:)))
        remember.font = .systemFont(ofSize: 13)
        optionCard.addSubview(remember)
        rememberCheck = remember

        // 音量：手动滑动。拖动即自动解除静音，勾上「静音播放」可在不丢音量的情况下静音。
        let volumeTitle = NSTextField(labelWithString: "音量")
        volumeTitle.font = .systemFont(ofSize: 13)
        optionCard.addSubview(volumeTitle)

        let slider = NSSlider(value: Double(AppConfig.shared.volume),
                              minValue: 0, maxValue: 1,
                              target: self, action: #selector(volumeChanged(_:)))
        slider.isContinuous = true                 // 拖动过程中实时生效
        slider.controlSize = .small
        optionCard.addSubview(slider)
        volumeSlider = slider

        let volumeValue = NSTextField(labelWithString: "60%")
        volumeValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        volumeValue.textColor = .secondaryLabelColor
        volumeValue.alignment = .right
        optionCard.addSubview(volumeValue)
        volumeValueLabel = volumeValue

        // ---------- 底部：状态 + 关闭 ----------
        let status = NSTextField(labelWithString: "就绪")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .tertiaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        content.addSubview(status)
        statusLabel = status

        let spinner = NSProgressIndicator(frame: .zero)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        content.addSubview(spinner)
        busyIndicator = spinner

        let close = NSButton(title: "关闭", target: self, action: #selector(closePanel))
        close.bezelStyle = .rounded
        content.addSubview(close)

        // ---------- 统一排版：从下往上画，坐标写死，避免 Auto Layout 的麻烦 ----------
        var y = contentHeight - padding

        // 标题区
        y -= 24
        title.frame.origin = NSPoint(x: padding, y: y)
        y -= 18
        subtitle.frame.origin = NSPoint(x: padding, y: y)
        y -= 18

        // 卡片通用内边距
        let inner: CGFloat = 16
        let cardWidth = width - padding * 2

        // 卡片 1：视频来源。缩略图在左，文件名两行 + 「选择 / 应用 / 导入」在右
        y -= videoCardHeight
        videoCard.frame = NSRect(x: padding, y: y, width: cardWidth, height: videoCardHeight)
        videoTitle.frame = NSRect(x: inner, y: videoCardHeight - 20 - inner, width: 260, height: 18)
        thumb.frame = NSRect(x: inner, y: inner + 20, width: 128, height: 72)
        let textX = inner + 128 + 14
        let textWidth = cardWidth - textX - inner
        // 文件名 + 规格说明，两行，和缩略图顶部对齐
        fileName.frame = NSRect(x: textX, y: inner + 80, width: textWidth, height: 34)
        // 第一排：选择 / 应用
        pickButton.frame = NSRect(x: textX, y: inner + 38, width: 108, height: 32)
        apply.frame = NSRect(x: textX + 116, y: inner + 38, width: 72, height: 32)
        // 第二排：导入 / 移除。下面必须留出 inner 的下边距，否则会被卡片边缘裁掉
        importBtn.frame = NSRect(x: textX, y: inner, width: 128, height: 28)
        removeBtn.frame = NSRect(x: textX + 136, y: inner + 2, width: 112, height: 24)
        y -= gap

        // 卡片 2：填充模式
        y -= fillCardHeight
        fillCard.frame = NSRect(x: padding, y: y, width: cardWidth, height: fillCardHeight)
        fillTitle.frame = NSRect(x: inner, y: fillCardHeight - 20 - inner, width: 260, height: 18)
        segment.frame = NSRect(x: inner, y: inner + 38, width: cardWidth - inner * 2, height: 30)
        fillDetail.frame = NSRect(x: inner, y: inner + 4, width: cardWidth - inner * 2, height: 30)
        y -= gap

        // 卡片 3：播放与启动（两列 + 一整行音量）
        y -= optionCardHeight
        optionCard.frame = NSRect(x: padding, y: y, width: cardWidth, height: optionCardHeight)
        optionTitle.frame = NSRect(x: inner, y: optionCardHeight - 20 - inner, width: 260, height: 18)
        let col1 = inner
        let col2 = inner + (cardWidth - inner * 2) / 2
        let row1 = optionCardHeight - inner - 46
        let row2 = row1 - 28
        let row3 = row2 - 30                       // 音量行（整行）
        mute.frame = NSRect(x: col1, y: row1, width: 200, height: 20)
        pause.frame = NSRect(x: col2, y: row1, width: 200, height: 20)
        auto.frame = NSRect(x: col1, y: row2, width: 240, height: 20)
        remember.frame = NSRect(x: col2, y: row2, width: 200, height: 20)
        volumeTitle.frame = NSRect(x: col1, y: row3 + 2, width: 40, height: 18)
        slider.frame = NSRect(x: col1 + 44, y: row3, width: cardWidth - inner * 2 - 44 - 60, height: 20)
        volumeValue.frame = NSRect(x: cardWidth - inner - 56, y: row3 + 1, width: 56, height: 18)
        y -= 20

        // 底部行：状态 + 关闭（导入时状态左边会转一个小圈）
        status.frame = NSRect(x: padding, y: y - 6, width: cardWidth - 110, height: 16)
        spinner.frame = NSRect(x: width - padding - 118, y: y - 9, width: 16, height: 16)
        close.frame = NSRect(x: width - padding - 80, y: y - 12, width: 80, height: 28)

        win.contentView = content
        return win
    }

    // MARK: 刷新界面

    /// 把 AppConfig / 播放引擎的当前状态灌进控件
    func refresh() {
        let config = AppConfig.shared

        // 填充模式
        let mode = config.fillMode
        fillSegment?.selectedSegment = FillMode.allCases.firstIndex(of: mode) ?? 0
        fillDetailLabel?.stringValue = mode.detail

        // 复选框
        muteCheck?.state = config.isMuted ? .on : .off
        pauseCheck?.state = config.isPaused ? .on : .off
        autoStartCheck?.state = config.autoStart ? .on : .off
        rememberCheck?.state = config.remembersPosition ? .on : .off

        // 音量滑块：数值本身始终显示用户设定的大小，静音只体现在生效音量上
        volumeSlider?.doubleValue = Double(config.volume)
        updateVolumeDisplay()
        let imported = config.isImported(config.videoURL)
        removeImportedButton?.isHidden = !imported
        pickButtonState()

        // 视频信息
        let (name, detail) = videoDescription()
        infoLabel?.stringValue = "\(name)\n\(detail)"
        infoLabel?.maximumNumberOfLines = 2

        // 状态行（导入过程中不要覆盖进度文字）
        if !isBusy {
            let playing = controller?.isPlaying == true
            let screens = NSScreen.screens.count
            statusLabel?.stringValue = "\(playing ? "● 正在播放" : "○ 已暂停")　·　\(screens) 台显示器　·　\(mode.title)"
            statusLabel?.textColor = playing ? .secondaryLabelColor : .tertiaryLabelColor
        }

        loadThumbnail()
    }

    /// 音量文字：显示百分比，静音时特意标出来，避免「明明拖到 60% 却没声音」的困惑
    private func updateVolumeDisplay() {
        let config = AppConfig.shared
        let percent = Int((config.volume * 100).rounded())
        volumeValueLabel?.stringValue = config.isMuted ? "\(percent)% 🔇" : "\(percent)%"
        volumeValueLabel?.textColor = config.isMuted ? .tertiaryLabelColor : .secondaryLabelColor
        volumeSlider?.isEnabled = !isBusy
    }

    /// 导入中禁用所有会打断的操作
    private func pickButtonState() {
        importButton?.isEnabled = !isBusy
        applyButton?.isEnabled = !isBusy && pendingVideo != nil
        removeImportedButton?.isEnabled = !isBusy
    }

    /// 进入 / 退出「忙」状态（导入大文件时用）
    private func setBusy(_ busy: Bool, message: String? = nil) {
        isBusy = busy
        pickButtonState()
        if busy {
            busyIndicator?.startAnimation(nil)
            if let message = message { setStatus(message) }
        } else {
            busyIndicator?.stopAnimation(nil)
        }
    }

    private func videoDescription() -> (String, String) {
        guard let url = AppConfig.shared.videoURL else { return ("尚未选择视频", "点击「选择视频…」挑一个 mp4 / mov") }
        let size = controller?.videoSize ?? .zero
        let duration = controller?.videoDuration ?? 0
        var parts: [String] = []
        if size.width > 0 {
            parts.append("\(Int(size.width)) × \(Int(size.height))")
        }
        if duration > 0 {
            let total = Int(duration.rounded())
            parts.append(String(format: "%d:%02d", total / 60, total % 60))
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let bytes = attrs[.size] as? Int64 {
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        return (url.lastPathComponent, parts.isEmpty ? url.deletingLastPathComponent().path : parts.joined(separator: "　·　"))
    }

    private func setStatus(_ text: String, isError: Bool = false) {
        statusLabel?.stringValue = text
        statusLabel?.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    // MARK: 缩略图（异步抽一帧）

    private var lastThumbURL: URL?

    private func loadThumbnail() {
        guard let url = AppConfig.shared.videoURL else {
            thumbnailView?.image = nil
            return
        }
        guard url != lastThumbURL || thumbnailView?.image == nil else { return }
        lastThumbURL = url

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 256, height: 256)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        generator.generateCGImageAsynchronously(for: CMTime(seconds: 2, preferredTimescale: 600)) { [weak self] cgImage, _, _ in
            guard let self = self, let cgImage = cgImage else { return }
            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            DispatchQueue.main.async { self.thumbnailView?.image = image }
        }
    }

    // MARK: 动作

    /// 供菜单栏调用：面板显示后立刻拉起文件选择器
    func beginPickingVideo() {
        DispatchQueue.main.async { [weak self] in self?.pickVideo() }
    }

    /// 弹原生文件选择器；取消返回 nil
    private func chooseVideoFile(title: String, message: String, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = prompt
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        }
        if let current = AppConfig.shared.videoURL {
            panel.directoryURL = current.deletingLastPathComponent()
        }
        Self.activateApp()
        return panel.runModal() == .OK ? panel.url : nil
    }

    @objc private func pickVideo() {
        guard let url = chooseVideoFile(title: "选择壁纸视频",
                                        message: "支持 mp4 / mov / m4v，建议选分辨率不低于屏幕的视频",
                                        prompt: "选择") else { return }

        pendingVideo = url
        pickButtonState()
        let current = AppConfig.shared.videoURL
        infoLabel?.stringValue = "\(url.lastPathComponent)\n待应用\(current == nil ? "" : "（当前：\(current!.lastPathComponent)）")"
        setStatus("已选择 \(url.lastPathComponent)，点「应用」立即切换")
    }

    // MARK: 导入视频

    @objc private func importVideo() {
        guard let url = chooseVideoFile(title: "导入壁纸视频",
                                        message: "视频会被复制到 App 自己的素材库，原文件之后移动或删除都不影响播放",
                                        prompt: "导入") else { return }
        guard !isBusy else { return }

        let dir = AppConfig.importedVideosDirectory
        let target = VideoImporter.uniqueDestination(for: url.lastPathComponent, in: dir)
        setBusy(true, message: "正在导入 \(url.lastPathComponent)…")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<URL, Error>
            do {
                let saved = try VideoImporter.copy(from: url, to: target) { fraction in
                    DispatchQueue.main.async {
                        let percent = Int((fraction * 100).rounded())
                        self?.setStatus("正在导入 \(url.lastPathComponent)：\(percent)%")
                    }
                }
                result = .success(saved)
            } catch is CancellationError {
                result = .failure(NSError(domain: "VideoWallpaper", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "导入已取消"]))
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.setBusy(false)
                switch result {
                case .success(let imported):
                    // 导入完直接就用，不用再点一次「应用」
                    self.pendingVideo = nil
                    AppConfig.shared.setVideo(imported)
                    self.setStatus("已导入并使用：\(imported.lastPathComponent)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.refresh() }
                case .failure(let error):
                    self.setStatus("导入失败：\(error.localizedDescription)", isError: true)
                    let alert = NSAlert()
                    alert.messageText = "导入失败"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "好")
                    alert.runModal()
                }
            }
        }
    }

    @objc private func removeImportedVideo() {
        guard let url = AppConfig.shared.videoURL, AppConfig.shared.isImported(url) else { return }

        let alert = NSAlert()
        alert.messageText = "移除已导入的视频？"
        alert.informativeText = "将从 App 素材库删除 \(url.lastPathComponent)，并切回内置视频。\n（不会影响你硬盘上的原文件）"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "移除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        try? FileManager.default.removeItem(at: url)
        AppConfig.shared.fallBackToBundledVideo()
        setStatus("已移除，切回内置视频")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refresh() }
    }

    @objc private func applyVideo() {
        guard let url = pendingVideo else { return }
        pendingVideo = nil
        pickButtonState()
        AppConfig.shared.setVideo(url)      // 触发 .videoURL 变化 → 引擎重载视频
        setStatus("已应用：\(url.lastPathComponent)")
        // 元数据是异步就绪的，稍后再刷新一次信息
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.refresh() }
    }

    @objc private func fillModeChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard index >= 0, index < FillMode.allCases.count else { return }
        let mode = FillMode.allCases[index]
        AppConfig.shared.fillMode = mode      // 触发 .fillMode → 只改 gravity，即时生效
        fillDetailLabel?.stringValue = mode.detail
        setStatus("填充方式已切换为：\(mode.title)")
        refresh()
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        // 拖动即生效；顺带解除静音，否则用户会以为滑块坏了
        AppConfig.shared.setVolumeActive(Float(sender.doubleValue))
        updateVolumeDisplay()
        setStatus("音量：\(Int((sender.doubleValue * 100).rounded()))%")
    }

    @objc private func muteChanged(_ sender: NSButton) {
        AppConfig.shared.isMuted = sender.state == .on
        updateVolumeDisplay()
        setStatus(sender.state == .on ? "已静音（音量值仍然保留）" : "已开启声音")
    }

    @objc private func pauseChanged(_ sender: NSButton) {
        AppConfig.shared.isPaused = sender.state == .on
        setStatus(sender.state == .on ? "已暂停（不再解码，省电）" : "已恢复播放")
        refresh()
    }

    @objc private func autoStartChanged(_ sender: NSButton) {
        let want = sender.state == .on
        do {
            if want {
                try LoginItem.enable()
            } else {
                try LoginItem.disable()
            }
            AppConfig.shared.autoStart = want
            setStatus(want ? "已设置为开机自动启动" : "已取消开机自启")
        } catch {
            sender.state = want ? .off : .on
            setStatus("开机自启设置失败：\(error.localizedDescription)", isError: true)
        }
    }

    @objc private func rememberChanged(_ sender: NSButton) {
        AppConfig.shared.remembersPosition = sender.state == .on
        if sender.state == .off { AppConfig.shared.clearSavedPosition() }
        setStatus(sender.state == .on ? "会记住播放进度" : "每次从头开始播")
    }

    @objc private func closePanel() {
        window?.close()      // 触发 windowWillClose → 回到 accessory
    }
}

// MARK: - 开机自启

/// 优先用系统 API（SMAppService），失败则退回到 LaunchAgent（不依赖终端、不需要管理员密码）
enum LoginItem {

    private static var launchAgentURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        return dir.appendingPathComponent("local.vk.wallpaper.plist")
    }

    static func enable() throws {
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.register()
                return
            } catch {
                NSLog("[VideoWallpaper] SMAppService 注册失败，改用 LaunchAgent：\(error)")
            }
        }
        try writeLaunchAgent()
    }

    static func disable() throws {
        if #available(macOS 13.0, *) {
            try? SMAppService.mainApp.unregister()
        }
        try? FileManager.default.removeItem(at: launchAgentURL)
    }

    private static func writeLaunchAgent() throws {
        let exePath = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let plist: [String: Any] = [
            "Label": "local.vk.wallpaper",
            "ProgramArguments": [exePath],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let url = launchAgentURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
    }
}

//  Installer.swift
//  一键安装器（安装器.app 的源码）
//
//  为什么要有这个东西：
//     原来的流程是「双击 build.sh → 弹出一个终端窗口 → 满屏滚动日志」，
//     这正是本次要干掉的体验。安装器本身就是一个原生小 App：
//     双击 → 进度条 → 完成提示，全程没有终端窗口。
//
//  它做的事（和原来的 build.sh 等价，但更稳）：
//     1. 用 swiftc 编译 Sources/*.swift（模块缓存强制放在工程内，避免系统缓存目录不可写）
//     2. 组装 VideoWallpaper.app（Info.plist + 可执行文件 + 默认视频）
//     3. ad-hoc 签名，避免每次重建都被系统重新校验
//     4. 停掉正在运行的旧实例 → 安装到 ~/Applications → 启动新版本
//
//  另外它还会自己重新编译自己：所以以后改完源码，双击安装器就能一步到位。

import Cocoa

// MARK: - 界面

final class InstallerController: NSObject, NSApplicationDelegate {

    private var window: NSWindow!
    private var statusLabel: NSTextField!
    private var detailLabel: NSTextField!
    private var progress: NSProgressIndicator!
    private var openLogButton: NSButton!

    private let root: URL                    // 工程根目录
    private let fm = FileManager.default
    private var logURL: URL { root.appendingPathComponent("build/build.log") }
    private var logText = ""

    /// 无界面模式（命令行/自动化用）：不建窗口、不弹提示，日志直接打到标准输出
    private let headless = CommandLine.arguments.contains("--headless")

    /// 只编译打包，不安装也不启动。
    /// 给两类人用：改代码的人（不想覆盖自己在用的那份），以及 CI（没有 GUI 也没有 /Applications 权限）。
    private let buildOnly = CommandLine.arguments.contains("--build-only")

    override init() {
        // 可执行文件在 Installer.app/Contents/MacOS/ 里，往上三层就是工程根目录；
        // 直接跑二进制时用当前工作目录兜底。
        let exe = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        let candidate = exe.deletingLastPathComponent()   // MacOS
            .deletingLastPathComponent()                  // Contents
            .deletingLastPathComponent()                  // Installer.app
        if fm.fileExists(atPath: candidate.appendingPathComponent("Sources/main.swift").path) {
            root = candidate
        } else {
            root = URL(fileURLWithPath: fm.currentDirectoryPath)
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if headless || buildOnly {
            runInstall()                       // 同步跑完，失败直接以非 0 退出
            return
        }
        buildUI()
        DispatchQueue.main.async { self.runInstall() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: 界面

    private func buildUI() {
        let width: CGFloat = 460, height: CGFloat = 220
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                          styleMask: [.titled],
                          backing: .buffered,
                          defer: false)
        window.title = "视频壁纸 · 安装器"
        window.isReleasedWhenClosed = false
        window.center()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let title = NSTextField(labelWithString: "正在安装「视频壁纸」")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.frame = NSRect(x: 24, y: height - 56, width: width - 48, height: 20)
        content.addSubview(title)

        statusLabel = NSTextField(labelWithString: "准备中…")
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.frame = NSRect(x: 24, y: height - 82, width: width - 48, height: 18)
        content.addSubview(statusLabel)

        progress = NSProgressIndicator(frame: NSRect(x: 24, y: height - 112, width: width - 48, height: 14))
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.doubleValue = 0
        content.addSubview(progress)

        detailLabel = NSTextField(labelWithString: "首次编译大约需要 10–30 秒")
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.frame = NSRect(x: 24, y: height - 138, width: width - 48, height: 16)
        content.addSubview(detailLabel)

        openLogButton = NSButton(title: "查看日志", target: self, action: #selector(openLog))
        openLogButton.bezelStyle = .rounded
        openLogButton.frame = NSRect(x: width - 24 - 96, y: 18, width: 96, height: 28)
        openLogButton.isHidden = true
        content.addSubview(openLogButton)

        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setStatus(_ text: String, progress value: Double) {
        if headless || buildOnly {
            print("[\(Int(value * 100))%] \(text)")
            return
        }
        DispatchQueue.main.async {
            self.statusLabel.stringValue = text
            self.progress.doubleValue = value
        }
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(logURL)
    }

    // MARK: 安装流程

    private func runInstall() {
        do {
            try installAll()
        } catch let error as InstallError {
            fail(error.message)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func installAll() throws {
        setStatus("检查编译环境…", progress: 0.05)
        let swiftc = "/usr/bin/swiftc"
        guard fm.isExecutableFile(atPath: swiftc) else {
            throw InstallError("找不到 swiftc。请先安装 Xcode 或 Command Line Tools（终端执行 xcode-select --install）。")
        }

        let buildDir = root.appendingPathComponent("build", isDirectory: true)
        let bundle = buildDir.appendingPathComponent("VideoWallpaper.app", isDirectory: true)
        let macosDir = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let resourcesDir = bundle.appendingPathComponent("Contents/Resources", isDirectory: true)
        let binary = macosDir.appendingPathComponent("VideoWallpaper")

        try fm.createDirectory(at: buildDir, withIntermediateDirectories: true)
        // 先把输出目录建好：链接器不会替你创建父目录
        try fm.createDirectory(at: macosDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
        resetLog()

        // ---------- 1. 先把自己（安装器）重新编一遍，保证界面和逻辑都是最新的 ----------
        let installerSrc = root.appendingPathComponent("Installer/Installer.swift")
        if fm.fileExists(atPath: installerSrc.path) {
            let installerApp = root.appendingPathComponent("安装器.app", isDirectory: true)
            let installerMacOS = installerApp.appendingPathComponent("Contents/MacOS", isDirectory: true)
            let installerBin = installerMacOS.appendingPathComponent("Installer")
            // 只有源码比二进制新才重编，省时间
            if needsRebuild(source: installerSrc, binary: installerBin) {
                setStatus("更新安装器本身…", progress: 0.12)
                try fm.createDirectory(at: installerMacOS, withIntermediateDirectories: true)
                let result = try run(swiftc,
                                     ["-swift-version", "5", "-O",
                                      "-module-cache-path", buildDir.appendingPathComponent("modulecache").path,
                                      "-o", installerBin.path,
                                      installerSrc.path,
                                      "-framework", "Cocoa"],
                                     label: "编译安装器")
                if result.status != 0 {
                    NSLog("[Installer] 安装器自编译失败，继续用现有版本")
                } else {
                    // 重新编译后旧的签名目录就作废了，留着会让 codesign 校验报
                    // “code has no resources but signature indicates they must be present”。
                    // 安装器是一次性工具、本来就由用户自己的机器编译，直接当未签名程序，
                    // 反而最不容易被系统拦；真正要分发的是它装出来的那个 App。
                    try? fm.removeItem(at: installerApp.appendingPathComponent("Contents/_CodeSignature"))
                    _ = try? run("/usr/bin/xattr", ["-cr", installerApp.path], label: "清理扩展属性")
                }
            }
        }

        // ---------- 2. 编译主体 ----------
        setStatus("正在编译视频壁纸…", progress: 0.25)
        let sources = try fm.contentsOfDirectory(at: root.appendingPathComponent("Sources"),
                                                 includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .map { $0.path }
            .sorted()
        guard !sources.isEmpty else { throw InstallError("Sources 目录里没有找到任何 .swift 文件。") }

        // 先编到一个独立路径：App 包在下一步会被整体清空重建，
        // 如果直接把它当输出目录，产物会在重装阶段被自己删掉。
        let staging = buildDir.appendingPathComponent("VideoWallpaper.bin")

        var args = ["-swift-version", "5", "-O",
                    "-module-cache-path", buildDir.appendingPathComponent("modulecache").path,
                    "-o", staging.path]
        args.append(contentsOf: sources)
        args.append(contentsOf: ["-framework", "Cocoa",
                                 "-framework", "AVFoundation",
                                 "-framework", "CoreGraphics",
                                 "-framework", "ServiceManagement"])
        let compile = try run(swiftc, args, label: "编译主体")
        guard compile.status == 0 else {
            throw InstallError("编译失败，日志见 build/build.log")
        }
        guard fm.fileExists(atPath: staging.path) else {
            throw InstallError("编译命令返回成功但没有生成可执行文件，请把 build/build.log 发我看看。")
        }

        // ---------- 3. 组装 App 包 ----------
        setStatus("正在组装 App 包…", progress: 0.6)
        try? fm.removeItem(at: bundle)
        try fm.createDirectory(at: macosDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
        try copyFile(from: staging, to: binary)
        let plist = root.appendingPathComponent("Info.plist")
        guard fm.fileExists(atPath: plist.path) else { throw InstallError("缺少 Info.plist") }
        try copyFile(from: plist, to: bundle.appendingPathComponent("Contents/Info.plist"))

        let defaultVideo = root.appendingPathComponent("Resources/default.mp4")
        if fm.fileExists(atPath: defaultVideo.path) {
            try copyFile(from: defaultVideo, to: resourcesDir.appendingPathComponent("default.mp4"))
        }

        // 图标：icon.icns 不存在时用 icon/build-icon.sh 现场生成（源图在 icon/icon-source.png）
        let icon = root.appendingPathComponent("icon/icon.icns")
        if !fm.fileExists(atPath: icon.path) {
            let script = root.appendingPathComponent("icon/build-icon.sh")
            if fm.fileExists(atPath: script.path) {
                setStatus("正在生成 App 图标…", progress: 0.68)
                _ = try? run("/bin/bash", [script.path], label: "生成图标")
            }
        }
        if fm.fileExists(atPath: icon.path) {
            try copyFile(from: icon, to: resourcesDir.appendingPathComponent("AppIcon.icns"))
        } else {
            NSLog("[Installer] 没有可用图标，跳过")
        }

        // ---------- 4. ad-hoc 签名 ----------
        setStatus("正在签名…", progress: 0.75)
        signBundle(bundle, identifier: "local.vk.wallpaper", executableName: "VideoWallpaper")

        // ---------- 5. 停旧装新（--build-only 时到此为止） ----------
        if buildOnly {
            setStatus("已完成构建（未安装）", progress: 1.0)
            let message = "构建产物：\(bundle.path)\n\n这次没有安装、也没有启动任何进程。\n\n想安装并启用：双击 安装器.app，或执行\n  ./安装器.app/Contents/MacOS/Installer --headless"
            if headless || buildOnly {
                finish(title: "构建完成", message: message)
            } else {
                DispatchQueue.main.async {
                    self.detailLabel.stringValue = "产物：\(bundle.path)"
                    self.finish(title: "构建完成", message: message)
                }
            }
            return
        }

        setStatus("正在安装并启动…", progress: 0.88)
        let target = installDirectory().appendingPathComponent("VideoWallpaper.app", isDirectory: true)
        let stopped = try stopRunningInstances()
        if stopped > 0 {
            appendLog("已停止 \(stopped) 个旧实例\n")
        }
        try? fm.removeItem(at: target)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try copyFile(from: bundle, to: target)

        // 用 /usr/bin/open 启动：headless 下也比 NSWorkspace 更可靠
        let launched = try? run("/usr/bin/open", [target.path], label: "启动 App")
        if launched?.status != 0 {
            NSWorkspace.shared.open(target)
        }

        // 顺手清掉系统对旧路径的注册，避免「打开方式」里出现幽灵条目
        _ = try? run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                     ["-f", target.path], label: "注册 App")

        setStatus("安装完成 ✓", progress: 1.0)
        var summary = "「视频壁纸」已安装并启动。\n\n通过菜单栏图标操作，打开控制面板可切换视频与填充方式。\n\n安装位置：\(target.path)"
        if stopped > 0 {
            summary += "\n\n（已停止 \(stopped) 个先前运行的实例，避免多个壁纸窗口叠加）"
        }
        if headless {
            finish(title: "安装完成", message: summary)
        } else {
            DispatchQueue.main.async {
                self.detailLabel.stringValue = "已安装到 \(target.path)"
                self.finish(title: "安装完成", message: summary)
            }
        }
    }

    /// 给 App 包做 ad-hoc 签名（先清 xattr 与旧签名，避免 "detritus not allowed"）
    private func signBundle(_ app: URL, identifier: String, executableName: String) {
        _ = try? run("/usr/bin/xattr", ["-cr", app.path], label: "清理扩展属性")
        try? fm.removeItem(at: app.appendingPathComponent("Contents/_CodeSignature"))
        _ = try? run("/usr/bin/codesign",
                     ["--force", "--sign", "-",
                      "--identifier", identifier,
                      app.appendingPathComponent("Contents/MacOS/\(executableName)").path],
                     label: "签名 \(executableName)")
    }

    /// 复制文件/目录：FileManager 失败时退回到 ditto（能保留签名与扩展属性）
    private func copyFile(from source: URL, to destination: URL) throws {
        do {
            try fm.copyItem(at: source, to: destination)
        } catch {
            appendLog("copyItem 失败（\(source.lastPathComponent) -> \(destination.path)）: \(error)，改用 ditto\n")
            let result = try run("/usr/bin/ditto", [source.path, destination.path], label: "ditto 复制")
            if result.status != 0 { throw error }
        }
    }

    /// 选择安装位置：优先 /Applications（可写时），否则用 ~/Applications（无需管理员密码）
    private func installDirectory() -> URL {
        let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if fm.isWritableFile(atPath: system.path) { return system }
        let user = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        try? fm.createDirectory(at: user, withIntermediateDirectories: true)
        return user
    }

    /// 停掉所有正在运行的旧实例，包括直接从工程目录跑的那个（它没有 .app 外壳，
    /// 命令行里只有 ".../vk-wallpaper/VideoWallpaper"，只按 .app 路径匹配是抓不到的）。
    ///
    /// 注意：这里必须排除安装器自己 —— 安装器的可执行路径里也含有
    /// "VideoWallpaper.app/Contents/MacOS/VideoWallpaper"（父目录名），
    /// 直接 pkill -f 会把自己一起杀掉，表现为「安装到一半静默退出」。
    ///
    /// - Returns: 被停掉的进程数量
    @discardableResult
    private func stopRunningInstances() throws -> Int {
        let myPID = ProcessInfo.processInfo.processIdentifier

        // 按命令行内容抓：App 包内实例、旧安装位置、以及开发期直接跑的裸二进制
        let patterns = ["VideoWallpaper.app/Contents/MacOS/VideoWallpaper",
                        "wallpaper/VideoWallpaper"]

        var victims = Set<Int32>()
        for pattern in patterns {
            guard let result = try? run("/usr/bin/pgrep", ["-f", pattern], label: "查找旧实例") else { continue }
            for pid in result.output.split(whereSeparator: { $0 == "\n" || $0 == " " }).compactMap({ Int32($0) }) {
                guard pid != myPID else { continue }        // 绝不自杀
                victims.insert(pid)
            }
        }
        guard !victims.isEmpty else { return 0 }

        let list = victims.sorted().map(String.init).joined(separator: ", ")
        appendLog("将停止旧实例 PID: \(list)\n")
        setStatus("正在停止旧实例（PID \(list)）…", progress: 0.84)
        for pid in victims {
            _ = try? run("/bin/kill", ["-TERM", String(pid)], label: "停止 PID \(pid)")
        }
        Thread.sleep(forTimeInterval: 0.8)
        for pid in victims where isAlive(pid) {
            _ = try? run("/bin/kill", ["-KILL", String(pid)], label: "强制停止 PID \(pid)")
        }
        return victims.count
    }

    private func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0        // 信号 0：只探测存在性，不真的发信号
    }


    private func needsRebuild(source: URL, binary: URL) -> Bool {
        guard let srcDate = modificationDate(of: source),
              let binDate = modificationDate(of: binary) else {
            return true
        }
        return srcDate > binDate
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // MARK: 进程与日志

    struct RunResult { let status: Int32; let output: String }

    private func run(_ launchPath: String, _ arguments: [String], label: String) throws -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.currentDirectoryURL = root

        // 关键：模块缓存放进工程目录。系统默认缓存目录在沙箱/受限环境里可能不可写，
        // 会导致 "unable to open output file ... ModuleCache" 这种莫名其妙的失败。
        var env = ProcessInfo.processInfo.environment
        env["SWIFT_MODULECACHE_PATH"] = root.appendingPathComponent("build/modulecache").path
        env["CLANG_MODULE_CACHE_PATH"] = root.appendingPathComponent("build/modulecache").path
        env["HOME"] = fm.homeDirectoryForCurrentUser.path
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""
        appendLog("=== \(label) (exit \(process.terminationStatus)) ===\n\(output)\n")
        if process.terminationStatus != 0 {
            NSLog("[Installer] %@ 失败（exit %d），详见 build/build.log", label, process.terminationStatus)
        }
        return RunResult(status: process.terminationStatus, output: output)
    }

    private func resetLog() {
        logText = "视频壁纸安装日志\n工程目录: \(root.path)\n\n"
        try? logText.write(to: logURL, atomically: true, encoding: .utf8)
    }

    private func appendLog(_ text: String) {
        logText += text
        try? logText.write(to: logURL, atomically: true, encoding: .utf8)
    }

    // MARK: 收尾

    private func finish(title: String, message: String, exitCode: Int32 = 0) {
        if headless || buildOnly {
            print("\n✓ \(title)\n\(message)")
            exit(exitCode)
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
        NSApp.terminate(nil)
    }

    private func fail(_ message: String) {
        if headless || buildOnly {
            FileHandle.standardError.write(("\n✗ 安装失败：\(message)\n完整日志：\(logURL.path)\n").data(using: .utf8)!)
            exit(1)
        }
        DispatchQueue.main.async {
            self.progress.doubleValue = 0
            self.statusLabel.stringValue = "安装失败"
            self.statusLabel.textColor = .systemRed
            self.detailLabel.stringValue = message.replacingOccurrences(of: "\n", with: " ")
            self.openLogButton.isHidden = false

            let alert = NSAlert()
            alert.messageText = "安装失败"
            alert.informativeText = message + "\n\n完整日志：build/build.log"
            alert.alertStyle = .critical
            alert.addButton(withTitle: "好")
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    struct InstallError: Error { let message: String; init(_ m: String) { message = m } }
}

// MARK: - 入口

let app = NSApplication.shared
let controller = InstallerController()
app.delegate = controller
app.setActivationPolicy(.regular)
app.run()

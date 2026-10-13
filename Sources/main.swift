//  main.swift
//  程序入口
//
//  用「顶层代码」而不是 @main：这样 swiftc 直接编译源文件就能产出可执行文件，
//  不需要 Xcode 工程、不需要 Storyboard，也不需要任何终端交互。

import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// 后台代理型 App：不在 Dock 占位、不进 Cmd+Tab；只有打开控制面板时才临时露脸
app.setActivationPolicy(.accessory)

// 收到 SIGTERM / SIGINT（关机、重启、脚本 kill、安装器停旧实例）时走正常退出流程，
// 这样 applicationWillTerminate 会被调用，播放进度能存下来，也不会留下僵尸窗口。
// 注意：DispatchSource 必须被强引用持有，否则会被立刻释放、信号也就没人接了。
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        NSLog("[VideoWallpaper] 收到退出信号 \(sig)，正在收尾")
        NSApp.terminate(nil)
    }
    source.resume()
    signalSources.append(source)
}

app.run()

# 开发文档

面向参与本项目的开发者。用户使用说明见 [README](README.md)，版本历史见 [CHANGELOG](CHANGELOG.md)。

---

## 目录

- [架构](#架构)
- [模块职责](#模块职责)
- [设计要点](#设计要点)
- [构建系统](#构建系统)
- [界面开发](#界面开发)
- [测试](#测试)
- [偏好存储](#偏好存储)
- [代码约定](#代码约定)

---

## 架构

```
控制面板 / 菜单栏  ──修改──▶  AppConfig（唯一状态源）
                                  │  NotificationCenter 广播变更
                                  ▼
                          WallpaperController（响应变更）
                                  │
                                  ▼
                       每块屏幕一个 WallpaperWindow
                                  │  全部绑定同一个 AVQueuePlayer
                                  ▼
                          PlayerView（AVPlayerLayer）
```

采用单向数据流：界面层只负责修改 `AppConfig`，播放引擎只负责响应变更通知，
两者之间没有直接引用。这样做的收益是新增配置项时的改动范围完全可预期。

### 新增一个配置项

1. 在 `AppConfig` 添加属性，setter 中调用 `notify(.新键)`，并在 `ChangedKey` 中登记
2. 在 `WallpaperController.observeConfig()` 的 `switch` 中处理该键
3. 在 `PreferencesWindow.refresh()` 中把状态呈现到控件

不需要在界面与播放器之间建立任何直接调用。

---

## 模块职责

| 文件 | 职责 | 边界 |
| --- | --- | --- |
| `AppConfig.swift` | 所有配置项的唯一来源，`UserDefaults` 持久化，变更广播 | 不涉及 UI，不涉及播放器 |
| `PlayerView.swift` | `AVPlayerLayer` 渲染、填充模式映射、播放元数据 | 不感知屏幕数量 |
| `WallpaperController.swift` | 窗口层级、多屏管理、播放器生命周期、功耗策略 | 不直接读写界面控件 |
| `PreferencesWindow.swift` | 控制面板 UI，仅修改 `AppConfig` | 不直接调用播放器 |
| `VideoImporter.swift` | 分块复制、进度回报、失败清理 | 不涉及 UI，可独立测试 |
| `AppDelegate.swift` | 菜单栏图标与菜单、应用生命周期 | 不处理播放逻辑 |
| `main.swift` | 入口与信号处理 | — |

保持这些边界是维护成本低的主要原因。跨层直接调用会立刻破坏单向数据流。

---

## 设计要点

### 窗口层级

桌面图标层在 macOS 窗口层级中高于系统壁纸层。窗口置于两者之间：

```swift
level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
```

同时满足两个约束：覆盖系统壁纸、图标保持最上层。

配合 `ignoresMouseEvents = true`，鼠标事件穿透至桌面，右键菜单、框选、拖拽文件均正常。

`collectionBehavior` 设为 `[.canJoinAllSpaces, .stationary, .ignoresCycle]`：
所有桌面空间可见，不参与 Mission Control 重排，`Cmd+\`` 无法切入。

### 播放器复用

所有屏幕的 `AVPlayerLayer` 指向同一个 `AVQueuePlayer`。图层各自维护 frame 与
`videoGravity`，解码器只有一份。多显示器场景下 GPU 开销不随屏幕数量线性增长。

### 无缝循环与渲染稳定性

- `AVPlayerLooper` 通过两个 item 交替实现无缝循环，循环点无可见中断
- 图层 frame 同步包裹在 `CATransaction` 中并禁用隐式动画，避免窗口尺寸变化时画面抖动

### 功耗控制

| 场景 | 监听通知 | 行为 |
| --- | --- | --- |
| 屏幕休眠 / 唤醒 | `NSWorkspace.screensDidSleep/Wake` | 暂停 / 恢复解码 |
| 锁屏 / 解锁 | `sessionDidResign/BecomeActive`、`com.apple.screenIsLocked` | 暂停 / 恢复 |
| 系统睡眠 / 唤醒 | `NSWorkspace.willSleep/didWake` | 暂停 / 恢复 |
| 手动暂停 | `AppConfig.isPaused` | 保留窗口，停止解码 |

锁屏使用 `DistributedNotificationCenter` 的 `com.apple.screenIsLocked`，
部分机型上它比 `sessionDidResign` 更及时，因此两者都监听。

### 退出处理

`main.swift` 将 `SIGTERM` / `SIGINT` / `SIGHUP` 转换为 `NSApp.terminate`，
使 `applicationWillTerminate` 得以执行：保存播放进度、关闭窗口、释放播放器。
关机、重启、脚本终止、安装器停止旧实例均走此路径。

> `DispatchSourceSignal` 必须被强引用持有，否则会被立即释放，信号将无人接收。

### 显示器热插拔

以 `CGDirectDisplayID` 为键维护窗口表。屏幕参数变化时只增删改变化的窗口，
不重建全部窗口 —— 后者会导致副屏闪烁。

---

## 构建系统

`安装器.app` 本身也是一个 App（源码位于 `Installer/Installer.swift`），执行流程：

1. 若安装器源码比二进制新，**重新编译安装器自身**
2. 使用 `swiftc` 编译 `Sources/*.swift`
3. 组装 `VideoWallpaper.app`（`Info.plist` + 可执行文件 + `default.mp4` + 图标）
4. ad-hoc 签名
5. 停止旧实例 → 安装至 `/Applications`（不可写时回退 `~/Applications`）→ 启动

### 命令行参数

| 参数 | 行为 |
| --- | --- |
| （无） | 图形界面，等同双击 |
| `--headless` | 无界面，日志输出至 stdout，失败以非 0 退出 |
| `--build-only` | 仅构建，不安装、不启动 |

`--build-only` 适用于不希望覆盖本地已安装版本的开发场景，以及没有
`/Applications` 写权限的 CI 环境。

### 构建实现约束

以下三点是构建流程的硬约束，修改时需保持：

**停止旧实例必须排除自身 PID。**
安装器的可执行路径包含 `VideoWallpaper.app/Contents/MacOS/VideoWallpaper`
（父目录名），基于路径匹配的进程查找会命中安装器自身。
当前实现通过 `pgrep` 获取 PID 后过滤 `ProcessInfo.processIdentifier`。

**编译产物不可直接输出到 App 包内。**
组装阶段会先清空目标包，若编译输出位于其中，产物会在组装时被删除。
当前先编译至 `build/VideoWallpaper.bin`，再复制进包。

**内容视图不应设置 `autoresizingMask`。**
窗口适配时会等比缩放整个内容视图，导致控件尺寸失真、超出可视区。
当前使用 `contentLayoutRect` 取得真实内容区高度，再按固定坐标排布。

### 模块缓存

构建脚本将 Swift 模块缓存固定至 `build/modulecache`。系统默认缓存目录在受限环境中
可能不可写，会导致 `unable to open output file ... ModuleCache` 失败。
等效的环境变量方式：

```bash
export SWIFT_MODULECACHE_PATH="$PWD/build/modulecache"
export CLANG_MODULE_CACHE_PATH="$PWD/build/modulecache"
```

---

## 界面开发

屏幕录制权限受限时 `screencapture` 不可用。项目内置离屏渲染工具，将控制面板渲染为 PNG：

```bash
swiftc -swift-version 5 -module-cache-path build/modulecache \
  -o /tmp/harness UIHarness/main.swift UIHarness/Harness.swift \
  Sources/AppConfig.swift Sources/PlayerView.swift \
  Sources/WallpaperController.swift Sources/PreferencesWindow.swift \
  Sources/VideoImporter.swift \
  -framework Cocoa -framework AVFoundation -framework CoreGraphics -framework ServiceManagement

/tmp/harness /tmp/panel.png
```

`UIHarness/Harness.swift` 会同时打印各控件的真实 frame，排查重叠与越界时比读图更直接。

修改界面后建议先渲染核对，再在真机上验证。

### 检查运行中的窗口

```swift
CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)
```

壁纸窗口的 layer 应为 `-2147483604`，即 `kCGDesktopIconWindowLevel - 1`。

---

## 测试

`VideoImporter` 设计为不依赖 UI 的纯逻辑模块，可独立编译运行断言：

```bash
mkdir -p /tmp/vwtest && cp <测试文件> /tmp/vwtest/main.swift
swiftc -swift-version 5 -module-cache-path build/modulecache \
  -o /tmp/vwtest/importer_test /tmp/vwtest/main.swift Sources/VideoImporter.swift
/tmp/vwtest/importer_test
```

> Swift 的顶层代码必须位于名为 `main.swift` 的文件中。

覆盖范围：

- 进度单调递增、终值到达 1.0、区间合法
- 复制后字节数与源文件一致
- 分块复制后内容哈希一致
- 重名自动追加序号，不覆盖已有文件
- 取消时抛出 `CancellationError` 且不残留半成品
- 源文件缺失时不留目标文件

新增纯逻辑模块时建议采用同样的结构：与 UI 解耦，便于独立断言。

---

## 偏好存储

使用 `UserDefaults.standard`，存储域为 bundle id `local.vk.wallpaper`。

```bash
defaults read local.vk.wallpaper
```

> **不要改用自定义 suite。** 以 App 自身 bundle id 作为 suite 名属于误用，
> 系统会在每次启动时记录告警：
> `Using your own bundle identifier as an NSUserDefaults suite name does not make sense`。
>
> `AppConfig.migrateLegacySuiteIfNeeded` 负责将历史上误存于该 suite 的数据
> 一次性迁移至 `.standard`，迁移完成后不再执行。该逻辑保证老用户升级后配置不丢失。

---

## 代码约定

- **注释解释原因，不复述代码。** 例如说明「为什么窗口层级要减 1」，而不是「设置窗口层级」
- **文档与注释使用中文**，代码标识符使用英文
- **保持模块边界。** 新增功能时先确认它应该属于哪个模块，避免跨层调用
- **避免新增常驻进程。** 应用本身零常驻开销，这是设计目标之一
- **破坏性改动需要提供回滚路径**，尤其是涉及系统级集成（`LaunchAgent`、`SMAppService`）时

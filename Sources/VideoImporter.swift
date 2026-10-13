//  VideoImporter.swift
//  视频导入器
//
//  把用户选的视频复制进 App 自己的素材库
//  （~/Library/Application Support/VideoWallpaper/Videos）。
//  这样原文件之后被移动、改名、删掉，壁纸都不会变成黑屏。
//
//  单独拆成一个文件是为了能独立测试：
//  分块复制 + 进度回报 + 失败清理这三件事都很容易写错，值得有测试兜着。

import Foundation

enum VideoImporter {

    /// 导入结果
    enum ImportError: LocalizedError {
        case cannotCreateFile(String)
        case notEnoughSpace(needBytes: Int64, freeBytes: Int64)
        case readFailed(String)

        var errorDescription: String? {
            switch self {
            case .cannotCreateFile(let path):
                return "无法在素材库创建文件：\(path)"
            case .notEnoughSpace(let need, let free):
                let fmt = ByteCountFormatter()
                return "磁盘空间不足：需要 \(fmt.string(fromByteCount: need))，可用 \(fmt.string(fromByteCount: free))"
            case .readFailed(let reason):
                return "读取源视频失败：\(reason)"
            }
        }
    }

    /// 分块大小：4MB。够大不至于拖慢速度，够小才能报进度、也方便随时中断。
    private static let chunkSize = 4 * 1024 * 1024

    /// 素材库里重名时自动加序号，绝不覆盖已有文件
    static func uniqueDestination(for fileName: String, in directory: URL) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = directory.appendingPathComponent(fileName)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = directory.appendingPathComponent(name)
            index += 1
        }
        return candidate
    }

    /// 复制文件并把进度（0…1）回报给调用方。失败时会把半个文件删掉，不留垃圾。
    /// - Parameter shouldCancel: 返回 true 时中止导入
    /// - Returns: 落盘后的目标路径
    @discardableResult
    static func copy(from source: URL,
                     to destination: URL,
                     progress: ((Double) -> Void)? = nil,
                     shouldCancel: (() -> Bool)? = nil) throws -> URL {
        let fm = FileManager.default
        let total = (try? fm.attributesOfItem(atPath: source.path))?[.size] as? Int64 ?? 0

        // 空间检查：素材库和源文件可能不在同一个卷上，这里只看目标卷
        if total > 0,
           let free = try? destination.deletingLastPathComponent()
               .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
               .volumeAvailableCapacityForImportantUsage,
           free < total {
            throw ImportError.notEnoughSpace(needBytes: total, freeBytes: free)
        }

        try? fm.createDirectory(at: destination.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        guard fm.createFile(atPath: destination.path, contents: nil) else {
            throw ImportError.cannotCreateFile(destination.path)
        }

        do {
            let input = try FileHandle(forReadingFrom: source)
            let output = try FileHandle(forWritingTo: destination)
            defer { try? input.close(); try? output.close() }

            var written: Int64 = 0
            var lastPercent = -1

            while true {
                if shouldCancel?() == true {
                    throw CancellationError()
                }
                let chunk = try input.read(upToCount: chunkSize) ?? Data()
                if chunk.isEmpty { break }
                try output.write(contentsOf: chunk)
                written += Int64(chunk.count)

                guard total > 0 else { continue }
                let percent = Int(Double(written) / Double(total) * 100)
                // 每变化 2% 才回报一次，避免把主线程刷爆
                if percent != lastPercent && percent % 2 == 0 {
                    lastPercent = percent
                    progress?(Double(written) / Double(total))
                }
            }
            progress?(1.0)
            return destination
        } catch {
            // 失败 / 取消：删掉半成品
            try? fm.removeItem(at: destination)
            throw error
        }
    }
}

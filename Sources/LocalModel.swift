import Foundation
import SwiftData

/// 本地 GGUF 模型。文件放在 App 的 Documents/Models 下。
@Model
final class LocalModel {
    @Attribute(.unique) var uid: UUID
    var name: String
    var fileName: String
    var sizeBytes: Int64
    /// 来源：download / import
    var origin: String
    var sourceURL: String
    var createdAt: Date
    var lastUsedAt: Date?

    /// 量化等级说明，例如 Q4_K_M
    var quant: String
    /// 参数规模说明，例如 1.5B
    var params: String
    /// 是否已接入推理引擎。GGUF 需要 llama.cpp，目前恒为 false
    var runnable: Bool = false

    init(
        name: String,
        fileName: String,
        sizeBytes: Int64,
        origin: String,
        sourceURL: String = "",
        quant: String = "",
        params: String = ""
    ) {
        self.uid = UUID()
        self.name = name
        self.fileName = fileName
        self.sizeBytes = sizeBytes
        self.origin = origin
        self.sourceURL = sourceURL
        self.quant = quant
        self.params = params
        self.createdAt = .now
        self.lastUsedAt = nil
    }

    var url: URL { LocalModelStore.modelsDirectory.appendingPathComponent(fileName) }

    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

// MARK: - 文件管理

enum LocalModelStore {

    static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Models", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 从文件名尽量猜出参数规模和量化
    static func inspect(fileName: String, sizeBytes: Int64) -> (params: String, quant: String) {
        let lower = fileName.lowercased()
        let quantPatterns = ["q2_k", "q3_k_m", "q3_k_s", "q4_0", "q4_k_m", "q4_k_s",
                             "q5_k_m", "q5_k_s", "q6_k", "q8_0", "f16", "fp16", "bf16"]
        var quant = ""
        for q in quantPatterns where lower.contains(q) {
            quant = q.uppercased()
            break
        }

        var params = ""
        let patterns = ["0\\.5b", "1\\.5b", "1b", "2b", "3b", "4b", "7b", "8b", "9b",
                        "13b", "14b", "27b", "30b", "32b", "70b"]
        for p in patterns {
            if lower.range(of: p, options: .regularExpression) != nil {
                params = p.uppercased().replacingOccurrences(of: "\\.", with: ".")
                break
            }
        }
        return (params, quant)
    }

    /// 导入外部文件（Files / 分享面板）
    static func importFile(from source: URL) throws -> (fileName: String, size: Int64) {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let dest = modelsDirectory.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: source, to: dest)

        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
        return (dest.lastPathComponent, size ?? 0)
    }

    static func delete(_ model: LocalModel) {
        try? FileManager.default.removeItem(at: model.url)
    }

    static func totalSize() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: modelsDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return files.reduce(Int64(0)) { acc, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return acc + Int64(size)
        }
    }
}

// MARK: - 下载器

@MainActor
final class ModelDownloader: NSObject, ObservableObject {

    @Published var isDownloading = false
    @Published var progress: Double = 0
    @Published var receivedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var errorText: String?
    @Published var statusText = ""

    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var destName = ""

    func start(urlString: String) {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorText = "地址无效"
            return
        }
        guard url.scheme == "https" || url.scheme == "http" else {
            errorText = "只支持 http(s) 地址"
            return
        }

        isDownloading = true
        progress = 0
        receivedBytes = 0
        totalBytes = 0
        errorText = nil
        statusText = "连接中…"
        destName = url.lastPathComponent.isEmpty ? "model-\(Int(Date().timeIntervalSince1970)).gguf" : url.lastPathComponent

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 2
        let s = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        session = s
        task = s.downloadTask(with: url)
        task?.resume()
    }

    func cancel() {
        task?.cancel()
        session?.invalidateAndCancel()
        isDownloading = false
        statusText = ""
    }
}

extension ModelDownloader: URLSessionDownloadDelegate {

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        Task { @MainActor in
            self.receivedBytes = totalBytesWritten
            if totalBytesExpectedToWrite > 0 {
                self.totalBytes = totalBytesExpectedToWrite
                self.progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
                self.statusText = "下载中…"
            } else {
                self.statusText = ByteCountFormatter.string(fromByteCount: totalBytesWritten, countStyle: .file)
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // 从任务对象取文件名，避免跨隔离域访问 @MainActor 属性
        let suggested = downloadTask.response?.suggestedFilename
            ?? downloadTask.originalRequest?.url?.lastPathComponent
            ?? "model.gguf"
        let name = suggested.isEmpty ? "model.gguf" : suggested
        let dest = LocalModelStore.modelsDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            Task { @MainActor in
                self.destName = name
                self.progress = 1
                self.statusText = "已保存"
                self.isDownloading = false
            }
        } catch {
            Task { @MainActor in
                self.errorText = "保存失败：\(error.localizedDescription)"
                self.isDownloading = false
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        Task { @MainActor in
            self.errorText = error.localizedDescription
            self.isDownloading = false
            self.statusText = ""
        }
    }
}

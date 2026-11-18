import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct LocalModelView: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \LocalModel.createdAt, order: .reverse) private var models: [LocalModel]

    @StateObject private var downloader = ModelDownloader()
    @State private var showImporter = false
    @State private var urlInput = ""
    @State private var showURLField = false
    @State private var pendingDelete: LocalModel?

    private var deviceStatus: (text: String, ready: Bool) {
        if #available(iOS 26.0, *) {
            let a = OnDeviceClient.availability()
            return (a.text, a.available)
        }
        return ("需要 iOS 26", false)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                List {
                    Section {
                        HStack {
                            Image(systemName: "cpu")
                                .foregroundStyle(deviceStatus.ready ? .green : .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("系统设备端模型")
                                Text(deviceStatus.text)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if deviceStatus.ready {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                    } header: {
                        Text("现在就能用")
                    } footer: {
                        Text("到「设置 → 供应商 → 添加 → 接口类型选设备端模型」，不用填地址和 key，完全离线。这是目前唯一能直接跑的本地模型。")
                    }

                    if downloader.isDownloading || downloader.errorText != nil {
                        Section("下载") {
                            if downloader.isDownloading {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(downloader.statusText).font(.caption)
                                        Spacer()
                                        Text("\(Int(downloader.progress * 100))%")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    ProgressView(value: downloader.progress)
                                    if downloader.totalBytes > 0 {
                                        Text("\(fmt(downloader.receivedBytes)) / \(fmt(downloader.totalBytes))")
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    Button("取消", role: .destructive) { downloader.cancel() }
                                        .font(.caption)
                                }
                            }
                            if let err = downloader.errorText {
                                Text(err).font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }

                    Section {
                        Button {
                            showImporter = true
                        } label: {
                            Label("从文件导入 GGUF", systemImage: "folder")
                        }

                        Button {
                            showURLField.toggle()
                        } label: {
                            Label("从链接下载 GGUF", systemImage: "arrow.down.circle")
                        }

                        if showURLField {
                            VStack(alignment: .leading, spacing: 8) {
                                TextField("https://…/model.gguf", text: $urlInput)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .keyboardType(.URL)
                                    .font(.callout.monospaced())

                                Button("开始下载") {
                                    downloader.start(urlString: urlInput)
                                    showURLField = false
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(urlInput.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }
                    } header: {
                        Text("GGUF 文件")
                    } footer: {
                        Text("**这些文件现在还不能推理。** GGUF 需要 llama.cpp 引擎，还没有接进来。先把文件备着，引擎接上就能直接用。")
                    }

                    Section {
                        if models.isEmpty {
                            Text("还没有文件").foregroundStyle(.secondary)
                        } else {
                            ForEach(models) { model in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(model.name).font(.body).lineLimit(1)
                                        Spacer()
                                        Text("待接引擎")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                    HStack(spacing: 6) {
                                        if !model.params.isEmpty {
                                            Text(model.params).font(.caption2).foregroundStyle(.secondary)
                                        }
                                        if !model.quant.isEmpty {
                                            Text(model.quant).font(.caption2).foregroundStyle(.secondary)
                                        }
                                        Text(model.displaySize)
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .swipeActions {
                                    Button(role: .destructive) {
                                        pendingDelete = model
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    } header: {
                        Text(models.isEmpty ? "已下载的文件" : "已下载的文件 · \(totalText)")
                    }

                    Section("存储") {
                        LabeledContent("位置", value: "Documents/Models")
                        LabeledContent("占用", value: totalText)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("本地模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { handleImport($0) }
            .alert("删除这个文件？", isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ), presenting: pendingDelete) { model in
                Button("删除", role: .destructive) {
                    LocalModelStore.delete(model)
                    ctx.delete(model)
                    try? ctx.save()
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            }
            .onChange(of: downloader.isDownloading) { _, downloading in
                if !downloading && downloader.progress >= 1 { registerDownloaded() }
            }
        }
    }

    private var totalText: String {
        ByteCountFormatter.string(fromByteCount: LocalModelStore.totalSize(), countStyle: .file)
    }

    private func fmt(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let (fileName, size) = try LocalModelStore.importFile(from: url)
                let info = LocalModelStore.inspect(fileName: fileName, sizeBytes: size)
                let model = LocalModel(
                    name: (fileName as NSString).deletingPathExtension,
                    fileName: fileName,
                    sizeBytes: size,
                    origin: "import",
                    quant: info.quant,
                    params: info.params
                )
                ctx.insert(model)
                try? ctx.save()
            } catch {
                downloader.errorText = error.localizedDescription
            }
        case .failure(let error):
            downloader.errorText = error.localizedDescription
        }
    }

    private func registerDownloaded() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: LocalModelStore.modelsDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        )) ?? []

        let known = Set(models.map(\.fileName))
        let fresh = files
            .filter { $0.pathExtension.lowercased() == "gguf" && !known.contains($0.lastPathComponent) }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }

        guard let file = fresh.first else { return }
        let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let info = LocalModelStore.inspect(fileName: file.lastPathComponent, sizeBytes: size)
        let model = LocalModel(
            name: file.deletingPathExtension().lastPathComponent,
            fileName: file.lastPathComponent,
            sizeBytes: size,
            origin: "download",
            sourceURL: urlInput,
            quant: info.quant,
            params: info.params
        )
        ctx.insert(model)
        try? ctx.save()
    }
}

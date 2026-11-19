import SwiftUI
import SwiftData

struct ProviderEditView: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss

    let provider: Provider?

    @State private var name = ""
    @State private var kind: ProviderKind = .openAI
    @State private var baseURL = ""
    @State private var model = ""
    @State private var apiKey = ""
    @State private var temperature = 0.7
    @State private var maxTokens = 4096
    @State private var timeoutSeconds = 120
    @State private var extraHeaders = ""
    @State private var systemPrompt = ""
    @State private var boostEnabled = true
    @State private var refusalRetry = true
    @State private var didLoad = false
    @State private var localModelFile = ""
    @State private var disableThinking = true

    @State private var testState: TestState = .idle
    @State private var modelList: [ModelCatalog.Entry] = []
    @State private var modelState: FetchState = .idle
    @State private var showModelPicker = false
    @State private var showPromptPreview = false

    private enum TestState: Equatable {
        case idle, running, ok(String), fail(String)
    }

    private enum FetchState: Equatable {
        case idle, loading, loaded(Int), failed(String)
    }

    @Query private var localModels: [LocalModel]

    private var deviceStatus: String {
        OnDeviceClient.availability().text
    }

    private var deviceReady: Bool {
        OnDeviceClient.availability().available
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名字", text: $name)

                    Picker("接口类型", selection: $kind) {
                        ForEach(ProviderKind.allCases) { k in
                            Label(k.title, systemImage: k.symbol).tag(k)
                        }
                    }
                    .onChange(of: kind) { previous, current in
                        if baseURL.isEmpty || baseURL == previous.defaultBaseURL {
                            baseURL = current.defaultBaseURL
                        }
                        if model.isEmpty || model == previous.defaultModel {
                            model = current.defaultModel
                        }
                        if name.isEmpty || ProviderKind.allCases.contains(where: { $0.title == name }) {
                            name = current.title
                        }
                        if current.isOnDevice {
                            baseURL = ""
                            model = current.defaultModel
                            apiKey = ""
                            if current == .onDevice { localModelFile = "" }
                        }
                        modelList = []
                        modelState = .idle
                    }

                    if !kind.isOnDevice {
                        TextField("Base URL", text: $baseURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .font(.callout.monospaced())
                    }
                } header: {
                    Text("基本")
                } footer: {
                    if kind.isOnDevice {
                        Text("使用 iOS 26 自带的设备端模型，不需要地址、不需要 key，完全离线。")
                    } else {
                        Text("中转站给的是 https://xxx.com/v1 这种，直接填，不要加 /chat/completions。")
                    }
                }

                if kind == .localGGUF {
                    Section {
                        if localModels.isEmpty {
                            Text("还没有本地模型文件")
                                .foregroundStyle(.secondary)
                            Text("先去「设置 → 本地模型」下载或导入 GGUF。")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        } else {
                            Picker("模型文件", selection: $localModelFile) {
                                Text("未选择").tag("")
                                ForEach(localModels.filter(\.exists)) { m in
                                    Text("\(m.name) · \(m.displaySize)").tag(m.fileName)
                                }
                            }
                        }
                    } header: {
                        Text("本地 GGUF")
                    } footer: {
                        if LocalLLMRunner.engineAvailable {
                            Text("用 llama.cpp 在本机推理。首次加载需要几秒，越大越慢。建议 1–4B 的 Q4 量化。")
                        } else {
                            Text("这个构建没编入 llama.cpp 引擎，本地推理不可用。模型文件仍可正常管理。")
                        }
                    }
                } else if kind.isOnDevice {
                    Section {
                        HStack {
                            Text("可用状态")
                            Spacer()
                            Text(deviceStatus)
                                .foregroundStyle(deviceReady ? Color.green : Color.orange)
                        }
                    } header: {
                        Text("设备端模型")
                    } footer: {
                        Text("需要在「设置 → Apple Intelligence 与 Siri」里开启。不占用 App 的存储。")
                    }
                } else {
                    Section("API Key") {
                        SecureField(kind.keyHint, text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.callout.monospaced())
                    }
                }

                if !kind.isOnDevice {
                Section {
                    HStack {
                        TextField("模型名", text: $model)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.callout.monospaced())

                        Button {
                            Task { await fetchModels() }
                        } label: {
                            if modelState == .loading {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.down.circle")
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .disabled(modelState == .loading || apiKey.isEmpty || baseURL.isEmpty)
                    }

                    if !modelList.isEmpty {
                        Button {
                            showModelPicker = true
                        } label: {
                            HStack {
                                Text("从 \(modelList.count) 个模型里选")
                                    .foregroundStyle(.tint)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }

                    switch modelState {
                    case .failed(let msg):
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    case .loaded, .idle, .loading:
                        EmptyView()
                    }
                } header: {
                    Text("模型")
                } footer: {
                    Text("点右侧箭头自动从接口拉取模型列表。")
                }
                }

                if kind == .localGGUF {
                    Section {
                        Toggle("关闭思考模式", isOn: $disableThinking)
                    } header: {
                        Text("本地模型选项")
                    } footer: {
                        Text("只有 Qwen3 这类 thinking 模型需要这个开关。Qwen2.5、Llama、Phi 等普通 instruct 模型没有思考模式，开着也不影响。")
                    }
                }

                Section {
                    Toggle("强化尾段", isOn: $boostEnabled)
                    Toggle("拒绝重试", isOn: $refusalRetry)
                } header: {
                    Text("破甲层")
                } footer: {
                    Text("移植自 dsh-purge 1.6.97：\(PromptBoost.ruleCount) 条拒绝正则、400 字符判定窗口、单次重试。尾段会追加在系统提示最后。")
                }

                Section("参数") {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("温度")
                            Spacer()
                            Text(String(format: "%.2f", temperature))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $temperature, in: 0...2, step: 0.05)
                    }

                    Stepper(value: $maxTokens, in: 256...64000, step: 512) {
                        LabeledContent("最大 tokens", value: "\(maxTokens)")
                    }

                    Stepper(value: $timeoutSeconds, in: 30...600, step: 30) {
                        LabeledContent("超时", value: "\(timeoutSeconds) 秒")
                    }
                }

                Section {
                    TextField("X-Api-Key: xxx（每行一个）", text: $extraHeaders, axis: .vertical)
                        .font(.caption.monospaced())
                        .lineLimit(2...5)
                } header: {
                    Text("附加请求头")
                }

                Section {
                    HStack {
                        Button("套预设") {
                            systemPrompt = PromptPresets.unrestricted
                        }
                        Spacer()
                        Button("预览实际发送") {
                            showPromptPreview = true
                        }
                        .foregroundStyle(.tint)
                    }

                    TextField("留空则不发送", text: $systemPrompt, axis: .vertical)
                        .font(.callout)
                        .lineLimit(6...18)

                    if !systemPrompt.isEmpty {
                        LabeledContent("字符数", value: "\(systemPrompt.count)")
                            .font(.caption)
                    }
                } header: {
                    Text("系统提示词")
                } footer: {
                    Text("点「预览实际发送」可以看到你的提示词加上破甲尾段之后的完整内容。")
                }

                Section {
                    Button {
                        Task { await runTest() }
                    } label: {
                        HStack {
                            Text("测试连通性")
                            Spacer()
                            if testState == .running {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .disabled(testState == .running || apiKey.isEmpty)

                    switch testState {
                    case .ok(let msg):
                        Label(msg, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    case .fail(let msg):
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    case .idle, .running:
                        EmptyView()
                    }
                }
            }
            .navigationTitle(provider == nil ? "添加供应商" : "编辑供应商")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(!kind.isOnDevice && (baseURL.isEmpty || model.isEmpty))
                }
            }
            .onAppear(perform: load)
            .sheet(isPresented: $showModelPicker) {
                ModelPickerSheet(entries: modelList, selected: $model)
            }
            .sheet(isPresented: $showPromptPreview) {
                PromptPreviewSheet(userPrompt: systemPrompt, boostEnabled: boostEnabled)
            }
        }
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        if let provider {
            name = provider.name
            kind = provider.kind
            baseURL = provider.baseURL
            model = provider.model
            temperature = provider.temperature
            maxTokens = provider.maxTokens
            timeoutSeconds = provider.timeoutSeconds
            extraHeaders = provider.extraHeaders
            systemPrompt = provider.systemPrompt
            boostEnabled = provider.boostOn
            refusalRetry = provider.retryOn
            localModelFile = provider.localModelFile
            disableThinking = provider.disableThinking
            apiKey = KeychainStore.read(provider.keychainAccount)
        } else {
            name = kind.title
            baseURL = kind.defaultBaseURL
            model = kind.defaultModel
            systemPrompt = PromptPresets.unrestricted
        }
    }

    @MainActor
    private func fetchModels() async {
        modelState = .loading
        let result = await ModelCatalog.fetch(
            kind: kind, baseURL: baseURL, apiKey: apiKey, extraHeaders: extraHeaders
        )
        switch result {
        case .success(let entries):
            modelList = entries
            modelState = .loaded(entries.count)
            if !entries.contains(where: { $0.id == model }), let first = entries.first {
                model = first.id
            }
        case .failure(let err):
            modelState = .failed(err.text)
        }
    }

    private func buildConfig() -> EndpointConfig {
        EndpointConfig(
            kind: kind, baseURL: baseURL, model: model,
            systemPrompt: systemPrompt, temperature: temperature,
            maxTokens: maxTokens, extraHeaders: extraHeaders,
            boostEnabled: boostEnabled, refusalRetry: refusalRetry,
            timeoutSeconds: timeoutSeconds, localModelFile: localModelFile,
            disableThinking: disableThinking
        )
    }

    @MainActor
    private func runTest() async {
        testState = .running
        do {
            let result = try await LLMClient.stream(
                config: buildConfig(),
                apiKey: apiKey,
                turns: [ChatTurn(role: "user", content: "回复两个字：连通")]
            ) { _ in }
            testState = .ok("通 · \(result.latencyMs)ms")
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            testState = .fail(msg)
        }
    }

    private func save() {
        if let provider {
            provider.name = name
            provider.kind = kind
            provider.baseURL = baseURL
            provider.model = model
            provider.temperature = temperature
            provider.maxTokens = maxTokens
            provider.timeoutSeconds = timeoutSeconds
            provider.extraHeaders = extraHeaders
            provider.systemPrompt = systemPrompt
            provider.boostOn = boostEnabled
            provider.retryOn = refusalRetry
            provider.localModelFile = localModelFile
            provider.disableThinking = disableThinking
            KeychainStore.save(apiKey, for: provider.keychainAccount)
        } else {
            let fresh = Provider(
                name: name, kind: kind, baseURL: baseURL, model: model,
                temperature: temperature, maxTokens: maxTokens,
                extraHeaders: extraHeaders, systemPrompt: systemPrompt,
                boostEnabled: boostEnabled, refusalRetry: refusalRetry
            )
            fresh.timeoutSeconds = timeoutSeconds
            fresh.localModelFile = localModelFile
            fresh.disableThinking = disableThinking
            ctx.insert(fresh)
            KeychainStore.save(apiKey, for: fresh.keychainAccount)
        }
        try? ctx.save()
        dismiss()
    }
}

// MARK: - 模型选择

struct ModelPickerSheet: View {
    let entries: [ModelCatalog.Entry]
    @Binding var selected: String

    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""

    private var filtered: [ModelCatalog.Entry] {
        guard !filter.isEmpty else { return entries }
        return entries.filter {
            $0.id.localizedCaseInsensitiveContains(filter) ||
            $0.display.localizedCaseInsensitiveContains(filter)
        }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { entry in
                Button {
                    selected = entry.id
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.id)
                                .font(.callout.monospaced())
                                .foregroundStyle(.primary)
                            if !entry.detail.isEmpty {
                                Text(entry.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        if entry.id == selected {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $filter, prompt: "搜模型")
            .navigationTitle("\(entries.count) 个模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 提示词预览

struct PromptPreviewSheet: View {
    let userPrompt: String
    let boostEnabled: Bool

    @Environment(\.dismiss) private var dismiss

    private var assembled: String {
        PromptBoost.assemble(systemPrompt: userPrompt, boostEnabled: boostEnabled)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("组成") {
                    LabeledContent("你的提示词", value: "\(userPrompt.count) 字符")
                    LabeledContent("破甲尾段", value: boostEnabled ? "\(PromptBoost.tail.count) 字符" : "关")
                    LabeledContent("合计", value: "\(assembled.count) 字符")
                }
                Section("完整内容") {
                    Text(assembled)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("实际发送")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
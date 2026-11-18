import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Provider.createdAt) private var providers: [Provider]
    @Query(sort: \PromptChip.createdAt) private var chips: [PromptChip]
    @Query private var localModels: [LocalModel]

    private var localModelCount: Int { localModels.count }

    @State private var editing: Provider?
    @State private var creating = false
    @State private var showChips = false
    @State private var showAppearance = false
    @State private var showLocalModels = false
    @State private var pendingDelete: Provider?

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                List {
                    Section {
                        ForEach(providers) { provider in
                            Button {
                                editing = provider
                            } label: {
                                ProviderCell(provider: provider)
                            }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button(role: .destructive) {
                                    pendingDelete = provider
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }

                        Button {
                            creating = true
                        } label: {
                            Label("添加供应商", systemImage: "plus.circle.fill")
                        }
                    } header: {
                        Text("API 供应商")
                    } footer: {
                        Text("Key 只存在本机 Keychain，不写进数据库、不上传。")
                    }

                    Section {
                        Button {
                            showAppearance = true
                        } label: {
                            HStack {
                                Label("外观", systemImage: "paintbrush")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        Button {
                            showChips = true
                        } label: {
                            HStack {
                                Label("提示词芯片", systemImage: "text.badge.plus")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text("\(chips.count)")
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        Button {
                            showLocalModels = true
                        } label: {
                            HStack {
                                Label("本地模型", systemImage: "internaldrive")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text("\(localModelCount)")
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    } header: {
                        Text("个性化")
                    }

                    Section("关于") {
                        LabeledContent("协议", value: "OpenAI / Anthropic / Gemini")
                        LabeledContent("流式", value: "SSE")
                        LabeledContent("存储", value: "SwiftData + Keychain")
                        LabeledContent("破甲", value: "尾段 + 13 条正则 + 重试")
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $editing) { ProviderEditView(provider: $0) }
            .sheet(isPresented: $creating) { ProviderEditView(provider: nil) }
            .sheet(isPresented: $showChips) { ChipManagerView() }
            .sheet(isPresented: $showAppearance) { AppearanceView() }
            .sheet(isPresented: $showLocalModels) { LocalModelView() }
            .confirmationDialog(
                "删除这个供应商？",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                presenting: pendingDelete
            ) { p in
                Button("删除", role: .destructive) {
                    KeychainStore.delete(p.keychainAccount)
                    ctx.delete(p)
                    try? ctx.save()
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            }
        }
    }
}

struct ProviderCell: View {
    let provider: Provider

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: provider.kind.symbol)
                .font(.system(size: 15))
                .foregroundStyle(.tint)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(provider.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                    if provider.boostEnabled {
                        Text("破甲")
                            .font(.caption2)
                            .foregroundStyle(.green)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.12), in: Capsule())
                    }
                }
                Text(provider.model)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

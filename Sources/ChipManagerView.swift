import SwiftUI
import SwiftData

struct ChipManagerView: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \PromptChip.createdAt) private var chips: [PromptChip]

    @State private var editing: PromptChip?
    @State private var creating = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                List {
                    Section {
                        ForEach(chips) { chip in
                            Button {
                                editing = chip
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(chip.title)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                    Text(chip.text)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button(role: .destructive) {
                                    ctx.delete(chip)
                                    try? ctx.save()
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }

                        Button {
                            creating = true
                        } label: {
                            Label("新建芯片", systemImage: "plus.circle.fill")
                        }
                    } footer: {
                        Text("常用指令存成标签，聊天时一点插入。")
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("提示词芯片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $editing) { ChipEditView(chip: $0) }
            .sheet(isPresented: $creating) { ChipEditView(chip: nil) }
        }
    }
}

struct ChipEditView: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss

    let chip: PromptChip?

    @State private var title = ""
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("名字") {
                    TextField("例如：先给代码", text: $title)
                }
                Section("内容") {
                    TextField("插入到输入框的文本", text: $text, axis: .vertical)
                        .lineLimit(5...14)
                }
            }
            .navigationTitle(chip == nil ? "新建芯片" : "编辑芯片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || text.isEmpty)
                }
            }
            .onAppear {
                if let chip {
                    title = chip.title
                    text = chip.text
                }
            }
        }
    }

    private func save() {
        if let chip {
            chip.title = title
            chip.text = text
        } else {
            ctx.insert(PromptChip(title: title, text: text))
        }
        try? ctx.save()
        dismiss()
    }
}

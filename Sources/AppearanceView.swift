import SwiftUI

struct AppearanceView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(Theme.appearanceKey) private var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage(Theme.accentKey) private var accentRaw = AccentChoice.blue.rawValue
    @AppStorage(Theme.backgroundKey) private var backgroundRaw = BackgroundStyle.plain.rawValue
    @AppStorage(Theme.bubbleKey) private var bubbleRaw = BubbleStyle.filled.rawValue
    @AppStorage(Theme.cornerKey) private var corner = 18.0

    var body: some View {
        NavigationStack {
            Form {
                Section("外观") {
                    Picker("模式", selection: $appearanceRaw) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 6), spacing: 14) {
                        ForEach(AccentChoice.allCases) { choice in
                            Button {
                                accentRaw = choice.rawValue
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(choice.color)
                                        .frame(width: 34, height: 34)
                                    if accentRaw == choice.rawValue {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(choice.label)
                        }
                    }
                    .padding(.vertical, 6)
                } header: {
                    Text("强调色")
                } footer: {
                    Text("跟系统「外观与亮度」里的强调色一致，会应用到按钮、开关、选中态。")
                }

                Section {
                    Picker("背景", selection: $backgroundRaw) {
                        ForEach(BackgroundStyle.allCases) { style in
                            Text(style.label).tag(style.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("气泡", selection: $bubbleRaw) {
                        ForEach(BubbleStyle.allCases) { style in
                            Text(style.label).tag(style.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("聊天外观")
                } footer: {
                    Text("「纯色」是系统背景色，最接近原生。渐变和柔光会用强调色做一层很淡的过渡。")
                }

                Section("圆角 (Int(corner))") {
                    Slider(value: $corner, in: Theme.cornerRange, step: 1)
                }

                Section {
                    previewCard
                } header: {
                    Text("预览")
                }
            }
            .navigationTitle("外观")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("我")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text("这个样子还满意吗？")
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill((AccentChoice(rawValue: accentRaw) ?? .blue).color.opacity(0.18))
                )
                .frame(maxWidth: .infinity, alignment: .trailing)

            HStack(spacing: 4) {
                Circle().fill(.tint).frame(width: 4, height: 4)
                Text("AI")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            Text("满意就留着，不满意继续调。")
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground))
                )
        }
        .listRowBackground(Color.clear)
    }
}

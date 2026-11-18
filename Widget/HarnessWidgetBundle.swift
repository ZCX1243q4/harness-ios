import WidgetKit
import SwiftUI
import ActivityKit

@main
struct HarnessWidgetBundle: WidgetBundle {
    var body: some Widget {
        GenerationLiveActivity()
    }
}

struct GenerationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GenerationAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 5) {
                        Image(systemName: icon(context.state.phase))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(tint(context.state.phase))
                        Text(context.attributes.providerName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Text(clock(context.state.elapsedSeconds))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.model)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(context.state.note)
                                .font(.caption2)
                                .foregroundStyle(tint(context.state.phase))
                            Spacer()
                            if context.state.receivedChars > 0 {
                                Text("\(context.state.receivedChars) 字")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(tint(context.state.phase))
                    }
                    .padding(.top, 2)
                }
            } compactLeading: {
                Image(systemName: icon(context.state.phase))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint(context.state.phase))
            } compactTrailing: {
                Text(compact(context.state))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(tint(context.state.phase))
            } minimal: {
                Image(systemName: icon(context.state.phase))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint(context.state.phase))
            }
            .keylineTint(tint(context.state.phase))
        }
    }

    private func icon(_ phase: GenerationAttributes.ContentState.Phase) -> String {
        switch phase {
        case .connecting: return "ellipsis"
        case .streaming: return "waveform"
        case .retrying: return "arrow.clockwise"
        case .finished: return "checkmark"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private func tint(_ phase: GenerationAttributes.ContentState.Phase) -> Color {
        switch phase {
        case .connecting: return .secondary
        case .streaming: return .cyan
        case .retrying: return .orange
        case .finished: return .green
        case .failed: return .red
        }
    }

    private func compact(_ state: GenerationAttributes.ContentState) -> String {
        switch state.phase {
        case .finished: return "完成"
        case .failed: return "失败"
        case .retrying: return "重试"
        default: return "\(state.receivedChars)"
        }
    }

    private func clock(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }
}

struct LockScreenView: View {
    let context: ActivityViewContext<GenerationAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.cyan)
                Text(context.attributes.providerName)
                    .font(.caption.weight(.medium))
                Spacer()
                Text(context.state.model)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(context.attributes.conversationTitle)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            HStack {
                Text(context.state.note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(context.state.receivedChars) 字")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView()
                .progressViewStyle(.linear)
                .tint(.cyan)
        }
        .padding(12)
    }
}

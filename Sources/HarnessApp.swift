import SwiftUI
import SwiftData

@main
struct HarnessApp: App {
    let container: ModelContainer
    @AppStorage(Theme.appearanceKey) private var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage(Theme.accentKey) private var accentRaw = AccentChoice.blue.rawValue

    init() {
        let schema = Schema([
            Provider.self,
            Conversation.self,
            ChatMessage.self,
            PromptChip.self,
            LocalModel.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            container = try! ModelContainer(for: schema, configurations: [fallback])
        }
    }

    private var scheme: ColorScheme? {
        (AppearanceMode(rawValue: appearanceRaw) ?? .system).colorScheme
    }

    private var tint: Color {
        (AccentChoice(rawValue: accentRaw) ?? .blue).color
    }

    var body: some Scene {
        WindowGroup {
            SessionListView()
                .preferredColorScheme(scheme)
                .tint(tint)
        }
        .modelContainer(container)
    }
}

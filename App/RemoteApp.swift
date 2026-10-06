import RemoteStorage
import SwiftUI

@main
struct RemoteApp: App {
    @State private var model: AppModel

    init() {
        let container = (try? DeviceStore.makeContainer()) ?? (try! DeviceStore.makeContainer(inMemory: true))
        _model = State(initialValue: AppModel(container: container))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(.accentColor)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppSettings.appearanceKey) private var appearance = AppSettings.Appearance.dark

    var body: some View {
        @Bindable var model = model
        Group {
            if let session = model.session {
                MainTabView(session: session)
                    .id(session.device.id)
            } else {
                NavigationStack { FindTVView() }
            }
        }
        .preferredColorScheme(appearance.colorScheme)
        .sheet(item: $model.pairingTarget) { device in
            PairingFlowView(device: device)
        }
        .sheet(isPresented: $model.isAddingTV) {
            NavigationStack {
                FindTVView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { model.isAddingTV = false }
                        }
                    }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(phase)
        }
    }
}

struct MainTabView: View {
    let session: RemoteViewModel

    var body: some View {
        TabView {
            RemoteView(session: session)
                .tabItem { Label("Remote", systemImage: "av.remote") }
            NavigationStack { AppsGridView(session: session) }
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

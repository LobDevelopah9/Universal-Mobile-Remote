import RemoteCore
import SwiftUI

struct AppsGridView: View {
    let session: RemoteViewModel
    @ScaledMetric(relativeTo: .body) private var tileWidth: CGFloat = 100

    var body: some View {
        Group {
            if !session.capabilities.contains(.apps) {
                ContentUnavailableView(
                    "No App Launching",
                    systemImage: "square.grid.2x2",
                    description: Text("\(session.device.name) doesn't support opening apps from your phone.")
                )
            } else if session.apps.isEmpty && session.isLoadingApps {
                ProgressView("Loading apps…")
            } else if session.apps.isEmpty {
                ContentUnavailableView {
                    Label("No Apps", systemImage: "square.grid.2x2")
                } description: {
                    Text(session.appsError?.userMessage ?? "No apps were found on this TV.")
                } actions: {
                    Button("Try Again") { Task { await session.loadApps() } }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !session.capabilities.contains(.appList) {
                            Text("This TV can't list its installed apps, so these are common ones. Apps that aren't installed open the store.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: tileWidth), spacing: 16)], spacing: 20) {
                            ForEach(session.apps) { app in
                                Button { session.launch(app) } label: {
                                    AppTile(app: app, showsIcon: session.capabilities.contains(.appIcons))
                                }
                                .buttonStyle(PressScaleStyle())
                                .accessibilityLabel("Open \(app.name)")
                            }
                        }
                    }
                    .padding(20)
                }
                .refreshable { await session.loadApps() }
            }
        }
        .navigationTitle("Apps")
        .toolbar {
            ToolbarItem(placement: .principal) {
                DeviceSwitcherPill(session: session)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AppTile: View {
    let app: TVApp
    let showsIcon: Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.remoteKey)
                if showsIcon, let url = app.iconURL {
                    AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: 0.2))) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            monogram
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    monogram
                }
            }
            .aspectRatio(4 / 3, contentMode: .fit)

            Text(app.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
        }
    }

    private var monogram: some View {
        Text(app.name.prefix(1).uppercased())
            .font(.title.weight(.bold))
            .foregroundStyle(.secondary)
    }
}

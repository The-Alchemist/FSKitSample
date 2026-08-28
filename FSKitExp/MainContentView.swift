import SwiftUI

struct MainContentView: View {
    @Environment(ViewModel.self) private var viewModel

    var body: some View {
        @Bindable var viewModel = viewModel

        VStack(alignment: .leading, spacing: 16) {
            GroupBox("File System Extension") {
                if let module = viewModel.ownModule {
                    LabeledContent("Bundle") {
                        Text(module.bundleIdentifier)
                            .textSelection(.enabled)
                    }
                    LabeledContent("Enabled") {
                        Text(module.isEnabled ? "Yes" : "No")
                    }
                    if !module.isEnabled {
                        HStack {
                            Text("The extension is off. Mounting will fail until you enable it.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Open Settings") {
                                viewModel.openExtensionSettings()
                            }
                        }
                    }
                } else {
                    Text("MyFS is not registered yet. Sign both targets with a paid team, then run this app once.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox("Mount ZIP") {
                HStack {
                    TextField("Archive path", text: $viewModel.zipPath)
                    Button("Browse…") {
                        viewModel.chooseArchive()
                    }
                    Button("Mount") {
                        Task { await viewModel.mountSelected() }
                    }
                    .disabled(viewModel.isMounting || viewModel.zipPath.isEmpty)
                }
            }

            GroupBox("Mounted archives") {
                if viewModel.mounts.isEmpty {
                    Text("No archives mounted from this app.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Table(viewModel.mounts) {
                        TableColumn("Archive") { volume in
                            Text(volume.zipURL.lastPathComponent)
                        }
                        TableColumn("Mount point") { volume in
                            Text(volume.mountPoint.path)
                                .lineLimit(1)
                        }
                        TableColumn("Actions") { volume in
                            HStack {
                                Button("Reveal") { viewModel.reveal(volume) }
                                Button("Unmount") { viewModel.unmount(volume) }
                            }
                        }
                    }
                    .frame(minHeight: 120)
                }
            }

            Spacer()
        }
        .padding()
        .frame(minWidth: 640, minHeight: 420)
        .navigationTitle("ZipFSKitExp")
        .alert(
            viewModel.errorMessage ?? "Error",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil; viewModel.errorDetails = nil } }
            )
        ) {
            if viewModel.errorSuggestsEnableExtension {
                Button("Open Settings") {
                    viewModel.openExtensionSettings()
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorDetails ?? "")
        }
    }
}

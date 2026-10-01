import SwiftUI

struct MainContentView: View {
    @Environment(ViewModel.self) private var viewModel

    var body: some View {
        @Bindable var viewModel = viewModel

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: viewModel.isExtensionEnabled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(viewModel.isExtensionEnabled ? .green : .orange)
                Text(viewModel.isExtensionEnabled ? "File System Extension enabled" : "File System Extension is off")
                    .font(.callout)
                Spacer(minLength: 8)
                if !viewModel.isExtensionEnabled {
                    Button("Open Settings") {
                        viewModel.openExtensionSettings()
                    }
                }
            }

            GroupBox("Mount ZIP") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Archive path", text: $viewModel.zipPath)
                    HStack {
                        Button("Browse…") {
                            viewModel.chooseArchive()
                        }
                        Spacer()
                        Button("Mount") {
                            Task { await viewModel.mountSelected() }
                        }
                        .disabled(viewModel.isMounting || viewModel.zipPath.isEmpty)
                    }
                }
            }

            GroupBox("Mounted archives") {
                if viewModel.mounts.isEmpty {
                    Text("No archives mounted from this app.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.mounts) { volume in
                            HStack(alignment: .center, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(volume.zipURL.lastPathComponent)
                                        .lineLimit(1)
                                    Text(volume.mountPoint.path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 8)
                                Button("Reveal") { viewModel.reveal(volume) }
                                Button("Unmount") { viewModel.unmount(volume) }
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
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

import SwiftUI

struct OnboardingView: View {
    @Environment(ViewModel.self) private var viewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Enable ZipFS")
                .font(.largeTitle.bold())

            Text("ZipFSKitExp needs permission to mount ZIP archives. macOS requires you to turn on the File System Extension once per install (and again after some app updates).")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox("Setup checklist") {
                VStack(alignment: .leading, spacing: 12) {
                    checklistRow(
                        number: 1,
                        title: "App installed",
                        detail: "You are running ZipFSKitExp.",
                        isComplete: true
                    )

                    checklistRow(
                        number: 2,
                        title: "Extension registered",
                        detail: registrationDetail,
                        isComplete: viewModel.isModuleRegistered
                    )

                    checklistRow(
                        number: 3,
                        title: "File System Extension enabled",
                        detail: "In System Settings, turn on **FSKitExpExtension** under File System Extensions.",
                        isComplete: viewModel.isExtensionEnabled
                    )

                    checklistRow(
                        number: 4,
                        title: "Open ZIP archives",
                        detail: "Double-click a `.zip` file or use Mount in this app.",
                        isComplete: viewModel.isExtensionEnabled
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Open System Settings") {
                    viewModel.openExtensionSettings()
                }
                .keyboardShortcut(.defaultAction)

                Button("I've enabled it") {
                    viewModel.refreshModules()
                }

                if viewModel.isPollingModules {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.leading, 4)
                    Text("Checking…")
                        .foregroundStyle(.secondary)
                }
            }

            if !viewModel.isModuleRegistered {
                Text("If the extension does not appear, rebuild with a paid Apple Developer team and run this app once from Xcode or Applications.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(24)
        .frame(minWidth: 640, minHeight: 420)
        .onAppear {
            viewModel.startModulePolling()
        }
        .onDisappear {
            viewModel.stopModulePolling()
        }
    }

    private var registrationDetail: String {
        if let module = viewModel.ownModule {
            return "Registered as \(module.bundleIdentifier)."
        }
        return "Launching this app registers the embedded extension with macOS."
    }

    @ViewBuilder
    private func checklistRow(
        number: Int,
        title: String,
        detail: String,
        isComplete: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isComplete ? .green : .secondary)
                .font(.title3)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(number). \(title)")
                    .font(.headline)
                Text(LocalizedStringKey(detail))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

import SwiftUI

struct OnboardingView: View {
    @Environment(ViewModel.self) private var viewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enable ZipFS")
                .font(.title2.bold())

            Text("ZipFS needs permission to mount ZIP and 7z archives. Turn on the File System Extension once per install (and again after some app updates).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox("Setup checklist") {
                VStack(alignment: .leading, spacing: 10) {
                    checklistRow(
                        number: 1,
                        title: "App installed",
                        detail: "ZipFS is running in the menu bar.",
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
                        title: "Extension enabled",
                        detail: "In System Settings, turn on **FSKitExpExtension** under File System Extensions.",
                        isComplete: viewModel.isExtensionEnabled
                    )

                    checklistRow(
                        number: 4,
                        title: "Open archives",
                        detail: "Double-click a `.zip` or `.7z` file or use Mount in this menu.",
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
                    Text("Checking…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !viewModel.isModuleRegistered {
                Text("If the extension does not appear, rebuild with a paid Apple Developer team and run this app once from Xcode or Applications.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
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
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isComplete ? .green : .secondary)
                .font(.body)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(number). \(title)")
                    .font(.subheadline.weight(.semibold))
                Text(LocalizedStringKey(detail))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

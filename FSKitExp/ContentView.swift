import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(ViewModel.self) private var viewModel

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if viewModel.needsOnboarding {
                    OnboardingView()
                } else {
                    MainContentView()
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Quit ZipFS") {
                    NSApp.terminate(nil)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 340)
        .onAppear {
            viewModel.refreshModules()
        }
    }
}

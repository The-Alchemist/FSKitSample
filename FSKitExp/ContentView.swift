import SwiftUI

struct ContentView: View {
    @Environment(ViewModel.self) private var viewModel

    var body: some View {
        Group {
            if viewModel.needsOnboarding {
                OnboardingView()
            } else {
                MainContentView()
            }
        }
        .onAppear {
            viewModel.refreshModules()
        }
    }
}

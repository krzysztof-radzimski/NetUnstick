import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "network")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("NetUnstick")
                .font(.largeTitle.bold())
            Text("Fundament aplikacji jest gotowy. Diagnostyka i naprawy sieci nie są jeszcze zaimplementowane.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Diagnostyka i naprawy sieci nie są jeszcze zaimplementowane")
        }
        .padding(32)
        .frame(minWidth: 460, minHeight: 280)
    }
}

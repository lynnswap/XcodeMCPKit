import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text(VerifierCore.message())
                .font(.headline)
                .accessibilityIdentifier("verifier-message")
            Text("\(VerifierCore.number())")
                .accessibilityIdentifier("verifier-number")
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
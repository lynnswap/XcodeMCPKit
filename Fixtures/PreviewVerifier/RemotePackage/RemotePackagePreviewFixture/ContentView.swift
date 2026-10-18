import SwiftUI
import Atomics
struct ContentView: View {
    let counter = ManagedAtomic(7)
    var body: some View {
        Text("REMOTE PACKAGE " + String(counter.load(ordering: .relaxed)))
            .padding(24).background(.cyan.opacity(0.2))
    }
}
#Preview("APP REMOTE PACKAGE DEPENDENCY", traits: .fixedLayout(width: 360, height: 180)) {
    ContentView()
}

import SwiftUI

struct NamedPhysicalPreview: PreviewProvider {
    static var previews: some View {
        GeometryReader { geometry in
            VStack(spacing: 12) {
                Text("PHYSICAL SOURCE DEVICE")
                Text("SIZE \(Int(geometry.size.width))x\(Int(geometry.size.height))")
                Text("SAFE \(Int(geometry.safeAreaInsets.top)),\(Int(geometry.safeAreaInsets.bottom))")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.blue.opacity(0.2))
        }
        .previewDevice(PreviewDevice(rawValue: __PREVIEW_DEVICE_NAME__))
        .previewDisplayName("NAMED PHYSICAL DEVICE")
    }
}

struct ContentView: View { var body: some View { Text("PHYSICAL PREVIEW FIXTURE") } }

import ABSCore
import SwiftUI

struct ContentView: View {
    var version = AppVersion()

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "headphones")
                .imageScale(.large)
            Text("Audiobookshelf")
                .font(.title)
            Text("Version \(version.description)")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}

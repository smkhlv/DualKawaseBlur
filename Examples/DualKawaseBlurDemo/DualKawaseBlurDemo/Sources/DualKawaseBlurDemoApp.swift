import SwiftUI

@main
struct DualKawaseBlurDemoApp: App {
    var body: some Scene {
        WindowGroup {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains(CPUEncodeBenchmark.flag) {
                CPUEncodeBenchmarkView(request: CPUEncodeBenchmark.request(from: arguments))
            } else {
                ContentView()
            }
        }
    }
}

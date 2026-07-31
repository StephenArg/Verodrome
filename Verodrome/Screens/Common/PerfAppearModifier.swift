import SwiftUI
import VerodromeKit

/// Logs appear / first-layout timing for a screen.
struct PerfAppearModifier: ViewModifier {
    let name: String
    let details: String
    @State private var token: Int?
    @State private var loggedAppear = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !loggedAppear else { return }
                loggedAppear = true
                token = PerfTrace.begin("\(name).appear", details: details)
                // End after the next run-loop turn so first layout work is included.
                DispatchQueue.main.async {
                    if let token {
                        PerfTrace.end(token, details: details)
                        self.token = nil
                    }
                }
            }
            .onDisappear {
                PerfTrace.event("\(name).disappear")
            }
    }
}

extension View {
    func perfAppear(_ name: String, details: String = "") -> some View {
        modifier(PerfAppearModifier(name: name, details: details))
    }
}

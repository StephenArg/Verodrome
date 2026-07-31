import SwiftUI
import VerodromeKit

/// Logs appear / first-layout timing for a screen.
struct PerfAppearModifier: ViewModifier {
    let name: String
    let details: String
    @State private var token: Int?
    @State private var loggedAppear = false

    func body(content: Content) -> some View {
        if PerfTrace.isEnabled {
            content
                .onAppear {
                    guard !loggedAppear else { return }
                    loggedAppear = true
                    token = PerfTrace.begin("\(name).appear", details: details)
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
        } else {
            content
        }
    }
}

extension View {
    func perfAppear(_ name: String, details: String = "") -> some View {
        modifier(PerfAppearModifier(name: name, details: details))
    }
}

import SwiftUI
import UIKit

struct MiniPlayerHostingView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

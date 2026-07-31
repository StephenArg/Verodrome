import UIKit

enum PopupPlayerTransitionController {
    static func configureSheet(_ controller: UIViewController) {
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 24
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
        }
    }
}

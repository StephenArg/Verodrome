import CarPlay
import UIKit
import VerodromeKit

@MainActor
final class CarPlaySearchController: NSObject, CPSearchTemplateDelegate {
    private let catalog: CarPlayCatalog

    init(catalog: CarPlayCatalog) {
        self.catalog = catalog
    }

    func makeSearchTemplate() -> CPSearchTemplate {
        let template = CPSearchTemplate()
        template.delegate = self
        return template
    }

    func items(matching query: String) -> [CPListItem] {
        catalog.songSearchItems(query: query)
    }

    func searchTemplate(
        _ searchTemplate: CPSearchTemplate,
        updatedSearchText searchText: String,
        completionHandler: @escaping ([CPListItem]) -> Void
    ) {
        completionHandler(items(matching: searchText))
    }

    func searchTemplate(
        _ searchTemplate: CPSearchTemplate,
        selectedResult item: CPListItem,
        completionHandler: @escaping () -> Void
    ) {
        item.handler?(item, completionHandler)
    }
}

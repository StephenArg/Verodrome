import SwiftUI
import VerodromeKit

struct LibraryEditorView: View {
    @EnvironmentObject private var settings: SettingsStore

    private var canRemove: Bool { settings.enabledLibraryCategories.count > 1 }

    var body: some View {
        List {
            Section {
                ForEach(settings.enabledLibraryCategories) { category in
                    Label(category.title, systemImage: category.systemImage)
                }
                .onMove { from, to in
                    settings.enabledLibraryCategories.move(fromOffsets: from, toOffset: to)
                    settings.save()
                }
                .onDelete(perform: canRemove ? deleteCategories : nil)
            } header: {
                Text("Visible Categories")
            } footer: {
                Text("Drag to reorder. Keep at least one category.")
            }

            if !hiddenCategories.isEmpty {
                Section("Hidden Categories") {
                    ForEach(hiddenCategories) { category in
                        Button {
                            settings.enabledLibraryCategories.append(category)
                            settings.save()
                        } label: {
                            Label(category.title, systemImage: category.systemImage)
                        }
                    }
                }
            }
        }
        .verodromePlainList()
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Customize Library")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var hiddenCategories: [LibraryCategory] {
        LibraryCategory.allCases.filter { !settings.enabledLibraryCategories.contains($0) }
    }

    private func deleteCategories(at offsets: IndexSet) {
        guard canRemove else { return }
        var next = settings.enabledLibraryCategories
        let sorted = offsets.sorted(by: >)
        for index in sorted where next.count > 1 {
            next.remove(at: index)
        }
        settings.enabledLibraryCategories = LibraryCategory.normalized(next)
        settings.save()
    }
}

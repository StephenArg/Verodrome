import SwiftUI
import VerodromeKit

struct TabBarEditorView: View {
    @EnvironmentObject private var settings: SettingsStore

    private var canRemove: Bool { settings.enabledRootTabs.count > 1 }
    private var canAdd: Bool { settings.enabledRootTabs.count < RootTabItem.maxVisible }

    var body: some View {
        List {
            Section {
                ForEach(settings.enabledRootTabs) { tab in
                    Label(tab.title, systemImage: tab.systemImage)
                }
                .onMove { from, to in
                    settings.enabledRootTabs.move(fromOffsets: from, toOffset: to)
                    settings.save()
                }
                .onDelete(perform: canRemove ? deleteTabs : nil)
            } header: {
                Text("Visible Tabs")
            } footer: {
                Text("Show between 1 and \(RootTabItem.maxVisible) tabs. Drag to reorder.")
            }

            if !hiddenTabs.isEmpty {
                Section("Available Tabs") {
                    ForEach(hiddenTabs) { tab in
                        Button {
                            guard canAdd else { return }
                            settings.enabledRootTabs.append(tab)
                            settings.save()
                        } label: {
                            Label(tab.title, systemImage: tab.systemImage)
                        }
                        .disabled(!canAdd)
                    }
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Tab Bar")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var hiddenTabs: [RootTabItem] {
        RootTabItem.allCases.filter { !settings.enabledRootTabs.contains($0) }
    }

    private func deleteTabs(at offsets: IndexSet) {
        guard canRemove else { return }
        // Keep at least one tab even if the user selects everything.
        var next = settings.enabledRootTabs
        let sorted = offsets.sorted(by: >)
        for index in sorted where next.count > 1 {
            next.remove(at: index)
        }
        settings.enabledRootTabs = RootTabItem.normalized(next)
        settings.save()
    }
}

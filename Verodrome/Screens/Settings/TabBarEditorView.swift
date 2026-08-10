import SwiftUI
import VerodromeKit

struct TabBarEditorView: View {
    @EnvironmentObject private var settings: SettingsStore

    private var canAdd: Bool { settings.enabledRootTabs.count < RootTabItem.maxVisible }

    var body: some View {
        List {
            Section {
                ForEach(settings.enabledRootTabs) { tab in
                    Label(tab.title, systemImage: tab.systemImage)
                        .deleteDisabled(isDeleteDisabled(tab))
                }
                .onMove { from, to in
                    settings.enabledRootTabs.move(fromOffsets: from, toOffset: to)
                    settings.save()
                }
                .onDelete(perform: deleteTabs)
            } header: {
                Text("Visible Tabs")
            } footer: {
                Text(
                    "Show between 1 and \(RootTabItem.maxVisible) tabs. Keep Home or Library so Settings stays reachable. Drag to reorder."
                )
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
        .verodromePlainList()
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Tab Bar")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var hiddenTabs: [RootTabItem] {
        RootTabItem.allCases.filter { !settings.enabledRootTabs.contains($0) }
    }

    /// Home/Library can leave the bar, but not the last one — that's how Settings is reached.
    private func isDeleteDisabled(_ tab: RootTabItem) -> Bool {
        guard RootTabItem.settingsAccessTabs.contains(tab) else { return false }
        return settingsAccessCount(in: settings.enabledRootTabs) <= 1
    }

    private func deleteTabs(at offsets: IndexSet) {
        var next = settings.enabledRootTabs
        let sorted = offsets.sorted(by: >)
        for index in sorted {
            guard next.indices.contains(index), next.count > 1 else { continue }
            let tab = next[index]
            if RootTabItem.settingsAccessTabs.contains(tab),
               settingsAccessCount(in: next) <= 1 {
                continue
            }
            next.remove(at: index)
        }
        settings.enabledRootTabs = RootTabItem.normalized(next)
        settings.save()
    }

    private func settingsAccessCount(in tabs: [RootTabItem]) -> Int {
        tabs.reduce(0) { count, tab in
            count + (RootTabItem.settingsAccessTabs.contains(tab) ? 1 : 0)
        }
    }
}

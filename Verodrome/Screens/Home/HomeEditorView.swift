import SwiftUI
import VerodromeKit

struct HomeEditorView: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Visible Sections") {
                    ForEach(settings.enabledHomeSections) { section in
                        Text(section.title)
                    }
                    .onMove { from, to in
                        settings.enabledHomeSections.move(fromOffsets: from, toOffset: to)
                        settings.save()
                    }
                    .onDelete { indexSet in
                        settings.enabledHomeSections.remove(atOffsets: indexSet)
                        settings.save()
                    }
                }

                Section("Hidden Sections") {
                    ForEach(hiddenSections) { section in
                        Button {
                            settings.enabledHomeSections.append(section)
                            settings.save()
                        } label: {
                            Label(section.title, systemImage: "plus.circle")
                        }
                    }
                }
            }
            .navigationTitle("Customize Home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
        }
    }

    private var hiddenSections: [HomeSection] {
        HomeSection.allCases.filter { !settings.enabledHomeSections.contains($0) }
    }
}

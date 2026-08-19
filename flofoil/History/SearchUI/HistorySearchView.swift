import SwiftUI

struct HistorySearchView: View {
    @ObservedObject var model: HistorySearchViewModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: model.mode == .url ? "globe" : "magnifyingglass").font(.title2).foregroundStyle(.secondary)
                TextField(placeholder, text: $model.query)
                    .textFieldStyle(.plain).font(.title3).focused($focused)
                    .accessibilityLabel(NSLocalizedString("Search History", comment: ""))
                if model.isSearching { ProgressView().controlSize(.small) }
            }
            .padding(18)

            if !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Divider()
                if model.resultCount == 0 && !model.isSearching {
                    Text(NSLocalizedString("No Search Results", comment: ""))
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 28)
                } else {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                                HistorySearchResultRow(result: result, isSelected: model.selectedIndex == index)
                                    .onTapGesture { model.open(result) }
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            model.delete(result)
                                        } label: {
                                            Label(NSLocalizedString("Delete", comment: ""), systemImage: "trash")
                                        }
                                }
                            }
                            if let url = model.openURL {
                                OpenURLSearchResultRow(url: url, isSelected: model.selectedIndex == model.results.count)
                                    .onTapGesture { model.openURLResult() }
                            }
                        }
                    }.frame(maxHeight: 560).padding(8)
                }
            }
        }
        .frame(width: 620)
        .fixedSize(horizontal: false, vertical: true)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear {
            focused = true
            triggerSelectAllIfNeeded()
        }
        .onChange(of: model.focusRequest) { _, _ in
            focused = true
            triggerSelectAllIfNeeded()
        }
    }

    private func triggerSelectAllIfNeeded() {
        if model.shouldSelectAll {
            DispatchQueue.main.async {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
    }

    private var placeholder: String {
        switch model.mode {
        case .history: NSLocalizedString("Search History Placeholder", comment: "")
        case .url: NSLocalizedString("Enter URL Placeholder", comment: "")
        }
    }
}

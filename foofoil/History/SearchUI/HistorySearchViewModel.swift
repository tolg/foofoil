import Foundation
import Combine

enum HistorySearchMode {
    case history
    case url
}

@MainActor
final class HistorySearchViewModel: ObservableObject {
    @Published var query = "" { didSet { queryChanged() } }
    @Published private(set) var mode: HistorySearchMode = .history
    @Published private(set) var results: [HistorySearchResult] = []
    @Published private(set) var openURL: URL?
    @Published var selectedIndex: Int?
    @Published private(set) var isSearching = false
    @Published private(set) var focusRequest = 0

    private var searchTask: Task<Void, Never>?
    private var generation = 0
    var openResult: ((UUID) -> Void)?
    var openWebURL: ((URL) -> Void)?

    var resultCount: Int { results.count + (openURL == nil ? 0 : 1) }

    @Published private(set) var shouldSelectAll = false

    func reset(mode: HistorySearchMode = .history, initialQuery: String? = nil) {
        searchTask?.cancel()
        generation += 1
        self.mode = mode
        let trimmedInitial = initialQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        shouldSelectAll = !trimmedInitial.isEmpty
        query = trimmedInitial
        results = []
        openURL = nil
        selectedIndex = nil
        isSearching = false
        focusRequest += 1
    }

    func moveSelection(by offset: Int) {
        guard resultCount > 0 else { return }
        selectedIndex = min(max((selectedIndex ?? 0) + offset, 0), resultCount - 1)
    }

    func openSelected() {
        guard let selectedIndex else { return }
        if results.indices.contains(selectedIndex) {
            openResult?(results[selectedIndex].id)
        } else if selectedIndex == results.count, let openURL {
            openWebURL?(openURL)
        }
    }

    func open(_ result: HistorySearchResult) { openResult?(result.id) }

    func openURLResult() {
        guard let openURL else { return }
        openWebURL?(openURL)
    }

    func delete(_ result: HistorySearchResult) {
        let oldIndex = results.firstIndex(of: result) ?? 0
        if let config = HistoryRepository.shared.config(id: result.id) {
            HistoryManager.shared.removeFromHistory(config)
        }
        performSearch(preferredIndex: oldIndex, debounce: false)
    }

    private func queryChanged() { performSearch(preferredIndex: 0, debounce: true) }

    private func performSearch(preferredIndex: Int, debounce: Bool) {
        searchTask?.cancel()
        generation += 1
        let currentGeneration = generation
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        results = []
        openURL = Self.url(from: trimmed)
        selectedIndex = openURL == nil ? nil : 0
        guard !trimmed.isEmpty else {
            results = []; openURL = nil; selectedIndex = nil; isSearching = false
            return
        }
        isSearching = true
        searchTask = Task { [weak self] in
            if debounce { try? await Task.sleep(nanoseconds: 150_000_000) }
            guard !Task.isCancelled else { return }
            let values = await HistoryRepository.shared.search(trimmed)
            guard let self, !Task.isCancelled, currentGeneration == self.generation else { return }
            self.results = self.mode == .url
                ? values.filter { $0.contentKind == .web }
                : values
            self.selectedIndex = self.resultCount == 0 ? nil : min(preferredIndex, self.resultCount - 1)
            self.isSearching = false
        }
    }

    private static func url(from input: String) -> URL? {
        guard !input.isEmpty, !input.contains(where: \.isWhitespace) else { return nil }
        let candidate: String
        if input.lowercased().hasPrefix("http://") || input.lowercased().hasPrefix("https://") {
            candidate = input
        } else if input == "localhost" || input.contains(".") {
            candidate = "https://\(input)"
        } else {
            return nil
        }
        guard let url = URL(string: candidate), let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

import SwiftUI

@MainActor @Observable
final class Pager {
    var items: [HGSeries] = []
    var hasMore = true
    var isLoading = false
    var error: Error?
    private(set) var page = HGPage(items: [], hasMore: true, nextOffset: 0)
    private var fetch: ((HGPage, [HGSeries]) async throws -> HGPage)?
    private var token = UUID()

    func reset(_ f: @escaping (HGPage, [HGSeries]) async throws -> HGPage) {
        fetch = f; items = []; hasMore = true; error = nil; isLoading = false
        page = HGPage(items: [], hasMore: true, nextOffset: 0); token = UUID()
        loadMore()
    }

    func loadMore() {
        guard let fetch, hasMore, !isLoading else { return }
        isLoading = true
        let t = token, prev = page, seen = items
        Task {
            do {
                let p = try await fetch(prev, seen)
                guard t == token else { return }
                var ids = Set(items.map(\.id))
                items += p.items.filter { ids.insert($0.id).inserted }
                page = p
                hasMore = p.hasMore && !p.items.isEmpty
                error = nil
            } catch {
                guard t == token else { return }
                self.error = error
            }
            if t == token { isLoading = false }
        }
    }
}

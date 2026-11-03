import Foundation

/// Search as you type: a search starts once typing pauses, runs off the main thread (through
/// `NyCore.searchRecords`), and only the newest one's results are shown.
@MainActor
final class RecordSearch {
    private var generation = 0

    /// Runs `search` after a short pause, then hands its result to `show` unless a newer search (or
    /// `cancel`) came meanwhile.
    func run<Result>(_ search: @escaping @MainActor () async -> Result, show: @escaping @MainActor (Result) -> Void) {
        generation += 1
        let mine = generation
        Task { [weak self] in
            // A pause in typing, so each keystroke doesn't start a search of its own.
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard mine == self?.generation else { return }
            let found = await search()
            guard mine == self?.generation else { return }
            show(found)
        }
    }

    /// Whatever is still on its way is dropped.
    func cancel() { generation += 1 }
}

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Apple Intelligence on the mixes

/// What the on-device model adds to the mixes, when it is there: which
/// listening modes to feature today, in what order, named and with a line
/// saying why - and, for a mix's shortlist, which songs belong together
/// best. It never sees more than the numbers the app already worked out,
/// never picks a song that is not on the list it was given, and everything
/// it answers is checked; whatever fails, the mixes stay as the app built
/// them.
enum TasteCurator {
    /// `operation`'s result, or nil if it takes longer than `seconds`.
    ///
    /// Raced through a continuation rather than a task group: a group does
    /// not return before all its children finish, and a model request that
    /// ignores cancellation kept the caller waiting well past the timeout.
    /// The operation is cancelled on timeout and left to wind down unobserved.
    /// Cancelling the caller answers nil at once the same way, and whichever
    /// side finishes first cancels the other - the sleeper too, when the
    /// work wins, so it does not linger for the rest of the timeout.
    static func timed<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async -> T?) async -> T? {
        let once = ResumeOnce<T?>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                // Already cancelled before the continuation existed.
                guard once.set(continuation) else {
                    continuation.resume(returning: nil)
                    return
                }
                let work = Task {
                    let value = await operation()
                    if once.resume(with: value) { once.cancelTasks() }
                }
                let sleeper = Task {
                    try? await Task.sleep(for: .seconds(seconds))
                    if once.resume(with: nil) { once.cancelTasks() }
                }
                once.adopt([work, sleeper])
            }
        } onCancel: {
            if once.resume(with: nil) { once.cancelTasks() }
        }
    }

    /// Resumes a continuation exactly once, whichever side gets there first
    /// (work, timeout or cancellation), and owns the racing tasks.
    private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Never>?
        private var finished = false
        private var tasks: [Task<Void, Never>] = []

        /// False when the race was already decided (cancelled early): the
        /// caller resumes the continuation itself.
        func set(_ continuation: CheckedContinuation<Value, Never>) -> Bool {
            lock.withLock {
                guard !finished else { return false }
                self.continuation = continuation
                return true
            }
        }

        /// Whether this call decided the race.
        @discardableResult
        func resume(with value: Value) -> Bool {
            let (won, pending) = lock.withLock { () -> (Bool, CheckedContinuation<Value, Never>?) in
                guard !finished else { return (false, nil) }
                finished = true
                defer { continuation = nil }
                return (true, continuation)
            }
            pending?.resume(returning: value)
            return won
        }

        /// Keeps the racing tasks to cancel; cancels them at once if the
        /// race was decided before they were handed over.
        func adopt(_ newTasks: [Task<Void, Never>]) {
            let decided = lock.withLock { () -> Bool in
                tasks = newTasks
                return finished
            }
            if decided { newTasks.forEach { $0.cancel() } }
        }

        func cancelTasks() {
            lock.withLock { tasks }.forEach { $0.cancel() }
        }
    }

    /// Whether the model can be asked at all on this device, now.
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    /// The device is not saving power or running hot: background or not,
    /// the model is not run then.
    static var deviceAllows: Bool {
        !ProcessInfo.processInfo.isLowPowerModeEnabled
            && ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue
    }

    struct Pick: Sendable {
        /// Index into the modes as given.
        let index: Int
        let title: String?
        let why: String?
    }

    /// One request: which of `modes` (each a few lines of facts) to feature
    /// today, best first, each with a title and a one-line why grounded in
    /// those facts. Nil when the model is unavailable, slow or answers
    /// nothing usable.
    static func curate(profile: String, modes: [String], today: String) async -> [Pick]? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *), isAvailable, !modes.isEmpty else { return nil }
        let language = Locale.current.localizedString(forLanguageCode: Locale.current.language.languageCode?.identifier ?? "en") ?? "English"
        let prompt = """
        Today: \(today)
        Listener: \(profile)
        Listening modes:
        \(modes.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
        """
        let answer = await timed(25) { () -> FeaturedModes? in
            let session = LanguageModelSession(instructions: """
            You help a music app present a listener's own listening habits ("modes"), found in their \
            listening history. Choose which modes to feature today and order them best first, \
            favouring modes that fit today and that the listener plays a lot or lately. For each, give \
            a short evocative name and one sentence saying why it is for them, both in \(language). \
            Use only the facts given: never invent artists, songs, places or numbers. Names must all differ.
            """)
            return try? await session.respond(to: prompt, generating: FeaturedModes.self).content
        }
        guard let answer else { return nil }
        let trim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”«»"))
        var seen = Set<Int>()
        var titles = Set<String>()
        let picks = answer.modes.compactMap { mode -> Pick? in
            let index = mode.mode - 1
            guard modes.indices.contains(index), seen.insert(index).inserted else { return nil }
            let title = mode.title.trimmingCharacters(in: trim)
            let why = mode.why.trimmingCharacters(in: trim)
            let goodTitle = !title.isEmpty && title.count <= 40 && titles.insert(title.lowercased()).inserted
            return Pick(index: index, title: goodTitle ? title : nil, why: why.isEmpty || why.count > 110 ? nil : why)
        }
        return picks.isEmpty ? nil : picks
        #else
        return nil
        #endif
    }

    /// One request: the songs of `songs` (one line each) that make the most
    /// coherent mix of the kind `description` says, best first - as indices
    /// into `songs`. Checked: in range, no repeats, and at least half of
    /// `keep` of them; nil otherwise.
    static func rerank(description: String, songs: [String], keep: Int, timeout: Double) async -> [Int]? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *), isAvailable, songs.count > keep else { return nil }
        let prompt = """
        Mix: \(description)
        Songs:
        \(songs.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
        Choose the \(keep) songs that fit this mix and each other best.
        """
        let answer = await timed(timeout) { () -> SongPicks? in
            let session = LanguageModelSession(instructions: """
            You help order a personal music mix. From a numbered list of songs from the listener's own \
            library, pick the ones that belong together best for the mix described, best first, \
            answering with their numbers only. Use only numbers from the list.
            """)
            return try? await session.respond(to: prompt, generating: SongPicks.self).content
        }
        guard let answer else { return nil }
        var seen = Set<Int>()
        let indices = answer.songs.map { $0 - 1 }.filter { songs.indices.contains($0) && seen.insert($0).inserted }
        return indices.count * 2 >= keep ? Array(indices.prefix(keep)) : nil
        #else
        return nil
        #endif
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct FeaturedMode {
    @Guide(description: "The number of the listening mode, as listed")
    var mode: Int
    @Guide(description: "A short, evocative name for this mode's mix, two to four words. No quotes, no emoji, not just the word Mix.")
    var title: String
    @Guide(description: "One short sentence, at most twelve words, telling the listener why this mix is for them, from the facts given only. No quotes.")
    var why: String
}

@available(iOS 26.0, *)
@Generable
struct FeaturedModes {
    @Guide(description: "The modes to feature today, best first", .maximumCount(6))
    var modes: [FeaturedMode]
}

@available(iOS 26.0, *)
@Generable
struct SongPicks {
    @Guide(description: "Numbers of the chosen songs from the list, best first", .maximumCount(60))
    var songs: [Int]
}
#endif

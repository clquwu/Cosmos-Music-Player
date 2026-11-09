import Foundation
import os
#if DEBUG
import QuartzCore
#endif

/// Signposts for the work that decides how fast and how frugal the app is:
/// launch, database startup, scans, Home, artwork, lyrics, track loads.
///
/// Read them in Instruments (os_signpost / Points of Interest, subsystem
/// "dev.clq.Cosmos-Music-Player", category "Perf"). They stay in release
/// builds on purpose: when Instruments is not recording, `OSSignposter`
/// checks one flag and returns, so leaving them in costs next to nothing,
/// and a performance question on a real device can then be answered
/// without a special build.
enum Perf {
    static let signposter = OSSignposter(subsystem: "dev.clq.Cosmos-Music-Player", category: "Perf")

    /// Runs `work` inside a signpost interval named `name`.
    @inline(__always)
    static func measure<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        let state = begin(name)
        defer { end(name, state) }
        return try work()
    }

    /// The async twin of `measure`.
    @inline(__always)
    static func measure<T>(_ name: StaticString, _ work: () async throws -> T) async rethrows -> T {
        let state = begin(name)
        defer { end(name, state) }
        return try await work()
    }

    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        #if DEBUG
        if logsToConsole {
            let start = DispatchTime.now().uptimeNanoseconds
            consoleStarts.withLock { $0[ObjectIdentifier(state)] = start }
        }
        #endif
        return state
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
        #if DEBUG
        if logsToConsole, let start = consoleStarts.withLock({ $0.removeValue(forKey: ObjectIdentifier(state)) }) {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            print(String(format: "⏱ %@: %.1f ms%@ @%.0f", "\(name)", ms, Thread.isMainThread ? " (main)" : "", sinceStartMs()))
        }
        #endif
    }

    static func event(_ name: StaticString) {
        signposter.emitEvent(name)
    }

    #if DEBUG
    /// `-cosmosPerfLog 1` (debug builds): every interval is also printed with
    /// its duration, and main-thread stalls are reported, so a measurement
    /// pass on a simulator or a device can be read from the console instead
    /// of an Instruments trace. Off unless asked for: printing per interval
    /// would itself cost time on the hot paths it measures.
    static let logsToConsole = UserDefaults.standard.bool(forKey: "cosmosPerfLog")

    /// Interval start times, keyed by the signpost state object (a class), so
    /// begin/end keep their signatures for every existing call site.
    private static let consoleStarts = OSAllocatedUnfairLock(initialState: [ObjectIdentifier: UInt64]())

    /// Milliseconds since the process started, from the kernel's record of
    /// it - so launch figures include the time before `main`.
    static func sinceStartMs() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return -1 }
        let start = info.kp_proc.p_un.__p_starttime
        let startSeconds = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        return (Date().timeIntervalSince1970 - startSeconds) * 1000
    }
    #endif

    // MARK: Launch

    /// Process start to the first Home render with the library in it. Begun
    /// by the app's init, ended once by HomeView.
    nonisolated(unsafe) private static var launchState: OSSignpostIntervalState?

    static func beginLaunch() {
        launchState = begin("Launch to Home")
        #if DEBUG
        if logsToConsole {
            print(String(format: "⏱ App init @%.0f", sinceStartMs()))
            DispatchQueue.main.async { MainThreadStallWatch.shared.start() }
        }
        #endif
    }

    /// Called from the main actor only (HomeView), so the plain static is safe.
    static func endLaunchIfNeeded() {
        guard let state = launchState else { return }
        launchState = nil
        end("Launch to Home", state)
    }
}

#if DEBUG
/// Reports every gap between display frames longer than two frames, which is
/// the main thread being busy for that long. Debug builds, `-cosmosPerfLog 1`.
@MainActor
final class MainThreadStallWatch: NSObject {
    static let shared = MainThreadStallWatch()
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        if last > 0 {
            let gap = (link.timestamp - last) * 1000
            if gap > 34 { print(String(format: "🐢 main thread stall %.0f ms @%.0f", gap, Perf.sinceStartMs())) }
        }
        last = link.timestamp
    }
}
#endif

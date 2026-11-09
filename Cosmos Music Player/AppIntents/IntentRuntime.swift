//
//  IntentRuntime.swift
//  Cosmos Music Player
//
//  Shared plumbing every App Intent goes through, so a request from Siri
//  either succeeds or fails with a sentence the person can act on - never
//  Siri's generic "Something went wrong".
//
//  Three things used to produce that generic failure:
//  - Raw GRDB / Foundation errors escaping perform(). The App Intents runtime
//    only speaks errors that conform to CustomLocalizedStringResourceConvertible;
//    anything else is reported as a generic failure.
//  - Writes while DatabaseSuspensionCoordinator has the database suspended.
//    An intent arriving while Cosmos sits in the background with playback
//    paused (the usual "like this song" / "add to playlist" situation) hit
//    "Database is suspended" (SQLITE_ABORT) on every write.
//  - Work with no time bound (on-device model calls, artwork, session
//    restoration) outliving Siri's response window.
//

import AppIntents
import Foundation
import UIKit

// MARK: - User-facing errors

@available(iOS 26.0, *)
enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    /// The library database could not be opened or read.
    case libraryUnavailable
    /// Anything unexpected; still spoken, never the generic Siri failure.
    case unexpected

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .libraryUnavailable:
            LocalizedStringResource(
                "Your Cosmos library isn't available right now. Open Cosmos and try again.",
                comment: "Spoken when an App Intent could not read or write the music library database."
            )
        case .unexpected:
            LocalizedStringResource(
                "Cosmos couldn't do that right now. Please try again.",
                comment: "Spoken when an App Intent failed for an unexpected reason."
            )
        }
    }
}

// MARK: - Runtime

@available(iOS 26.0, *)
@MainActor
enum IntentRuntime {

    // MARK: Lifecycle

    /// Number of intents currently between `begin` and `end`.
    private static var activeIntents = 0

    /// Call first in every perform(). Logs the entry point and keeps the
    /// database writable for the duration of the intent.
    ///
    /// DatabaseSuspensionCoordinator suspends GRDB whenever the app is in
    /// the background and playback is idle, to avoid the 0xdead10cc kill.
    /// The system holds a process assertion while an intent runs, so writes
    /// are safe here; `end` hands control back to the coordinator, which
    /// re-suspends from PlayerEngine's real state.
    static func begin(_ name: String) {
        SiriDiag.log("APP \(name) begin appState=\(applicationStateDescription)")
        activeIntents += 1
        DatabaseSuspensionCoordinator.shared.beginHold()
    }

    /// Call (via defer) at the end of every perform() that called `begin`.
    static func end(_ name: String) {
        activeIntents = max(0, activeIntents - 1)
        DatabaseSuspensionCoordinator.shared.endHold()
        SiriDiag.log("APP \(name) end")
    }

    /// Converts any error into one the App Intents runtime can speak, and
    /// records the original in the diagnostics log.
    static func userFacing(_ error: Error, in name: String) -> Error {
        SiriDiag.log("APP \(name) failed: \(String(reflecting: error))")

        // Already user-facing: AudioIntentError, ResumePlaybackError, ...
        if error is CustomLocalizedStringResourceConvertible {
            return error
        }
        if error is AppIntentError {
            return error
        }
        if error is CancellationError {
            return IntentFailure.unexpected
        }
        let typeName = String(reflecting: type(of: error))
        if typeName.contains("GRDB") || typeName.contains("Database") {
            return IntentFailure.libraryUnavailable
        }
        return IntentFailure.unexpected
    }

    // MARK: Time limits

    /// Runs `operation`, but stops waiting after `seconds` and returns nil.
    /// The operation is cancelled on timeout; work that ignores cancellation
    /// keeps running unobserved instead of holding the intent hostage.
    static func withDeadline<T>(
        _ seconds: Double,
        _ operation: @escaping @MainActor () async -> T
    ) async -> T? {
        let work = Task { @MainActor in DeadlineBox(await operation()) }
        let gate = DeadlineGate<T>()
        return await withCheckedContinuation { (continuation: CheckedContinuation<DeadlineBox<T?>, Never>) in
            gate.continuation = continuation
            Task { @MainActor in
                let box = await work.value
                gate.resume(with: box.value)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if gate.resume(with: nil) {
                    work.cancel()
                }
            }
        }.value
    }

    // MARK: Session

    /// Restores the saved session (bounded) when an intent cold-launched the
    /// app, so "this song" refers to the song the person was listening to.
    static func restoreSavedSessionIfNeeded(timeout: Double = 2) async {
        guard PlayerEngine.shared.currentTrack == nil else { return }
        let finished = await withDeadline(timeout) {
            await PlayerEngine.shared.ensureSavedStateRestored()
            return true
        }
        if finished == nil {
            SiriDiag.log("APP saved-session restore exceeded \(timeout)s")
        }
    }

    // MARK: Helpers

    private static var applicationStateDescription: String {
        switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }
}

/// Carries a main-actor value across the Task/continuation boundary; every
/// producer and consumer of it runs on the main actor.
private final class DeadlineBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Resumes a continuation exactly once, whichever side finishes first.
@MainActor
private final class DeadlineGate<T> {
    var continuation: CheckedContinuation<DeadlineBox<T?>, Never>?

    @discardableResult
    func resume(with value: T?) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(returning: DeadlineBox(value))
        return true
    }
}

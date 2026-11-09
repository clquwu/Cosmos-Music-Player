//
//  SelfTestsEnergy.swift
//  Cosmos Music Player
//
//  DEBUG-only `energy` suite: how much CPU the app itself uses, and how
//  often it wakes the processor, in the states people spend the most time
//  in - idle on Home with the halo moving or still, playing with Home on
//  screen, and playing with the full-screen player open. Measured from
//  inside the process (getrusage + task_power_info), so the render server's
//  share of drawing is not included; the halo's cost shows as the
//  difference between the moving and still runs.
//

#if DEBUG
import Foundation
import UIKit

extension SelfTests {

    /// CPU seconds used by every thread of this process so far.
    static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }

    /// Times this process has woken the processor so far.
    static func processWakeups() -> UInt64 {
        var info = task_power_info()
        var count = mach_msg_type_number_t(MemoryLayout<task_power_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return info.task_interrupt_wakeups + info.task_platform_idle_wakeups
    }

    /// Settles for a few seconds, then measures for `seconds`.
    @discardableResult
    static func measureEnergy(_ label: String, seconds: Double = 20) async -> (cpu: Double, wakeups: Double) {
        try? await Task.sleep(for: .seconds(4))
        let startCPU = processCPUSeconds()
        let startWakeups = processWakeups()
        let start = Date()
        try? await Task.sleep(for: .seconds(seconds))
        let elapsed = Date().timeIntervalSince(start)
        let cpu = (processCPUSeconds() - startCPU) / elapsed * 100
        let wakeups = Double(processWakeups() &- startWakeups) / elapsed
        info("energy.\(label)", String(format: "CPU %.1f%% of one core, %.0f wake-ups/s over %.0fs", cpu, wakeups, elapsed))
        return (cpu, wakeups)
    }

    static func energySuite() async {
        let router = AppRouter.shared
        let player = PlayerEngine.shared
        let defaults = UserDefaults.standard
        let savedMotion = defaults.object(forKey: HaloStyle.motionKey)
        defer {
            if let savedMotion { defaults.set(savedMotion, forKey: HaloStyle.motionKey) } else { defaults.removeObject(forKey: HaloStyle.motionKey) }
            router.isPlayerPresented = false
        }
        info("energy.context", "lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled) thermal=\(ProcessInfo.processInfo.thermalState.rawValue) halo=\(defaults.string(forKey: HaloStyle.storageKey) ?? "default") reduceMotion=\(UIAccessibility.isReduceMotionEnabled)")

        router.isPlayerPresented = false
        router.selectedTab = .home
        defaults.set(true, forKey: HaloStyle.motionKey)
        HaloActivity.shared.noteActivity()
        await measureEnergy("idle-home-halo-moving")
        // Left untouched, the halo holds still after HaloActivity.idleDelay.
        let wentIdle = await waitUntil(HaloActivity.idleDelay + 5) { HaloActivity.shared.isIdle }
        report("energy.halo-idles", wentIdle, "halo \(wentIdle ? "held still" : "still moving") \(Int(HaloActivity.idleDelay))s after the last activity")
        let idle = await measureEnergy("idle-home-untouched")
        report("energy.idle-untouched-cheap", idle.cpu < 2, String(format: "%.1f%% of one core on an untouched Home", idle.cpu))
        HaloActivity.shared.noteActivity()
        report("energy.halo-resumes", !HaloActivity.shared.isIdle, "a touch starts it moving again")
        defaults.set(false, forKey: HaloStyle.motionKey)
        await measureEnergy("idle-home-halo-still")
        defaults.set(true, forKey: HaloStyle.motionKey)

        // A song long enough for both playing runs.
        let tracks = await allTracks()
        guard let track = tracks.filter({ ($0.durationMs ?? 0) > 150_000 }).shuffled().first(where: isLocal) else {
            skip("energy.playing", "no song over two minutes stored on the device")
            return
        }
        await player.playTrack(track, queue: [track])
        HaloActivity.shared.noteActivity()
        guard await waitUntil(10, { player.isPlaying }) else {
            report("energy.playing", false, "'\(track.title)' did not start: \(player.playbackErrorMessage ?? "no error")")
            return
        }
        info("energy.track", "'\(track.title)' \(fileExtension(track)) sfb=\(player.isUsingSFBEngine)")
        await measureEnergy("playing-home")
        router.isPlayerPresented = true
        await measureEnergy("playing-player-open")
        defaults.set(false, forKey: HaloStyle.motionKey)
        await measureEnergy("playing-player-open-halo-still")
        router.isPlayerPresented = false
        await measureEnergy("playing-home-halo-still")
        defaults.set(true, forKey: HaloStyle.motionKey)
        timedStop("energy")
    }
}
#endif

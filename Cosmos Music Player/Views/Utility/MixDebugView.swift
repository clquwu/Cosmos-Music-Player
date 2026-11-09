#if DEBUG
import SwiftUI

/// Developer view of the mixes: how each was received, what the log holds,
/// and a replay of the engine against real listening - for tuning weights on
/// evidence. Debug builds only; reached from Settings.
struct MixDebugView: View {
    @ObservedObject private var store = MixStore.shared
    @ObservedObject private var log = ListeningLog.shared
    @State private var replay: String?
    @State private var isReplaying = false
    @State private var analysis: (analyzed: Int, heard: Int, total: Int)?
    @State private var isAnalyzing = false
    @State private var lastBatch: String?

    var body: some View {
        List {
            Section("Listening log") {
                LabeledContent("Listens", value: "\(log.events.count)")
                LabeledContent("With completion", value: "\(log.events.filter { $0.heard != nil }.count)")
                LabeledContent("Early skips", value: "\(log.events.filter(\.isSkip).count)")
                LabeledContent("From mixes", value: "\(log.events.filter { $0.source?.hasPrefix("mix:") == true }.count)")
                LabeledContent("From song mixes", value: "\(log.events.filter { $0.source?.hasPrefix("radio:") == true }.count)")
                if let builtAt = store.builtAt {
                    LabeledContent("Mixes built", value: builtAt.formatted(date: .abbreviated, time: .shortened))
                }
                if let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                    .appendingPathComponent("listening-log.json"),
                   FileManager.default.fileExists(atPath: url.path) {
                    ShareLink(item: url) { Label("Export listening log", systemImage: "square.and.arrow.up") }
                }
            }

            Section("Listening modes") {
                if let taste = store.taste {
                    Text(String(format: "%d sessions · k %d · silhouette %.2f · novelty %.0f%% · repeats %.0f%% · %d songs per sitting",
                                taste.sessions, taste.clusters, taste.silhouette, taste.noveltySeeking * 100,
                                taste.repeatTendency * 100, taste.typicalSessionLength))
                        .font(.caption.monospacedDigit())
                    if !taste.risingArtists.isEmpty { LabeledContent("Rising", value: taste.risingArtists.joined(separator: ", ")) }
                    if !taste.fadingArtists.isEmpty { LabeledContent("Fading", value: taste.fadingArtists.joined(separator: ", ")) }
                }
                if store.modes.isEmpty {
                    Text("No modes yet: too little history, or no clear split.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(store.modes) { mode in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(mode.id)\(mode.isActive ? "" : " (faded)")").font(.headline.monospaced())
                        Text(TasteWords.modeWhy(mode)).font(.caption)
                        Text(String(format: "%d sessions · %d recent · %.0f%% share · %d songs · energy %@ · part %@ · weekend %@ · route %@",
                                    mode.sessions, mode.recentSessions, mode.share * 100, mode.songs.count,
                                    mode.energyLabel ?? "-", mode.dayPart.map(String.init) ?? "-",
                                    mode.weekend.map { $0 ? "yes" : "no" } ?? "-", mode.route ?? "-"))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                if let analysis {
                    LabeledContent("Analysed", value: "\(analysis.analyzed) / \(analysis.total)")
                    LabeledContent("With a result", value: "\(analysis.heard)")
                }
                Button {
                    isAnalyzing = true
                    Task {
                        let clock = ContinuousClock()
                        let start = clock.now
                        let done = await AudioAnalysisScheduler.shared.runBatch(limit: AudioAnalysisScheduler.backgroundBatch, foreground: false)
                        lastBatch = "\(done) songs in \(clock.now - start)"
                        await refreshAnalysis()
                        isAnalyzing = false
                    }
                } label: {
                    if isAnalyzing { ProgressView() } else { Text("Analyse one batch now") }
                }
                .disabled(isAnalyzing)
                if let lastBatch {
                    Text(lastBatch).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            } header: {
                Text("Audio analysis")
            } footer: {
                Text("Loudness, brightness and tempo heard on the device, for songs whose tags say nothing. Runs while charging; per-song timings are in the console.")
            }

            Section("Made for You") {
                ForEach(store.madeForYou) { mix in row(mix) }
            }

            Section("Rediscover") {
                ForEach(store.moments) { mix in row(mix) }
            }

            Section("Song mixes") {
                statsRow(store.stats(forSource: "radio:"))
            }

            Section {
                Button {
                    isReplaying = true
                    Task {
                        replay = await store.replayEvaluation()
                        isReplaying = false
                    }
                } label: {
                    if isReplaying { ProgressView() } else { Text("Run replay test") }
                }
                .disabled(isReplaying)
                if let replay {
                    Text(replay)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
                Button("Rebuild mixes now", role: .destructive) {
                    store.invalidate()
                    NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRefresh"), object: nil)
                }
            } header: {
                Text("Replay")
            } footer: {
                Text("Builds mixes as of a past day and counts how many of their songs were played, not skipped, in the days after - beside random songs by the same artists.")
            }
        }
        .navigationTitle("Mix Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshAnalysis() }
    }

    private func refreshAnalysis() async {
        analysis = try? await Task.detached(priority: .utility) { try DatabaseManager.shared.analysisProgress() }.value
    }

    private func row(_ mix: Mix) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(mix.title).font(.headline)
            Text("\(mix.id) · \(mix.trackIds.count) songs · \(mix.subtitle)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let why = mix.why, why != mix.subtitle {
                Text(why).font(.caption2).foregroundStyle(.secondary)
            }
            statsRow(store.stats(forSource: "mix:\(mix.id)"))
        }
    }

    private func statsRow(_ stats: MixStore.Stats) -> some View {
        Text(stats.plays == 0
             ? "Not played yet"
             : String(format: "%d plays · %.0f%% early skips · %.0f%% finished", stats.plays, stats.earlySkipRate * 100, stats.completionRate * 100))
            .font(.caption.monospacedDigit())
            .foregroundStyle(stats.plays > 0 && stats.earlySkipRate > 0.4 ? Color.orange : Color.secondary)
    }
}
#endif

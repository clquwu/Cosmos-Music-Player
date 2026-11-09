import SwiftUI

// MARK: - Support

/// Donations to the project through PayPal or GitHub Sponsors: the rows in
/// Settings and a reminder shown at most once a month.
@MainActor
enum SupportCosmos {
    static let githubSponsorsURL = URL(string: "https://github.com/sponsors/clquwu")!
    /// PayPal first where there is one: GitHub Sponsors needs a GitHub
    /// account, which most listeners don't have. The PayPal buttons stay
    /// hidden while this is nil.
    static let paypalURL: URL? = URL(string: "https://www.paypal.com/donate/?hosted_button_id=F69BB4AWCC2VC")

    /// The listener's switch in Settings; "Don't Ask Again" turns it off.
    static let reminderEnabledKey = "cosmos.support.reminderEnabled"
    /// Set by "I've Donated" - on trust: nothing ties it to a payment, and
    /// nothing is unlocked by it. It thanks the listener and stops the
    /// reminder. On this device only.
    static let supporterKey = "cosmos.support.isSupporter"
    private static let firstUseKey = "cosmos.support.firstUse"
    private static let lastPromptKey = "cosmos.support.lastPrompt"
    private static let interval: TimeInterval = 30 * 24 * 60 * 60

    /// Off only once the listener says so; on by default.
    static var isReminderEnabled: Bool {
        UserDefaults.standard.object(forKey: reminderEnabledKey) as? Bool ?? true
    }

    static var isSupporter: Bool {
        UserDefaults.standard.bool(forKey: supporterKey)
    }

    /// True once a month has passed since the last reminder - or, before the
    /// first one, since the app was first used, so a new listener (or one who
    /// just updated) gets a month with the app before being asked.
    static func isReminderDue(now: Date = Date()) -> Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "cosmosDebugSupportPrompt") { return true }
        #endif
        guard isReminderEnabled, !isSupporter else { return false }
        let defaults = UserDefaults.standard
        guard let firstUse = defaults.object(forKey: firstUseKey) as? Date else {
            defaults.set(now, forKey: firstUseKey)
            return false
        }
        let since = defaults.object(forKey: lastPromptKey) as? Date ?? firstUse
        return now.timeIntervalSince(since) >= interval
    }

    /// Starts the next month: called when the reminder is shown, and when the
    /// listener opens a donation page from Settings.
    static func markPrompted(now: Date = Date()) {
        UserDefaults.standard.set(now, forKey: lastPromptKey)
    }

    static func disableReminder() {
        UserDefaults.standard.set(false, forKey: reminderEnabledKey)
    }
}

// MARK: - Monthly reminder

struct SupportPromptView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    /// The content's own height: the sheet is sized to it, so neither a
    /// half-height detent nor the iPad sheet leaves an empty band above it.
    @State private var contentHeight: CGFloat = 420

    var body: some View {
        VStack(spacing: Design.Spacing.l) {
            Image(systemName: "heart.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.pink)
                .frame(width: 72, height: 72)
                .background(Color.pink.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
                .padding(.top, Design.Spacing.xl)

            VStack(spacing: Design.Spacing.s) {
                Text(Localized.supportCosmos)
                    .font(.title2.weight(.bold))
                Text(Localized.supportPromptMessage)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            askButtons
        }
        .padding(.horizontal, Design.Spacing.xl)
        .padding(.bottom, Design.Spacing.l)
        .frame(maxWidth: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        .frame(maxHeight: .infinity, alignment: .top)
        // Sheets don't inherit the root's accent colour.
        .tint(ThemeStore.shared.accent)
        .presentationDetents([.height(contentHeight)])
        .presentationDragIndicator(.visible)
        // Opaque: a short sheet is glass by default, and the Home grid
        // showing through made the text hard to read.
        .presentationBackground(SurfaceColor.card)
    }

    private var askButtons: some View {
        VStack(spacing: Design.Spacing.m) {
            if let paypal = SupportCosmos.paypalURL {
                donateButton(Localized.supportPayPal, systemImage: "heart", url: paypal)
                    .buttonStyle(.borderedProminent)
                donateButton(Localized.supportGitHub, systemImage: "chevron.left.forwardslash.chevron.right", url: SupportCosmos.githubSponsorsURL)
                    .buttonStyle(.bordered)
            } else {
                donateButton(Localized.supportGitHub, systemImage: "heart", url: SupportCosmos.githubSponsorsURL)
                    .buttonStyle(.borderedProminent)
            }

            // "I've Donated" lives in Settings, not here.
            HStack(spacing: Design.Spacing.xl) {
                Button(Localized.supportNotNow) {
                    dismiss()
                }
                .fontWeight(.semibold)
                Button(Localized.supportDontAskAgain) {
                    SupportCosmos.disableReminder()
                    dismiss()
                }
            }
            .font(.subheadline)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .frame(minHeight: Design.Size.minTouch)
        }
    }

    private func donateButton(_ title: String, systemImage: String, url: URL) -> some View {
        Button {
            openURL(url)
            dismiss()
        } label: {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: Design.Size.actionButtonHeight)
        }
    }
}

/// Shows the monthly reminder a few seconds after the app becomes active,
/// only when nothing else is on screen: not over the tutorial, Settings, the
/// player or any other sheet.
struct SupportPromptModifier: ViewModifier {
    let isReady: Bool
    @State private var isPresented = false
    @State private var check: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onChange(of: isReady) { _, ready in
                if ready { scheduleCheck() }
            }
            .onAppear {
                if isReady { scheduleCheck() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                if isReady { scheduleCheck() }
            }
            .sheet(isPresented: $isPresented) {
                SupportPromptView()
            }
    }

    private func scheduleCheck() {
        check?.cancel()
        check = Task { @MainActor in
            // Let launch, restore and the first screen settle first.
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled,
                  UIApplication.shared.applicationState == .active,
                  !isPresented, !Self.isPresentingAnything,
                  SupportCosmos.isReminderDue() else { return }
            SupportCosmos.markPrompted()
            isPresented = true
        }
    }

    /// Any sheet or full-screen cover, from anywhere in the app: SwiftUI
    /// can't present a second sheet from the root over one, and a reminder
    /// that silently failed would still count as this month's.
    private static var isPresentingAnything: Bool {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
        return windows.contains { $0.isKeyWindow && $0.rootViewController?.presentedViewController != nil }
            || !windows.contains(where: \.isKeyWindow)
    }
}

// MARK: - Thank-you

/// Hearts rising from where "I've Donated" was tapped: shown once, when the
/// listener says they donated.
struct HeartBurstView: View {
    private struct Heart: Identifiable {
        let id = UUID()
        let drift = CGFloat.random(in: -150...150)
        let rise = CGFloat.random(in: 220...460)
        let size = CGFloat.random(in: 14...30)
        let spin = Double.random(in: -30...30)
        let delay = Double.random(in: 0...0.3)
    }

    private let hearts = (0..<16).map { _ in Heart() }
    @State private var launched = false

    var body: some View {
        ZStack {
            ForEach(hearts) { heart in
                Image(systemName: "heart.fill")
                    .font(.system(size: heart.size))
                    .foregroundStyle(.pink.gradient)
                    .scaleEffect(launched ? 1 : 0.3)
                    .rotationEffect(.degrees(launched ? heart.spin : 0))
                    .offset(x: launched ? heart.drift : 0, y: launched ? -heart.rise : 0)
                    .animation(.easeOut(duration: 1.5).delay(heart.delay), value: launched)
                    // Fades only in the second half, so the burst is seen.
                    .opacity(launched ? 0 : 1)
                    .animation(.easeIn(duration: 0.6).delay(heart.delay + 0.9), value: launched)
            }
        }
        .onAppear { launched = true }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

import SwiftUI

/// Settings section for the automatic refresh. Backs `Lookout.refreshMinutes` (whole minutes,
/// 1 to 360); `onChanged` tells the poll loop, which moves the next check without making one.
///
/// The field and the stepper apply differently, on purpose. The stepper applies each click: every
/// click is a finished value. The field keeps its own `draft` and applies it only on Return or when
/// it loses focus, because it reports every keystroke and a number typed digit by digit passes
/// through values nobody chose. In 1.3.0 typing 166 applied "1" first, and that started a check.
struct LookoutRefreshSettings: View {
    @State private var minutes = LookoutRefresh.storedMinutes
    @State private var draft = LookoutRefresh.storedMinutes
    @FocusState private var fieldFocused: Bool
    var onChanged: (() -> Void)?

    var body: some View {
        Section("Refresh") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Check GitHub every")
                    Spacer()
                    TextField("", value: $draft, format: .number)
                        .labelsHidden()
                        .frame(width: 54)
                        .multilineTextAlignment(.trailing)
                        .focused($fieldFocused)
                        .onSubmit { commitDraft() }
                    Stepper("", value: $minutes, in: LookoutRefresh.minutes)
                        .labelsHidden()
                    Text(minutes == 1 ? "minute" : "minutes")
                        .foregroundStyle(.secondary)
                }
                .onChange(of: fieldFocused) { _, focused in
                    if !focused { commitDraft() }
                }
                .onChange(of: minutes) { _, newValue in
                    draft = newValue
                    apply(newValue)
                }
                // Closing the window is also leaving the field, and neither of the two signals above
                // reports it. Clicking Done does not take focus from a text field on macOS, and
                // JorvikKit keeps the Settings window for reuse (`isReleasedWhenClosed = false`), so
                // the view never disappears. In grace-2, typing 5 and clicking Done left the old
                // value in force. Any window closing commits: committing an unchanged draft is a
                // no-op, so a popover or another window closing does nothing.
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
                    commitDraft()
                }
                Text("From 1 to 360 minutes. A longer wait keeps Lookout clear of GitHub\u{2019}s rate limits. The Refresh button checks at once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Clamps the typed number into range and applies it. Out-of-range input snaps to the nearest
    /// end, so 0 becomes 1 and 999 becomes 360.
    private func commitDraft() {
        let range = LookoutRefresh.minutes
        let clamped = min(range.upperBound, max(range.lowerBound, draft))
        draft = clamped
        minutes = clamped
        // Applied here, not left to the onChange above: this runs as the window closes, and SwiftUI
        // need not deliver onChange to a view whose window has gone. The onChange then finds the
        // value already stored and does nothing.
        apply(clamped)
    }

    /// Stores the interval and tells the poll loop. Does nothing if the value is already stored.
    private func apply(_ value: Int) {
        guard value != LookoutRefresh.storedMinutes else { return }
        UserDefaults.standard.set(value, forKey: LookoutRefresh.defaultsKey)
        onChanged?()
    }
}

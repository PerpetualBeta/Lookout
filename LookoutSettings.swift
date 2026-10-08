import SwiftUI

/// Settings section for the automatic refresh. Backs `Lookout.refreshMinutes` (whole minutes,
/// 1 to 360); `onChanged` tells the poll loop, which moves the next check without making one.
struct LookoutRefreshSettings: View {
    @State private var minutes = LookoutRefresh.storedMinutes
    var onChanged: (() -> Void)?

    var body: some View {
        Section("Refresh") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Check GitHub every")
                    Spacer()
                    TextField("", value: $minutes, format: .number)
                        .labelsHidden()
                        .frame(width: 54)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: $minutes, in: LookoutRefresh.minutes)
                        .labelsHidden()
                    Text(minutes == 1 ? "minute" : "minutes")
                        .foregroundStyle(.secondary)
                }
                .onChange(of: minutes) { _, newValue in
                    // TextField can produce out-of-range values; the Stepper can't.
                    let range = LookoutRefresh.minutes
                    let clamped = min(range.upperBound, max(range.lowerBound, newValue))
                    if clamped != newValue { minutes = clamped; return }  // re-fires with clamped
                    UserDefaults.standard.set(clamped, forKey: LookoutRefresh.defaultsKey)
                    onChanged?()
                }
                Text("From 1 to 360 minutes. A longer wait keeps Lookout clear of GitHub\u{2019}s rate limits. The Refresh button checks at once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

import SwiftUI
import AppKit

struct LookoutSetupSheet: View {
    let onSaved: (String) -> Void
    let onCancel: () -> Void

    @State private var token: String = ""
    @State private var isValidating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GitHub Personal Access Token")
                .font(.headline)

            Text("Paste a fine-grained PAT. It's stored in your Keychain and never sent anywhere except api.github.com.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("ghp_… or github_pat_…", text: $token)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 4) {
                Text("Required scopes:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("• notifications  • repo (or public_repo)  • read:user")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Link("Create one →", destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
                    .font(.caption)
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { validateAndSave() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isValidating)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func validateAndSave() {
        let trimmed = token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { $0.isASCII && !$0.isWhitespace }
        guard !trimmed.isEmpty else { return }
        isValidating = true
        errorMessage = nil

        Task {
            do {
                try await pingUser(token: trimmed)
                _ = LookoutKeychain.saveToken(trimmed)
                await MainActor.run {
                    isValidating = false
                    onSaved(trimmed)
                }
            } catch {
                await MainActor.run {
                    isValidating = false
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    private func pingUser(token: String) async throws {
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Lookout/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LookoutGitHubError.decode("no HTTP response")
        }
        if (200..<300).contains(http.statusCode) { return }

        // Surface GitHub's actual error message so we know whether the token
        // is bad, SSO-blocked, IP-allowlisted, missing scopes, etc.
        var detail = "HTTP \(http.statusCode)"
        if let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let msg = body["message"] as? String { detail += " — \(msg)" }
            if let errors = body["errors"] as? [[String: Any]],
               let first = errors.first?["message"] as? String { detail += " (\(first))" }
        }
        if let sso = http.value(forHTTPHeaderField: "X-GitHub-SSO") {
            detail += " [SSO: \(sso)]"
        }
        throw LookoutGitHubError.decode(detail)
    }
}

enum LookoutSetupWindow {
    private static var existing: NSWindow?

    static func show(onSaved: @escaping (String) -> Void) {
        if let existing {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = LookoutSetupSheet(
            onSaved: { token in
                close()
                onSaved(token)
            },
            onCancel: { close() }
        )

        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        let size = controller.view.fittingSize

        let window = NSWindow(contentViewController: controller)
        window.title = "Lookout — GitHub Token"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: max(460, size.width), height: max(240, size.height)))
        JorvikWindowHelper.centreOnActiveDisplay(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        existing = window
    }

    static func close() {
        existing?.close()
        existing = nil
    }
}

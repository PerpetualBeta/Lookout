import SwiftUI
import AppKit

struct LookoutPanel: View {
    @Bindable var core: LookoutCore
    let onSetup: () -> Void
    let onQuit: () -> Void
    let onAbout: () -> Void
    let onSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 380)
        .frame(minHeight: 220, maxHeight: 520)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "binoculars.fill")
                .foregroundStyle(.secondary)
            Text("Lookout")
                .font(.headline)
            Spacer()
            switch core.state {
            case .polling:
                ProgressView().controlSize(.small)
            case .ok(_, let when):
                Text(relative(when))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            default:
                EmptyView()
            }
            Button(action: { core.refreshNow() }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch core.state {
        case .unconfigured:
            unconfiguredView
        case .error(let msg):
            errorView(msg)
        case .idle, .polling, .ok:
            if core.items.isEmpty {
                emptyView
            } else {
                itemsList
            }
        }
    }

    private var unconfiguredView: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            Image(systemName: "key.fill")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Add your GitHub token to start")
                .font(.headline)
            Text("Paste a fine-grained PAT with notifications, repo, and read:user scopes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Set up GitHub Token…") { onSetup() }
                .buttonStyle(.borderedProminent)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text(msg)
                .font(.callout)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            HStack {
                Button("Retry") { core.refreshNow() }
                Button("Re-enter Token…") { onSetup() }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 32))
                .foregroundStyle(.green)
            Text("All clear")
                .font(.headline)
            Text("Nothing on GitHub needs your attention right now.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private var itemsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groupedByRepo, id: \.repo) { group in
                    Section {
                        ForEach(group.items) { item in
                            ItemRow(item: item)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    NSWorkspace.shared.open(item.url)
                                }
                        }
                    } header: {
                        repoHeader(group.repo)
                    }
                }
            }
        }
    }

    private func repoHeader(_ repo: String) -> some View {
        HStack {
            Text(repo)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(.ultraThinMaterial)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button("Mark all read") { core.markAllRead() }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(core.items.isEmpty)
            Spacer()
            Menu {
                Button("About Lookout") { onAbout() }
                Divider()
                Button("Re-enter Token…") { onSetup() }
                Divider()
                Button("Settings…") { onSettings() }
                Divider()
                Button("Quit Lookout") { onQuit() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private struct RepoGroup { let repo: String; let items: [LookoutItem] }

    private var groupedByRepo: [RepoGroup] {
        let grouped = Dictionary(grouping: core.items, by: \.repo)
        return grouped
            .map { RepoGroup(repo: $0.key, items: $0.value.sorted { $0.updatedAt > $1.updatedAt }) }
            .sorted { $0.repo.lowercased() < $1.repo.lowercased() }
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct ItemRow: View {
    let item: LookoutItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.kind.symbolName)
                .frame(width: 18)
                .foregroundStyle(colour)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.callout)
                    .lineLimit(2)
                Text(relative(item.updatedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var colour: Color {
        switch item.kind {
        case .ciFailure: .red
        case .reviewRequested: .blue
        case .mention: .purple
        case .assigned: .orange
        default: .secondary
        }
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

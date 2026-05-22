import SwiftUI

struct EmptyWorkspaceView: View {
    let recentFolders: [RecentFolder]
    let openFolder: () -> Void
    let openRecentFolder: (RecentFolder) -> Void

    var body: some View {
        VStack(spacing: 24) {
            ContentUnavailableView {
                Label("No Folder Open", systemImage: "folder")
            } description: {
                Text("Choose a folder to browse its immediate contents.")
            } actions: {
                Button(action: openFolder) {
                    Label("Open Folder", systemImage: "folder")
                }
            }

            if !recentFolders.isEmpty {
                RecentFoldersView(folders: recentFolders, open: openRecentFolder)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RecentFoldersView: View {
    let folders: [RecentFolder]
    let open: (RecentFolder) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent Folders")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(folders) { folder in
                    Button {
                        open(folder)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "folder")
                                .foregroundStyle(.blue)
                                .frame(width: 18)
                                .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(folder.displayName)
                                    .lineLimit(1)

                                Text(folder.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer()
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(folder.displayName)")
                }
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }
}

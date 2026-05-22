import SwiftUI

protocol FolderShortcut: Identifiable {
    var displayName: String { get }
    var path: String { get }
}

extension FavoriteFolder: FolderShortcut {}
extension RecentFolder: FolderShortcut {}

struct EmptyWorkspaceView: View {
    let favoriteFolders: [FavoriteFolder]
    let recentFolders: [RecentFolder]
    let openFolder: () -> Void
    let openFavoriteFolder: (FavoriteFolder) -> Void
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

            if !favoriteFolders.isEmpty {
                FolderShortcutListView(
                    title: "Favorite Folders",
                    rowAccessibilityIdentifier: "favorite-folder-row",
                    folders: favoriteFolders,
                    open: openFavoriteFolder
                )
            }

            if !recentFolders.isEmpty {
                FolderShortcutListView(
                    title: "Recent Folders",
                    rowAccessibilityIdentifier: "recent-folder-row",
                    folders: recentFolders,
                    open: openRecentFolder
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FolderShortcutListView<Folder: FolderShortcut>: View {
    let title: String
    let rowAccessibilityIdentifier: String
    let folders: [Folder]
    let open: (Folder) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
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
                    .accessibilityIdentifier(rowAccessibilityIdentifier)
                }
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }
}

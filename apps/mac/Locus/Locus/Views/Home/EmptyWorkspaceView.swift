import SwiftUI

protocol FileLocationShortcut: Identifiable {
    var url: URL { get }
    var displayName: String { get }
    var path: String { get }
}

extension FavoriteFolder: FileLocationShortcut {}
extension RecentFile: FileLocationShortcut {}
extension RecentFolder: FileLocationShortcut {}

struct EmptyWorkspaceView: View {
    let favoriteFolders: [FavoriteFolder]
    let recentFiles: [RecentFile]
    let recentFolders: [RecentFolder]
    let actions: EmptyWorkspaceActions

    var body: some View {
        VStack(spacing: 24) {
            ContentUnavailableView {
                Label("No Folder Open", systemImage: "folder")
            } description: {
                Text("Choose a folder to browse its immediate contents.")
            } actions: {
                Button(action: actions.openFolder) {
                    Label("Open Folder", systemImage: "folder")
                }
            }

            if !favoriteFolders.isEmpty {
                FolderShortcutListView(
                    title: "Favorite Folders",
                    rowAccessibilityIdentifier: "favorite-folder-row",
                    folders: favoriteFolders,
                    open: actions.openFavoriteFolder,
                    remove: actions.removeFavoriteFolder,
                    copyPath: actions.copyPath
                )
            }

            if !recentFiles.isEmpty {
                FileShortcutListView(
                    title: "Recent Files",
                    rowAccessibilityIdentifier: "recent-file-row",
                    files: recentFiles,
                    open: actions.openRecentFile,
                    remove: actions.removeRecentFile,
                    copyPath: actions.copyPath
                )
            }

            if !recentFolders.isEmpty {
                FolderShortcutListView(
                    title: "Recent Folders",
                    rowAccessibilityIdentifier: "recent-folder-row",
                    folders: recentFolders,
                    open: actions.openRecentFolder,
                    remove: actions.removeRecentFolder,
                    copyPath: actions.copyPath
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyWorkspaceActions {
    let openFolder: () -> Void
    let openFavoriteFolder: (FavoriteFolder) -> Void
    let openRecentFile: (RecentFile) -> Void
    let openRecentFolder: (RecentFolder) -> Void
    let removeFavoriteFolder: (FavoriteFolder) -> Void
    let removeRecentFile: (RecentFile) -> Void
    let removeRecentFolder: (RecentFolder) -> Void
    let copyPath: (URL) -> Void
}

private struct FileShortcutListView<File: FileLocationShortcut>: View {
    let title: String
    let rowAccessibilityIdentifier: String
    let files: [File]
    let open: (File) -> Void
    let remove: (File) -> Void
    let copyPath: (URL) -> Void

    var body: some View {
        ShortcutListView(
            title: title,
            rowAccessibilityIdentifier: rowAccessibilityIdentifier,
            items: files,
            systemImage: "doc",
            symbolColor: .secondary,
            open: open,
            remove: remove,
            copyPath: copyPath
        )
    }
}

private struct FolderShortcutListView<Folder: FileLocationShortcut>: View {
    let title: String
    let rowAccessibilityIdentifier: String
    let folders: [Folder]
    let open: (Folder) -> Void
    let remove: (Folder) -> Void
    let copyPath: (URL) -> Void

    var body: some View {
        ShortcutListView(
            title: title,
            rowAccessibilityIdentifier: rowAccessibilityIdentifier,
            items: folders,
            systemImage: "folder",
            symbolColor: .blue,
            open: open,
            remove: remove,
            copyPath: copyPath
        )
    }
}

private struct ShortcutListView<Item: FileLocationShortcut>: View {
    let title: String
    let rowAccessibilityIdentifier: String
    let items: [Item]
    let systemImage: String
    let symbolColor: Color
    let open: (Item) -> Void
    let remove: (Item) -> Void
    let copyPath: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(items) { item in
                    Button {
                        open(item)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: systemImage)
                                .foregroundStyle(symbolColor)
                                .frame(width: 18)
                                .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.displayName)
                                    .lineLimit(1)

                                Text(item.path)
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
                    .contextMenu {
                        Button("Open") {
                            open(item)
                        }

                        Button("Copy Path") {
                            copyPath(item.url)
                        }

                        Button("Remove") {
                            remove(item)
                        }
                    }
                    .accessibilityLabel("Open \(item.displayName)")
                    .accessibilityIdentifier(rowAccessibilityIdentifier)
                }
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }
}

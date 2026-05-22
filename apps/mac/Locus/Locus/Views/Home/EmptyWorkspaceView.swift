import SwiftUI

extension FavoriteFolder: FileLocationShortcut {}
extension RecentFile: FileLocationShortcut {}
extension RecentFolder: FileLocationShortcut {}

struct EmptyWorkspaceView: View {
    let favoriteFolders: [FavoriteFolder]
    let recentFiles: [RecentFile]
    let recentFolders: [RecentFolder]
    let actions: EmptyWorkspaceActions
    @State private var searchQuery = ""

    var body: some View {
        let filteredFavoriteFolders = WorkspaceEntrySearch.filteredShortcuts(favoriteFolders, query: searchQuery)
        let filteredRecentFiles = WorkspaceEntrySearch.filteredShortcuts(recentFiles, query: searchQuery)
        let filteredRecentFolders = WorkspaceEntrySearch.filteredShortcuts(recentFolders, query: searchQuery)
        let hasAnyShortcuts = !favoriteFolders.isEmpty || !recentFiles.isEmpty || !recentFolders.isEmpty
        let hasActiveSearch = WorkspaceEntrySearch.hasSearchTerms(in: searchQuery)
        let hasNoSearchResults = hasActiveSearch
            && filteredFavoriteFolders.isEmpty
            && filteredRecentFiles.isEmpty
            && filteredRecentFolders.isEmpty

        ScrollView {
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

                if hasAnyShortcuts {
                    TextField("Search favorites and recent items", text: $searchQuery)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 520)
                        .accessibilityLabel("Search favorites and recent items")
                        .accessibilityIdentifier("home-shortcut-search-field")
                }

                if !filteredFavoriteFolders.isEmpty {
                    FolderShortcutListView(
                        title: "Favorite Folders",
                        rowAccessibilityIdentifier: "favorite-folder-row",
                        folders: filteredFavoriteFolders,
                        open: actions.openFavoriteFolder,
                        remove: actions.removeFavoriteFolder,
                        copyPath: actions.copyPath
                    )
                }

                if !filteredRecentFiles.isEmpty {
                    FileShortcutListView(
                        title: "Recent Files",
                        rowAccessibilityIdentifier: "recent-file-row",
                        files: filteredRecentFiles,
                        open: actions.openRecentFile,
                        remove: actions.removeRecentFile,
                        copyPath: actions.copyPath
                    )
                }

                if !filteredRecentFolders.isEmpty {
                    FolderShortcutListView(
                        title: "Recent Folders",
                        rowAccessibilityIdentifier: "recent-folder-row",
                        folders: filteredRecentFolders,
                        open: actions.openRecentFolder,
                        remove: actions.removeRecentFolder,
                        copyPath: actions.copyPath
                    )
                }

                if hasAnyShortcuts, hasNoSearchResults {
                    ContentUnavailableView(
                        "No Matching Items",
                        systemImage: "magnifyingglass",
                        description: Text(verbatim: "No favorites or recent items match \"\(searchQuery)\".")
                    )
                    .frame(maxWidth: 520)
                    .accessibilityIdentifier("home-shortcut-search-empty-state")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: hasAnyShortcuts) { _, hasAnyShortcuts in
            if !hasAnyShortcuts {
                searchQuery = ""
            }
        }
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

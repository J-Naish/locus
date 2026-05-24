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
    let filteredFavoriteFolders = WorkspaceEntrySearch.filteredShortcuts(
      favoriteFolders, query: searchQuery)
    let filteredRecentFiles = WorkspaceEntrySearch.filteredShortcuts(
      recentFiles, query: searchQuery)
    let filteredRecentFolders = WorkspaceEntrySearch.filteredShortcuts(
      recentFolders, query: searchQuery)
    let hasAnyShortcuts = !favoriteFolders.isEmpty || !recentFiles.isEmpty || !recentFolders.isEmpty
    let hasActiveSearch = WorkspaceEntrySearch.hasSearchTerms(in: searchQuery)
    let hasNoSearchResults =
      hasActiveSearch
      && filteredFavoriteFolders.isEmpty
      && filteredRecentFiles.isEmpty
      && filteredRecentFolders.isEmpty

    ScrollView {
      VStack(spacing: 24) {
        ContentUnavailableView {
          Label("Home Folder Unavailable", systemImage: "folder")
        } description: {
          Text("Choose another folder to browse in Locus.")
        } actions: {
          Button(action: actions.openFolder) {
            Label("Choose Folder", systemImage: "folder")
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
            open: actions.shortcuts.openFavoriteFolder,
            remove: actions.shortcuts.removeFavoriteFolder,
            showInLocus: actions.shortcuts.showInLocus,
            copyPath: actions.shortcuts.copyPath
          )
        }

        if !filteredRecentFiles.isEmpty {
          FileShortcutListView(
            title: "Recent Files",
            rowAccessibilityIdentifier: "recent-file-row",
            files: filteredRecentFiles,
            open: actions.shortcuts.showRecentFile,
            remove: actions.shortcuts.removeRecentFile,
            preview: actions.shortcuts.previewFile,
            showInLocus: actions.shortcuts.showInLocus,
            copyPath: actions.shortcuts.copyPath
          )
        }

        if !filteredRecentFolders.isEmpty {
          FolderShortcutListView(
            title: "Recent Folders",
            rowAccessibilityIdentifier: "recent-folder-row",
            folders: filteredRecentFolders,
            open: actions.shortcuts.openRecentFolder,
            remove: actions.shortcuts.removeRecentFolder,
            showInLocus: actions.shortcuts.showInLocus,
            copyPath: actions.shortcuts.copyPath
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
  let shortcuts: FileLocationShortcutActions
}

struct FileLocationShortcutActions {
  let openFavoriteFolder: (FavoriteFolder) -> Void
  let showRecentFile: (RecentFile) -> Void
  let openRecentFolder: (RecentFolder) -> Void
  let removeFavoriteFolder: (FavoriteFolder) -> Void
  let removeRecentFile: (RecentFile) -> Void
  let removeRecentFolder: (RecentFolder) -> Void
  let previewFile: (URL) -> Void
  let showInLocus: (URL) -> Void
  let copyPath: (URL) -> Void
}

private struct FileShortcutListView<File: FileLocationShortcut>: View {
  let title: String
  let rowAccessibilityIdentifier: String
  let files: [File]
  let open: (File) -> Void
  let remove: (File) -> Void
  let preview: (URL) -> Void
  let showInLocus: (URL) -> Void
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
      preview: preview,
      showInLocus: showInLocus,
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
  let showInLocus: (URL) -> Void
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
      showInLocus: showInLocus,
      copyPath: copyPath
    )
  }
}

struct ShortcutListView<Item: FileLocationShortcut>: View {
  let title: String
  let rowAccessibilityIdentifier: String
  let items: [Item]
  let systemImage: String
  let symbolColor: Color
  var maxWidth: CGFloat? = 520
  let open: (Item) -> Void
  let remove: (Item) -> Void
  // Shortcut preview is file-only for now; folders keep navigation and path actions.
  var preview: ((URL) -> Void)? = nil
  let showInLocus: (URL) -> Void
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

            if let preview {
              Button("Preview") {
                preview(item.url)
              }
            }

            Button("Show in Locus") {
              showInLocus(item.url)
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
    .frame(maxWidth: maxWidth, alignment: .leading)
  }
}

import SwiftUI

extension RecentFile: FileLocationShortcut {}
extension RecentFolder: FileLocationShortcut {}

struct EmptyWorkspaceView: View {
  let recentFiles: [RecentFile]
  let recentFolders: [RecentFolder]
  let actions: EmptyWorkspaceActions

  var body: some View {
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

        if !recentFiles.isEmpty {
          FileShortcutListView(
            title: "Recent Files",
            rowAccessibilityIdentifier: "recent-file-row",
            files: recentFiles,
            open: actions.shortcuts.showRecentFile,
            remove: actions.shortcuts.removeRecentFile,
            preview: actions.shortcuts.previewFile,
            showInLocus: actions.shortcuts.showInLocus,
            copyPath: actions.shortcuts.copyPath
          )
        }

        if !recentFolders.isEmpty {
          FolderShortcutListView(
            title: "Recent Folders",
            rowAccessibilityIdentifier: "recent-folder-row",
            folders: recentFolders,
            open: actions.shortcuts.openRecentFolder,
            remove: actions.shortcuts.removeRecentFolder,
            showInLocus: actions.shortcuts.showInLocus,
            copyPath: actions.shortcuts.copyPath
          )
        }
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 4)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct EmptyWorkspaceActions {
  let openFolder: () -> Void
  let shortcuts: FileLocationShortcutActions
}

struct FileLocationShortcutActions {
  let showRecentFile: (RecentFile) -> Void
  let openRecentFolder: (RecentFolder) -> Void
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

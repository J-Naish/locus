import SwiftUI

struct WorkspaceDocumentTab: Identifiable, Equatable {
  let entry: WorkspaceEntry

  var id: WorkspaceEntry.ID {
    entry.id
  }

  var url: URL {
    entry.url
  }

  var name: String {
    entry.name
  }

  var symbolName: String {
    entry.symbolName
  }

  var symbolColor: Color {
    entry.symbolColor
  }

  init?(entry: WorkspaceEntry) {
    guard WorkspaceDocumentSurfaceSupport.surfaceKind(for: entry).supportsInPlaceOpen else {
      return nil
    }

    self.entry = entry
  }
}

struct WorkspaceDocumentTabsHeader: View {
  let tabs: [WorkspaceDocumentTab]
  let selectedTabID: WorkspaceEntry.ID?
  let select: (WorkspaceDocumentTab) -> Void
  let close: (WorkspaceDocumentTab) -> Void

  var body: some View {
    VStack(spacing: 0) {
      ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 0) {
            ForEach(tabs) { tab in
              WorkspaceDocumentTabItem(
                tab: tab,
                isSelected: tab.id == selectedTabID,
                select: select,
                close: close
              )
              .id(tab.id)
            }
          }
          .frame(height: WorkspaceDocumentTabMetrics.height)
        }
        .onAppear {
          scrollSelectedTab(proxy)
        }
        .onChange(of: selectedTabID) {
          scrollSelectedTab(proxy)
        }
      }

      Divider()
    }
    .background(.bar)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("document-tab-bar")
    .accessibilityHidden(tabs.isEmpty)
  }

  private func scrollSelectedTab(_ proxy: ScrollViewProxy) {
    guard let selectedTabID else {
      return
    }

    withAnimation(.easeInOut(duration: 0.15)) {
      proxy.scrollTo(selectedTabID, anchor: .center)
    }
  }
}

private struct WorkspaceDocumentTabItem: View {
  let tab: WorkspaceDocumentTab
  let isSelected: Bool
  let select: (WorkspaceDocumentTab) -> Void
  let close: (WorkspaceDocumentTab) -> Void
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 8) {
      Button {
        select(tab)
      } label: {
        HStack(spacing: 8) {
          Image(systemName: tab.symbolName)
            .foregroundStyle(tab.symbolColor)
            .accessibilityHidden(true)

          Text(tab.name)
            .lineLimit(1)
            .truncationMode(.middle)

          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(Text(verbatim: tab.name))
      .accessibilityIdentifier("document-tab-item")

      Button {
        close(tab)
      } label: {
        Image(systemName: "xmark")
          .font(.caption2)
          .frame(
            width: WorkspaceDocumentTabMetrics.closeButtonSize,
            height: WorkspaceDocumentTabMetrics.closeButtonSize
          )
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .accessibilityLabel(Text(verbatim: "Close \(tab.name)"))
      .accessibilityIdentifier("document-tab-close-button")
      .help(Text(verbatim: "Close \(tab.name)"))
    }
    .padding(.horizontal, 8)
    .frame(
      minWidth: WorkspaceDocumentTabMetrics.minimumWidth,
      maxWidth: WorkspaceDocumentTabMetrics.maximumWidth,
      minHeight: WorkspaceDocumentTabMetrics.height,
      maxHeight: WorkspaceDocumentTabMetrics.height
    )
    .background {
      Rectangle()
        .fill(backgroundColor)
    }
    .overlay(alignment: .trailing) {
      Divider()
    }
    .onHover { isHovered = $0 }
    .help(Text(verbatim: tab.url.locusStandardizedPath))
  }

  private var backgroundColor: Color {
    if isSelected {
      return Color.primary.opacity(0.10)
    }

    return isHovered ? Color.primary.opacity(0.06) : Color.clear
  }
}

enum WorkspaceDocumentTabMetrics {
  static let height: CGFloat = 32
  static let minimumWidth: CGFloat = 112
  static let maximumWidth: CGFloat = 192
  static let closeButtonSize: CGFloat = 24
}

import SwiftUI

enum DocumentCardMetrics {
  static let cornerRadius: CGFloat = 12
  static let inset: CGFloat = 10
  static let borderWidth: CGFloat = 1
  static let shadowOpacity: Double = 0.06
  static let shadowRadius: CGFloat = 3
  static let shadowOffsetY: CGFloat = 1
}

enum LocusChromeColors {
  // On macOS 26, windowBackgroundColor, textBackgroundColor, and
  // controlBackgroundColor resolve to the same values in both appearances.
  // Derive the field from the editor/card color so the card stays separated.
  static let fieldDarkeningFractionLight: CGFloat = 0.05
  static let fieldDarkeningFractionDark: CGFloat = 0.35

  static let documentCard: NSColor = .textBackgroundColor

  static let documentField = NSColor(name: NSColor.Name("LocusDocumentField")) { appearance in
    let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    let fraction = isDark ? fieldDarkeningFractionDark : fieldDarkeningFractionLight
    var base = NSColor.textBackgroundColor
    appearance.performAsCurrentDrawingAppearance {
      base = NSColor.textBackgroundColor.usingColorSpace(.sRGB) ?? .textBackgroundColor
    }
    return base.blended(withFraction: fraction, of: .black) ?? base
  }
}

enum DocumentTabStripMetrics {
  static let chipSpacing: CGFloat = 6
  static let chipMaxWidth: CGFloat = 180
  static let chipLeadingPadding: CGFloat = 12
  static let chipTrailingPadding: CGFloat = 14
  static let chipVerticalPadding: CGFloat = 6
  static let documentIconFontSize: CGFloat = 11
  static let closeIconFontSize: CGFloat = 9
  static let closeHitTarget: CGFloat = 16
  static let inactiveHoverOpacity: Double = 0.08
  static let activeChipShadowOpacity: Double = 0.06
  static let activeChipShadowRadius: CGFloat = 3
  static let activeChipShadowOffsetY: CGFloat = 1
  static let chipShadowHeadroom: CGFloat = 4
  static let toolbarTrailingReserve: CGFloat = 24
}

struct DocumentCardModifier: ViewModifier {
  func body(content: Content) -> some View {
    let shape = RoundedRectangle(
      cornerRadius: DocumentCardMetrics.cornerRadius,
      style: .continuous
    )

    content
      .clipShape(shape)
      .background(
        shape
          .fill(Color(nsColor: LocusChromeColors.documentCard))
          .shadow(
            color: .black.opacity(DocumentCardMetrics.shadowOpacity),
            radius: DocumentCardMetrics.shadowRadius,
            y: DocumentCardMetrics.shadowOffsetY
          )
      )
      .overlay(
        shape.strokeBorder(
          Color(nsColor: .separatorColor),
          lineWidth: DocumentCardMetrics.borderWidth
        )
      )
      .padding(DocumentCardMetrics.inset)
  }
}

struct DocumentTabStripView: View {
  let tabs: [DocumentTab]
  let activeTabID: WorkspaceEntry.ID?
  let maxWidth: CGFloat
  let onSelect: (DocumentTab) -> Void
  let onClose: (DocumentTab) -> Void

  @State private var chipContentWidth: CGFloat = 0

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: DocumentTabStripMetrics.chipSpacing) {
          ForEach(tabs) { tab in
            DocumentTabChip(
              tab: tab,
              isActive: tab.id == activeTabID,
              onSelect: { onSelect(tab) },
              onClose: { onClose(tab) }
            )
            .id(tab.id)
          }
        }
        .onGeometryChange(for: CGFloat.self) { geometry in
          geometry.size.width
        } action: { width in
          chipContentWidth = width
        }
      }
      .scrollClipDisabled()
      .onChange(of: activeTabID) { _, newID in
        if let newID {
          proxy.scrollTo(newID, anchor: .center)
        }
      }
    }
    // NSToolbar uses the hosted view fitting width as its required minimum.
    // Without this explicit cap, SwiftUI publishes the full ideal tab width and
    // the toolbar sends the item into the overflow menu.
    .frame(width: min(max(chipContentWidth, 0), max(maxWidth, 0)), alignment: .leading)
    .clipShape(Rectangle().inset(by: -DocumentTabStripMetrics.chipShadowHeadroom))
    .accessibilityIdentifier("document-tab-strip")
  }
}

struct DocumentTabToolbar: ToolbarContent {
  let tabs: [DocumentTab]
  let activeTabID: WorkspaceEntry.ID?
  let maxStripWidth: CGFloat
  let onSelect: (DocumentTab) -> Void
  let onClose: (DocumentTab) -> Void

  @ToolbarContentBuilder
  var body: some ToolbarContent {
    if #available(macOS 26.0, *) {
      ToolbarItem(placement: .navigation) {
        strip
      }
      .sharedBackgroundVisibility(.hidden)
    } else {
      ToolbarItem(placement: .navigation) {
        strip
      }
    }
  }

  private var strip: some View {
    DocumentTabStripView(
      tabs: tabs,
      activeTabID: activeTabID,
      maxWidth: maxStripWidth,
      onSelect: onSelect,
      onClose: onClose
    )
  }
}

private struct DocumentTabChip: View {
  let tab: DocumentTab
  let isActive: Bool
  let onSelect: () -> Void
  let onClose: () -> Void

  @State private var isHovering = false

  var body: some View {
    let shape = Capsule(style: .continuous)

    Button(action: onSelect) {
      HStack(spacing: 4) {
        // Leading slot: the document glyph at rest, swapped for the close
        // button (the sibling overlay below) on hover or while active, so the
        // title never shifts as the affordance changes.
        Color.clear
          .frame(
            width: DocumentTabStripMetrics.closeHitTarget,
            height: DocumentTabStripMetrics.closeHitTarget
          )
          .overlay {
            if !showsCloseButton {
              Image(systemName: "doc.text")
                .font(.system(size: DocumentTabStripMetrics.documentIconFontSize))
                .foregroundStyle(.tertiary)
            }
          }

        Text(tab.name)
          .font(.callout)
          .lineLimit(1)
          .truncationMode(.tail)
          .foregroundStyle(isActive ? .primary : .secondary)
      }
      .padding(.leading, DocumentTabStripMetrics.chipLeadingPadding)
      .padding(.trailing, DocumentTabStripMetrics.chipTrailingPadding)
      .padding(.vertical, DocumentTabStripMetrics.chipVerticalPadding)
      .frame(maxWidth: DocumentTabStripMetrics.chipMaxWidth)
      .background(
        shape
          .fill(backgroundColor)
          .shadow(
            color: .black.opacity(
              isActive ? DocumentTabStripMetrics.activeChipShadowOpacity : 0
            ),
            radius: DocumentTabStripMetrics.activeChipShadowRadius,
            y: DocumentTabStripMetrics.activeChipShadowOffsetY
          )
      )
      .overlay {
        if isActive {
          shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
      }
      .contentShape(shape)
    }
    .buttonStyle(.plain)
    .overlay(alignment: .leading) {
      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.system(size: DocumentTabStripMetrics.closeIconFontSize, weight: .semibold))
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .frame(
        width: DocumentTabStripMetrics.closeHitTarget,
        height: DocumentTabStripMetrics.closeHitTarget
      )
      .padding(.leading, DocumentTabStripMetrics.chipLeadingPadding)
      .opacity(showsCloseButton ? 1 : 0)
      .accessibilityLabel("Close \(tab.name)")
      .accessibilityIdentifier("document-tab-close-\(tab.id)")
    }
    .onHover { isHovering = $0 }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(tab.name)
    .accessibilityAddTraits(isActive ? .isSelected : [])
    .accessibilityIdentifier("document-tab-\(tab.id)")
  }

  private var showsCloseButton: Bool {
    isHovering || isActive
  }

  private var backgroundColor: Color {
    if isActive {
      return Color(nsColor: LocusChromeColors.documentCard)
    }
    if isHovering {
      return Color.primary.opacity(DocumentTabStripMetrics.inactiveHoverOpacity)
    }
    return .clear
  }
}

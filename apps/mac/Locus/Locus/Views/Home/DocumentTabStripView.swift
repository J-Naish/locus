import SwiftUI

enum DocumentCardMetrics {
  static let cornerRadius: CGFloat = 12
  /// Flush under the header band: the toolbar row above provides all the
  /// visual breathing room the card top needs.
  static let topInset: CGFloat = 0
  /// 8pt matches the gutter the system leaves around the floating sidebar
  /// panel, so the card's side and bottom margins read as the sidebar's.
  static let horizontalInset: CGFloat = 8
  static let bottomInset: CGFloat = 8
  static let borderWidth: CGFloat = 1
  static let shadowOpacity: Double = 0.06
  static let shadowRadius: CGFloat = 3
  static let shadowOffsetY: CGFloat = 1

  static var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
  }
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
  /// Optical centering within the unified toolbar: the chips sit a touch high
  /// in the bar, so nudge them down. An offset, not padding — it must not
  /// change the strip's fitting size, which the toolbar treats as a minimum.
  static let toolbarVerticalNudge: CGFloat = 2

  /// Live-reorder drag: how far the press must travel before it becomes a
  /// reorder rather than a click, and the lift styling on the dragged chip.
  static let reorderActivationDistance: CGFloat = 4
  /// Auto-scroll while dragging near the strip's edges, so a chip can travel
  /// to tabs that are scrolled out of view.
  static let autoScrollEdgeZone: CGFloat = 28
  static let autoScrollMaxSpeedPerTick: CGFloat = 10
  static let autoScrollTickInterval: TimeInterval = 1.0 / 60.0
  static let draggedChipScale: CGFloat = 1.04
  static let draggedChipShadowOpacity: Double = 0.18
  static let draggedChipShadowRadius: CGFloat = 6
  static let draggedChipShadowOffsetY: CGFloat = 2
  /// One spring for the whole interaction: neighbors sliding aside and the
  /// released chip settling into its slot.
  static let reorderAnimation = Animation.spring(response: 0.3, dampingFraction: 0.8)
}

struct DocumentCardModifier: ViewModifier {
  func body(content: Content) -> some View {
    let shape = DocumentCardMetrics.shape

    return
      content
      // The rounded corners are painted on, not clipped: a SwiftUI clip
      // container around the AppKit editor suppresses its pointer cursor
      // (measured — both legacy cursor rects and the editor's own cursorUpdate
      // tracking areas register correctly yet the arrow wins while .clipShape
      // is present, and recover as soon as it is removed). Field-colored caps
      // over the square corners are visually identical to clipping here,
      // because everything outside the card's border is the field.
      .overlay(
        RoundedCornerCaps()
          .fill(
            Color(nsColor: LocusChromeColors.documentField),
            style: FillStyle(eoFill: true)
          )
          .allowsHitTesting(false)
      )
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
        // The hairline is decoration only; keep it out of hit testing so it
        // never intercepts clicks meant for the card content.
        .allowsHitTesting(false)
      )
      .padding(.top, DocumentCardMetrics.topInset)
      .padding(.horizontal, DocumentCardMetrics.horizontalInset)
      .padding(.bottom, DocumentCardMetrics.bottomInset)
  }
}

/// The region between a rectangle and the inscribed card shape — the notches
/// at the rounded top corners. Filled with `FillStyle(eoFill: true)` it covers
/// exactly what `clipShape` would have masked.
private struct RoundedCornerCaps: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.addRect(rect)
    path.addPath(DocumentCardMetrics.shape.path(in: rect))
    return path
  }
}

struct DocumentTabStripView: View {
  let tabs: [DocumentTab]
  let activeTabID: WorkspaceEntry.ID?
  let maxWidth: CGFloat
  let onSelect: (DocumentTab) -> Void
  let onClose: (DocumentTab) -> Void
  /// Reorder request from a chip drag: insert the dragged tab before the
  /// second id, or at the trailing edge when it is nil.
  let onMove: (WorkspaceEntry.ID, WorkspaceEntry.ID?) -> Void

  @State private var chipContentWidth: CGFloat = 0
  @State private var chipWidths: [WorkspaceEntry.ID: CGFloat] = [:]
  @State private var draggedTabID: WorkspaceEntry.ID?
  @State private var dragTranslation: CGFloat = 0
  /// Layout shift accumulated by live swaps: each time the dragged chip trades
  /// places with a neighbor its settled slot moves by that neighbor's width
  /// (plus spacing), so the visual offset compensates to keep the chip under
  /// the cursor.
  @State private var dragShift: CGFloat = 0
  /// Content scrolled under the resting cursor by edge auto-scroll: counts as
  /// extra drag travel so the held chip stays put while neighbors stream by.
  @State private var dragScrollCompensation: CGFloat = 0
  @State private var dragPointerGlobalX: CGFloat = 0
  @State private var stripGlobalFrame: CGRect = .zero
  @State private var scrollOffsetX: CGFloat = 0
  @State private var scrollPosition = ScrollPosition()

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: DocumentTabStripMetrics.chipSpacing) {
          ForEach(tabs) { tab in
            let isDragged = tab.id == draggedTabID
            DocumentTabChip(
              tab: tab,
              isActive: tab.id == activeTabID,
              onSelect: { onSelect(tab) },
              onClose: { onClose(tab) }
            )
            .id(tab.id)
            .onGeometryChange(for: CGFloat.self) { geometry in
              geometry.size.width
            } action: { width in
              chipWidths[tab.id] = width
            }
            .offset(x: isDragged ? dragTranslation + dragScrollCompensation - dragShift : 0)
            .scaleEffect(isDragged ? DocumentTabStripMetrics.draggedChipScale : 1)
            .shadow(
              color: .black.opacity(
                isDragged ? DocumentTabStripMetrics.draggedChipShadowOpacity : 0
              ),
              radius: DocumentTabStripMetrics.draggedChipShadowRadius,
              y: DocumentTabStripMetrics.draggedChipShadowOffsetY
            )
            .zIndex(isDragged ? 1 : 0)
            // The grabbed chip must not animate: on a swap its slot shift and
            // the dragShift compensation cancel exactly only when both apply
            // instantly, keeping the chip glued to the cursor while the
            // neighbors spring aside. (Releasing flips isDragged off first,
            // so the settle into the slot still animates.)
            .transaction { transaction in
              if isDragged {
                transaction.animation = nil
              }
            }
            .highPriorityGesture(reorderGesture(for: tab))
          }
        }
        .onGeometryChange(for: CGFloat.self) { geometry in
          geometry.size.width
        } action: { width in
          chipContentWidth = width
        }
      }
      .scrollClipDisabled()
      .scrollPosition($scrollPosition)
      .onScrollGeometryChange(for: CGFloat.self) { geometry in
        geometry.contentOffset.x
      } action: { _, offset in
        scrollOffsetX = offset
      }
      .onChange(of: activeTabID) { _, newID in
        if let newID, draggedTabID == nil {
          proxy.scrollTo(newID, anchor: .center)
        }
      }
    }
    // Span the full available width whenever there are tabs: with few tabs the
    // strip still fills the header band (the empty trailing area stays
    // draggable and reads as one surface) rather than hugging the chips. An
    // empty strip collapses to zero so the toolbar item reserves no width.
    // NSToolbar uses the hosted view fitting width as its required minimum, so
    // this width is also the explicit cap that keeps the item from reporting
    // the full ideal tab width and overflowing into the "»" menu — maxWidth is
    // the detail width less a small trailing reserve, so it always fits.
    .frame(width: tabs.isEmpty ? 0 : max(maxWidth, 0), alignment: .leading)
    .clipShape(Rectangle().inset(by: -DocumentTabStripMetrics.chipShadowHeadroom))
    .onGeometryChange(for: CGRect.self) { geometry in
      geometry.frame(in: .global)
    } action: { frame in
      stripGlobalFrame = frame
    }
    // The edge auto-scroll must keep running while the pointer rests inside an
    // edge zone, which gesture events alone cannot do — they only fire on
    // movement. The driver exists (and ticks) only during a drag.
    .overlay {
      if draggedTabID != nil {
        DocumentTabAutoScrollDriver(onTick: autoScrollTick)
          .allowsHitTesting(false)
      }
    }
    .accessibilityIdentifier("document-tab-strip")
  }

  /// Scrolls the strip while a drag holds near an edge, and converts the
  /// scrolled distance into drag travel so the held chip keeps swapping past
  /// the chips streaming under it.
  private func autoScrollTick() {
    guard let draggedTabID, let tab = tabs.first(where: { $0.id == draggedTabID }) else {
      return
    }
    let viewportWidth = stripGlobalFrame.width
    guard viewportWidth > 0 else { return }

    let speed = DocumentTabReorder.autoScrollSpeed(
      pointerX: dragPointerGlobalX,
      viewportMinX: stripGlobalFrame.minX,
      viewportMaxX: stripGlobalFrame.maxX,
      edgeZone: DocumentTabStripMetrics.autoScrollEdgeZone,
      maxSpeed: DocumentTabStripMetrics.autoScrollMaxSpeedPerTick
    )
    guard speed != 0 else { return }

    let maxOffset = max(0, chipContentWidth - viewportWidth)
    let target = min(max(scrollOffsetX + speed, 0), maxOffset)
    let delta = target - scrollOffsetX
    guard delta != 0 else { return }

    scrollPosition.scrollTo(x: target)
    scrollOffsetX = target
    dragScrollCompensation += delta
    settleSwapIfNeeded(for: tab)
  }

  /// Live reorder, react-beautiful-dnd style: the grabbed chip follows the
  /// cursor while its neighbors spring aside as it crosses their midpoints —
  /// the order updates during the drag, not at drop. A plain click stays a
  /// selection because the gesture only activates after a few points of
  /// travel.
  private func reorderGesture(for tab: DocumentTab) -> some Gesture {
    // Measured in a space that does not move with the chip: in the default
    // .local space a swap shifts the chip's own coordinate origin, the
    // reported translation drops by the shifted distance, and the swap
    // immediately reverses — A and B oscillate while the cursor rests near
    // the threshold.
    DragGesture(
      minimumDistance: DocumentTabStripMetrics.reorderActivationDistance,
      coordinateSpace: .global
    )
    .onChanged { value in
      if draggedTabID != tab.id {
        draggedTabID = tab.id
        dragShift = 0
        dragScrollCompensation = 0
      }
      dragTranslation = value.translation.width
      dragPointerGlobalX = value.location.x
      settleSwapIfNeeded(for: tab)
    }
    .onEnded { _ in
      withAnimation(DocumentTabStripMetrics.reorderAnimation) {
        draggedTabID = nil
        dragTranslation = 0
        dragShift = 0
        dragScrollCompensation = 0
      }
    }
  }

  /// Trades the dragged chip with one neighbor when its displacement crosses
  /// that neighbor's midpoint. One swap per gesture event: the next event
  /// re-evaluates against the freshly reordered `tabs`, so fast drags catch up
  /// over a few events without ever acting on stale order.
  private func settleSwapIfNeeded(for tab: DocumentTab) {
    guard let draggedIndex = tabs.firstIndex(where: { $0.id == tab.id }) else { return }

    let displacement = dragTranslation + dragScrollCompensation - dragShift
    guard
      let step = DocumentTabReorder.swapStep(
        widths: tabs.map { chipWidths[$0.id] ?? 0 },
        draggedIndex: draggedIndex,
        displacement: displacement,
        spacing: DocumentTabStripMetrics.chipSpacing
      )
    else { return }

    let neighbor = tabs[draggedIndex + step]
    let neighborWidth = chipWidths[neighbor.id] ?? 0
    withAnimation(DocumentTabStripMetrics.reorderAnimation) {
      if step > 0 {
        let followerIndex = draggedIndex + 2
        onMove(tab.id, followerIndex < tabs.count ? tabs[followerIndex].id : nil)
      } else {
        onMove(tab.id, neighbor.id)
      }
    }
    dragShift += CGFloat(step) * (neighborWidth + DocumentTabStripMetrics.chipSpacing)
  }
}

/// Invisible 60Hz heartbeat for the drag's edge auto-scroll. Lives only while
/// a drag is active; @State keeps the publisher alive across the parent's
/// re-renders so the ticks stay steady.
private struct DocumentTabAutoScrollDriver: View {
  let onTick: () -> Void

  @State private var clock = Timer.publish(
    every: DocumentTabStripMetrics.autoScrollTickInterval, on: .main, in: .common
  ).autoconnect()

  var body: some View {
    Color.clear
      .onReceive(clock) { _ in
        onTick()
      }
  }
}

struct DocumentTabToolbar: ToolbarContent {
  let tabs: [DocumentTab]
  let activeTabID: WorkspaceEntry.ID?
  let maxStripWidth: CGFloat
  let onSelect: (DocumentTab) -> Void
  let onClose: (DocumentTab) -> Void
  let onMove: (WorkspaceEntry.ID, WorkspaceEntry.ID?) -> Void

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
      onClose: onClose,
      onMove: onMove
    )
    .offset(y: DocumentTabStripMetrics.toolbarVerticalNudge)
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
          // No truncation and no width cap: the full file name always shows,
          // since the sidebar truncates it and the tab is the only place the
          // exact name is legible. fixedSize keeps the text at its intrinsic
          // width so the chip grows to fit rather than compressing the name;
          // the strip scrolls horizontally to reach long names.
          .fixedSize(horizontal: true, vertical: false)
          .foregroundStyle(isActive ? .primary : .secondary)
      }
      .padding(.leading, DocumentTabStripMetrics.chipLeadingPadding)
      .padding(.trailing, DocumentTabStripMetrics.chipTrailingPadding)
      .padding(.vertical, DocumentTabStripMetrics.chipVerticalPadding)
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

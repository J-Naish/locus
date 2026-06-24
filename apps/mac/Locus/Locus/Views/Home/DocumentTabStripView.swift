import SwiftUI

enum DocumentCardMetrics {
  static let cornerRadius: CGFloat = 18
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

/// A complete look for the app's chrome: the appearance it runs under (so the
/// system-driven colors — sidebar labels, editor text — match), the document
/// card (also the editor background, so they never seam), the field around and
/// behind it, and the active tab's fill, stroke, and foreground (where a theme
/// can carry an accent).
struct LocusTheme {
  enum FieldBackgroundStyle: Equatable {
    case solid
    case glass
  }

  let id: String
  let displayName: String
  let appearanceName: NSAppearance.Name
  let documentCard: NSColor
  let documentField: NSColor
  let fieldBackgroundStyle: FieldBackgroundStyle
  let activeTabFill: NSColor
  let activeTabStroke: NSColor
  let activeTabText: NSColor
}

enum LocusChromeColors {
  static let fieldDarkeningFractionLight: CGFloat = 0.05

  /// Light — the original neutral look: the system editor white on a faintly
  /// darker off-white field, with a neutral active tab.
  static let light = LocusTheme(
    id: "light",
    displayName: "Light",
    appearanceName: .aqua,
    documentCard: .textBackgroundColor,
    documentField: lightFieldFromSystemWhite,
    fieldBackgroundStyle: .solid,
    activeTabFill: .textBackgroundColor,
    activeTabStroke: .separatorColor,
    activeTabText: .labelColor
  )

  /// Glass — the original light palette on a single window-level Liquid Glass
  /// field. Kept as a separate theme so the neutral Light theme remains a true
  /// solid-background option.
  static let glass = LocusTheme(
    id: "glass",
    displayName: "Glass",
    appearanceName: .aqua,
    documentCard: .textBackgroundColor,
    documentField: lightFieldFromSystemWhite,
    fieldBackgroundStyle: .glass,
    activeTabFill: .textBackgroundColor,
    activeTabStroke: .separatorColor,
    activeTabText: .labelColor
  )

  /// Paper — a low-contrast warm cream look with a bold clay (book-cloth)
  /// accent. The editor card and the field are the same cream family with only
  /// a slight step between them, so the editor reads as part of the page. The
  /// active tab is a solid clay pill with light text. Named for the palette's
  /// own hues, not its origin.
  static let paper = LocusTheme(
    id: "paper",
    displayName: "Paper",
    appearanceName: .aqua,
    documentCard: srgb255(245, 240, 228),  // warm cream paper
    documentField: srgb255(232, 225, 210),  // soft warm cream main background
    fieldBackgroundStyle: .solid,
    activeTabFill: clay,
    activeTabStroke: deeperClay,
    activeTabText: srgb255(250, 249, 245)  // ivory, for contrast on clay
  )

  /// Dark — a black-based slate look (fixed, so it never absorbs the desktop
  /// wallpaper tint the system dark gray does) with the same clay accent.
  static let dark = LocusTheme(
    id: "dark",
    displayName: "Dark",
    appearanceName: .darkAqua,
    documentCard: srgb255(38, 38, 37),  // slate medium
    documentField: srgb255(25, 25, 24),  // slate dark
    fieldBackgroundStyle: .solid,
    activeTabFill: clay,
    activeTabStroke: deeperClay,
    activeTabText: srgb255(250, 249, 245)
  )

  static let registeredThemes = [light, glass, paper, dark]

  /// Book Cloth — the palette's signature warm terracotta.
  static let clay = srgb255(204, 120, 92)
  /// A step darker, for the active tab's border definition against its fill.
  static let deeperClay = srgb255(181, 99, 74)

  /// The active theme. Switch the whole app's chrome — and its appearance — by
  /// reassigning this.
  static let active = light

  static var documentCard: NSColor { active.documentCard }
  static var documentField: NSColor { active.documentField }
  static var fieldBackgroundStyle: LocusTheme.FieldBackgroundStyle {
    active.fieldBackgroundStyle
  }
  static var activeTabFill: NSColor { active.activeTabFill }
  static var activeTabStroke: NSColor { active.activeTabStroke }
  static var activeTabText: NSColor { active.activeTabText }

  /// The NSAppearance the active theme runs under, so the app's system-driven
  /// colors match its chrome.
  static var activeAppearance: NSAppearance? {
    NSAppearance(named: active.appearanceName)
  }

  private static func srgb255(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
    NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
  }

  /// The light field: the system editor white nudged a touch darker so the
  /// card stays separated from it.
  private static var lightFieldFromSystemWhite: NSColor {
    var base = NSColor.textBackgroundColor
    NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
      base = NSColor.textBackgroundColor.usingColorSpace(.sRGB) ?? .textBackgroundColor
    }
    return base.blended(withFraction: fieldDarkeningFractionLight, of: .black) ?? base
  }
}

struct LocusDocumentFieldBackground: View {
  var body: some View {
    let tint = Color(nsColor: LocusChromeColors.documentField)

    switch LocusChromeColors.fieldBackgroundStyle {
    case .solid:
      tint
    case .glass:
      if #available(macOS 26.0, *) {
        Rectangle()
          .fill(tint.opacity(0.48))
          .glassEffect(
            .regular.tint(tint.opacity(0.18)),
            in: .rect
          )
      } else {
        Rectangle()
          .fill(.regularMaterial)
          .overlay(tint.opacity(0.48))
      }
    }
  }
}

struct LocusWindowFieldBackgroundModifier: ViewModifier {
  func body(content: Content) -> some View {
    content.containerBackground(for: .window) {
      LocusDocumentFieldBackground()
    }
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
  /// Reserve for the toolbar's own trailing overflow room while the sidebar is
  /// visible. The traffic lights and native sidebar toggle live over the
  /// sidebar surface in this state, so the tab strip can use almost the whole
  /// detail column.
  static let toolbarVisibleSidebarReserve: CGFloat = 24
  /// Reserve for titlebar chrome when the sidebar is hidden. The detail column
  /// then grows to nearly the full window width, but the toolbar item still
  /// cannot occupy the traffic-light/sidebar-toggle area at the leading edge.
  /// Keeping this budget out of the strip's fitting width prevents NSToolbar
  /// from moving the item into its overflow menu during close/open transitions.
  static let toolbarHiddenSidebarReserve: CGFloat = 160
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

  static func toolbarStripWidth(
    forDetailWidth detailWidth: CGFloat,
    sidebarIsVisible: Bool
  ) -> CGFloat {
    let reserve =
      sidebarIsVisible ? toolbarVisibleSidebarReserve : toolbarHiddenSidebarReserve
    return max(0, detailWidth - reserve)
  }
}

struct DocumentCardModifier: ViewModifier {
  func body(content: Content) -> some View {
    let shape = DocumentCardMetrics.shape

    return
      content
      // With a material/glass field, painted corner caps sample a different
      // background than the window and show as artifacts. Clip only the card
      // surface so the window-level field remains visible in the rounded
      // notches, while the shadowed background can still draw outside the card.
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
        // The hairline is decoration only; keep it out of hit testing so it
        // never intercepts clicks meant for the card content.
        .allowsHitTesting(false)
      )
      .padding(.top, DocumentCardMetrics.topInset)
      .padding(.horizontal, DocumentCardMetrics.horizontalInset)
      .padding(.bottom, DocumentCardMetrics.bottomInset)
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
    // the detail width less the state-appropriate toolbar reserve.
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
          .foregroundStyle(
            isActive ? Color(nsColor: LocusChromeColors.activeTabText) : .secondary
          )
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
          shape.strokeBorder(Color(nsColor: LocusChromeColors.activeTabStroke), lineWidth: 1)
        }
      }
      .contentShape(shape)
    }
    .buttonStyle(.plain)
    .overlay(alignment: .leading) {
      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.system(size: DocumentTabStripMetrics.closeIconFontSize, weight: .semibold))
          .foregroundStyle(
            isActive ? Color(nsColor: LocusChromeColors.activeTabText) : .secondary
          )
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
      return Color(nsColor: LocusChromeColors.activeTabFill)
    }
    if isHovering {
      return Color.primary.opacity(DocumentTabStripMetrics.inactiveHoverOpacity)
    }
    return .clear
  }
}

import Foundation

// `dump` (the PPM debug writer) and the Wasm export block from Atlas.zig are
// intentionally not ported because the native Metal path consumes this buffer directly.
@MainActor
final class TerminalGlyphAtlas {
  // ghostty: Atlas.zig:53 Format
  enum Format {
    case grayscale
    case bgr
    case bgra

    var depth: Int {
      switch self {
      case .grayscale:
        1
      case .bgr:
        3
      case .bgra:
        4
      }
    }
  }

  // ghostty: Atlas.zig:83 Region
  struct Region: Equatable {
    var x: UInt32
    var y: UInt32
    var width: UInt32
    var height: UInt32
  }

  // ghostty: Atlas.zig:70 Node
  private struct Node {
    var x: UInt32
    var y: UInt32
    var width: UInt32
  }

  // ghostty: Atlas.zig:76 Error
  enum Error: Swift.Error, Equatable {
    case atlasFull
  }

  // ghostty: Atlas.zig:93 node_prealloc
  private static let nodePrealloc = 64

  private(set) var data: [UInt8]
  private(set) var size: UInt32
  let format: Format
  private var nodes: [Node] = []

  // ghostty uses atomics because another renderer thread observes these counters.
  // Locus confines atlas mutation and observation to the main actor, so plain Ints suffice.
  private(set) var modified = 0
  private(set) var resized = 0

  // ghostty: Atlas.zig:100 init
  init(size: UInt32, format: Format) {
    precondition(size >= 2)
    let sizeInt = Int(size)
    self.data = [UInt8](repeating: 0, count: sizeInt * sizeInt * format.depth)
    self.size = size
    self.format = format
    nodes.reserveCapacity(Self.nodePrealloc)
    clear()
  }

  // ghostty: Atlas.zig:136 reserve
  func reserve(width: UInt32, height: UInt32) throws -> Region {
    var region = Region(x: 0, y: 0, width: width, height: height)
    if width == 0, height == 0 {
      return region
    }

    var bestHeight = UInt32.max
    var bestWidth = UInt32.max
    var bestIndex: Int?
    for index in nodes.indices {
      guard let y = fit(index: index, width: width, height: height) else {
        continue
      }
      let node = nodes[index]
      let candidateHeight = y + height
      if candidateHeight < bestHeight
        || (candidateHeight == bestHeight && node.width > 0 && node.width < bestWidth)
      {
        bestIndex = index
        bestWidth = node.width
        bestHeight = candidateHeight
        region.x = node.x
        region.y = y
      }
    }
    guard let bestIndex else {
      throw Error.atlasFull
    }

    nodes.insert(
      Node(x: region.x, y: region.y + height, width: width),
      at: bestIndex
    )
    let index = bestIndex + 1
    while index < nodes.count {
      let previous = nodes[index - 1]
      if nodes[index].x < previous.x + previous.width {
        let shrink = previous.x + previous.width - nodes[index].x
        nodes[index].x += shrink
        nodes[index].width = nodes[index].width > shrink ? nodes[index].width - shrink : 0
        if nodes[index].width == 0 {
          nodes.remove(at: index)
          continue
        }
      }
      break
    }
    merge()
    return region
  }

  // ghostty: Atlas.zig:215 fit
  private func fit(index: Int, width: UInt32, height: UInt32) -> UInt32? {
    let node = nodes[index]
    guard node.x + width <= size - 1 else {
      return nil
    }

    var y = node.y
    var nodeIndex = index
    var widthLeft = width
    while widthLeft > 0 {
      guard nodeIndex < nodes.count else {
        return nil
      }
      let candidate = nodes[nodeIndex]
      y = max(y, candidate.y)
      guard y + height <= size - 1 else {
        return nil
      }
      widthLeft = widthLeft > candidate.width ? widthLeft - candidate.width : 0
      nodeIndex += 1
    }
    return y
  }

  // ghostty: Atlas.zig:238 merge
  private func merge() {
    var index = 0
    while index + 1 < nodes.count {
      if nodes[index].y == nodes[index + 1].y {
        nodes[index].width += nodes[index + 1].width
        nodes.remove(at: index + 1)
      } else {
        index += 1
      }
    }
  }

  // ghostty: Atlas.zig:256 set
  func set(region: Region, data: [UInt8]) {
    set(region: region, source: data[...])
  }

  private func set<Source>(region: Region, source: Source)
  where Source: RandomAccessCollection, Source.Element == UInt8 {
    validate(region)
    let depth = format.depth
    let rowByteCount = Int(region.width) * depth
    precondition(source.count >= rowByteCount * Int(region.height))
    for row in 0..<Int(region.height) {
      let textureOffset =
        ((Int(region.y) + row) * Int(size) + Int(region.x)) * depth
      let sourceOffset = row * rowByteCount
      for byteOffset in 0..<rowByteCount {
        let sourceIndex = source.index(source.startIndex, offsetBy: sourceOffset + byteOffset)
        self.data[textureOffset + byteOffset] = source[sourceIndex]
      }
    }
    modified &+= 1
  }

  // ghostty: Atlas.zig:280 setFromLarger
  func setFromLarger(
    region: Region,
    src: [UInt8],
    srcWidth: UInt32,
    srcX: UInt32,
    srcY: UInt32
  ) {
    validate(region)
    precondition(srcX + region.width <= srcWidth)
    let depth = format.depth
    let rowByteCount = Int(region.width) * depth
    let requiredRows = Int(srcY + region.height)
    precondition(src.count >= Int(srcWidth) * requiredRows * depth)
    for row in 0..<Int(region.height) {
      let textureOffset =
        ((Int(region.y) + row) * Int(size) + Int(region.x)) * depth
      let sourceOffset =
        ((Int(srcY) + row) * Int(srcWidth) + Int(srcX)) * depth
      for byteOffset in 0..<rowByteCount {
        data[textureOffset + byteOffset] = src[sourceOffset + byteOffset]
      }
    }
    modified &+= 1
  }

  // ghostty: Atlas.zig:314 grow
  func grow(sizeNew: UInt32) {
    precondition(sizeNew >= size)
    guard sizeNew != size else {
      return
    }

    let oldData = data
    let oldSize = size
    let newSize = Int(sizeNew)
    data = [UInt8](repeating: 0, count: newSize * newSize * format.depth)
    size = sizeNew

    // Keep the left/right border bytes in the row copy so each old row remains
    // contiguous; only the first and last border rows are skipped.
    let oldRowStart = Int(oldSize) * format.depth
    set(
      region: Region(x: 0, y: 1, width: oldSize, height: oldSize - 2),
      source: oldData[oldRowStart...]
    )
    nodes.append(
      Node(x: oldSize - 1, y: 1, width: sizeNew - oldSize)
    )
    modified &+= 1
    resized &+= 1
  }

  // ghostty: Atlas.zig:367 clear
  func clear() {
    modified &+= 1
    data = [UInt8](repeating: 0, count: data.count)
    nodes.removeAll(keepingCapacity: true)
    // The one-pixel border prevents neighboring atlas regions from bleeding
    // into each other during filtered sampling.
    nodes.append(Node(x: 1, y: 1, width: size - 2))
  }

  private func validate(_ region: Region) {
    precondition(region.x < size - 1)
    precondition(region.x + region.width <= size - 1)
    precondition(region.y < size - 1)
    precondition(region.y + region.height <= size - 1)
  }
}

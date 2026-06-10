import Foundation

/// Decoded text plus the encoding it should be re-encoded with on save.
struct TextDocument: Equatable, Sendable {
  let text: String
  let encoding: String.Encoding
}

/// Shared text-encoding detection / round-trip used by the buffer-backed text
/// path (`TextBufferStore`): it recognizes, preserves, and re-encodes a fixed set
/// of encodings.
///
/// Decoding mirrors the historical rules: UTF-8 (with or without a BOM, BOM
/// stripped), UTF-16 (LE/BE distinguished by the BOM), then a Shift JIS / Latin-1
/// fallback, while rejecting anything that looks binary. The reported `encoding`
/// is exactly what the file is re-encoded to on save (UTF-16 keeps its byte order
/// and BOM).
enum TextEncoding {
  /// Thrown when re-encoding to the original encoding would lose characters.
  enum CodingError: LocalizedError, Equatable {
    case unrepresentable(String.Encoding)

    var errorDescription: String? {
      "Some characters can't be saved in this file's original encoding. Save as UTF-8 instead."
    }
  }

  /// Decodes `data` into text plus the encoding to save it back with, or `nil`
  /// when the bytes do not look like text.
  static func decode(_ data: Data) -> TextDocument? {
    guard !data.isEmpty else {
      return TextDocument(text: "", encoding: .utf8)
    }

    if data.starts(with: [0xEF, 0xBB, 0xBF]) {
      return decode(Data(data.dropFirst(3)), as: .utf8)  // UTF-8 BOM stripped
    }
    if data.starts(with: [0xFF, 0xFE]) {
      return decode(Data(data.dropFirst(2)), as: .utf16LittleEndian)  // BOM stripped
    }
    if data.starts(with: [0xFE, 0xFF]) {
      return decode(Data(data.dropFirst(2)), as: .utf16BigEndian)  // BOM stripped
    }

    guard !data.contains(0) else {
      return nil
    }
    for encoding in fallbackEncodings {
      if let document = decode(data, as: encoding) {
        return document
      }
    }
    return nil
  }

  /// Re-encodes `text` to `encoding`, throwing `CodingError.unrepresentable` if a
  /// character cannot be represented. UTF-16 LE/BE re-prepend their byte-order
  /// mark so the exact byte order is preserved.
  static func encode(_ text: String, as encoding: String.Encoding) throws -> Data {
    switch encoding {
    case .utf16LittleEndian:
      return try Data([0xFF, 0xFE]) + body(of: text, as: encoding)
    case .utf16BigEndian:
      return try Data([0xFE, 0xFF]) + body(of: text, as: encoding)
    default:
      return try body(of: text, as: encoding)
    }
  }

  private static func body(of text: String, as encoding: String.Encoding) throws -> Data {
    guard let data = text.data(using: encoding, allowLossyConversion: false) else {
      throw CodingError.unrepresentable(encoding)
    }
    return data
  }

  private static func decode(_ data: Data, as encoding: String.Encoding) -> TextDocument? {
    guard let text = String(data: data, encoding: encoding), isProbablyText(text) else {
      return nil
    }
    return TextDocument(text: text, encoding: encoding)
  }

  private static func isProbablyText(_ text: String) -> Bool {
    !text.unicodeScalars.contains { scalar in
      let value = scalar.value
      return value == 0
        || (value < 0x20 && value != 0x09 && value != 0x0A && value != 0x0D)
        || (value >= 0x7F && value <= 0x9F)
    }
  }

  private static let fallbackEncodings: [String.Encoding] = [
    .utf8,
    .shiftJIS,
    .windowsCP1252,
    .isoLatin1,
  ]
}

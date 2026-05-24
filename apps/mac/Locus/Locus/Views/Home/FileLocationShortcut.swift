import Foundation

protocol FileLocationShortcut: Identifiable {
  var url: URL { get }
  var displayName: String { get }
  var path: String { get }
}

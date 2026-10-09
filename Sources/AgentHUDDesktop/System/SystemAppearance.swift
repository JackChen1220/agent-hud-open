import Foundation

enum SystemAppearance {
    /// The menu bar follows the system setting even when the app forces its own appearance.
    static var isLight: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased() != "dark"
    }
}

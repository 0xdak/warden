import Foundation

/// Every user-visible brand string lives here (plus `scripts/brand.env` for the bundle/build side).
/// Renaming the product = edit this file + brand.env.
public enum Brand {
    public static let appName = "Warden"
    public static let tagline = "A checkpoint between your coding agents and your Mac."
    public static let bundleID = "com.dakcyber.warden"
    public static let website = URL(string: "https://github.com/0xdak/warden")!
    public static let supportEmail = "ali@dakcyber.com"

    /// File name of the hook CLI (inside the bundle and at the stable install path).
    public static let hookBinaryName = "warden-hook"
    /// Folder under ~/Library/Application Support.
    public static let supportFolderName = "Warden"
    /// Prefix of every environment variable the app and hook read (WARDEN_HOME_OVERRIDE, …).
    public static let envPrefix = "WARDEN_"
    /// Prefix for UserDefaults keys, queue labels, etc.
    public static let identifierPrefix = bundleID

    /// Running version from the bundle (falls back when run unbundled).
    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
    public static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
}

import Foundation

/// Protection policy for the durable local files the app must touch while the device is locked.
///
/// The offline capture and the mutation journal are written from paths that do not wait for the
/// scene to become active: a WatchConnectivity relay can wake the app in a pocket, and a Live
/// Activity intent runs without unlocking the phone. `NSFileProtectionComplete` refuses both
/// reads and writes in that state, and the resulting "you don't have permission" error looks like
/// a corrupt file. `completeUntilFirstUserAuthentication` keeps the data encrypted at rest but
/// available after the owner's first unlock, which is the class for background work.
enum DurableFileProtection {
    static let type: FileProtectionType = .completeUntilFirstUserAuthentication

    /// An atomic replacement carries the protection option onto the new file, so a file left with
    /// the old complete class is healed by the next successful write.
    static let writingOptions: Data.WritingOptions = [
        .atomic,
        .completeFileProtectionUntilFirstUserAuthentication,
    ]

    /// True when the OS refused to open a file because its protection class key is unavailable,
    /// which on an app container means the device is locked or has not been unlocked since boot.
    static func isAccessDenied(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == NSCocoaErrorDomain else { return false }
        return error.code == NSFileReadNoPermissionError
            || error.code == NSFileWriteNoPermissionError
    }

    /// Moves a file written by an older build off `NSFileProtectionComplete`. This succeeds while
    /// the device is unlocked; while it is locked the key is unavailable and the caller must retry
    /// later. Returns whether the file now carries the background-accessible class.
    @discardableResult
    static func adopt(at url: URL) -> Bool {
        guard let current = currentType(at: url) else { return false }
        guard current != type else { return true }
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: type], ofItemAtPath: url.path
            )
            return true
        } catch {
            return false
        }
    }

    /// The protection class the filesystem reports, or nil when the platform does not expose one.
    static func currentType(at url: URL) -> FileProtectionType? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        if let raw = attributes[.protectionKey] as? String {
            return FileProtectionType(rawValue: raw)
        }
        return attributes[.protectionKey] as? FileProtectionType
    }
}

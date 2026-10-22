//
//  SandboxSupport.swift
//  extension_poc
//
//  Things that make the app work INSIDE the App Sandbox (App Store builds):
//  • remembering folders the user picked (security-scoped bookmarks),
//  • finding the real home folder (in the sandbox "home" is the app's container),
//  • unzipping Xcode's build logs in-process (sandboxed apps can't run /usr/bin/gzip).
//

import Foundation

nonisolated enum SandboxSupport {

    /// True when the app is actually running inside the App Sandbox.
    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// The user's real home folder (not the sandbox container).
    static var realHome: URL {
        if let home = getpwuid(getuid())?.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: home), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Where Xcode keeps build products and logs by default.
    static var defaultDerivedData: URL {
        realHome.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
    }

    // MARK: - Remember folders the user picked

    static func saveBookmark(for url: URL, key: String) {
        if let data = try? url.bookmarkData(options: [.withSecurityScope],
                                            includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Resolves a saved folder and starts access to it (needed in the sandbox).
    static func resolveBookmark(key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        if stale { saveBookmark(for: url, key: key) }
        return url
    }

    // MARK: - gzip, in-process

    /// Decompresses a .gz / .xcactivitylog file without running any tool.
    static func gunzip(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0 {                                   // extra field
            guard index + 2 <= bytes.count else { return nil }
            index += 2 + (Int(bytes[index]) | Int(bytes[index + 1]) << 8)
        }
        if flags & 0x08 != 0 {                                   // file name
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            index += 1
        }
        if flags & 0x10 != 0 {                                   // comment
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            index += 1
        }
        if flags & 0x02 != 0 { index += 2 }                      // header checksum
        guard index < bytes.count - 8 else { return nil }
        // The rest (minus the 8-byte trailer) is raw DEFLATE, which Apple calls ".zlib".
        let deflated = Data(bytes[index..<(bytes.count - 8)]) as NSData
        return try? deflated.decompressed(using: .zlib) as Data
    }
}

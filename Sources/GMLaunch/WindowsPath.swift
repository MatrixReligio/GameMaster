import Foundation

/// Maps between Windows-style paths inside a bottle and unix paths.
/// Wine's default drives: C:\ → <prefix>/drive_c, Z:\ → /.
public enum WindowsPath {
    public static func toUnix(_ windowsPath: String, prefix: URL) -> URL {
        let normalized = windowsPath.replacingOccurrences(of: "\\", with: "/")
        let upper = normalized.uppercased()
        if upper.hasPrefix("C:/") {
            return prefix.appendingPathComponent("drive_c" + String(normalized.dropFirst(2)))
        }
        if upper.hasPrefix("Z:/") {
            return URL(fileURLWithPath: String(normalized.dropFirst(2)))
        }
        // Unknown drive letters fall back to the prefix's dosdevices mapping.
        let drive = normalized.prefix(1).lowercased()
        return prefix.appendingPathComponent("dosdevices/\(drive):" + String(normalized.dropFirst(2)))
    }

    public static func toWindows(_ unix: URL, prefix: URL) -> String {
        let path = unix.path
        let driveC = prefix.appendingPathComponent("drive_c").path
        if path.hasPrefix(driveC + "/") || path == driveC {
            let rest = String(path.dropFirst(driveC.count))
            return "C:" + rest.replacingOccurrences(of: "/", with: "\\")
        }
        return "Z:" + path.replacingOccurrences(of: "/", with: "\\")
    }
}

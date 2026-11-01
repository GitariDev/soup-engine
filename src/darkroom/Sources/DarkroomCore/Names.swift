import Foundation

/// How the camera names things. See `se_file_no` in prints.c and `se_out_name`
/// in develop.c. Digits are ASCII only.
public enum CardName {
    private static func isDigit(_ b: UInt8) -> Bool { b >= 48 && b <= 57 }

    /// A CR2 by name, in any case. Names starting with `.` are macOS's leavings.
    public static func isCR2(_ name: String) -> Bool {
        !name.hasPrefix(".") && name.lowercased().hasSuffix(".cr2")
    }

    /// The four digits before the extension, or nil.
    public static func digits(_ name: String) -> String? {
        let u = Array(name.utf8), n = u.count
        guard n >= 8, u[n - 4] == 46 else { return nil }
        let d = u[(n - 8)..<(n - 4)]
        guard d.allSatisfy(isDigit) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    /// The digits of an `FLM_nnnn.JPG`, in any case, or nil for any other name.
    public static func printDigits(_ name: String) -> String? {
        let low = name.lowercased()
        guard low.utf8.count == 12, low.hasPrefix("flm_"), low.hasSuffix(".jpg") else { return nil }
        return digits(name)
    }

    /// Three digits then five characters, as `100CANON`.
    public static func isDCFFolder(_ name: String) -> Bool {
        let u = Array(name.utf8)
        guard u.count == 8, u[0..<3].allSatisfy(isDigit) else { return false }
        return u[3...].allSatisfy { isDigit($0) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 95 }
    }

    /// The folder number of a DCF folder. Any other folder has none, even one
    /// that starts with digits: "2024 trip" is not folder 202.
    public static func folderNumber(_ name: String) -> Int? {
        isDCFFolder(name) ? Int(name.prefix(3)) : nil
    }
}

import Foundation

public enum ByteFormat {
    /// Binary units, because the RAM size that macOS reports is a power of two.
    public static func string(_ bytes: UInt64) -> String {
        let (value, unit) = parts(bytes)
        return "\(value) \(unit)"
    }

    public static func parts(_ bytes: UInt64) -> (value: String, unit: String) {
        let gigabyte = Double(1 << 30)
        let megabyte = Double(1 << 20)
        let value = Double(bytes)
        if value >= gigabyte {
            return (decimal(value / gigabyte), "GB")
        }
        if value >= megabyte {
            return (String(Int((value / megabyte).rounded())), "MB")
        }
        return (String(Int((value / 1024).rounded())), "KB")
    }

    public static func whole(_ bytes: UInt64) -> String {
        let gigabytes = Double(bytes) / Double(1 << 30)
        if gigabytes >= 1, gigabytes == gigabytes.rounded() {
            return "\(Int(gigabytes)) GB"
        }
        return string(bytes)
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

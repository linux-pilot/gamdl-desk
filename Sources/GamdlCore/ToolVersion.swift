import Foundation

/// Version numbers printed by a tool's `--version`.
public enum ToolVersion {
    /// The first version number in the output: "4.0.2" from "Gamdl 4.0.2", "0.13.6" from "uv 0.13.6 (…)".
    public static func find(in lines: [String]) -> String? {
        lines.lazy.compactMap { $0.firstMatch(of: /\d+\.\d+(\.\d+)?/) }.first.map { String($0.output.0) }
    }

    public static func major(_ version: String) -> Int? {
        Int(version.prefix { $0.isNumber })
    }

    /// Whether `version` is later than `current`, comparing numbers part by part: "1.10.0" > "1.9",
    /// "v1.3" > "1.2.9", "1.2" == "1.2.0". Not a version number at all: false.
    public static func isNewer(_ version: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int]? {
            guard let match = v.firstMatch(of: /\d+(\.\d+)*/) else { return nil }
            return match.output.0.split(separator: ".").compactMap { Int($0) }
        }
        guard let new = parts(version), let old = parts(current) else { return false }
        for i in 0..<max(new.count, old.count) {
            let a = i < new.count ? new[i] : 0, b = i < old.count ? old[i] : 0
            if a != b { return a > b }
        }
        return false
    }
}

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
}

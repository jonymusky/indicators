import Foundation

/// Reads another app's generic password through `/usr/bin/security`. The "Always Allow" answer is
/// granted to Apple's signed binary, so it survives rebuilds of Indicators (unlike SecItemCopyMatching).
public enum KeychainCLI {
    public static func read(service: String, account: String? = nil) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        var arguments = ["find-generic-password", "-s", service]
        if let account { arguments += ["-a", account] }
        process.arguments = arguments + ["-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        // `security -w` prints the raw value followed by a newline.
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

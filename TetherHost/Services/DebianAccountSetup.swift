import Foundation

/// Validates the account details before any VM files are created. These values
/// are held only by the creation sheet and passed directly to seed generation.
public enum DebianAccountSetup {
    public static func usernameError(_ username: String) -> String? {
        guard !username.isEmpty else { return "Enter a Debian username." }
        guard username.utf8.count <= 32,
              let first = username.utf8.first, (97...122).contains(first),
              username.utf8.dropFirst().allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 }),
              !["root", "daemon", "bin", "sys", "nobody", "www-data"].contains(username) else {
            return "Use 1–32 lowercase letters, digits, underscores, or hyphens, starting with a letter."
        }
        return nil
    }

    public static func passwordError(_ password: String, confirmation: String) -> String? {
        guard password.utf8.count >= 12 else { return "Use at least 12 characters for the Debian password." }
        guard password.utf8.count <= 128,
              password.utf8.allSatisfy({ (32...126).contains($0) }) else {
            return "Use at most 128 printable characters for the Debian password."
        }
        guard password == confirmation else { return "The Debian passwords do not match." }
        return nil
    }
}

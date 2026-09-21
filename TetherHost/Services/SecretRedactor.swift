import Foundation

public struct SecretRedactor: Sendable {
    private let literalSecrets: [String]

    public init(literalSecrets: [String] = []) {
        self.literalSecrets = literalSecrets.filter { !$0.isEmpty }
    }

    public func redact(_ input: String) -> String {
        var output = input
        for secret in literalSecrets.sorted(by: { $0.count > $1.count }) {
            output = output.replacingOccurrences(of: secret, with: "<redacted>")
        }

        let patterns = [
            #"(?i)(authorization\s*:\s*bearer\s+)[^\s,;]+"#,
            #"(?i)(\b(?:token|api[_-]?key|secret|password)\b\s*[=:]\s*)[^\s,;&]+"#,
            #"(?i)([?&](?:token|api[_-]?key|secret|password)=)[^&#\s]+"#,
            #"(?i)(https?://[^/@:\s]+:)[^/@\s]+(@)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = regex.stringByReplacingMatches(
                in: output,
                range: range,
                withTemplate: "$1<redacted>$2"
            )
        }
        return output
    }
}

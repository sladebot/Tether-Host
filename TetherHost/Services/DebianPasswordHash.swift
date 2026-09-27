import CryptoKit
import Foundation

/// SHA-512 crypt, the password format accepted by Debian's shadow database.
/// Only this salted hash is written to the NoCloud image.
enum DebianPasswordHash {
    private static let alphabet = Array("./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    static func make(_ password: String, salt: String = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))) -> String {
        let key = Array(password.utf8)
        let saltBytes = Array(salt.utf8)
        func digest(_ bytes: [UInt8]) -> [UInt8] { Array(SHA512.hash(data: Data(bytes))) }

        let alternate = digest(key + saltBytes + key)
        var context = key + saltBytes
        for index in 0..<key.count { context.append(alternate[index % alternate.count]) }
        var count = key.count
        while count > 0 {
            context += (count & 1) == 1 ? alternate : key
            count >>= 1
        }
        var result = digest(context)

        let repeatedKey = digest(Array(repeating: key, count: key.count).flatMap { $0 })
        let p = (0..<key.count).map { repeatedKey[$0 % repeatedKey.count] }
        let repeatedSalt = digest(Array(repeating: saltBytes, count: 16 + Int(result[0])).flatMap { $0 })
        let s = (0..<saltBytes.count).map { repeatedSalt[$0 % repeatedSalt.count] }

        for round in 0..<5000 {
            var bytes = (round & 1) == 1 ? p : result
            if round % 3 != 0 { bytes += s }
            if round % 7 != 0 { bytes += p }
            bytes += (round & 1) == 1 ? result : p
            result = digest(bytes)
        }

        let groups: [(Int, Int, Int, Int)] = [
            (0,21,42,4), (22,43,1,4), (44,2,23,4), (3,24,45,4),
            (25,46,4,4), (47,5,26,4), (6,27,48,4), (28,49,7,4),
            (50,8,29,4), (9,30,51,4), (31,52,10,4), (53,11,32,4),
            (12,33,54,4), (34,55,13,4), (56,14,35,4), (15,36,57,4),
            (37,58,16,4), (59,17,38,4), (18,39,60,4), (40,61,19,4),
            (62,20,41,4)
        ]
        var encoded = ""
        for (a,b,c,length) in groups {
            var value = Int(result[a]) << 16 | Int(result[b]) << 8 | Int(result[c])
            for _ in 0..<length {
                encoded.append(alphabet[value & 0x3f])
                value >>= 6
            }
        }
        var final = Int(result[63])
        for _ in 0..<2 {
            encoded.append(alphabet[final & 0x3f])
            final >>= 6
        }
        return "$6$\(salt)$\(encoded)"
    }
}

import CryptoKit
import Foundation

enum CryptoHelpers {
    static func sha256Hex(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func md5Hex(_ value: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func randomSalt(length: Int = 6) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<length).map { _ in alphabet.randomElement()! })
    }

    static func unixTimestamp() -> String {
        String(Int(Date().timeIntervalSince1970))
    }
}

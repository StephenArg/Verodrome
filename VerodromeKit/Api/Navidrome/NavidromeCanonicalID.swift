import CryptoKit
import Foundation

/// Reimplementation of Navidrome 0.64.0's canonical ID transform, so a client that already
/// holds pre-migration IDs can produce the post-migration equivalents locally without a
/// server round-trip.
///
/// This mirrors the `canonicalID` function from Navidrome's
/// `db/migrations/20260720015443_uniform_canonical_ids.go`, verified byte-for-byte against
/// every golden vector in `id_canonical_test.go` and `model/id/id_test.go`. Any drift from
/// Navidrome's algorithm will silently corrupt IDs (and therefore filenames, cache-meta
/// keys, and DB rows), so this file is intentionally a straight port and covered by the
/// same golden vectors — do not "clean up" edge cases without re-verifying.
public enum NavidromeCanonicalID {
    /// Go's `big.Int.Text(62)` alphabet. Note the ordering: digits, then *lowercase*, then
    /// uppercase, which is not the more common URL-safe alphabet.
    static let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

    private static let index: [Character: Int] = {
        var m: [Character: Int] = [:]
        for (i, c) in alphabet.enumerated() { m[c] = i }
        return m
    }()

    /// Map any historical Navidrome ID shape to the canonical 22-char base62 encoding of a
    /// 128-bit value. Unrecognized shapes (including the empty string and 10-char share
    /// IDs) pass through unchanged.
    public static func canonical(_ s: String) -> String {
        switch s.count {
        case 22:
            // Base62 that overflows 128 bits gets deterministically remapped via MD5 of
            // the ID's ASCII bytes; hash-family IDs already fit and pass through.
            guard let v = decodeBase62(s) else { return s }
            if bitLength(v) <= 128 { return s }
            let md5 = Insecure.MD5.hash(data: Data(s.utf8))
            return encode16(Array(md5))
        case 32:
            // Legacy pre-BFR 32-hex media_file / album IDs: value-preserving re-encode.
            guard let bytes = hexDecode(s) else { return s }
            return encode16(bytes)
        case 36:
            // Legacy playlist UUIDs: value-preserving re-encode. Must match Go's exact
            // dash-position check; anything else passes through.
            let chars = Array(s)
            guard chars[8] == "-", chars[13] == "-", chars[18] == "-", chars[23] == "-" else {
                return s
            }
            let hex = String(chars[0..<8]) + String(chars[9..<13])
                + String(chars[14..<18]) + String(chars[19..<23])
                + String(chars[24..<36])
            guard let bytes = hexDecode(hex) else { return s }
            return encode16(bytes)
        default:
            return s
        }
    }

    /// Encode a 16-byte value as the canonical 22-char zero-padded base62 ID.
    public static func encode16(_ bytes: [UInt8]) -> String {
        precondition(bytes.count == 16, "canonical id encoding takes exactly 16 bytes")
        // Little-endian base-2^32 limbs, most-significant first. big.Int in Go treats the
        // input as big-endian, so limb[0] is the top 4 bytes.
        var limbs: [UInt32] = [
            UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]),
            UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7]),
            UInt32(bytes[8]) << 24 | UInt32(bytes[9]) << 16 | UInt32(bytes[10]) << 8 | UInt32(bytes[11]),
            UInt32(bytes[12]) << 24 | UInt32(bytes[13]) << 16 | UInt32(bytes[14]) << 8 | UInt32(bytes[15]),
        ]
        // Divide-by-62 in place, emitting digits from least significant to most, then
        // reverse and left-pad to 22. The all-zero input encodes as "0", which pads to the
        // 22-char zero string that Go's `%022s` produces.
        var digits: [Character] = []
        digits.reserveCapacity(22)
        while !limbs.allSatisfy({ $0 == 0 }) {
            var remainder: UInt64 = 0
            for i in 0..<limbs.count {
                let acc = (remainder << 32) | UInt64(limbs[i])
                limbs[i] = UInt32(acc / 62)
                remainder = acc % 62
            }
            digits.append(alphabet[Int(remainder)])
        }
        if digits.isEmpty { digits.append("0") }
        while digits.count < 22 { digits.append("0") }
        return String(digits.reversed())
    }

    /// Parse a 22-char base62 string into 128-bit limbs. Returns nil for any character
    /// outside the alphabet or a leading sign, matching Go's `big.Int.SetString` semantics
    /// with base=62. The returned array is up to 5 32-bit limbs, most-significant first;
    /// callers should check `bitLength` before assuming it fits in 128 bits.
    static func decodeBase62(_ s: String) -> [UInt32]? {
        guard let first = s.first, first != "+", first != "-" else { return nil }
        var limbs: [UInt32] = [0]
        for c in s {
            guard let digit = index[c] else { return nil }
            // multiply limbs by 62
            var carry: UInt64 = UInt64(digit)
            for i in stride(from: limbs.count - 1, through: 0, by: -1) {
                let acc = UInt64(limbs[i]) &* 62 &+ carry
                limbs[i] = UInt32(truncatingIfNeeded: acc)
                carry = acc >> 32
            }
            while carry != 0 {
                limbs.insert(UInt32(truncatingIfNeeded: carry), at: 0)
                carry >>= 32
            }
        }
        return limbs
    }

    /// Bit length of a multi-limb integer (most-significant-first). Zero returns 0, which
    /// mirrors Go's `big.Int.BitLen` and correctly treats zero as fitting in any bit width.
    static func bitLength(_ limbs: [UInt32]) -> Int {
        var i = 0
        while i < limbs.count && limbs[i] == 0 { i += 1 }
        if i == limbs.count { return 0 }
        let highLimb = limbs[i]
        let remainingLimbs = limbs.count - i - 1
        // 32 minus leading zeros of the top non-zero limb, plus the full lower limbs.
        return (32 - highLimb.leadingZeroBitCount) + 32 * remainingLimbs
    }

    /// Strict hex decode: 32 lowercase-or-uppercase hex chars → 16 bytes. Any non-hex
    /// character (including whitespace) returns nil, so the caller falls through to the
    /// unchanged-passthrough branch.
    private static func hexDecode(_ s: String) -> [UInt8]? {
        guard s.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(s.count / 2)
        var high: UInt8?
        for c in s {
            let v: UInt8
            switch c {
            case "0"..."9": v = UInt8(c.asciiValue! - Character("0").asciiValue!)
            case "a"..."f": v = UInt8(c.asciiValue! - Character("a").asciiValue!) + 10
            case "A"..."F": v = UInt8(c.asciiValue! - Character("A").asciiValue!) + 10
            default: return nil
            }
            if let h = high {
                out.append((h << 4) | v)
                high = nil
            } else {
                high = v
            }
        }
        return out
    }
}

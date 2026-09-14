import XCTest
@testable import VerodromeKit

/// The 16 golden vectors from Navidrome 0.64.0's own test suite. These are the correctness
/// contract for `NavidromeCanonicalID` — every one must pass byte-for-byte, or the client
/// migration will disagree with what the server did and corrupt IDs. The source vectors
/// live in `db/migrations/id_canonical_test.go` and `model/id/id_test.go` on the tag.
final class NavidromeCanonicalIDTests: XCTestCase {

    // MARK: - Encode16 goldens (from model/id/id_test.go)

    func testEncode16AllZeros() {
        XCTAssertEqual(NavidromeCanonicalID.encode16([UInt8](repeating: 0, count: 16)),
                       "0000000000000000000000")
    }

    func testEncode16AllFF() {
        XCTAssertEqual(NavidromeCanonicalID.encode16([UInt8](repeating: 0xff, count: 16)),
                       "7N42dgm5tFLK9N8MT7fHC7")
    }

    func testEncode16MixedValue() {
        // Round-trip vector from Navidrome's own test suite.
        let bytes: [UInt8] = [0xe3, 0xb7, 0xfc, 0x2a, 0xe9, 0x44, 0x7b, 0xbe,
                              0xc3, 0x7a, 0x13, 0xbf, 0x91, 0x6e, 0x3c, 0xf6]
        XCTAssertEqual(NavidromeCanonicalID.encode16(bytes), "6VHl3uR4kss6sUPKA8Cwnk")
    }

    // MARK: - canonical() goldens (from db/migrations/id_canonical_test.go)

    func testHashFamilyIdIsKept() {
        // Fits in 128 bits, so it's already canonical.
        XCTAssertEqual(NavidromeCanonicalID.canonical("5cLJPkLA5DK2BADhoeotPk"),
                       "5cLJPkLA5DK2BADhoeotPk")
    }

    func testOverflowingRandomIdIsRemappedViaMd5() {
        // "zzzzzzzzzzzzzzzzzzzzzz" is a 22-char base62 value that overflows 128 bits, so it
        // is deterministically remapped through MD5. This is the case ~87% of pre-migration
        // NewRandom nanoids fall into.
        XCTAssertEqual(NavidromeCanonicalID.canonical("zzzzzzzzzzzzzzzzzzzzzz"),
                       "3LyqmwQBm5IRqlVjNYASwb")
    }

    func testLegacy32HexIsReencodedValuePreserving() {
        XCTAssertEqual(NavidromeCanonicalID.canonical("e3b7fc2ae9447bbec37a13bf916e3cf6"),
                       "6VHl3uR4kss6sUPKA8Cwnk")
    }

    func testPlaylistUuidIsReencodedValuePreserving() {
        XCTAssertEqual(NavidromeCanonicalID.canonical("f47ac10b-58cc-4372-a567-0e02b2c3d479"),
                       "7rke2SAWaicSeSYzkhww6R")
    }

    func testEmptyPassesThrough() {
        XCTAssertEqual(NavidromeCanonicalID.canonical(""), "")
    }

    func testShareId10CharsPassesThrough() {
        // Share IDs are explicitly exempt in Navidrome's migration, so public URLs keep
        // working across the upgrade.
        XCTAssertEqual(NavidromeCanonicalID.canonical("aB3xY9kQz1"), "aB3xY9kQz1")
    }

    func testTruncatedFinamp16CharsPassesThrough() {
        XCTAssertEqual(NavidromeCanonicalID.canonical("0123456789abcdef"),
                       "0123456789abcdef")
    }

    func testTwentyTwoCharsWithNonBase62PassesThrough() {
        XCTAssertEqual(NavidromeCanonicalID.canonical("!!!!!!!!!!!!!!!!!!!!!!"),
                       "!!!!!!!!!!!!!!!!!!!!!!")
    }

    func testThirtyTwoCharsNonHexPassesThrough() {
        XCTAssertEqual(NavidromeCanonicalID.canonical("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"),
                       "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz")
    }

    func testThirtySixCharsWithoutUuidDashesPassesThrough() {
        XCTAssertEqual(NavidromeCanonicalID.canonical("000000000000000000000000000000000000"),
                       "000000000000000000000000000000000000")
    }

    // MARK: - Structural invariants

    /// Every canonicalization must be idempotent: applying it twice yields the same
    /// answer as applying it once. This is what lets the migration hook run safely on
    /// re-launch without checking state.
    func testIdempotentForEveryShape() {
        for s in ["5cLJPkLA5DK2BADhoeotPk",
                  "zzzzzzzzzzzzzzzzzzzzzz",
                  "e3b7fc2ae9447bbec37a13bf916e3cf6",
                  "f47ac10b-58cc-4372-a567-0e02b2c3d479"] {
            let once = NavidromeCanonicalID.canonical(s)
            let twice = NavidromeCanonicalID.canonical(once)
            XCTAssertEqual(twice, once, "not idempotent for \(s): \(once) vs \(twice)")
        }
    }

    // MARK: - Base62 decoder edge cases

    func testDecodeBase62RejectsSignedInputs() {
        // Go's big.Int.SetString rejects leading sign; matching that keeps the pass-through
        // rule identical.
        XCTAssertNil(NavidromeCanonicalID.decodeBase62("-000000000000000000001"))
        XCTAssertNil(NavidromeCanonicalID.decodeBase62("+000000000000000000001"))
    }

    func testBitLengthOfAllOnes128() {
        // 0xFF...FF (16 bytes) decodes to exactly 128 bits.
        let ffId = NavidromeCanonicalID.encode16([UInt8](repeating: 0xff, count: 16))
        guard let limbs = NavidromeCanonicalID.decodeBase62(ffId) else {
            XCTFail("decode failed for all-ones id"); return
        }
        XCTAssertEqual(NavidromeCanonicalID.bitLength(limbs), 128)
    }

    func testBitLengthOfZero() {
        // The all-zero base62 string decodes to 0, which has bit-length 0.
        guard let limbs = NavidromeCanonicalID.decodeBase62("0000000000000000000000") else {
            XCTFail("decode failed for zero id"); return
        }
        XCTAssertEqual(NavidromeCanonicalID.bitLength(limbs), 0)
    }
}

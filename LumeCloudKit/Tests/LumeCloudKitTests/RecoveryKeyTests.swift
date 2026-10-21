import Foundation
@testable import LumeCloudKit
import Testing

@Suite("Recovery key")
struct RecoveryKeyTests {
    @Test func roundTripsRandomKeys() throws {
        for _ in 0 ..< 200 {
            let keys = LumeCloudKeys.generate()
            let rendered = LumeCloudRecoveryKey.encode(keys)
            #expect(try LumeCloudRecoveryKey.decode(rendered) == keys.rootKey)
            #expect(try LumeCloudRecoveryKey.keys(from: rendered) == keys)
        }
    }

    @Test func formatIsGroupedByFour() throws {
        let rendered = try LumeCloudRecoveryKey.encode(rootKey: Data(0 ..< 32))
        let groups = rendered.split(separator: "-")
        #expect(groups.count == 14)
        #expect(groups.dropLast().allSatisfy { $0.count == 4 })
        #expect(groups.last?.count == 1)
        #expect(rendered.count == 53 + 13)
        // Data symbols never use I, L, O or U.
        #expect(!groups.dropLast().joined().contains { "ILOU".contains($0) })
    }

    @Test func knownRendering() throws {
        // 0x00…0x1f, computed independently (Python).
        let rendered = try LumeCloudRecoveryKey.encode(rootKey: Data(0 ..< 32))
        #expect(rendered == "000G-40R4-0M30-E209-185G-R38E-1W81-24GK-2GAH-C5RR-34D1-P70X-3RFG-*")
        let allFF = try LumeCloudRecoveryKey.encode(rootKey: Data(repeating: 0xFF, count: 32))
        // 51 full symbols of 11111 and a last symbol of 1 + 0000.
        #expect(allFF.replacingOccurrences(of: "-", with: "").dropLast() == Substring(String(repeating: "Z", count: 51) + "G"))
    }

    @Test func decodingIsLenient() throws {
        let root = Data(0 ..< 32)
        let rendered = try LumeCloudRecoveryKey.encode(rootKey: root)
        let compact = rendered.replacingOccurrences(of: "-", with: "")
        #expect(try LumeCloudRecoveryKey.decode(rendered.lowercased()) == root)
        #expect(try LumeCloudRecoveryKey.decode(compact) == root)
        #expect(try LumeCloudRecoveryKey.decode("  " + rendered.replacingOccurrences(of: "-", with: " ") + "\n") == root)
        // O → 0 and I/L → 1.
        let confusable = rendered.replacingOccurrences(of: "0", with: "o").replacingOccurrences(of: "1", with: "l")
        #expect(confusable != rendered.lowercased())
        #expect(try LumeCloudRecoveryKey.decode(confusable) == root)
        #expect(try LumeCloudRecoveryKey.decode(rendered.replacingOccurrences(of: "1", with: "I")) == root)
    }

    @Test func checksumCatchesEverySingleSymbolTypo() throws {
        let keys = LumeCloudKeys.generate()
        let symbols = Array(LumeCloudRecoveryKey.encode(keys).replacingOccurrences(of: "-", with: ""))
        var caught = 0
        for index in symbols.indices.dropLast() {
            for replacement in LumeCloudRecoveryKey.alphabet where replacement != symbols[index] {
                var typo = symbols
                typo[index] = replacement
                #expect(throws: LumeCloudCryptoError.recoveryKeyChecksumMismatch) {
                    try LumeCloudRecoveryKey.decode(String(typo))
                }
                caught += 1
            }
        }
        #expect(caught == 52 * 31)
    }

    @Test func checksumCatchesAdjacentSwaps() throws {
        let symbols = Array(LumeCloudRecoveryKey.encode(LumeCloudKeys.generate()).replacingOccurrences(of: "-", with: ""))
        for index in 0 ..< 51 where symbols[index] != symbols[index + 1] {
            var swapped = symbols
            swapped.swapAt(index, index + 1)
            #expect(throws: LumeCloudCryptoError.recoveryKeyChecksumMismatch) {
                try LumeCloudRecoveryKey.decode(String(swapped))
            }
        }
    }

    @Test func wrongCheckSymbolIsCaught() throws {
        let rendered = try LumeCloudRecoveryKey.encode(rootKey: Data(0 ..< 32))
        let check = rendered.last!
        let other: Character = check == "*" ? "~" : "*"
        #expect(throws: LumeCloudCryptoError.recoveryKeyChecksumMismatch) {
            try LumeCloudRecoveryKey.decode(String(rendered.dropLast()) + String(other))
        }
    }

    @Test func malformedInputIsRejected() throws {
        let rendered = try LumeCloudRecoveryKey.encode(rootKey: Data(0 ..< 32))
        #expect(throws: LumeCloudCryptoError.invalidRecoveryKey) { try LumeCloudRecoveryKey.decode("") }
        #expect(throws: LumeCloudCryptoError.invalidRecoveryKey) { try LumeCloudRecoveryKey.decode(String(rendered.dropLast())) }
        #expect(throws: LumeCloudCryptoError.invalidRecoveryKey) { try LumeCloudRecoveryKey.decode(rendered + "0") }
        // U and the check-only symbols aren't valid data symbols.
        #expect(throws: LumeCloudCryptoError.invalidRecoveryKey) { try LumeCloudRecoveryKey.decode("U" + rendered.dropFirst()) }
        #expect(throws: LumeCloudCryptoError.invalidRecoveryKey) { try LumeCloudRecoveryKey.decode("*" + rendered.dropFirst()) }
        #expect(throws: LumeCloudCryptoError.invalidKeyLength(expected: 32)) {
            try LumeCloudRecoveryKey.encode(rootKey: Data(count: 16))
        }
    }

    @Test func nonZeroPaddingBitsAreRejected() throws {
        // A last data symbol with padding bits set, and a matching check symbol.
        var digits = Array(repeating: 0, count: 52)
        digits[51] = 0b00001
        let check = LumeCloudRecoveryKey.checkAlphabet[LumeCloudRecoveryKey.checksum(digits)]
        let text = String(digits.map { LumeCloudRecoveryKey.alphabet[$0] }) + String(check)
        #expect(throws: LumeCloudCryptoError.invalidRecoveryKey) { try LumeCloudRecoveryKey.decode(text) }
    }
}

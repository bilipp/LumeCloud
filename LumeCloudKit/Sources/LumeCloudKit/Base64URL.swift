import Foundation

/// Base64url without padding (RFC 4648 §5), the encoding of every binary value
/// on the wire (PROTOCOL.md §1).
public enum Base64URL {
    /// Encodes `data` as base64url without `=` padding.
    public static func encode(_ data: some DataProtocol) -> String {
        var string = Data(data).base64EncodedString()
        string = string.replacingOccurrences(of: "+", with: "-")
        string = string.replacingOccurrences(of: "/", with: "_")
        while string.hasSuffix("=") {
            string.removeLast()
        }
        return string
    }

    /// Decodes base64url without padding. Returns `nil` for padding, the
    /// standard-alphabet characters `+`/`/`, whitespace, or an impossible length.
    public static func decode(_ string: String) -> Data? {
        guard string.utf8.allSatisfy(isURLAlphabet) else { return nil }
        guard string.utf8.count % 4 != 1 else { return nil }
        var base64 = string.replacingOccurrences(of: "-", with: "+")
        base64 = base64.replacingOccurrences(of: "_", with: "/")
        let remainder = base64.utf8.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }

    private static func isURLAlphabet(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A") ... UInt8(ascii: "Z"),
             UInt8(ascii: "a") ... UInt8(ascii: "z"),
             UInt8(ascii: "0") ... UInt8(ascii: "9"),
             UInt8(ascii: "-"), UInt8(ascii: "_"):
            true
        default:
            false
        }
    }
}

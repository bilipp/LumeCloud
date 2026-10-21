import Foundation

/// Local failures of the key, envelope, payload, recovery-key and pairing
/// helpers. None of them carries key material, plaintext or tokens.
public enum LumeCloudCryptoError: Error, Sendable, Equatable {
    /// A key or nonce has the wrong length (the associated value is the length that was expected).
    case invalidKeyLength(expected: Int)
    /// A value that should be base64url without padding isn't.
    case invalidBase64
    /// The envelope is too short to hold a version byte, nonce and tag.
    case malformedEnvelope
    /// The envelope's version byte isn't one this Kit knows. Per PROTOCOL.md
    /// §2.4 the caller skips the record, keeps it, and never overwrites or
    /// deletes it.
    case unsupportedEnvelopeVersion(UInt8)
    /// AES-GCM or HPKE authentication failed: wrong key, wrong `rid`, wrong
    /// pairing code, or tampered ciphertext.
    case authenticationFailed
    /// A recovery key has the wrong length or an invalid character.
    case invalidRecoveryKey
    /// A recovery key's checksum character doesn't match (most likely a typo).
    case recoveryKeyChecksumMismatch
    /// The payload JSON isn't valid or lacks `v`, `type`, `key` or `data`.
    case invalidPayload(String)
    /// The value can't be represented as JSON (a NaN or infinite number).
    case nonFiniteNumber
}

extension LumeCloudCryptoError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidKeyLength(expected):
            "The key must be \(expected) bytes long."
        case .invalidBase64:
            "The value isn't valid base64url."
        case .malformedEnvelope:
            "The encrypted record is malformed."
        case let .unsupportedEnvelopeVersion(version):
            "The encrypted record uses envelope version \(version), which this app doesn't support."
        case .authenticationFailed:
            "The data couldn't be decrypted. It was changed, or the key or code is wrong."
        case .invalidRecoveryKey:
            "That isn't a valid recovery key."
        case .recoveryKeyChecksumMismatch:
            "The recovery key has a typo. Check it and try again."
        case let .invalidPayload(reason):
            "The decrypted record isn't a valid payload (\(reason))."
        case .nonFiniteNumber:
            "A number can't be written as JSON."
        }
    }
}

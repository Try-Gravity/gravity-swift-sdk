import Foundation
import CryptoKit

/// SHA-256 hashing for PII fields, matching the normalization
/// used by the Gravity pixel and CAPI pipeline.
public struct HashedIdentity: Sendable {
    public let emailHash: String?
    public let hashedPhone: String?
}

/// Hash PII for attribution without sending raw values over the wire.
///
/// Normalization matches the Gravity pixel and CAPI pipeline:
/// - Email: `strip().lowercased()`
/// - Phone: digits only
///
/// - Parameters:
///   - email: Raw email address.
///   - phone: Raw phone number.
/// - Returns: A ``HashedIdentity`` with only the fields that hashed successfully.
public func hashPII(email: String? = nil, phone: String? = nil) -> HashedIdentity {
    let emailHash: String? = email.flatMap { raw in
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return sha256Hex(normalized)
    }

    let phoneHash: String? = phone.flatMap { raw in
        let digits = raw.unicodeScalars.filter(CharacterSet.decimalDigits.contains).map(Character.init)
        let normalized = String(digits)
        guard !normalized.isEmpty else { return nil }
        return sha256Hex(normalized)
    }

    return HashedIdentity(emailHash: emailHash, hashedPhone: phoneHash)
}

private func sha256Hex(_ input: String) -> String {
    let data = Data(input.utf8)
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}

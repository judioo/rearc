import CommonCrypto
import Foundation
import SQLite3
@testable import SidebarModel

/// Passwords and cookies in a Chromium profile on macOS are encrypted with
/// a key derived from the browser's Keychain item (`ImportBrowser
/// .safeStorageService`): PBKDF2-HMAC-SHA1 over the item's password, salt
/// `saltysalt`, 1003 rounds, 16 bytes; then AES-128-CBC with an IV of 16
/// spaces, PKCS#7 padding and a `v10` prefix (Chromium
/// `keychain_key_provider.mm`). Reading the item shows macOS's Keychain
/// prompt for that browser, so it happens only after the user asks for
/// that one browser's passwords (PROFILE-IMPORT §2.3). Nothing in ReArc
/// reads the Keychain: this entire file belongs to SidebarModelTests and is
/// excluded from every shipping target, in debug and release builds.
public enum ChromiumSafeStorage {
    static let prefix = Data("v10".utf8)
    static let salt = Data("saltysalt".utf8)
    static let rounds: UInt32 = 1003
    static let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)

    public static func key(password: String) -> Data? {
        var key = Data(count: kCCKeySizeAES128)
        let secret = Data(password.utf8)
        let status = key.withUnsafeMutableBytes { keyBytes in
            secret.withUnsafeBytes { secretBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        secretBytes.baseAddress?.assumingMemoryBound(to: CChar.self), secret.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), rounds,
                        keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128
                    )
                }
            }
        }
        return status == kCCSuccess ? key : nil
    }

    /// nil for anything that is not a `v10` blob this key opens.
    public static func decrypt(_ blob: Data, key: Data) -> Data? {
        guard blob.starts(with: prefix) else { return nil }
        return crypt(CCOperation(kCCDecrypt), blob.dropFirst(prefix.count), key: key)
    }

    /// The inverse, for fixtures.
    public static func encrypt(_ plaintext: Data, key: Data) -> Data? {
        crypt(CCOperation(kCCEncrypt), plaintext, key: key).map { prefix + $0 }
    }

    private static func crypt(_ operation: CCOperation, _ input: Data, key: Data) -> Data? {
        guard key.count == kCCKeySizeAES128 else { return nil }
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var written = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                inBytes.baseAddress, input.count, out.baseAddress, capacity, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return output.prefix(written)
    }
}

/// The one step that would raise the Keychain prompt. ReArc ships no
/// implementation: one is added with the consent UI, and only ever asked
/// for the single browser the user chose.
public protocol SafeStoragePasswordSource {
    func safeStoragePassword(for browser: ImportBrowser) throws -> String
}

/// The consent the passwords step records before it asks the Keychain,
/// one browser at a time and never remembered across imports.
public struct SecretImportConsent: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case passwords
        case cookies
    }

    public var browser: ImportBrowser
    public var kinds: Set<Kind>

    public init(browser: ImportBrowser, kinds: Set<Kind>) {
        self.browser = browser
        self.kinds = kinds
    }

    /// The sheet's text, said before macOS asks.
    public var explanation: String {
        let what = kinds.contains(.cookies) ? "saved passwords and sign-ins" : "saved passwords"
        return "To read \(browser.name)'s \(what), macOS will ask you to allow access to \u{201C}\(browser.safeStorageService)\u{201D} in your keychain. "
            + "Choose Allow (not Always Allow). ReArc reads it once for this import and does not keep it."
    }
}

/// A saved password from a copy of `Login Data` (`logins`: origin_url,
/// username_value, password_value, blacklisted_by_user).
public struct ImportedLogin: Equatable, Sendable {
    public var url: String
    public var username: String
    public var password: String
}

public enum ChromiumLoginReader {
    public static let fileName = "Login Data"

    /// Rows the key opens; never-save entries and undecryptable rows are skipped.
    public static func read(_ url: URL, key: Data) throws -> [ImportedLogin] {
        let snapshot = try SQLiteSnapshot(copying: url)
        defer { snapshot.remove() }
        return try ChromiumHistoryReader.withDatabase(snapshot.url) { db in
            var logins: [ImportedLogin] = []
            try ChromiumHistoryReader.query(db, "SELECT origin_url, username_value, password_value FROM logins WHERE blacklisted_by_user = 0") { row in
                guard let origin = sqlite3_column_text(row, 0), let bytes = sqlite3_column_blob(row, 2) else { return true }
                let blob = Data(bytes: bytes, count: Int(sqlite3_column_bytes(row, 2)))
                guard let plain = ChromiumSafeStorage.decrypt(blob, key: key),
                      let password = String(data: plain, encoding: .utf8) else { return true }
                let username = sqlite3_column_text(row, 1).map { String(cString: $0) } ?? ""
                logins.append(ImportedLogin(url: String(cString: origin), username: username, password: password))
                return true
            }
            return logins
        }
    }

    /// Chromium's password CSV (`name,url,username,password,note`), the
    /// format chrome://password-manager imports. The file is written to a
    /// private temporary folder and removed after the engine reads it.
    public static func csv(_ logins: [ImportedLogin]) -> String {
        func field(_ value: String) -> String {
            value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
                ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
        }
        let rows = logins.map { login in
            [URL(string: login.url)?.host() ?? login.url, login.url, login.username, login.password, ""].map(field).joined(separator: ",")
        }
        return (["name,url,username,password,note"] + rows).joined(separator: "\n") + "\n"
    }
}

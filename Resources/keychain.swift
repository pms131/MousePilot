// keychain: helper for scripts/build.sh, for the Security framework calls `security` cannot
// make without a terminal — the system password dialogs, and exporting one identity.
//
//   keychain create <keychain-path>                          new keychain; asks for its password
//   keychain unlock <keychain-path>                          asks for the password if locked
//   keychain export <name> <keychain-path> <out.p12> <pass>  exports the identity whose
//                                                            certificate is <name> (macOS asks
//                                                            to allow the export)
import Foundation
import Security

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("keychain: \(message)\n".utf8))
    exit(1)
}

func describe(_ status: OSStatus) -> String {
    "\(status) \((SecCopyErrorMessageString(status, nil) as String?) ?? "")"
}

func openKeychain(_ path: String) -> SecKeychain {
    var keychain: SecKeychain?
    let status = SecKeychainOpen(path, &keychain)
    guard status == errSecSuccess, let keychain else { fail("cannot open \(path): \(describe(status))") }
    return keychain
}

let args = CommandLine.arguments
guard args.count >= 3 else { fail("usage: keychain create|unlock <path> | export <name> <path> <out.p12> <pass>") }

switch args[1] {
case "create":
    var keychain: SecKeychain?
    let status = SecKeychainCreate(args[2], 0, nil, true, nil, &keychain)   // promptUser: new password
    guard status == errSecSuccess else { fail("create failed: \(describe(status))") }

case "unlock":
    let keychain = openKeychain(args[2])
    var state: SecKeychainStatus = 0
    let status = SecKeychainGetStatus(keychain, &state)
    guard status == errSecSuccess else { fail("cannot read status: \(describe(status))") }
    if state & SecKeychainStatus(kSecUnlockStateStatus) == 0 {
        let unlocked = SecKeychainUnlock(keychain, 0, nil, false)               // asks for the password
        guard unlocked == errSecSuccess else { fail("unlock failed: \(describe(unlocked))") }
    }

case "export":
    guard args.count == 6 else { fail("usage: keychain export <name> <keychain-path> <out.p12> <pass>") }
    let keychain = openKeychain(args[3])
    let query: [String: Any] = [
        kSecClass as String: kSecClassIdentity,
        kSecMatchSearchList as String: [keychain],
        kSecMatchLimit as String: kSecMatchLimitAll,
        kSecReturnRef as String: true,
    ]
    var result: CFTypeRef?
    let found = SecItemCopyMatching(query as CFDictionary, &result)
    guard found == errSecSuccess, let identities = result as? [SecIdentity] else {
        fail("no identities in \(args[3]): \(describe(found))")
    }
    let identity = identities.first { identity in
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { return false }
        return SecCertificateCopySubjectSummary(certificate) as String? == args[2]
    }
    guard let identity else { fail("no identity named \(args[2]) in \(args[3])") }
    var parameters = SecItemImportExportKeyParameters()
    parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
    parameters.passphrase = Unmanaged.passRetained(args[5] as AnyObject)
    var data: CFData?
    let exported = SecItemExport(identity, .formatPKCS12, [], &parameters, &data)
    guard exported == errSecSuccess, let data else { fail("export failed: \(describe(exported))") }
    guard FileManager.default.createFile(atPath: args[4], contents: data as Data,
                                         attributes: [.posixPermissions: 0o600]) else { fail("cannot write \(args[4])") }

default:
    fail("unknown command \(args[1])")
}

import Foundation
import OpenDirectory

// A new password for the workspace's account ({"op":"rekey","old":"…","new":"…"}), from aOS when it replaces the
// workspace's secrets. Runs in the account's session, so it can change the account's own password with the old one
// (Open Directory) and its login keychain to match: the passwords travel in the request (stdin and the helper's
// socket), never in a command line that other programs in the workspace could read. The keychain goes first; if
// the account's password can't change, the keychain goes back. The automatic login (/etc/kcpassword) is root's part
// and aOS writes it afterwards.

private typealias KeychainOpen = @convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<Unmanaged<AnyObject>?>) -> OSStatus
private typealias KeychainChangePassword = @convention(c) (AnyObject, UInt32, UnsafeRawPointer, UInt32, UnsafeRawPointer) -> OSStatus

/// SecKeychainOpen and SecKeychainChangePassword (still in Security, no longer in the SDK's headers).
private func changeKeychainPassword(from old: String, to new: String) -> OSStatus {
    guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW),
          let openSymbol = dlsym(security, "SecKeychainOpen"),
          let changeSymbol = dlsym(security, "SecKeychainChangePassword") else { return -1 }
    let open = unsafeBitCast(openSymbol, to: KeychainOpen.self)
    let change = unsafeBitCast(changeSymbol, to: KeychainChangePassword.self)
    let path = NSHomeDirectory() + "/Library/Keychains/login.keychain-db"
    var keychain: Unmanaged<AnyObject>?
    let opened = path.withCString { open($0, &keychain) }
    guard opened == 0, let keychain else { return opened == 0 ? -1 : opened }
    defer { keychain.release() }
    let o = Array(old.utf8), n = Array(new.utf8)
    return o.withUnsafeBytes { ob in
        n.withUnsafeBytes { nb in
            change(keychain.takeUnretainedValue(), UInt32(o.count), ob.baseAddress!, UInt32(n.count), nb.baseAddress!)
        }
    }
}

private func accountRecord() throws -> ODRecord {
    let node = try ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeLocalNodes))
    return try node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
}

func rekey(_ r: [String: Any]) -> [String: Any] {
    guard let old = r["old"] as? String, let new = r["new"] as? String, !old.isEmpty, !new.isEmpty, old != new,
          new.count >= 16, new.count <= 128 else {
        return ["ok": false, "error": "bad request"]
    }
    let record: ODRecord
    do {
        record = try accountRecord()
    } catch {
        return ["ok": false, "error": "no account record"]
    }
    if (try? record.verifyPassword(old)) == nil {
        // An earlier attempt got this far and aOS didn't hear back: the new one is in place already.
        if (try? record.verifyPassword(new)) != nil { return ["ok": true, "already": true] }
        return ["ok": false, "error": "the current password doesn't match"]
    }
    let keychain = changeKeychainPassword(from: old, to: new)
    guard keychain == 0 else { return ["ok": false, "error": "login keychain: \(keychain)"] }
    do {
        try record.changePassword(old, toPassword: new)
    } catch {
        _ = changeKeychainPassword(from: new, to: old)
        return ["ok": false, "error": "account password: \(error.localizedDescription)"]
    }
    let verified = (try? accountRecord().verifyPassword(new)) != nil
    return ["ok": verified, "error": verified ? "" : "the new password doesn't work"]
}

#if ICLOUD
import CloudKit
import Foundation
import os
import UIKit

private let log = Logger(subsystem: "dev.marquart.aos.ios", category: "icloud")

/// The Mac's requests through the user's own iCloud (CloudKit, private database), see App/Sources/CloudRelay.swift on
/// the Mac: a notification arrives even while the app is closed or the Mac is far away, and answers that hold no secret
/// (allow, decline, done, which Bitwarden login) go back the same way. Passwords and codes typed on the phone never go
/// through iCloud; those need the direct connection (SSH).
///
/// Records are turned into the same JSON the Mac sends over SSH, so they take the app's normal path.
@MainActor
final class CloudInbox {
    static let containerID = "iCloud.dev.marquart.aos"
    private let database = CKContainer(identifier: containerID).privateCloudDatabase
    private(set) var available = false
    /// Request ids that came through iCloud (answers to these may go back through iCloud).
    private(set) var known: Set<String> = []
    var onEvent: ((CompanionEvent) -> Void)?

    func start() async {
        do {
            available = try await CKContainer(identifier: Self.containerID).accountStatus() == .available
        } catch {
            log.error("account: \(error.localizedDescription, privacy: .public)")
        }
        guard available else { return }
        await subscribe()
        await fetchOpen()
    }

    // MARK: Notifications

    /// One subscription per kind of request, each with its own notification text (localized on the phone: the
    /// server only fills in the agent's name).
    private func subscribe() async {
        let kinds: [(String, String)] = [("signin", "PUSH_SIGNIN"), ("approval", "PUSH_APPROVAL"), ("help", "PUSH_HELP")]
        for (kind, key) in kinds {
            let id = "aos-\(kind)-v1"
            if (try? await database.subscription(for: id)) != nil { continue }
            let subscription = CKQuerySubscription(recordType: "AOSRequest", predicate: NSPredicate(format: "kind == %@", kind),
                                                   subscriptionID: id, options: [.firesOnRecordCreation])
            let info = CKSubscription.NotificationInfo()
            info.alertLocalizationKey = key
            info.alertLocalizationArgs = ["agent"]
            info.titleLocalizationKey = "PUSH_TITLE"
            info.soundName = "default"
            info.shouldBadge = true
            info.desiredKeys = ["requestId", "kind"]
            info.category = "AOS_REQUEST"
            subscription.notificationInfo = info
            do { _ = try await database.save(subscription) } catch {
                log.error("subscribe \(kind, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Requests in

    /// The requests still open (at launch, when the app comes to the front, after a notification).
    func fetchOpen() async {
        guard available else { return }
        let query = CKQuery(recordType: "AOSRequest", predicate: NSPredicate(format: "expires > %@", Date() as NSDate))
        do {
            let (results, _) = try await database.records(matching: query, resultsLimit: 20)
            for (_, result) in results {
                guard let record = try? result.get(), let event = Self.event(from: record) else { continue }
                if let id = record["requestId"] as? String { known.insert(id) }
                onEvent?(event)
            }
        } catch let error as CKError where error.code == .unknownItem {
            // No request was ever sent through iCloud yet.
        } catch {
            log.error("fetch: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The record as the Mac's JSON event line, decoded the normal way.
    static func event(from record: CKRecord) -> CompanionEvent? {
        guard let id = record["requestId"] as? String, let kind = record["kind"] as? String else { return nil }
        var object: [String: Any] = ["event": kind, "request": id, "agent": record["agent"] as? String ?? ""]
        if let host = record.encryptedValues["host"] as? String { object["host"] = host }
        if let purpose = record.encryptedValues["purpose"] as? String { object["purpose"] = purpose }
        if let field = record["field"] as? String { object["field"] = field }
        if let minutes = record["minutes"] as? Int { object["minutes"] = minutes }
        if let expires = record["expires"] as? Date { object["expires"] = ISO8601DateFormatter().string(from: expires) }
        // Fields added later travel as JSON in one encrypted field
        if let extra = record.encryptedValues["extra"] as? String, let data = extra.data(using: .utf8),
           let more = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (k, v) in more where object[k] == nil { object[k] = v }
        }
        guard let line = try? JSONSerialization.data(withJSONObject: object),
              case .event(let event)? = try? CompanionMessage.decode(line: line) else { return nil }
        return event
    }

    // MARK: Answers out

    /// An answer without a secret: "allow", "decline", "done" or "login" (with the Bitwarden item's id).
    func answer(request: String, decision: String, login: String? = nil, device: String) async throws {
        let record = CKRecord(recordType: "AOSAnswer", recordID: CKRecord.ID(recordName: "answer-\(request)"))
        record["requestId"] = request
        record["decision"] = decision
        record["device"] = device
        record.encryptedValues["login"] = login
        _ = try await database.save(record)
    }
}
#endif

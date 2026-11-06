import AOSKit
import CloudKit
import Foundation
import Security

/// Requests through the user's own iCloud (CloudKit, private database): the iPhone gets a notification even while
/// aOS on the iPhone is closed or far away, and answers that hold no secret (allow, decline, done, which Bitwarden
/// login) come back the same way. Passwords and codes the user types never go through iCloud: those answers need the
/// direct connection (SSH). Website and purpose are end-to-end encrypted fields (encryptedValues), so Apple's servers
/// see only the kind of request and the agent's name (for the notification text).
///
/// Optional: without the iCloud entitlement or an iCloud account aOS works as before.
@MainActor
final class CloudRelay {
    static let containerID = "iCloud.dev.marquart.aos"
    static let requestType = "AOSRequest"
    static let answerType = "AOSAnswer"

    struct Answer: Sendable {
        var request: String
        /// "allow", "decline", "done" or "login"
        var decision: String
        /// The Bitwarden item the user chose (decision "login").
        var login: String?
        var device: String
    }

    private let database: CKDatabase?
    private(set) var available = false
    /// Open requests in iCloud, by request id.
    private var published: [String: CKRecord.ID] = [:]
    private var poll: Task<Void, Never>?
    var onAnswer: ((Answer) -> Void)?
    var log: (String) -> Void = { _ in }

    init() {
        // CKContainer stops the app when the entitlement is missing: look first.
        guard Self.hasEntitlement else { database = nil; return }
        database = CKContainer(identifier: Self.containerID).privateCloudDatabase
        Task { await checkAccount() }
    }

    static var hasEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
        else { return false }
        return (value as? [String])?.contains(containerID) == true
    }

    private func checkAccount() async {
        guard let database else { return }
        do {
            let status = try await CKContainer(identifier: Self.containerID).accountStatus()
            available = status == .available
            log(available ? "iCloud: ready for notifications" : "iCloud: no account (\(status.rawValue)), notifications only while the phone is connected")
            _ = database
        } catch {
            log("iCloud: \(error.localizedDescription)")
        }
    }

    // MARK: Requests out

    /// A question for the phone ("signin", "approval" or "help").
    func publish(_ e: CompanionEvent, macName: String) {
        guard available, let database, let id = e.request, published[id] == nil else { return }
        let recordID = CKRecord.ID(recordName: "request-\(id)")
        let record = CKRecord(recordType: Self.requestType, recordID: recordID)
        record["requestId"] = id
        record["kind"] = e.event
        record["agent"] = e.agent ?? "Your agent"
        record["field"] = e.field
        record["minutes"] = e.minutes.map { NSNumber(value: $0) }
        record["expires"] = e.expires ?? Date().addingTimeInterval(300)
        record["mac"] = macName
        record.encryptedValues["host"] = e.host
        record.encryptedValues["purpose"] = e.purpose
        published[id] = recordID
        Task {
            do { _ = try await database.save(record) } catch {
                log("iCloud: could not send the request: \(error.localizedDescription)")
            }
        }
        startPolling()
    }

    /// The question is answered or gone: its record goes, so the phone doesn't show it any more.
    func close(_ requestID: String) {
        guard let database, let recordID = published.removeValue(forKey: requestID) else { return }
        Task { _ = try? await database.deleteRecord(withID: recordID) }
        if published.isEmpty { poll?.cancel(); poll = nil }
    }

    // MARK: Answers in

    /// While questions are open, look for answers every few seconds (the Mac needs no push for this).
    private func startPolling() {
        guard poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await self?.fetchAnswers()
            }
        }
    }

    private func fetchAnswers() async {
        guard let database, !published.isEmpty else { return }
        let ids = Array(published.keys)
        let query = CKQuery(recordType: Self.answerType, predicate: NSPredicate(format: "requestId IN %@", ids))
        do {
            let (results, _) = try await database.records(matching: query, resultsLimit: 20)
            for (recordID, result) in results {
                guard let record = try? result.get(), let request = record["requestId"] as? String,
                      let decision = record["decision"] as? String else { continue }
                _ = try? await database.deleteRecord(withID: recordID)
                guard published[request] != nil else { continue }
                onAnswer?(Answer(request: request, decision: decision, login: record.encryptedValues["login"] as? String,
                                 device: (record["device"] as? String) ?? "iPhone"))
            }
        } catch let error as CKError where error.code == .unknownItem {
            // No answer has ever been written yet (the record type doesn't exist): nothing to do.
        } catch {
            log("iCloud: \(error.localizedDescription)")
        }
    }
}

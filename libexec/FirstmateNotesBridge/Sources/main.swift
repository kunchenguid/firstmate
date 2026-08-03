import ApplicationServices
import CryptoKit
import Darwin
import Foundation
import ScriptingBridge

private let protocolSchema = "firstmate.apple-notes.bridge/v1"
private let fixedBundleID = "com.apple.Notes"
private let fixedAccountName = "iCloud"
private let fixedFolderNames: [String: String] = [
    "root": "Firstmate",
    "guide": "00 Guide",
    "inbox": "10 Inbox",
    "acknowledgments": "20 Acknowledgments",
    "outbox": "30 Outbox",
    "archive": "90 Archive",
    "archive_inbound": "Inbound",
    "archive_acknowledgments": "Acknowledgments",
    "archive_outbound": "Outbound",
]
private let allowedOperations: Set<String> = [
    "status",
    "pair-fixed-tree",
    "probe-binding",
    "list-inbox-metadata",
    "read-inbox-note",
    "find-owned-note",
    "create-owned-note",
]
private let allowedDestinations: Set<String> = ["acknowledgments", "outbox"]
private let allowedKinds: Set<String> = ["ACK", "DONE", "DECISION", "INFO", "CONFLICT"]
private let maximumInputBytes = 64 * 1024
private let maximumOutputBytes = 1024 * 1024
private let maximumObjects = 200
private let listedLifetime: TimeInterval = 10 * 60

private struct BridgeFailure: Error {
    let code: String
    let detail: String
}

private struct FolderBinding: Codable {
    let id: String
    let name: String
    let parent_id: String
    let shared: Bool
}

private struct AccountBinding: Codable {
    let id: String
    let name: String
}

private struct Binding: Codable {
    let account: AccountBinding
    let root: FolderBinding
    let guide: FolderBinding
    let inbox: FolderBinding
    let acknowledgments: FolderBinding
    let outbox: FolderBinding
    let archive: FolderBinding
    let archive_inbound: FolderBinding
    let archive_acknowledgments: FolderBinding
    let archive_outbound: FolderBinding
}

private struct ListedSet: Codable {
    let bindingHash: String
    let listedAt: Date
    let noteIDs: [String]
}

private final class NotesObjects {
    let app: SBApplication

    init() throws {
        guard let notes = SBApplication(bundleIdentifier: fixedBundleID) else {
            throw BridgeFailure(code: "notes-unavailable", detail: "Notes application object is unavailable")
        }
        self.app = notes
    }

    func elements(_ object: NSObject, key: String) throws -> SBElementArray {
        guard let result = object.value(forKey: key) as? SBElementArray else {
            throw BridgeFailure(code: "notes-object-model", detail: "Notes did not expose expected \(key) elements")
        }
        return result
    }

    func string(_ object: NSObject, key: String) throws -> String {
        guard let result = object.value(forKey: key) as? String, !result.isEmpty else {
            throw BridgeFailure(code: "notes-object-model", detail: "Notes did not expose expected \(key) string")
        }
        return result
    }

    func bool(_ object: NSObject, key: String) throws -> Bool {
        guard let result = object.value(forKey: key) as? Bool else {
            throw BridgeFailure(code: "notes-object-model", detail: "Notes did not expose expected \(key) boolean")
        }
        return result
    }

    func date(_ object: NSObject, key: String) throws -> Date {
        guard let result = object.value(forKey: key) as? Date else {
            throw BridgeFailure(code: "notes-object-model", detail: "Notes did not expose expected \(key) date")
        }
        return result
    }

    func object(_ elements: SBElementArray, exactID: String) throws -> NSObject {
        let matches = elements.compactMap { $0 as? NSObject }.filter {
            (try? string($0, key: "id")) == exactID
        }
        guard matches.count == 1, let match = matches.first else {
            throw BridgeFailure(code: "binding-drift", detail: "exact Notes object ID is missing or ambiguous")
        }
        return match
    }
}

private final class Bridge {
    private let fileManager = FileManager.default
    private let iso = ISO8601DateFormatter()

    private var supportDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("FirstmateNotesBridge", isDirectory: true)
    }

    private var bindingURL: URL { supportDirectory.appendingPathComponent("binding.json") }
    private var listedURL: URL { supportDirectory.appendingPathComponent("listed-inbox.json") }

    func response(operation: String, request: [String: Any]) throws -> Any {
        guard allowedOperations.contains(operation) else {
            throw BridgeFailure(code: "unknown-operation", detail: "operation is not in the fixed bridge API")
        }
        guard request["schema"] as? String == protocolSchema,
              request["operation"] as? String == operation,
              Set(request.keys).isSubset(of: allowedRequestKeys(operation)) else {
            throw BridgeFailure(code: "invalid-request", detail: "request schema or keys are invalid")
        }
        if operation == "status" {
            return try status()
        }
        let ask = operation == "pair-fixed-tree" && request["request_automation"] as? Bool == true
        try requireAutomation(askUser: ask)
        switch operation {
        case "pair-fixed-tree":
            return try pairFixedTree()
        case "probe-binding":
            let binding = try loadBinding()
            try requireBindingHash(request, binding: binding)
            _ = try resolveBinding(binding)
            return ["valid": true, "binding_hash": try hash(binding)]
        case "list-inbox-metadata":
            let binding = try loadBinding()
            let requested = request["limit"] as? Int ?? 0
            guard requested > 0 && requested <= maximumObjects else {
                throw BridgeFailure(code: "invalid-limit", detail: "Inbox metadata limit is outside the fixed cap")
            }
            return try listInbox(binding: binding, limit: requested)
        case "read-inbox-note":
            let binding = try loadBinding()
            guard let noteID = request["note_id"] as? String, !noteID.isEmpty,
                  let maxBytes = request["max_bytes"] as? Int, maxBytes > 0, maxBytes <= 16 * 1024 else {
                throw BridgeFailure(code: "invalid-read", detail: "bounded note read request is invalid")
            }
            return try readInbox(binding: binding, noteID: noteID, maxBytes: maxBytes)
        case "find-owned-note":
            let binding = try loadBinding()
            guard let destination = request["destination"] as? String,
                  allowedDestinations.contains(destination),
                  let logicalID = request["logical_id"] as? String,
                  isLogicalID(logicalID) else {
                throw BridgeFailure(code: "invalid-find", detail: "owned-note find request is invalid")
            }
            return try findOwned(binding: binding, destination: destination, logicalID: logicalID)
        case "create-owned-note":
            let binding = try loadBinding()
            guard let intent = request["intent"] as? [String: Any] else {
                throw BridgeFailure(code: "invalid-create", detail: "owned-note intent is missing")
            }
            return try createOwned(binding: binding, intent: intent)
        default:
            throw BridgeFailure(code: "unknown-operation", detail: "operation is not in the fixed bridge API")
        }
    }

    private func allowedRequestKeys(_ operation: String) -> Set<String> {
        switch operation {
        case "status": return ["schema", "operation"]
        case "pair-fixed-tree": return ["schema", "operation", "request_automation"]
        case "probe-binding": return ["schema", "operation", "binding_hash"]
        case "list-inbox-metadata": return ["schema", "operation", "limit"]
        case "read-inbox-note": return ["schema", "operation", "note_id", "max_bytes"]
        case "find-owned-note": return ["schema", "operation", "destination", "logical_id"]
        case "create-owned-note": return ["schema", "operation", "intent"]
        default: return []
        }
    }

    private func status() throws -> [String: Any] {
        let bindingPresent = fileManager.fileExists(atPath: bindingURL.path)
        return [
            "bundle_id": Bundle.main.bundleIdentifier ?? "",
            "notes_target": fixedBundleID,
            "binding_present": bindingPresent,
            "provider_calls": 0,
        ]
    }

    private func requireAutomation(askUser: Bool) throws {
        var target = AEAddressDesc()
        let bytes = Array(fixedBundleID.utf8)
        let createStatus = bytes.withUnsafeBytes {
            AECreateDesc(DescType(typeApplicationBundleID), $0.baseAddress, $0.count, &target)
        }
        guard createStatus == noErr else {
            throw BridgeFailure(code: "automation-preflight", detail: "could not construct the fixed Notes target")
        }
        defer { AEDisposeDesc(&target) }
        let status = AEDeterminePermissionToAutomateTarget(
            &target,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            askUser
        )
        if status == noErr { return }
        if status == errAEEventNotPermitted {
            throw BridgeFailure(code: askUser ? "tcc-denied" : "tcc-not-determined", detail: "Notes Automation is not authorized")
        }
        throw BridgeFailure(code: "automation-preflight", detail: "Notes Automation preflight failed with OSStatus \(status)")
    }

    private func pairFixedTree() throws -> [String: Any] {
        let notes = try NotesObjects()
        let accounts = try notes.elements(notes.app, key: "accounts")
        let accountMatches = accounts.compactMap { $0 as? NSObject }.filter {
            (try? notes.string($0, key: "name")) == fixedAccountName
        }
        guard accountMatches.count == 1, let account = accountMatches.first else {
            throw BridgeFailure(code: "pairing-ambiguous", detail: "exactly one iCloud account is required")
        }
        let accountID = try notes.string(account, key: "id")
        let accountFolders = try notes.elements(account, key: "folders")
        let roots = accountFolders.compactMap { $0 as? NSObject }.filter {
            (try? notes.string($0, key: "name")) == fixedFolderNames["root"]
        }
        guard roots.count == 1, let root = roots.first else {
            throw BridgeFailure(code: "pairing-ambiguous", detail: "exactly one fresh Firstmate root is required")
        }
        let rootBinding = try folderBinding(notes, folder: root, parentID: accountID, key: "root")
        let rootChildren = try notes.elements(root, key: "folders")
        guard rootChildren.count == 5 else {
            throw BridgeFailure(code: "pairing-ambiguous", detail: "the fresh Firstmate root must contain only the five fixed child folders")
        }
        var children: [String: FolderBinding] = [:]
        for key in ["guide", "inbox", "acknowledgments", "outbox", "archive"] {
            let folder = try exactNamedFolder(notes, elements: rootChildren, name: fixedFolderNames[key]!)
            children[key] = try folderBinding(notes, folder: folder, parentID: rootBinding.id, key: key)
        }
        let archiveObject = try notes.object(rootChildren, exactID: children["archive"]!.id)
        let archiveChildren = try notes.elements(archiveObject, key: "folders")
        guard archiveChildren.count == 3 else {
            throw BridgeFailure(code: "pairing-ambiguous", detail: "the fresh Archive folder must contain only the three fixed child folders")
        }
        for key in ["archive_inbound", "archive_acknowledgments", "archive_outbound"] {
            let folder = try exactNamedFolder(notes, elements: archiveChildren, name: fixedFolderNames[key]!)
            children[key] = try folderBinding(notes, folder: folder, parentID: children["archive"]!.id, key: key)
        }
        var foldersToCheck: [NSObject] = [root, archiveObject]
        for key in ["guide", "inbox", "acknowledgments", "outbox"] {
            foldersToCheck.append(try notes.object(rootChildren, exactID: children[key]!.id))
        }
        for key in ["archive_inbound", "archive_acknowledgments", "archive_outbound"] {
            foldersToCheck.append(try notes.object(archiveChildren, exactID: children[key]!.id))
        }
        for folder in foldersToCheck {
            let noteCount = try notes.elements(folder, key: "notes").count
            guard noteCount == 0 else {
                throw BridgeFailure(code: "pairing-not-empty", detail: "the fresh fixed tree must contain zero notes before pairing")
            }
        }
        let binding = Binding(
            account: AccountBinding(id: accountID, name: fixedAccountName),
            root: rootBinding,
            guide: children["guide"]!,
            inbox: children["inbox"]!,
            acknowledgments: children["acknowledgments"]!,
            outbox: children["outbox"]!,
            archive: children["archive"]!,
            archive_inbound: children["archive_inbound"]!,
            archive_acknowledgments: children["archive_acknowledgments"]!,
            archive_outbound: children["archive_outbound"]!
        )
        try store(binding)
        return ["binding": try jsonObject(binding), "binding_hash": try hash(binding), "empty_tree_verified": true]
    }

    private func exactNamedFolder(_ notes: NotesObjects, elements: SBElementArray, name: String) throws -> NSObject {
        let matches = elements.compactMap { $0 as? NSObject }.filter {
            (try? notes.string($0, key: "name")) == name
        }
        guard matches.count == 1, let match = matches.first else {
            throw BridgeFailure(code: "pairing-ambiguous", detail: "fixed folder name is missing or duplicated")
        }
        return match
    }

    private func folderBinding(_ notes: NotesObjects, folder: NSObject, parentID: String, key: String) throws -> FolderBinding {
        let name = try notes.string(folder, key: "name")
        let id = try notes.string(folder, key: "id")
        let shared = try notes.bool(folder, key: "shared")
        guard name == fixedFolderNames[key], !shared else {
            throw BridgeFailure(code: "binding-drift", detail: "fixed folder name or shared invariant failed")
        }
        return FolderBinding(id: id, name: name, parent_id: parentID, shared: false)
    }

    private func resolveBinding(_ binding: Binding) throws -> [String: NSObject] {
        let notes = try NotesObjects()
        let accounts = try notes.elements(notes.app, key: "accounts")
        let namedAccounts = accounts.compactMap { $0 as? NSObject }.filter {
            (try? notes.string($0, key: "name")) == fixedAccountName
        }
        guard namedAccounts.count == 1 else {
            throw BridgeFailure(code: "binding-drift", detail: "the bound iCloud account became ambiguous")
        }
        let account = try notes.object(accounts, exactID: binding.account.id)
        guard try notes.string(account, key: "name") == fixedAccountName else {
            throw BridgeFailure(code: "binding-drift", detail: "bound account name changed")
        }
        let accountFolders = try notes.elements(account, key: "folders")
        let namedRoots = accountFolders.compactMap { $0 as? NSObject }.filter {
            (try? notes.string($0, key: "name")) == fixedFolderNames["root"]
        }
        guard namedRoots.count == 1 else {
            throw BridgeFailure(code: "binding-drift", detail: "the bound Firstmate root became ambiguous")
        }
        let root = try notes.object(accountFolders, exactID: binding.root.id)
        _ = try validateResolvedFolder(notes, folder: root, expected: binding.root, parentID: binding.account.id)
        var result: [String: NSObject] = ["account": account, "root": root]
        let rootChildren = try notes.elements(root, key: "folders")
        guard rootChildren.count == 5 else {
            throw BridgeFailure(code: "binding-drift", detail: "the bound Firstmate root child set changed")
        }
        for key in ["guide", "inbox", "acknowledgments", "outbox", "archive"] {
            let expected = bindingFolder(binding, key: key)
            let object = try notes.object(rootChildren, exactID: expected.id)
            _ = try validateResolvedFolder(notes, folder: object, expected: expected, parentID: binding.root.id)
            result[key] = object
        }
        let archiveChildren = try notes.elements(result["archive"]!, key: "folders")
        guard archiveChildren.count == 3 else {
            throw BridgeFailure(code: "binding-drift", detail: "the bound Archive child set changed")
        }
        for key in ["archive_inbound", "archive_acknowledgments", "archive_outbound"] {
            let expected = bindingFolder(binding, key: key)
            let object = try notes.object(archiveChildren, exactID: expected.id)
            _ = try validateResolvedFolder(notes, folder: object, expected: expected, parentID: binding.archive.id)
            result[key] = object
        }
        return result
    }

    private func bindingFolder(_ binding: Binding, key: String) -> FolderBinding {
        switch key {
        case "root": return binding.root
        case "guide": return binding.guide
        case "inbox": return binding.inbox
        case "acknowledgments": return binding.acknowledgments
        case "outbox": return binding.outbox
        case "archive": return binding.archive
        case "archive_inbound": return binding.archive_inbound
        case "archive_acknowledgments": return binding.archive_acknowledgments
        default: return binding.archive_outbound
        }
    }

    private func validateResolvedFolder(_ notes: NotesObjects, folder: NSObject, expected: FolderBinding, parentID: String) throws -> Bool {
        guard try notes.string(folder, key: "id") == expected.id,
              try notes.string(folder, key: "name") == expected.name,
              try notes.bool(folder, key: "shared") == false,
              expected.parent_id == parentID else {
            throw BridgeFailure(code: "binding-drift", detail: "bound folder identity drifted")
        }
        return true
    }

    private func listInbox(binding: Binding, limit: Int) throws -> [[String: Any]] {
        let notes = try NotesObjects()
        let resolved = try resolveBinding(binding)
        let noteElements = try notes.elements(resolved["inbox"]!, key: "notes")
        guard noteElements.count <= limit else {
            return [["over_cap": true, "count": noteElements.count]]
        }
        var output: [[String: Any]] = []
        var ids: [String] = []
        for case let note as NSObject in noteElements {
            let id = try notes.string(note, key: "id")
            let shared = try notes.bool(note, key: "shared")
            let passwordProtected = try notes.bool(note, key: "passwordProtected")
            let attachments = try notes.elements(note, key: "attachments").count
            let plaintextBytes: Int
            if shared || passwordProtected || attachments != 0 {
                // Never ask Notes for body text after metadata has already made
                // the object ineligible.
                plaintextBytes = 0
            } else {
                plaintextBytes = try notes.string(note, key: "plaintext").lengthOfBytes(using: .utf8)
            }
            output.append([
                "id": id,
                "title": try notes.string(note, key: "name"),
                "creation_date": iso.string(from: try notes.date(note, key: "creationDate")),
                "modification_date": iso.string(from: try notes.date(note, key: "modificationDate")),
                "shared": shared,
                "password_protected": passwordProtected,
                "attachment_count": attachments,
                "plaintext_bytes": plaintextBytes,
                "folder_id": binding.inbox.id,
                "account_id": binding.account.id,
            ])
            ids.append(id)
        }
        try store(ListedSet(bindingHash: try hash(binding), listedAt: Date(), noteIDs: ids), at: listedURL)
        return output
    }

    private func readInbox(binding: Binding, noteID: String, maxBytes: Int) throws -> [String: Any] {
        let listed: ListedSet = try load(ListedSet.self, from: listedURL)
        guard listed.bindingHash == (try hash(binding)),
              Date().timeIntervalSince(listed.listedAt) <= listedLifetime,
              listed.noteIDs.contains(noteID) else {
            throw BridgeFailure(code: "unlisted-note", detail: "note ID was not in the current bound Inbox listing")
        }
        let notes = try NotesObjects()
        let resolved = try resolveBinding(binding)
        let note = try notes.object(try notes.elements(resolved["inbox"]!, key: "notes"), exactID: noteID)
        let shared = try notes.bool(note, key: "shared")
        let passwordProtected = try notes.bool(note, key: "passwordProtected")
        let attachments = try notes.elements(note, key: "attachments").count
        guard !shared, !passwordProtected, attachments == 0 else {
            throw BridgeFailure(code: "note-metadata-drift", detail: "note eligibility changed before its bounded body read")
        }
        let plaintext = try notes.string(note, key: "plaintext")
        guard plaintext.lengthOfBytes(using: .utf8) <= maxBytes else {
            throw BridgeFailure(code: "note-too-large", detail: "note plaintext exceeds the fixed read cap")
        }
        return [
            "id": noteID,
            "title": try notes.string(note, key: "name"),
            "plaintext": plaintext,
            "html": try notes.string(note, key: "body"),
            "creation_date": iso.string(from: try notes.date(note, key: "creationDate")),
            "modification_date": iso.string(from: try notes.date(note, key: "modificationDate")),
            "shared": shared,
            "password_protected": passwordProtected,
            "attachment_count": attachments,
            "folder_id": binding.inbox.id,
            "account_id": binding.account.id,
        ]
    }

    private func findOwned(binding: Binding, destination: String, logicalID: String) throws -> [[String: Any]] {
        let notes = try NotesObjects()
        let resolved = try resolveBinding(binding)
        let noteElements = try notes.elements(resolved[destination]!, key: "notes")
        guard noteElements.count <= maximumObjects else {
            throw BridgeFailure(code: "outbound-over-cap", detail: "owned destination folder exceeds the fixed cap")
        }
        var matches: [[String: Any]] = []
        for case let note as NSObject in noteElements {
            let plaintext = try notes.string(note, key: "plaintext")
            let foundID = receiptValue("message_id", in: plaintext)
            if foundID == logicalID {
                matches.append([
                    "id": try notes.string(note, key: "id"),
                    "logical_id": logicalID,
                    "content_sha256": receiptValue("content_sha256", in: plaintext) ?? "",
                    "folder_id": bindingFolder(binding, key: destination).id,
                ])
            }
        }
        return matches
    }

    private func createOwned(binding: Binding, intent: [String: Any]) throws -> [String: Any] {
        let required: Set<String> = [
            "schema", "logical_id", "destination", "kind", "summary", "outcome", "evidence",
            "action", "links", "in_reply_to", "created_at", "content_sha256",
        ]
        guard Set(intent.keys) == required,
              intent["schema"] as? String == "firstmate.apple-notes.outbound/v1",
              let destination = intent["destination"] as? String, allowedDestinations.contains(destination),
              let kind = intent["kind"] as? String, allowedKinds.contains(kind),
              let logicalID = intent["logical_id"] as? String, isLogicalID(logicalID),
              let digest = intent["content_sha256"] as? String, isSHA256(digest),
              let summary = boundedString(intent["summary"], 120),
              let outcome = boundedString(intent["outcome"], 2048),
              let action = boundedString(intent["action"], 1024),
              let reply = intent["in_reply_to"] as? String, isReplyID(reply),
              let created = intent["created_at"] as? String, isISODate(created),
              let evidence = intent["evidence"] as? [String], evidence.count <= 5,
              evidence.allSatisfy({ !$0.isEmpty && $0.lengthOfBytes(using: .utf8) <= 1024 }),
              let links = intent["links"] as? [String], links.count <= 5,
              links.allSatisfy(isInertHTTPS),
              try validIntentDigest(intent, supplied: digest) else {
            throw BridgeFailure(code: "invalid-create", detail: "owned-note intent failed fixed validation")
        }
        let existing = try findOwned(binding: binding, destination: destination, logicalID: logicalID)
        if existing.count == 1, existing[0]["content_sha256"] as? String == digest {
            return existing[0]
        }
        guard existing.isEmpty else {
            throw BridgeFailure(code: "outbound-conflict", detail: "owned-note logical ID already exists with ambiguous content")
        }
        let title = "\(kind) · \(logicalID.suffix(4).uppercased()) · \(summary)"
        let fields: [(String, String)] = [
            ("in_reply_to", reply), ("message_id", logicalID), ("published_on_mac", created),
            ("content_sha256", digest), ("channel_state", "published-awaiting-sync"),
        ]
        let evidenceHTML = evidence.isEmpty ? "<li>No additional evidence.</li>" : evidence.map { "<li>\(escape($0))</li>" }.joined()
        let linksHTML = links.isEmpty ? "<div>None.</div>" : links.map { "<div><a href=\"\(escape($0))\">\(escape($0))</a></div>" }.joined()
        let receiptHTML = fields.map { "<div>\(escape($0.0)): \(escape($0.1))</div>" }.joined()
        let body = "<div><strong>\(escape(title))</strong></div>" +
            "<div><strong>Outcome</strong></div><div>\(escape(outcome))</div>" +
            "<div><strong>Evidence</strong></div><ul>\(evidenceHTML)</ul>" +
            "<div><strong>Your decision / next action</strong></div><div>\(escape(action))</div>" +
            "<div><strong>Links</strong></div>\(linksHTML)" +
            "<div><strong>Receipt</strong></div>\(receiptHTML)"
        guard body.lengthOfBytes(using: .utf8) <= 12 * 1024 else {
            throw BridgeFailure(code: "outbound-too-large", detail: "rendered owned note exceeds 12 KiB")
        }
        let notes = try NotesObjects()
        let resolved = try resolveBinding(binding)
        let destinationNotes = try notes.elements(resolved[destination]!, key: "notes")
        guard destinationNotes.count < maximumObjects else {
            throw BridgeFailure(code: "outbound-over-cap", detail: "owned destination folder exceeds the fixed cap")
        }
        guard let noteType = notes.app.class(forScriptingClass: "note") as? SBObject.Type else {
            throw BridgeFailure(code: "notes-object-model", detail: "Notes note scripting class is unavailable")
        }
        let newNote = noteType.init(properties: ["body": body])
        destinationNotes.add(newNote)
        let noteID = try notes.string(newNote, key: "id")
        return ["id": noteID, "logical_id": logicalID, "content_sha256": digest]
    }

    private func receiptValue(_ key: String, in plaintext: String) -> String? {
        let prefix = "\(key): "
        let matches = plaintext.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line -> String? in
            let value = String(line)
            return value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : nil
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func boundedString(_ value: Any?, _ bytes: Int) -> String? {
        guard let string = value as? String, !string.isEmpty,
              string.lengthOfBytes(using: .utf8) <= bytes,
              !string.unicodeScalars.contains(where: { scalar in
                  scalar.value == 0 ||
                  (scalar.value < 0x20 && scalar.value != 0x0A && scalar.value != 0x09) ||
                  (0x202A...0x202E).contains(scalar.value) ||
                  (0x2066...0x2069).contains(scalar.value) ||
                  scalar.value == 0x061C || scalar.value == 0x200E || scalar.value == 0x200F ||
                  (0xFDD0...0xFDEF).contains(scalar.value) ||
                  scalar.value & 0xFFFF == 0xFFFE || scalar.value & 0xFFFF == 0xFFFF
              }) else { return nil }
        return string
    }

    private func validIntentDigest(_ intent: [String: Any], supplied: String) throws -> Bool {
        var fields = intent
        fields.removeValue(forKey: "content_sha256")
        guard JSONSerialization.isValidJSONObject(fields) else { return false }
        let canonical = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        return Digest.hex(canonical) == supplied
    }

    private func isReplyID(_ value: String) -> Bool {
        value.range(of: "^(?:-|ni1_[a-z2-7]{26}|na1_[a-z0-9._-]{8,80}|no1_[a-z0-9._-]{8,80})$", options: .regularExpression) != nil
    }

    private func isISODate(_ value: String) -> Bool {
        if iso.date(from: value) != nil { return true }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) != nil
    }

    private func isInertHTTPS(_ value: String) -> Bool {
        guard value.lengthOfBytes(using: .utf8) <= 2048,
              let parts = URLComponents(string: value),
              parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil else { return false }
        let lower = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if lower == "localhost" || lower.hasSuffix(".localhost") || lower.contains(":") {
            return false
        }
        let octets = lower.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4 {
            guard octets.allSatisfy({ (0...255).contains($0) }) else { return false }
            let first = octets[0]
            let second = octets[1]
            if first == 10 || first == 127 || first == 0 ||
                (first == 169 && second == 254) ||
                (first == 172 && (16...31).contains(second)) ||
                (first == 192 && second == 168) || first >= 224 {
                return false
            }
        }
        return true
    }

    private func isLogicalID(_ value: String) -> Bool {
        value.range(of: "^(?:na1|no1)_[a-z0-9._-]{8,80}$", options: .regularExpression) != nil
    }

    private func isSHA256(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private func requireBindingHash(_ request: [String: Any], binding: Binding) throws {
        guard let supplied = request["binding_hash"] as? String, supplied == (try hash(binding)) else {
            throw BridgeFailure(code: "binding-drift", detail: "owner and helper binding hashes differ")
        }
    }

    private func store(_ binding: Binding) throws {
        try store(binding, at: bindingURL)
        try? fileManager.removeItem(at: listedURL)
    }

    private func store<T: Encodable>(_ value: T, at url: URL) throws {
        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try validateSupportDirectory()
        let data = try JSONEncoder().encode(value)
        let temporary = supportDirectory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard fileManager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw BridgeFailure(code: "helper-state", detail: "could not create private helper state")
        }
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary, backupItemName: nil, options: .usingNewMetadataOnly)
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
        try validatePrivateState(at: url)
    }

    private func validateSupportDirectory() throws {
        let attributes = try fileManager.attributesOfItem(atPath: supportDirectory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw BridgeFailure(code: "helper-state", detail: "private helper state directory is unsafe")
        }
    }

    private func validatePrivateState(at url: URL) throws {
        try validateSupportDirectory()
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else {
            throw BridgeFailure(code: "helper-state", detail: "private helper state is missing or unsafe")
        }
    }

    private func loadBinding() throws -> Binding {
        try load(Binding.self, from: bindingURL)
    }

    private func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try validatePrivateState(at: url)
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    private func hash<T: Encodable>(_ value: T) throws -> String {
        let object = try jsonObject(value)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return Digest.hex(data)
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }
}

private enum Digest {
    static func hex(_ data: Data) -> String {
        CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private func readRequest() throws -> [String: Any] {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard data.count <= maximumInputBytes else {
        throw BridgeFailure(code: "input-too-large", detail: "bridge input exceeds 64 KiB")
    }
    guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw BridgeFailure(code: "invalid-request", detail: "bridge input root must be a JSON object")
    }
    return request
}

private func writeResponse(ok: Bool, result: Any? = nil, failure: BridgeFailure? = nil) {
    var response: [String: Any] = ["schema": protocolSchema, "ok": ok]
    if let result { response["result"] = result }
    if let failure {
        response["error"] = ["code": failure.code, "detail": failure.detail]
    }
    do {
        let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
        guard data.count <= maximumOutputBytes else {
            throw BridgeFailure(code: "output-too-large", detail: "bridge output exceeds 1 MiB")
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
        let fallback = "{\"error\":{\"code\":\"response-error\",\"detail\":\"could not encode fixed bridge response\"},\"ok\":false,\"schema\":\"\(protocolSchema)\"}\n"
        FileHandle.standardOutput.write(Data(fallback.utf8))
    }
}

private func runMain() -> Int32 {
    do {
        guard CommandLine.arguments.count == 2 else {
            throw BridgeFailure(code: "invalid-arguments", detail: "one fixed operation argument is required")
        }
        let operation = CommandLine.arguments[1]
        guard allowedOperations.contains(operation) else {
            throw BridgeFailure(code: "unknown-operation", detail: "operation is not in the fixed bridge API")
        }
        let request = try readRequest()
        let result = try Bridge().response(operation: operation, request: request)
        writeResponse(ok: true, result: result)
        return 0
    } catch let failure as BridgeFailure {
        writeResponse(ok: false, failure: failure)
        return 1
    } catch {
        writeResponse(ok: false, failure: BridgeFailure(code: "internal-refusal", detail: "dedicated bridge refused an unexpected condition"))
        return 1
    }
}

@main
private struct Main {
    static func main() {
        Foundation.exit(runMain())
    }
}

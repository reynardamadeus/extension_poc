//
//  BLERelay.swift
//  extension_poc
//
//  The Mac side of the direct Bluetooth link.
//  • Advertises the "Error Relay" service.
//  • A watch must be paired (approved on this Mac after comparing a code)
//    and must prove it has the shared key on every connection.
//  • Only verified watches receive errors; everything is encrypted.
//  Everything runs on the main queue.
//

import CoreBluetooth
import CryptoKit
import Foundation

/// A watch the user approved on this Mac.
nonisolated struct TrustedWatch: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
}

nonisolated enum TrustedWatches {
    private static let key = "trustedWatches"

    static var all: [TrustedWatch] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([TrustedWatch].self, from: data)) ?? []
    }

    /// Adding a watch replaces an older entry with the same name: that's the same watch
    /// that got a new ID (reinstalled app), not a second watch. Its old key is deleted too.
    static func add(_ watch: TrustedWatch) {
        let list = all
        for old in list where old.id != watch.id && old.name == watch.name {
            KeyStore.delete(account: keychainAccount(old.id))
        }
        save(list.filter { $0.id != watch.id && $0.name != watch.name } + [watch])
    }

    /// One-time cleanup of the duplicates made before: keeps the newest entry per name.
    static func removeDuplicates() {
        let list = all
        var keep: [TrustedWatch] = []
        for watch in list.reversed() where !keep.contains(where: { $0.name == watch.name }) {
            keep.insert(watch, at: 0)
        }
        guard keep.count != list.count else { return }
        for old in list where !keep.contains(old) { KeyStore.delete(account: keychainAccount(old.id)) }
        save(keep)
    }

    static func remove(id: String) {
        save(all.filter { $0.id != id })
        KeyStore.delete(account: keychainAccount(id))
    }

    static func keychainAccount(_ id: String) -> String { "watch.\(id)" }

    private static func save(_ list: [TrustedWatch]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: key)
    }
}

/// A watch asking to pair, shown as an Allow / Don't Allow alert on the Mac.
nonisolated struct PairingRequest: Identifiable, Sendable {
    let id = UUID()
    let watchID: String
    let watchName: String
    let code: String
}

nonisolated final class BLERelay: NSObject, CBPeripheralManagerDelegate, @unchecked Sendable {
    typealias OpenHandler = @MainActor (_ generation: Int, _ index: Int) -> (ok: Bool, message: String)

    var onStatus: (@MainActor (String) -> Void)?
    var currentSnapshot: (@MainActor () -> DiagnosticSnapshot)?
    var onOpen: OpenHandler?
    var onPairingRequest: (@MainActor (PairingRequest) -> Void)?
    var onPairingCancelled: (@MainActor (_ watchID: String) -> Void)?
    var onTrustedChanged: (@MainActor () -> Void)?
    /// Watch double tap: read an error. The answer goes back so the watch can tap success / failure.
    var onSpeak: (@MainActor (_ generation: Int, _ index: Int) -> (ok: Bool, message: String))?
    /// Watch double tap with no error shown: say the current state.
    var onStatusRequest: (@MainActor () -> (ok: Bool, message: String))?

    /// One connected watch.
    private final class Session {
        let central: CBCentral
        var watchID: String?
        var watchName = "Apple Watch"
        var key: SymmetricKey?
        var nonce: String?
        var pendingKey: SymmetricKey?
        var authenticated = false
        init(central: CBCentral) { self.central = central }
    }

    private enum Kind { case control, snapshot }

    private var manager: CBPeripheralManager?
    private var serviceAdded = false
    private var sessions: [UUID: Session] = [:]
    private var outgoing: [(value: Data, central: CBCentral, kind: Kind)] = []

    private let messageCharacteristic = CBMutableCharacteristic(
        type: CBUUID(string: BLEKeys.messageUUID), properties: [.notify], value: nil, permissions: [.readable])
    private let commandCharacteristic = CBMutableCharacteristic(
        type: CBUUID(string: BLEKeys.commandUUID), properties: [.write], value: nil, permissions: [.writeable])

    // MARK: - Public

    /// Paired watches connected right now (0 → the Mac plays sounds instead).
    var verifiedWatchCount: Int { sessions.values.filter(\.authenticated).count }

    func start() {
        guard manager == nil else { return }
        manager = CBPeripheralManager(delegate: self, queue: nil)   // nil = main queue
    }

    /// Sends the new error list to every verified watch.
    func send(_ snapshot: DiagnosticSnapshot) {
        for session in sessions.values where session.authenticated {
            sendSnapshot(snapshot, to: session)
        }
    }

    /// The user's answer to a pairing alert.
    func answerPairing(watchID: String, allow: Bool) {
        guard let session = sessions.values.first(where: { $0.watchID == watchID && $0.pendingKey != nil }) else { return }
        defer { session.pendingKey = nil }
        guard allow, let key = session.pendingKey else {
            enqueue(BLEMessage(t: "denied"), to: session, kind: .control)
            return
        }
        KeyStore.save(key, account: TrustedWatches.keychainAccount(watchID))
        TrustedWatches.add(TrustedWatch(id: watchID, name: session.watchName))
        session.key = key
        session.authenticated = true
        enqueue(BLEMessage(t: "paired"), to: session, kind: .control)
        updateStatus()
        sendCurrentSnapshot(to: session)
        MainActor.assumeIsolated { onTrustedChanged?() }
    }

    /// Removes a watch: it must pair again before it gets anything.
    func forget(watchID: String) {
        TrustedWatches.remove(id: watchID)
        for session in sessions.values where session.watchID == watchID {
            session.key = nil
            session.authenticated = false
            enqueue(BLEMessage(t: "unpaired"), to: session, kind: .control)
        }
        updateStatus()
        MainActor.assumeIsolated { onTrustedChanged?() }
    }

    // MARK: - Sending

    private func enqueue(_ message: BLEMessage, to session: Session, kind: Kind) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        if kind == .snapshot {
            // Newest error list wins; the watch restarts at the next start flag.
            outgoing.removeAll { $0.central.identifier == session.central.identifier && $0.kind == .snapshot }
        }
        let size = max(19, session.central.maximumUpdateValueLength - 1)
        outgoing += BLEKeys.chunks(data, size: size).map { (value: $0, central: session.central, kind: kind) }
        pump()
    }

    /// Sends queued chunks until Bluetooth's buffer is full; resumes in `isReady`.
    private func pump() {
        guard let manager else { return }
        while let next = outgoing.first {
            guard manager.updateValue(next.value, for: messageCharacteristic,
                                      onSubscribedCentrals: [next.central]) else { return }
            outgoing.removeFirst()
        }
    }

    private func sendSnapshot(_ snapshot: DiagnosticSnapshot, to session: Session) {
        guard session.authenticated, let key = session.key,
              let plain = try? JSONEncoder().encode(CompactSnapshot(snapshot)),
              let sealed = SecureLink.seal(plain, key: key) else { return }
        enqueue(BLEMessage(t: "snap", d: sealed), to: session, kind: .snapshot)
    }

    private func sendCurrentSnapshot(to session: Session) {
        if let snapshot = MainActor.assumeIsolated({ currentSnapshot?() }) {
            sendSnapshot(snapshot, to: session)
        }
    }

    private func sendResult(ok: Bool, message: String, to session: Session) {
        guard let key = session.key,
              let plain = try? JSONEncoder().encode(BLEResult(ok: ok, message: message)),
              let sealed = SecureLink.seal(plain, key: key) else { return }
        enqueue(BLEMessage(t: "res", d: sealed), to: session, kind: .control)
    }

    private func report(_ text: String) {
        MainActor.assumeIsolated { onStatus?(text) }
    }

    private func updateStatus() {
        let verified = sessions.values.filter(\.authenticated)
        if let first = verified.first {
            report(verified.count == 1 ? "\(first.watchName) connected" : "\(verified.count) watches connected")
        } else {
            report("Waiting for the watch…")
        }
    }

    // MARK: - Commands from the watch

    private func handle(command: String, from central: CBCentral) {
        let session = sessions[central.identifier] ?? {
            let new = Session(central: central)
            sessions[central.identifier] = new
            return new
        }()
        let parts = command.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)

        switch parts.first {
        case "hello" where parts.count >= 2:
            // A watch introduces itself. Known → challenge it. Unknown → it must pair.
            session.watchID = parts[1]
            session.authenticated = false
            if let key = KeyStore.load(account: TrustedWatches.keychainAccount(parts[1])) {
                session.key = key
                session.watchName = TrustedWatches.all.first(where: { $0.id == parts[1] })?.name ?? session.watchName
                // Key survived but the list didn't (the sandbox started with empty settings):
                // put the watch back in "paired watches" so the Mac shows it again.
                if !TrustedWatches.all.contains(where: { $0.id == parts[1] }) {
                    TrustedWatches.add(TrustedWatch(id: parts[1], name: session.watchName))
                    MainActor.assumeIsolated { onTrustedChanged?() }
                }
                report("Watch found: checking its pairing…")
                let nonce = SecureLink.randomNonce()
                session.nonce = nonce
                enqueue(BLEMessage(t: "challenge", n: nonce), to: session, kind: .control)
            } else {
                report("New watch found: waiting for it to send a pairing request…")
                enqueue(BLEMessage(t: "unpaired"), to: session, kind: .control)
            }

        case "auth" where parts.count >= 2:
            guard let key = session.key, let nonce = session.nonce,
                  SecureLink.verify(proof: parts[1], nonce: nonce, key: key) else {
                session.key = nil
                enqueue(BLEMessage(t: "unpaired"), to: session, kind: .control)
                return
            }
            session.nonce = nil
            session.authenticated = true
            enqueue(BLEMessage(t: "authed"), to: session, kind: .control)
            updateStatus()
            sendCurrentSnapshot(to: session)

        case "pair" where parts.count >= 3:
            // "pair:<watchID>:<publicKey>:<watch name>"
            let myKey = SecureLink.newKeyPair()
            guard let derived = SecureLink.derive(myKey: myKey, theirPublicKey: parts[2]) else { return }
            session.watchID = parts[1]
            session.watchName = parts.count > 3 && !parts[3].isEmpty ? parts[3] : "Apple Watch"
            session.pendingKey = derived.key
            session.authenticated = false
            enqueue(BLEMessage(t: "pairing", k: SecureLink.publicKeyString(myKey)), to: session, kind: .control)
            let request = PairingRequest(watchID: parts[1], watchName: session.watchName, code: derived.code)
            report("\(session.watchName) wants to pair: code \(derived.code)")
            MainActor.assumeIsolated { onPairingRequest?(request) }

        case "sec" where parts.count >= 2:
            // Encrypted command from a verified watch; anything else is ignored.
            guard session.authenticated, let key = session.key,
                  let plain = SecureLink.open(parts[1], key: key),
                  let text = String(data: plain, encoding: .utf8) else { return }
            handleSecure(text, session: session)

        default:
            break
        }
    }

    private func handleSecure(_ text: String, session: Session) {
        let parts = text.split(separator: ":")
        if parts.first == "fetch" {
            sendCurrentSnapshot(to: session)
        } else if parts.first == "status" {
            let result = MainActor.assumeIsolated { onStatusRequest?() } ?? (ok: false, message: "Mac app not ready")
            sendResult(ok: result.ok, message: result.message, to: session)
        } else if parts.count == 3, parts[0] == "speak", let generation = Int(parts[1]), let index = Int(parts[2]) {
            let result = MainActor.assumeIsolated { onSpeak?(generation, index) } ?? (ok: false, message: "Mac app not ready")
            sendResult(ok: result.ok, message: result.message, to: session)
            sendCurrentSnapshot(to: session)                     // keep the watch's list fresh
        } else if parts.count == 3, parts[0] == "open", let generation = Int(parts[1]), let index = Int(parts[2]) {
            let result = MainActor.assumeIsolated { onOpen?(generation, index) } ?? (ok: false, message: "Mac app not ready")
            sendResult(ok: result.ok, message: result.message, to: session)
            if !result.ok { sendCurrentSnapshot(to: session) }   // the watch's list was out of date
        }
    }

    // MARK: - CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            guard !serviceAdded else { return }
            let service = CBMutableService(type: CBUUID(string: BLEKeys.serviceUUID), primary: true)
            service.characteristics = [messageCharacteristic, commandCharacteristic]
            peripheral.add(service)
            serviceAdded = true
        case .poweredOff: report("Bluetooth is off")
        case .unauthorized: report("Bluetooth not allowed (System Settings → Privacy & Security → Bluetooth)")
        case .unsupported: report("This Mac doesn't support Bluetooth LE")
        default: report("Starting Bluetooth…")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error { report("Bluetooth failed: \(error.localizedDescription)"); return }
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: BLEKeys.serviceUUID)],
            CBAdvertisementDataLocalNameKey: BLEKeys.localName,
        ])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error { report("Advertising failed: \(error.localizedDescription)") } else { updateStatus() }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        guard characteristic.uuid == messageCharacteristic.uuid, sessions[central.identifier] == nil else { return }
        sessions[central.identifier] = Session(central: central)   // nothing is sent until it says hello
        report("A watch connected: waiting for it to say hello…")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard characteristic.uuid == messageCharacteristic.uuid,
              let session = sessions.removeValue(forKey: central.identifier) else { return }
        outgoing.removeAll { $0.central.identifier == central.identifier }
        if session.pendingKey != nil, let watchID = session.watchID {
            MainActor.assumeIsolated { onPairingCancelled?(watchID) }
        }
        updateStatus()
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        pump()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        var commands: [(String, CBCentral)] = []
        for request in requests where request.characteristic.uuid == commandCharacteristic.uuid {
            if let value = request.value, let text = String(data: value, encoding: .utf8) {
                commands.append((text, request.central))
            }
        }
        if let first = requests.first { peripheral.respond(to: first, withResult: .success) }
        for (text, central) in commands { handle(command: text, from: central) }
    }
}

//
//  MacLink.swift
//  watch Watch App
//
//  The watch side of the direct Bluetooth link.
//  • Finds the Mac app's "Error Relay" service and connects (and reconnects).
//  • First time: pairs. Both devices show a 4-digit code; the user approves
//    on the Mac. The shared key is kept in the Keychain.
//  • Every connection: proves it has the key, then receives encrypted errors
//    and sends encrypted "open" commands.
//  Runs on the main queue.
//

import CoreBluetooth
import CryptoKit
import Foundation
import WatchKit

nonisolated final class MacLink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    var onStatus: (@MainActor (_ text: String, _ connected: Bool) -> Void)?
    /// Non-nil while pairing: the code to compare with the Mac. Nil when done.
    var onPairingCode: (@MainActor (String?) -> Void)?
    var onSnapshot: (@MainActor (DiagnosticSnapshot) -> Void)?
    var onResult: (@MainActor (_ ok: Bool, _ message: String) -> Void)?

    private let serviceUUID = CBUUID(string: BLEKeys.serviceUUID)
    private let messageUUID = CBUUID(string: BLEKeys.messageUUID)
    private let commandUUID = CBUUID(string: BLEKeys.commandUUID)
    private static let keyAccount = "mac"

    private var central: CBCentralManager?
    private var mac: CBPeripheral?
    private var command: CBCharacteristic?
    private var buffer = Data()
    private var wantsConnection = false

    private var key: SymmetricKey? = KeyStore.load(account: MacLink.keyAccount)
    private var authenticated = false
    private var pairingKey: P256.KeyAgreement.PrivateKey?
    private var pendingKey: SymmetricKey?
    /// Gives up on a connection that never finishes the hello (stale Bluetooth link,
    /// e.g. after the Mac app restarted), so it can't hang on "Connecting…" forever.
    private var handshakeWatchdog: DispatchWorkItem?

    /// A stable random ID for this watch (no personal data).
    /// Kept in the Keychain, next to the pairing key: UserDefaults is wiped when the app is
    /// reinstalled (new Xcode build, TestFlight), the Keychain isn't. A new ID with the old
    /// key made the Mac see a "new" watch every time and pile up paired watches.
    private let watchID: String = {
        if let saved = KeyStore.loadString(account: "watchID") { return saved }
        let id = UserDefaults.standard.string(forKey: "watchID") ?? UUID().uuidString   // older builds
        KeyStore.saveString(id, account: "watchID")
        UserDefaults.standard.set(id, forKey: "watchID")
        return id
    }()

    // MARK: - Public

    func connect() {
        wantsConnection = true
        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil)    // nil = main queue
        } else {
            scanIfNeeded()
        }
    }

    func disconnect() {
        wantsConnection = false
        central?.stopScan()
        if let mac { central?.cancelPeripheralConnection(mac) }
    }

    /// "Find my Mac again": drops the current (maybe stuck) link and starts over,
    /// so the Mac gets a fresh hello and shows the pairing code if it needs one.
    func rediscover() {
        wantsConnection = true
        guard let central else { connect(); return }
        if let mac {
            central.cancelPeripheralConnection(mac)   // → didDisconnect → reset → new search
        } else {
            central.stopScan()
            scanIfNeeded()
        }
    }

    /// Forget the pairing; the next connection pairs again.
    func forgetMac() {
        KeyStore.delete(account: Self.keyAccount)
        key = nil
        authenticated = false
        if let mac { central?.cancelPeripheralConnection(mac) }   // reconnects and pairs
    }

    /// Returns false when not connected and verified.
    func open(generation: Int, index: Int) -> Bool {
        writeSecure("open:\(generation):\(index)")
    }

    func requestSnapshot() {
        _ = writeSecure("fetch")
    }

    /// Asks the Mac to say the current state ("No errors yet"…) through VoiceOver.
    func requestStatus() -> Bool {
        writeSecure("status")
    }

    /// Asks the Mac to read this error aloud through VoiceOver. False when not connected.
    func speak(generation: Int, index: Int) -> Bool {
        writeSecure("speak:\(generation):\(index)")
    }

    // MARK: - Writing

    private func write(_ text: String) -> Bool {
        guard let mac, let command, mac.state == .connected else { return false }
        mac.writeValue(Data(text.utf8), for: command, type: .withResponse)
        return true
    }

    private func writeSecure(_ text: String) -> Bool {
        guard authenticated, let key, let sealed = SecureLink.seal(Data(text.utf8), key: key) else { return false }
        return write("sec:\(sealed)")
    }

    // MARK: - Pairing / verification

    private func startPairing() {
        let myKey = SecureLink.newKeyPair()
        pairingKey = myKey
        let name = MainActor.assumeIsolated { WKInterfaceDevice.current().name }
            .replacingOccurrences(of: ":", with: " ")
            .prefix(40)
        _ = write("pair:\(watchID):\(SecureLink.publicKeyString(myKey)):\(name)")
        report("Pairing with your Mac…", connected: false)
    }

    private func handle(_ message: BLEMessage) {
        switch message.t {
        case "challenge":
            if let key, let nonce = message.n {
                _ = write("auth:\(SecureLink.proof(nonce: nonce, key: key))")
            } else {
                startPairing()
            }

        case "unpaired":
            // The Mac doesn't know us (or forgot us): drop our key and pair.
            KeyStore.delete(account: Self.keyAccount)
            key = nil
            authenticated = false
            startPairing()

        case "pairing":
            guard let pairingKey, let theirKey = message.k,
                  let derived = SecureLink.derive(myKey: pairingKey, theirPublicKey: theirKey) else { return }
            pendingKey = derived.key
            let code = derived.code
            handshakeDone()
            MainActor.assumeIsolated { onPairingCode?(code) }
            report("Compare the code with your Mac", connected: false)

        case "paired":
            guard let pendingKey else { return }
            KeyStore.save(pendingKey, account: Self.keyAccount)
            key = pendingKey
            self.pendingKey = nil
            pairingKey = nil
            authenticated = true
            MainActor.assumeIsolated { onPairingCode?(nil) }
            report("Paired with your Mac", connected: true)

        case "denied":
            pendingKey = nil
            pairingKey = nil
            MainActor.assumeIsolated { onPairingCode?(nil) }
            report("Pairing was declined on the Mac. Reopen the app to try again.", connected: false)
            disconnect()

        case "authed":
            handshakeDone()
            authenticated = true
            report("Connected to your Mac", connected: true)

        case "snap":
            guard let key, let sealed = message.d, let plain = SecureLink.open(sealed, key: key),
                  let compact = try? JSONDecoder().decode(CompactSnapshot.self, from: plain) else { return }
            let snapshot = compact.snapshot
            MainActor.assumeIsolated { onSnapshot?(snapshot) }

        case "res":
            guard let key, let sealed = message.d, let plain = SecureLink.open(sealed, key: key),
                  let result = try? JSONDecoder().decode(BLEResult.self, from: plain) else { return }
            MainActor.assumeIsolated { onResult?(result.ok, result.message) }

        default:
            break
        }
    }

    // MARK: - Connection

    private func scanIfNeeded() {
        guard wantsConnection, mac == nil, let central, central.state == .poweredOn else { return }
        if let known = central.retrieveConnectedPeripherals(withServices: [serviceUUID]).first {
            attach(known)
            return
        }
        report("Searching for your Mac…", connected: false)
        central.scanForPeripherals(withServices: [serviceUUID], options: nil)
    }

    private func attach(_ peripheral: CBPeripheral) {
        mac = peripheral
        peripheral.delegate = self
        central?.stopScan()
        central?.connect(peripheral, options: nil)
        report("Connecting to your Mac…", connected: false)
        startWatchdog(for: peripheral)
    }

    private func startWatchdog(for peripheral: CBPeripheral) {
        handshakeWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            // Only a shown pairing code (pendingKey) waits for the user; everything else should be quick.
            guard let self, self.mac === peripheral, !self.authenticated, self.pendingKey == nil else { return }
            self.report("No answer from your Mac. Retrying…", connected: false)
            self.central?.cancelPeripheralConnection(peripheral)
            // A connection that never opened may not report a disconnect: start over ourselves.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.mac === peripheral, peripheral.state != .connected else { return }
                self.reset("Searching for your Mac…")
            }
        }
        handshakeWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
    }

    /// The Mac answered (connected, or pairing in progress): no more timeout.
    private func handshakeDone() {
        handshakeWatchdog?.cancel()
        handshakeWatchdog = nil
    }

    private func reset(_ message: String) {
        handshakeDone()
        mac = nil
        command = nil
        buffer = Data()
        authenticated = false
        if pendingKey != nil || pairingKey != nil {
            pendingKey = nil
            pairingKey = nil
            MainActor.assumeIsolated { onPairingCode?(nil) }
        }
        report(message, connected: false)
        scanIfNeeded()
    }

    private func report(_ text: String, connected: Bool) {
        MainActor.assumeIsolated { onStatus?(text, connected) }
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: scanIfNeeded()
        case .poweredOff: report("Bluetooth is off", connected: false)
        case .unauthorized: report("Allow Bluetooth for this app in Settings", connected: false)
        default: report("Bluetooth unavailable", connected: false)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard mac == nil else { return }
        attach(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        reset("Couldn't connect. Retrying…")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard mac == nil || mac === peripheral else { return }   // a late report about an old link
        reset(wantsConnection ? "Mac disconnected. Searching…" : "Disconnected")
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([messageUUID, commandUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let characteristics = service.characteristics ?? []
        guard error == nil,
              characteristics.contains(where: { $0.uuid == commandUUID }),
              characteristics.contains(where: { $0.uuid == messageUUID }) else {
            central?.cancelPeripheralConnection(peripheral)        // half-visible service: start over
            return
        }
        for characteristic in characteristics {
            if characteristic.uuid == commandUUID {
                command = characteristic
            } else if characteristic.uuid == messageUUID {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == messageUUID else { return }
        // Subscribing failed (often a stale link after the Mac app restarted): reconnect fresh.
        guard error == nil, characteristic.isNotifying else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        // Subscribed: introduce ourselves. The Mac answers with a challenge or "unpaired".
        _ = write("hello:\(watchID)")
    }

    /// The Mac app restarted and re-published its service: the old handles are gone.
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard invalidatedServices.contains(where: { $0.uuid == serviceUUID }) else { return }
        central?.cancelPeripheralConnection(peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == messageUUID, let value = characteristic.value, !value.isEmpty else { return }
        let flags = value[value.startIndex]
        if flags & BLEKeys.chunkStart != 0 { buffer = Data() }
        buffer.append(value.dropFirst())
        guard flags & BLEKeys.chunkEnd != 0,
              let message = try? JSONDecoder().decode(BLEMessage.self, from: buffer) else { return }
        buffer = Data()
        handle(message)
    }
}

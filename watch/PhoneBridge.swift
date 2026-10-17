//
//  PhoneBridge.swift
//  watch (iPhone relay app)
//
//  Relays watch requests to the Mac:
//    Watch --WatchConnectivity--> iPhone --HTTP--> Mac
//  The watch's sendMessage wakes this app in the background, so it only
//  needs to be opened once (to allow local network access).
//

import Foundation
import Combine
import Network
import WatchConnectivity

/// Lets us pass WatchConnectivity's reply handler into network callbacks.
nonisolated struct ReplyBox: @unchecked Sendable {
    let send: ([String: Any]) -> Void
}

final class PhoneBridge: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = PhoneBridge()

    @Published var macAddress: String {
        didSet { UserDefaults.standard.set(macAddress, forKey: MacClient.addressKey) }
    }
    @Published var pairingCode: String {
        didSet { UserDefaults.standard.set(pairingCode, forKey: MacClient.codeKey) }
    }
    @Published private(set) var status = "Not tested yet"
    @Published private(set) var watchStatus = "Checking…"
    @Published private(set) var snapshot = DiagnosticSnapshot.empty
    @Published private(set) var discoveryStatus = "Looking for your Mac…"

    private var browser: NWBrowser?

    override init() {
        macAddress = UserDefaults.standard.string(forKey: MacClient.addressKey) ?? MacClient.defaultAddress
        pairingCode = UserDefaults.standard.string(forKey: MacClient.codeKey) ?? ""
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { watchStatus = "WatchConnectivity not supported"; return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Finds the Mac app on the Wi-Fi network (Bonjour) and fills in its address.
    func startDiscovery() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: RelayKeys.bonjourType, domain: nil),
                                using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.handleBrowseResults(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                MainActor.assumeIsolated { self?.discoveryStatus = "Discovery failed: \(error.localizedDescription)" }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        for result in results {
            guard case .bonjour(let txt) = result.metadata,
                  let host = txt["host"], let port = txt["port"] else { continue }
            let address = "http://\(host):\(port)"
            if macAddress != address { macAddress = address }
            var name = host
            if case .service(let serviceName, _, _, _) = result.endpoint { name = serviceName }
            discoveryStatus = "Found \(name)"
            return
        }
        discoveryStatus = "Looking for your Mac… (is the Mac app running on the same Wi-Fi?)"
    }

    /// Run once in the foreground: this is what triggers the Local Network permission prompt.
    func testConnection() {
        status = "Connecting…"
        MacClient.saved.fetch { result in
            Task { @MainActor in
                switch result {
                case .success(let snapshot):
                    self.snapshot = snapshot
                    self.status = "Connected: \(snapshot.diagnostics.count) error(s) in \(snapshot.projectName)"
                case .failure(let error):
                    self.status = "Failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func refreshWatchStatus() {
        let session = WCSession.default
        guard session.activationState == .activated else { watchStatus = "Connecting to watch…"; return }
        if !session.isPaired {
            watchStatus = "No Apple Watch paired"
        } else if !session.isWatchAppInstalled {
            watchStatus = "Watch app not installed yet"
        } else {
            watchStatus = session.isReachable ? "Watch app is open and connected" : "Watch app installed (not open)"
        }
    }

    // MARK: - WCSessionDelegate (called on a background queue)

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in self.refreshWatchStatus() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.refreshWatchStatus() }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.refreshWatchStatus() }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        let reply = ReplyBox(send: replyHandler)
        let client = MacClient.saved

        switch message[RelayKeys.command] as? String {
        case RelayKeys.fetch?:
            client.fetch { result in
                switch result {
                case .success(let snapshot):
                    reply.send([RelayKeys.snapshot: (try? JSONEncoder().encode(snapshot)) ?? Data()])
                    Task { @MainActor in
                        self.snapshot = snapshot
                        self.status = "Connected (relaying for the watch)"
                    }
                case .failure(let error):
                    reply.send([RelayKeys.error: error.localizedDescription])
                }
            }

        case RelayKeys.open?:
            guard let id = message[RelayKeys.id] as? String else {
                reply.send([RelayKeys.error: "Missing error id"])
                return
            }
            client.open(id: id) { result in
                switch result {
                case .success: reply.send([RelayKeys.ok: true])
                case .failure(let error): reply.send([RelayKeys.error: error.localizedDescription])
                }
            }

        default:
            reply.send([RelayKeys.error: "Unknown command"])
        }
    }
}

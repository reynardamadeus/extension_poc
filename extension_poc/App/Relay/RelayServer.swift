//
//  RelayServer.swift
//  extension_poc
//
//  A tiny HTTP server on the local network (Network framework).
//  The iPhone app calls:
//      GET  /snapshot            → current syntax errors (JSON)
//      POST /open  {"id": "…"}   → open that error in Xcode
//  Every request must carry the pairing code header.
//

import Foundation
import Network

nonisolated struct HTTPRequest: Sendable {
    var method: String
    var path: String
    var headers: [String: String]   // lower-cased names
    var body: Data

    /// Returns nil until the whole request (headers + body) has arrived.
    init?(data: Data) {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard data.endIndex - bodyStart >= length else { return nil }

        self.method = String(requestLine[0])
        self.path = String(requestLine[1].split(separator: "?").first ?? "/")
        self.headers = headers
        self.body = data.subdata(in: bodyStart..<(bodyStart + length))
    }
}

nonisolated struct HTTPResponse: Sendable {
    var status: Int
    var reason: String
    var body: Data

    static func json<T: Encodable>(_ value: T) -> HTTPResponse {
        HTTPResponse(status: 200, reason: "OK", body: (try? JSONEncoder().encode(value)) ?? Data())
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        let body = (try? JSONEncoder().encode([RelayKeys.error: message])) ?? Data()
        return HTTPResponse(status: status, reason: message, body: body)
    }

    var serialized: Data {
        let head = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

/// Everything runs on the main queue, so the handler can touch UI state.
nonisolated final class RelayServer: @unchecked Sendable {
    typealias Handler = @MainActor (HTTPRequest) -> HTTPResponse

    private let handler: Handler
    private let onStatus: @MainActor (String) -> Void
    private var listener: NWListener?

    init(handler: @escaping Handler, onStatus: @escaping @MainActor (String) -> Void) {
        self.handler = handler
        self.onStatus = onStatus
    }

    /// - Parameter advertisedHost: e.g. "Reynards-MacBook-Pro.local", published over
    ///   Bonjour so the iPhone app can connect without typing an address.
    func start(port: UInt16, advertisedHost: String?) {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.report("Running on port \(port)")
                case .failed(let error): self?.report("Failed: \(error.localizedDescription)")
                case .cancelled: self?.report("Stopped")
                default: self?.report("Starting…")
                }
            }
            if let advertisedHost {
                listener.service = NWListener.Service(
                    name: nil, type: RelayKeys.bonjourType, domain: nil,
                    txtRecord: NWTXTRecord(["host": advertisedHost, "port": String(port)]))
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            report("Failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func report(_ text: String) {
        MainActor.assumeIsolated { onStatus(text) }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let request = HTTPRequest(data: buffer) {
                let response = MainActor.assumeIsolated { self.handler(request) }
                connection.send(content: response.serialized, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            } else if isComplete || error != nil || buffer.count > 1_000_000 {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }
}

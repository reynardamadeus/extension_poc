//
//  MacClient.swift
//  watch (iPhone relay app)
//
//  Talks HTTP to the Mac app's relay server on the local network.
//

import Foundation

nonisolated struct MacClient: Sendable {
    static let addressKey = "macAddress"
    static let codeKey = "pairingCode"
    /// Fallback when Bonjour discovery hasn't found the Mac yet.
    static let defaultAddress = "http://Reynards-MacBook-Pro.local:8765"

    var address: String
    var code: String

    static var saved: MacClient {
        MacClient(address: UserDefaults.standard.string(forKey: addressKey) ?? defaultAddress,
                  code: UserDefaults.standard.string(forKey: codeKey) ?? "")
    }

    enum ClientError: LocalizedError {
        case noAddress
        case server(String)

        var errorDescription: String? {
            switch self {
            case .noAddress: return "Enter the Mac address first"
            case .server(let message): return message
            }
        }
    }

    func fetch(completion: @escaping @Sendable (Result<DiagnosticSnapshot, Error>) -> Void) {
        send(path: "/snapshot") { result in
            completion(result.flatMap { data in
                Result { try JSONDecoder().decode(DiagnosticSnapshot.self, from: data) }
            })
        }
    }

    func open(id: String, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        let body = try? JSONEncoder().encode([RelayKeys.id: id])
        send(path: "/open", method: "POST", body: body) { result in
            completion(result.map { _ in () })
        }
    }

    private func send(path: String, method: String = "GET", body: Data? = nil,
                      completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        var base = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { completion(.failure(ClientError.noAddress)); return }
        if !base.lowercased().hasPrefix("http") { base = "http://" + base }
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path) else {
            completion(.failure(ClientError.server("That address doesn't look right")))
            return
        }

        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(code, forHTTPHeaderField: RelayKeys.pairingHeader)
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { completion(.failure(error)); return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let data else {
                let message = status == 401 ? "Wrong pairing code" : "Mac replied with status \(status)"
                completion(.failure(ClientError.server(message)))
                return
            }
            completion(.success(data))
        }.resume()
    }
}

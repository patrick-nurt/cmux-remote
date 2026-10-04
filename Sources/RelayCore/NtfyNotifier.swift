import AsyncHTTPClient
import Foundation
import SharedKit

/// Forwards cmux notification events to an ntfy server (ntfy.sh or
/// self-hosted). ntfy's iOS app subscribes to the topic and surfaces the
/// message as a push notification — no Apple Developer account, no APNs
/// credentials. See https://docs.ntfy.sh/publish/.
///
/// Disabled while the configured topic is empty, mirroring the `apns` gate.
public final class NtfyNotifier: @unchecked Sendable {
    private let config: @Sendable () -> RelayConfig.Ntfy
    private let client: HTTPClient

    public init(config: @escaping @Sendable () -> RelayConfig.Ntfy, client: HTTPClient) {
        self.config = config
        self.client = client
    }

    public var isEnabled: Bool { !config().topic.isEmpty }

    /// Sends one notification. Returns the ntfy message id on success.
    @discardableResult
    public func send(_ notification: NotificationRecord) async throws -> String {
        let cfg = config()
        guard !cfg.topic.isEmpty else { throw APNsProviderError.disabled }

        // ntfy JSON publish: title, message, priority, tags. `priority` must
        // be an INTEGER (1=min .. 5=urgent) — the string names are only
        // accepted in header mode; "default" as a JSON string 400s (40024).
        struct NtfyMessage: Encodable {
            let topic: String
            let title: String
            let message: String
            let priority: Int
            let tags: [String]
        }
        let priority = ntfyPriorityInt(cfg.priority)
        let message = NtfyMessage(
            topic: cfg.topic,
            title: notification.title,
            message: notification.body,
            priority: priority,
            tags: ["computer"]
        )
        let body = try JSONEncoder().encode(message)

        // ntfy's JSON publish mode POSTs to the server ROOT with the topic in
        // the body; POSTing JSON to /<topic> instead makes ntfy treat the raw
        // JSON as the message text. See docs.ntfy.sh/publish/#publish-as-json.
        var request = HTTPClientRequest(url: cfg.server + "/")
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/json")
        if !cfg.token.isEmpty {
            request.headers.add(name: "Authorization", value: "Bearer \(cfg.token)")
        }
        request.body = .bytes(body)

        let response = try await client.execute(request, timeout: .seconds(10))
        let payload = try? await response.body.collect(upTo: 1 << 16)
        let text = payload.map { String(buffer: $0) } ?? ""
        guard (200..<300).contains(response.status.code) else {
            throw NtfyError.rejected(status: Int(response.status.code), body: String(text.prefix(200)))
        }
        // ntfy returns the message id as plain text on success.
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Convenience entry point matching `InboxPushFanout.deliver` so the event
    /// handler can call both fanouts symmetrically.
    public func deliver(event: EventFrame) async {
        guard isEnabled, let notification = InboxNotification.record(from: event) else { return }
        do {
            _ = try await send(notification)
        } catch {
            // Best-effort: a failed ntfy push must never break the event stream.
        }
    }
}

public enum NtfyError: Error, Equatable {
    case rejected(status: Int, body: String)
}

/// ntfy accepts 1=min, 2=low, 3=default, 4=high, 5=urgent/max. Names are
/// accepted for operator convenience; unknown values fall back to default.
func ntfyPriorityInt(_ raw: String) -> Int {
    switch raw.lowercased() {
    case "1", "min": return 1
    case "2", "low": return 2
    case "4", "high": return 4
    case "5", "urgent", "max": return 5
    default: return 3
    }
}

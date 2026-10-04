import AsyncHTTPClient
import NIOCore
import NIOHTTP1
import NIOPosix
import SharedKit
import XCTest

@testable import RelayCore

/// Value box shared between the loopback ntfy stand-in and the test.
private final class CaptureBox: @unchecked Sendable {
    var method = ""
    var path = ""
    var contentType = ""
    var authorization = ""
    var body = Data()
}

/// Accepts one HTTP request, captures it into `CaptureBox`, replies with a
/// canned status + body, then closes. Used as the ntfy server under test.
private final class CaptureHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart

    let box: CaptureBox
    let status: HTTPResponseStatus
    let responseBody: String

    init(box: CaptureBox, status: HTTPResponseStatus, responseBody: String) {
        self.box = box
        self.status = status
        self.responseBody = responseBody
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part: HTTPServerRequestPart = self.unwrapInboundIn(data)
        switch part {
        case .head(let head):
            self.box.method = head.method.rawValue
            self.box.path = head.uri
            self.box.contentType = head.headers["content-type"].first ?? ""
            self.box.authorization = head.headers["authorization"].first ?? ""
        case .body(var buffer):
            self.box.body.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? [])
        case .end:
            let head = HTTPResponseHead(
                version: .http1_1, status: self.status,
                headers: HTTPHeaders([("content-type", "text/plain")]))
            context.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
            var body = ByteBufferAllocator().buffer(capacity: self.responseBody.utf8.count)
            body.writeString(self.responseBody)
            context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(body))), promise: nil)
            context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).whenComplete { _ in
                context.close(promise: nil)
            }
        }
    }
}

final class NtfyNotifierTests: XCTestCase {
    /// Binds a one-shot loopback ntfy stand-in; returns its ephemeral port.
    private func startMockNtfy(
        status: HTTPResponseStatus, body: String
    ) throws -> (port: Int, box: CaptureBox, channel: Channel, group: MultiThreadedEventLoopGroup) {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let box = CaptureBox()
        let channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .childChannelInitializer { child in
                child.pipeline.configureHTTPServerPipeline().flatMap {
                    child.pipeline.addHandler(CaptureHandler(box: box, status: status, responseBody: body))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        return (channel.localAddress!.port!, box, channel, group)
    }

    // MARK: - Config decode

    func testMinimalConfigGetsNtfyDefaults() throws {
        let cfg = try RelayConfig.decode(jsonString: #"{"listen":"0.0.0.0:4399"}"#)
        XCTAssertEqual(cfg.ntfy.server, "https://ntfy.sh")
        XCTAssertEqual(cfg.ntfy.topic, "")
        XCTAssertEqual(cfg.ntfy.token, "")
        XCTAssertEqual(cfg.ntfy.priority, "default")
    }

    func testParsesExplicitNtfyBlock() throws {
        let json = #"""
        {"listen":"0.0.0.0:4399",
         "ntfy":{"server":"https://ntfy.example","topic":"cmux-x","token":"tk_1","priority":"high"}}
        """#
        let cfg = try RelayConfig.decode(jsonString: json)
        XCTAssertEqual(cfg.ntfy.server, "https://ntfy.example")
        XCTAssertEqual(cfg.ntfy.topic, "cmux-x")
        XCTAssertEqual(cfg.ntfy.token, "tk_1")
        XCTAssertEqual(cfg.ntfy.priority, "high")
    }

    // MARK: - Priority mapping

    func testPriorityMapping() {
        XCTAssertEqual(ntfyPriorityInt("min"), 1)
        XCTAssertEqual(ntfyPriorityInt("low"), 2)
        XCTAssertEqual(ntfyPriorityInt("default"), 3)
        XCTAssertEqual(ntfyPriorityInt("high"), 4)
        XCTAssertEqual(ntfyPriorityInt("urgent"), 5)
        XCTAssertEqual(ntfyPriorityInt("max"), 5)
        XCTAssertEqual(ntfyPriorityInt("3"), 3)
        XCTAssertEqual(ntfyPriorityInt("5"), 5)
        XCTAssertEqual(ntfyPriorityInt("nonsense"), 3)
        XCTAssertEqual(ntfyPriorityInt(""), 3)
    }

    // MARK: - Disabled gate

    func testDisabledWhenTopicEmpty() async {
        let cfg = RelayConfig.Ntfy(server: "https://ntfy.sh", topic: "", token: "", priority: "default")
        let client = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { try? client.syncShutdown() }
        let notifier = NtfyNotifier(config: { cfg }, client: client)
        XCTAssertFalse(notifier.isEnabled)
        do {
            _ = try await notifier.send(Self.anyRecord())
            XCTFail("expected disabled error")
        } catch APNsProviderError.disabled {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Wire format (loopback)

    func testSendPostsNtfyJSONToServerRoot() async throws {
        let (port, box, serverChannel, group) = try startMockNtfy(status: .ok, body: "id12345")
        defer { try? serverChannel.close().wait(); try? group.syncShutdownGracefully() }

        let cfg = RelayConfig.Ntfy(
            server: "http://127.0.0.1:\(port)", topic: "cmux-topic-1",
            token: "tk_secret", priority: "high")
        let client = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { try? client.syncShutdown() }
        let notifier = NtfyNotifier(config: { cfg }, client: client)
        XCTAssertTrue(notifier.isEnabled)

        let id = try await notifier.send(Self.anyRecord())
        XCTAssertEqual(id, "id12345")

        XCTAssertEqual(box.method, "POST")
        XCTAssertEqual(box.path, "/")
        XCTAssertEqual(box.contentType, "application/json")
        XCTAssertEqual(box.authorization, "Bearer tk_secret")

        let json = try JSONSerialization.jsonObject(with: box.body) as! [String: Any]
        XCTAssertEqual(json["topic"] as? String, "cmux-topic-1")
        XCTAssertEqual(json["title"] as? String, "Agent finished")
        XCTAssertEqual(json["message"] as? String, "Build completed")
        // Regression: priority must be a JSON INTEGER — ntfy rejects the
        // string names in JSON mode with 400 code 40024 ("request body must
        // be valid JSON").
        XCTAssertEqual(json["priority"] as? Int, 4)
        XCTAssertEqual(json["tags"] as? [String], ["computer"])
    }

    func testErrorStatusThrowsRejected() async throws {
        let (port, _, serverChannel, group) = try startMockNtfy(status: .forbidden, body: "")
        defer { try? serverChannel.close().wait(); try? group.syncShutdownGracefully() }

        let cfg = RelayConfig.Ntfy(
            server: "http://127.0.0.1:\(port)", topic: "t", token: "", priority: "default")
        let client = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { try? client.syncShutdown() }
        let notifier = NtfyNotifier(config: { cfg }, client: client)

        do {
            _ = try await notifier.send(Self.anyRecord())
            XCTFail("expected rejected error")
        } catch let error as NtfyError {
            XCTAssertEqual(error, .rejected(status: 403, body: ""))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    private static func anyRecord() -> NotificationRecord {
        NotificationRecord(
            id: "n1", workspaceId: "ws1", surfaceId: "sf1",
            title: "Agent finished", subtitle: nil, body: "Build completed",
            ts: 1_700_000_000, threadId: "ws1")
    }
}

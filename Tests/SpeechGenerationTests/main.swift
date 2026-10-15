import Foundation

/// Offline HTTP fixtures: no credentials or paid provider calls are used.
@main
struct SpeechGenerationTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: \(message)") }
        print("PASS: \(message)")
    }

    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpeechFixture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = SpeechGenerationService(session: session)
        let mp3 = Data([0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 0])
        let key = "fixture-secret-123"
        let customMini = SpeechGenerationConfiguration(provider: .minimax, baseURL: "https://speech.example/v1",
                                                       model: "speech-2.8-turbo", voice: "My_Speaker")
        SpeechFixture.set { request, body in
            check(request.url?.absoluteString == "https://speech.example/v1/t2a_v2", "MiniMax uses configured base URL")
            check(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)", "MiniMax uses bearer credentials")
            let payload = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
            let voice = payload["voice_setting"] as! [String: Any]
            check(payload["model"] as? String == "speech-2.8-turbo" && voice["voice_id"] as? String == "My_Speaker",
                  "exact selected model and voice reach the provider")
            check(payload["stream"] as? Bool == false && payload["output_format"] as? String == "hex"
                  && voice["speed"] as? Double == 1.2 && payload["subtitle_enable"] == nil,
                  "speech is nonstreaming and does not claim subtitle alignment")
            let hex = mp3.map { String(format: "%02x", $0) }.joined()
            return .init(status: 200, data: Data("{\"base_resp\":{\"status_code\":0},\"data\":{\"status\":2,\"audio\":\"\(hex)\"}}".utf8))
        }
        let mini = try await service.generate(request: .init(text: "Demo narration.", configuration: customMini, speed: 1.2), apiKey: key)
        check(mini.audioData == mp3 && mini.fileExtension == "mp3", "MiniMax hex is decoded without audio corruption")

        SpeechFixture.set { request, body in
            let payload = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
            check(request.url?.path == "/v1/audio/speech" && request.httpMethod == "POST", "OpenAI uses audio/speech")
            check(payload["input"] as? String == "Hello." && payload["model"] as? String == "gpt-4o-mini-tts"
                  && payload["voice"] as? String == "coral" && payload["response_format"] as? String == "mp3",
                  "OpenAI uses its speech payload and requested MP3 output")
            return .init(status: 200, data: mp3, headers: ["Content-Type": "audio/mpeg"])
        }
        let openAI = try await service.generate(request: .init(text: "Hello.", configuration: .init(provider: .openAI)), apiKey: key)
        check(openAI.audioData == mp3, "OpenAI binary audio is preserved")
        SpeechFixture.set { request, _ in
            check(request.value(forHTTPHeaderField: "Authorization") == nil, "local compatible server can omit authentication")
            return .init(status: 200, data: mp3)
        }
        _ = try await service.generate(request: .init(text: "Local.", configuration:
            .init(provider: .openAICompatible, baseURL: "http://127.0.0.1:1234/v1", model: "local-tts", voice: "speaker")), apiKey: "")

        SpeechFixture.set { _, _ in .init(status: 200, data: mp3) }
        for base in ["http://api.openai.com/v1", "https://user:pass@api.openai.com/v1", "https://api.openai.com/v1?key=bad",
                     "https://api.openai.com/v1#secret", "file:///tmp/speech"] {
            await fails("unsafe endpoint rejected before sending") {
                _ = try await service.generate(request: .init(text: "Hello", configuration: .init(provider: .openAI, baseURL: base)), apiKey: key)
            }
        }
        await fails("empty exact model never silently falls back") {
            _ = try await service.generate(request: .init(text: "Hello", configuration: .init(provider: .minimax, model: "")), apiKey: key)
        }
        await fails("invalid speed rejected") {
            _ = try await service.generate(request: .init(text: "Hello", configuration: customMini, speed: .nan), apiKey: key)
        }
        await fails("oversized input rejected") {
            _ = try await service.generate(request: .init(text: String(repeating: "a", count: 4097), configuration: .init(provider: .openAI)), apiKey: key)
        }
        await fails("official provider requires a key") {
            _ = try await service.generate(request: .init(text: "Hello", configuration: customMini), apiKey: "")
        }
        check(SpeechFixture.requestCount == 0, "invalid input never starts a billable request")

        SpeechFixture.set { _, _ in .init(status: 401, data: Data("{\"error\":{\"message\":\"Invalid \(key); Bearer other-token\"}}".utf8)) }
        do {
            _ = try await service.generate(request: .init(text: "Hello", configuration: .init(provider: .openAI)), apiKey: key)
            fatalError("FAIL: HTTP failure should throw")
        } catch {
            check(!error.localizedDescription.contains(key) && !error.localizedDescription.contains("other-token")
                  && error.localizedDescription.contains("401"), "HTTP error includes status and redacts credentials")
        }
        check(SpeechFixture.requestCount == 1, "a billable POST is never automatically retried")

        SpeechFixture.set { _, _ in .init(status: 200, data: Data("{\"base_resp\":{\"status_code\":1008,\"status_msg\":\"Quota \(key)\"},\"data\":null}".utf8)) }
        do {
            _ = try await service.generate(request: .init(text: "Hello", configuration: customMini), apiKey: key)
            fatalError("FAIL: MiniMax business failure should throw")
        } catch {
            check(error.localizedDescription.contains("1008") && !error.localizedDescription.contains(key),
                  "MiniMax HTTP 200 provider failure is surfaced and redacted")
        }
        for payload in ["{}", "{\"base_resp\":{\"status_code\":0},\"data\":null}",
                        "{\"base_resp\":{\"status_code\":0},\"data\":{\"audio\":\"4944zz\"}}"] {
            SpeechFixture.set { _, _ in .init(status: 200, data: Data(payload.utf8)) }
            await fails("invalid MiniMax response never creates audio") {
                _ = try await service.generate(request: .init(text: "Hello", configuration: customMini), apiKey: key)
            }
        }
        SpeechFixture.set { _, _ in .init(status: 200, data: Data("<html>Not audio</html>".utf8)) }
        await fails("HTML success response is not saved as MP3") {
            _ = try await service.generate(request: .init(text: "Hello", configuration: .init(provider: .openAI)), apiKey: key)
        }
        SpeechFixture.set { _, _ in .init(status: 200, data: mp3, headers: ["Content-Length": "100000000"]) }
        await fails("oversized Content-Length is rejected") {
            _ = try await service.generate(request: .init(text: "Hello", configuration: .init(provider: .openAI)), apiKey: key)
        }

        SpeechFixture.set { _, _ in nil }
        let task = Task { try await service.generate(request: .init(text: "Hello", configuration: customMini), apiKey: key) }
        for _ in 0..<100 where SpeechFixture.requestCount == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        check(SpeechFixture.requestCount == 1, "cancellation fixture started a request")
        task.cancel()
        do { _ = try await task.value; fatalError("FAIL: cancelled generation returned audio") }
        catch is CancellationError { check(true, "in-flight cancellation stays a CancellationError") }
        print("All speech gateway fixtures passed.")
    }

    static func fails(_ message: String, action: () async throws -> Void) async {
        do { try await action(); fatalError("FAIL: \(message)") }
        catch { check(true, message) }
    }
}

private final class SpeechFixture: URLProtocol, @unchecked Sendable {
    struct Reply { var status: Int; var data: Data; var headers: [String: String] = [:] }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: ((URLRequest, Data) -> Reply?)?
    nonisolated(unsafe) private static var count = 0
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    static func set(_ handler: @escaping (URLRequest, Data) -> Reply?) {
        lock.lock(); defer { lock.unlock() }; self.handler = handler; count = 0
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handler; Self.count += 1; Self.lock.unlock()
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count))
            }
        }
        guard let reply = handler?(request, body) else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

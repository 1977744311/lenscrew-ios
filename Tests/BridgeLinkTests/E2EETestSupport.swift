import CryptoKit
import Foundation
import Testing

@testable import BridgeLink

// E2EE 测试的共享底座：用与产品代码同一套 Swift 原语「反串」mac 侧
// （SecureChannelHost 的最小镜像），以及异步流的录制/轮询工具。
// 与 TS 侧的逐字节对齐由 SecureProtocolFixtureTests 单独钉死，
// 这里只验证两端状态机咬合。

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

func nowMs() -> Int {
    Int(Date().timeIntervalSince1970 * 1000)
}

// MARK: - 反串 mac 的最小 host

/// bridge/src/secure/channel.ts SecureChannelHost 的测试镜像：
/// 只保留握手判定、信任表、counter 防重放与信封加解密——够陪 phone 走完全流程。
final class FakeMacHost: @unchecked Sendable {
    let macDeviceId: String
    let displayName: String
    let identitySeed: Data
    let identityPublicKeyBase64: String

    private let lock = NSLock()
    var pairingWindowOpen = true
    var pairingExpiresAtMs: Int
    /// phoneDeviceId → 身份公钥 base64
    private(set) var trustedPhones: [String: String] = [:]
    private(set) var seenHandshakeModes: [HandshakeMode] = []
    private(set) var receivedPlaintexts: [String] = []
    /// 收到解密明文时的应答策略，返回要回给 phone 的明文数组
    var onPlaintext: (@Sendable (String) -> [String])?

    private struct PendingSession {
        let roomId: String
        let mode: HandshakeMode
        let keyEpoch: Int
        let phoneIdentityPublicKey: String
        let transcript: Data
        let sharedSecret: Data
    }

    private struct EstablishedSession {
        let roomId: String
        let keyEpoch: Int
        let keyPhoneToMac: Data
        let keyMacToPhone: Data
        var outboundCounter = 0
        var lastInboundCounter = 0
    }

    private enum SessionState {
        case pending(PendingSession)
        case established(EstablishedSession)
    }

    private var sessions: [String: SessionState] = [:]
    private var roomToPhone: [String: String] = [:]
    private var keyEpochs: [String: Int] = [:]

    init(macDeviceId: String = UUID().uuidString.lowercased(), displayName: String = "Fake Mac") {
        self.macDeviceId = macDeviceId
        self.displayName = displayName
        self.identitySeed = SecureCrypto.randomBytes(32)
        self.identityPublicKeyBase64 = try! SecureCrypto.ed25519PublicKeyRaw(seed: identitySeed)
            .base64EncodedString()
        self.pairingExpiresAtMs = nowMs() + 120_000
    }

    func pairingPayload(relay: String? = nil, lan: PairingPayload.LanEndpoint? = nil)
        -> PairingPayload
    {
        PairingPayload(
            v: 1, kind: "lenscrew-pair", macDeviceId: macDeviceId,
            macIdentityPublicKey: identityPublicKeyBase64, displayName: displayName,
            expiresAtMs: pairingExpiresAtMs, relay: relay, lan: lan
        )
    }

    func trustPhone(deviceId: String, identityPublicKey: String) {
        lock.withLock { trustedPhones[deviceId] = identityPublicKey }
    }

    /// 处理一帧，返回要回给 phone 的帧（可能多帧：envelope 应答）
    func handleFrame(_ frame: SecureFrame) throws -> [SecureFrame] {
        try lock.withLock {
            switch frame {
            case let .clientHello(hello): return try handleClientHello(hello)
            case let .clientAuth(auth): return try handleClientAuth(auth)
            case let .encryptedEnvelope(envelope): return try handleEnvelope(envelope)
            case .serverHello, .secureReady, .secureError:
                throw TestFailure("mac 收到了不该出现的下行帧: \(frame)")
            }
        }
    }

    /// mac 主动向 phone 推一帧密文（模拟 hub 事件下发）
    func sealToPhone(_ phoneDeviceId: String, plaintext: String) throws -> SecureFrame {
        try lock.withLock { try sealLocked(phoneDeviceId, plaintext: plaintext) }
    }

    // MARK: 内部（都在 lock 内）

    private func handleClientHello(_ hello: ClientHelloFrame) throws -> [SecureFrame] {
        seenHandshakeModes.append(hello.handshakeMode)
        guard hello.protocolVersion == SecureCrypto.secureProtocolVersion else {
            return [.secureError(SecureErrorFrame(code: .protocolMismatch, message: "版本不符"))]
        }
        if hello.handshakeMode == .qrBootstrap, !pairingWindowOpen {
            return [.secureError(SecureErrorFrame(code: .pairingExpired, message: "配对窗口已关"))]
        }
        if hello.handshakeMode == .trustedReconnect {
            guard let trusted = trustedPhones[hello.phoneDeviceId] else {
                return [.secureError(SecureErrorFrame(code: .phoneNotTrusted, message: "未配对"))]
            }
            guard trusted == hello.phoneIdentityPublicKey else {
                return [
                    .secureError(SecureErrorFrame(code: .phoneIdentityChanged, message: "身份变更"))
                ]
            }
        }

        let keyEpoch = (keyEpochs[hello.phoneDeviceId] ?? 0) + 1
        keyEpochs[hello.phoneDeviceId] = keyEpoch
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let macEphemeralPublicKey = ephemeral.publicKey.rawRepresentation.base64EncodedString()
        let serverNonce = SecureCrypto.randomBytes(32).base64EncodedString()
        let expiresAtMs = hello.handshakeMode == .qrBootstrap ? pairingExpiresAtMs : 0

        let transcript = SecureCrypto.buildTranscript(
            TranscriptParams(
                roomId: hello.roomId,
                protocolVersion: SecureCrypto.secureProtocolVersion,
                handshakeMode: hello.handshakeMode,
                keyEpoch: keyEpoch,
                macDeviceId: macDeviceId,
                phoneDeviceId: hello.phoneDeviceId,
                macIdentityPublicKey: identityPublicKeyBase64,
                phoneIdentityPublicKey: hello.phoneIdentityPublicKey,
                macEphemeralPublicKey: macEphemeralPublicKey,
                phoneEphemeralPublicKey: hello.phoneEphemeralPublicKey,
                clientNonce: hello.clientNonce,
                serverNonce: serverNonce,
                pairingExpiresAtMs: expiresAtMs
            ))

        guard let phoneEphemeralRaw = Data(base64Encoded: hello.phoneEphemeralPublicKey) else {
            throw TestFailure("phoneEphemeralPublicKey 不是合法 base64")
        }
        if let previous = sessions[hello.phoneDeviceId] {
            switch previous {
            case let .pending(p): roomToPhone[p.roomId] = nil
            case let .established(e): roomToPhone[e.roomId] = nil
            }
        }
        sessions[hello.phoneDeviceId] = .pending(
            PendingSession(
                roomId: hello.roomId,
                mode: hello.handshakeMode,
                keyEpoch: keyEpoch,
                phoneIdentityPublicKey: hello.phoneIdentityPublicKey,
                transcript: transcript,
                sharedSecret: try SecureCrypto.x25519SharedSecret(
                    privateKeyRaw: ephemeral.rawRepresentation,
                    peerPublicRaw: phoneEphemeralRaw
                )
            ))
        roomToPhone[hello.roomId] = hello.phoneDeviceId

        return [
            .serverHello(
                ServerHelloFrame(
                    protocolVersion: SecureCrypto.secureProtocolVersion,
                    roomId: hello.roomId,
                    handshakeMode: hello.handshakeMode,
                    macDeviceId: macDeviceId,
                    macIdentityPublicKey: identityPublicKeyBase64,
                    macEphemeralPublicKey: macEphemeralPublicKey,
                    serverNonce: serverNonce,
                    keyEpoch: keyEpoch,
                    pairingExpiresAtMs: expiresAtMs,
                    macSignature: try SecureCrypto.signTranscript(
                        seed: identitySeed, message: transcript
                    ).base64EncodedString(),
                    clientNonce: hello.clientNonce,
                    displayName: displayName
                ))
        ]
    }

    private func handleClientAuth(_ auth: ClientAuthFrame) throws -> [SecureFrame] {
        guard case let .pending(pending) = sessions[auth.phoneDeviceId],
            pending.roomId == auth.roomId, pending.keyEpoch == auth.keyEpoch
        else {
            return [.secureError(SecureErrorFrame(code: .unexpectedFrame, message: "无待验会话"))]
        }
        guard let publicKeyRaw = Data(base64Encoded: pending.phoneIdentityPublicKey),
            let signature = Data(base64Encoded: auth.phoneSignature),
            SecureCrypto.verifyTranscript(
                publicKeyRaw: publicKeyRaw,
                message: SecureCrypto.buildClientAuthMessage(transcript: pending.transcript),
                signature: signature
            )
        else {
            sessions[auth.phoneDeviceId] = nil
            roomToPhone[pending.roomId] = nil
            return [.secureError(SecureErrorFrame(code: .invalidSignature, message: "验签失败"))]
        }

        let keys = SecureCrypto.deriveKeys(
            sharedSecret: pending.sharedSecret, transcript: pending.transcript,
            roomId: auth.roomId, macDeviceId: macDeviceId,
            phoneDeviceId: auth.phoneDeviceId, keyEpoch: auth.keyEpoch
        )
        sessions[auth.phoneDeviceId] = .established(
            EstablishedSession(
                roomId: auth.roomId, keyEpoch: auth.keyEpoch,
                keyPhoneToMac: keys.phoneToMac, keyMacToPhone: keys.macToPhone
            ))
        if pending.mode == .qrBootstrap {
            trustedPhones[auth.phoneDeviceId] = pending.phoneIdentityPublicKey
        }
        return [
            .secureReady(
                SecureReadyFrame(
                    roomId: auth.roomId, keyEpoch: auth.keyEpoch, macDeviceId: macDeviceId))
        ]
    }

    private func handleEnvelope(_ envelope: EncryptedEnvelope) throws -> [SecureFrame] {
        guard envelope.v == 1, envelope.sender == .phone,
            let phoneDeviceId = roomToPhone[envelope.roomId],
            case var .established(session) = sessions[phoneDeviceId],
            session.keyEpoch == envelope.keyEpoch
        else {
            return [.secureError(SecureErrorFrame(code: .unexpectedFrame, message: "无已建会话"))]
        }
        // 重放/乱序旧帧静默丢弃，镜像 TS 侧不回帧防放大
        guard envelope.counter > session.lastInboundCounter else { return [] }
        let plaintext = try SecureCrypto.openEnvelope(key: session.keyPhoneToMac, envelope: envelope)
        session.lastInboundCounter = envelope.counter
        sessions[phoneDeviceId] = .established(session)
        receivedPlaintexts.append(plaintext)

        guard let replies = onPlaintext?(plaintext) else { return [] }
        return try replies.map { try sealLocked(phoneDeviceId, plaintext: $0) }
    }

    private func sealLocked(_ phoneDeviceId: String, plaintext: String) throws -> SecureFrame {
        guard case var .established(session) = sessions[phoneDeviceId] else {
            throw TestFailure("phone \(phoneDeviceId) 没有已建会话")
        }
        session.outboundCounter += 1
        sessions[phoneDeviceId] = .established(session)
        return .encryptedEnvelope(
            try SecureCrypto.sealEnvelope(
                key: session.keyMacToPhone, roomId: session.roomId, keyEpoch: session.keyEpoch,
                sender: .mac, counter: session.outboundCounter, plaintext: plaintext
            ))
    }
}

// MARK: - 帧提取

func requireServerHello(_ frames: [SecureFrame]) throws -> ServerHelloFrame {
    for frame in frames { if case let .serverHello(hello) = frame { return hello } }
    throw TestFailure("期望 serverHello，实际: \(frames)")
}

func requireSecureReady(_ frames: [SecureFrame]) throws -> SecureReadyFrame {
    for frame in frames { if case let .secureReady(ready) = frame { return ready } }
    throw TestFailure("期望 secureReady，实际: \(frames)")
}

func requireSecureError(_ frames: [SecureFrame]) throws -> SecureErrorFrame {
    for frame in frames { if case let .secureError(error) = frame { return error } }
    throw TestFailure("期望 secureError，实际: \(frames)")
}

func requireEnvelope(_ frames: [SecureFrame]) throws -> EncryptedEnvelope {
    for frame in frames { if case let .encryptedEnvelope(envelope) = frame { return envelope } }
    throw TestFailure("期望 encryptedEnvelope，实际: \(frames)")
}

// MARK: - 异步流录制与轮询

/// 后台把 AsyncStream 全量录下来，测试用轮询等待目标状态出现。
/// 比手持 iterator 简单，也避免 iterator 跨 await 的所有权纠纷。
final class StreamRecorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<Value>) {
        task = Task { [weak self] in
            for await value in stream {
                guard let self else { return }
                self.lock.withLock { self.storage.append(value) }
            }
        }
    }

    deinit { task?.cancel() }

    var values: [Value] {
        lock.withLock { storage }
    }

    func waitUntil(
        timeout: Duration = .seconds(5),
        _ predicate: @escaping @Sendable ([Value]) -> Bool
    ) async throws {
        try await eventually(timeout: timeout) { [self] in predicate(values) }
    }
}

/// 轮询直到条件成立；超时抛错让测试红而不是挂死
func eventually(
    timeout: Duration = .seconds(5),
    _ condition: @escaping @Sendable () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw TestFailure("等待条件超时（\(timeout)）")
}

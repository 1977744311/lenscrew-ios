import Foundation
import Testing

@testable import BridgeLink

/// phone 侧握手状态机全流程：用 FakeMacHost（同一套 Swift 原语反串 mac）
/// 把帧在两个状态机之间搬运，不经任何网络。
@Suite("SecurePhoneSession 握手状态机")
struct SecurePhoneSessionTests {
    private let phoneDeviceId = "22222222-2222-4222-8222-222222222222"

    private func makeSession(
        _ host: FakeMacHost, mode: HandshakeMode, identity: PhoneIdentity
    ) throws -> SecurePhoneSession {
        try SecurePhoneSession(
            mode: mode,
            roomId: host.macDeviceId,
            phoneDeviceId: phoneDeviceId,
            identity: identity,
            macDeviceId: host.macDeviceId,
            macIdentityPublicKey: host.identityPublicKeyBase64
        )
    }

    /// 帧搬运工：hello → serverHello → clientAuth → secureReady
    @discardableResult
    private func completeHandshake(
        _ session: SecurePhoneSession, host: FakeMacHost
    ) throws -> ServerHelloFrame {
        let serverHello = try requireServerHello(
            host.handleFrame(.clientHello(session.makeClientHello())))
        let clientAuth = try session.handleServerHello(serverHello)
        try session.handleSecureReady(
            try requireSecureReady(host.handleFrame(.clientAuth(clientAuth))))
        return serverHello
    }

    @Test("qr_bootstrap 全流程：握手建立 + 双向信封互通 + mac 写信任表")
    func qrBootstrapFullFlow() throws {
        let host = FakeMacHost()
        let identity = PhoneIdentity()
        // 扫码入口：payload 解析给出信任根
        let payload = try PairingPayload.parse(
            JSONEncoder().encode(host.pairingPayload()), nowMs: nowMs())
        let session = try SecurePhoneSession(
            mode: .qrBootstrap,
            roomId: payload.macDeviceId,
            phoneDeviceId: phoneDeviceId,
            identity: identity,
            macDeviceId: payload.macDeviceId,
            macIdentityPublicKey: payload.macIdentityPublicKey
        )
        #expect(session.phase == .idle)

        let serverHello = try completeHandshake(session, host: host)
        #expect(session.phase == .established)
        #expect(session.keyEpoch == 1)
        #expect(serverHello.pairingExpiresAtMs == host.pairingExpiresAtMs)
        #expect(session.macDisplayName == host.displayName)
        // 验签通过后 mac 才把 phone 写进信任表
        #expect(host.trustedPhones[phoneDeviceId] == identity.publicKeyRawBase64)

        // phone → mac
        let outbound = try session.seal("hello from phone")
        #expect(outbound.sender == .phone)
        #expect(outbound.counter == 1)
        let replies = try host.handleFrame(.encryptedEnvelope(outbound))
        #expect(host.receivedPlaintexts == ["hello from phone"])
        #expect(replies.isEmpty)

        // mac → phone
        let inbound = try requireEnvelope(
            [try host.sealToPhone(phoneDeviceId, plaintext: "hello from mac")])
        #expect(try session.open(inbound) == "hello from mac")
    }

    @Test("trusted_reconnect 全流程：pairingExpiresAtMs 恒 0，keyEpoch 递增")
    func trustedReconnectFullFlow() throws {
        let host = FakeMacHost()
        let identity = PhoneIdentity()
        // 先走一次 qr_bootstrap 完成配对
        try completeHandshake(
            try makeSession(host, mode: .qrBootstrap, identity: identity), host: host)

        // 断线重连：新会话走 trusted_reconnect
        let session = try makeSession(host, mode: .trustedReconnect, identity: identity)
        let serverHello = try completeHandshake(session, host: host)
        #expect(session.phase == .established)
        #expect(serverHello.pairingExpiresAtMs == 0)
        #expect(session.keyEpoch == 2)
        #expect(host.seenHandshakeModes == [.qrBootstrap, .trustedReconnect])

        // 新纪元下密钥独立可用
        let envelope = try session.seal("after reconnect")
        _ = try host.handleFrame(.encryptedEnvelope(envelope))
        #expect(host.receivedPlaintexts.last == "after reconnect")
    }

    @Test("trusted_reconnect 未配对/身份变更被 mac 拒绝")
    func trustedReconnectRejections() throws {
        let host = FakeMacHost()
        let stranger = try makeSession(host, mode: .trustedReconnect, identity: PhoneIdentity())
        let error = try requireSecureError(
            host.handleFrame(.clientHello(stranger.makeClientHello())))
        #expect(error.code == .phoneNotTrusted)

        // 换了身份钥匙的同名设备必须重新扫码
        host.trustPhone(deviceId: phoneDeviceId, identityPublicKey: PhoneIdentity().publicKeyRawBase64)
        let impostor = try makeSession(host, mode: .trustedReconnect, identity: PhoneIdentity())
        let changed = try requireSecureError(
            host.handleFrame(.clientHello(impostor.makeClientHello())))
        #expect(changed.code == .phoneIdentityChanged)
    }

    @Test("mac 签名被篡改即拒绝，会话作废")
    func rejectsTamperedMacSignature() throws {
        let host = FakeMacHost()
        let session = try makeSession(host, mode: .qrBootstrap, identity: PhoneIdentity())
        var serverHello = try requireServerHello(
            host.handleFrame(.clientHello(session.makeClientHello())))
        // 翻转签名一个比特：结构仍是 64 字节合法签名，但对 transcript 验不过
        serverHello.macSignature = Data(
            base64Encoded: serverHello.macSignature
        ).map { data -> String in
            var tampered = data
            tampered[0] ^= 0x01
            return tampered.base64EncodedString()
        }!
        #expect(throws: SecureSessionError.invalidSignature) {
            _ = try session.handleServerHello(serverHello)
        }
        #expect(session.phase == .failed)
    }

    @Test("serverHello 回显的 mac 身份公钥必须等于信任根（二维码公钥）")
    func rejectsMacIdentityMismatch() throws {
        let host = FakeMacHost()
        let session = try makeSession(host, mode: .qrBootstrap, identity: PhoneIdentity())
        var serverHello = try requireServerHello(
            host.handleFrame(.clientHello(session.makeClientHello())))
        serverHello.macIdentityPublicKey = PhoneIdentity().publicKeyRawBase64
        #expect(throws: SecureSessionError.identityMismatch("mac 身份公钥与信任根不符")) {
            _ = try session.handleServerHello(serverHello)
        }
        #expect(session.phase == .failed)
    }

    @Test("clientNonce 回显不符视为不匹配的 serverHello")
    func rejectsClientNonceMismatch() throws {
        let host = FakeMacHost()
        let session = try makeSession(host, mode: .qrBootstrap, identity: PhoneIdentity())
        var serverHello = try requireServerHello(
            host.handleFrame(.clientHello(session.makeClientHello())))
        serverHello.clientNonce = SecureCrypto.randomBytes(32).base64EncodedString()
        #expect(throws: SecureSessionError.unexpectedFrame("serverHello 与本次 clientHello 不匹配")) {
            _ = try session.handleServerHello(serverHello)
        }
        #expect(session.phase == .failed)
    }

    @Test("counter 重放：phone 侧静默丢弃，mac 侧同样丢弃")
    func rejectsReplayedCounters() throws {
        let host = FakeMacHost()
        let session = try makeSession(host, mode: .qrBootstrap, identity: PhoneIdentity())
        try completeHandshake(session, host: host)

        // mac → phone 重放
        let inbound = try requireEnvelope([try host.sealToPhone(phoneDeviceId, plaintext: "once")])
        #expect(try session.open(inbound) == "once")
        #expect(try session.open(inbound) == nil)
        #expect(session.phase == .established)

        // phone → mac 重放
        let outbound = try session.seal("ping")
        _ = try host.handleFrame(.encryptedEnvelope(outbound))
        let repliesOnReplay = try host.handleFrame(.encryptedEnvelope(outbound))
        #expect(repliesOnReplay.isEmpty)
        #expect(host.receivedPlaintexts == ["ping"])
    }

    @Test("密文被篡改解密失败并作废会话")
    func rejectsTamperedCiphertext() throws {
        let host = FakeMacHost()
        let session = try makeSession(host, mode: .qrBootstrap, identity: PhoneIdentity())
        try completeHandshake(session, host: host)

        var envelope = try requireEnvelope(
            [try host.sealToPhone(phoneDeviceId, plaintext: "secret")])
        var raw = Data(base64Encoded: envelope.ciphertext)!
        raw[0] ^= 0x01
        envelope.ciphertext = raw.base64EncodedString()
        #expect(throws: SecureSessionError.decryptFailed) {
            _ = try session.open(envelope)
        }
        #expect(session.phase == .failed)
    }

    @Test("secureError 传播：会话作废并携带远端错误码")
    func propagatesSecureError() throws {
        let host = FakeMacHost()
        host.pairingWindowOpen = false
        let session = try makeSession(host, mode: .qrBootstrap, identity: PhoneIdentity())
        let frame = try requireSecureError(
            host.handleFrame(.clientHello(session.makeClientHello())))
        let error = session.handleSecureError(frame)
        #expect(error == .remoteError(code: .pairingExpired, message: "配对窗口已关"))
        #expect(session.phase == .failed)
        #expect(throws: SecureSessionError.notEstablished) {
            _ = try session.seal("after failure")
        }
    }

    @Test("PairingPayload 解析：合法载荷 + v/kind/过期（60s 时钟偏移）校验")
    func pairingPayloadParsing() throws {
        let host = FakeMacHost()
        let now = nowMs()
        let full = host.pairingPayload(
            relay: "https://relay.example", lan: .init(host: "192.168.1.2", port: 8787))
        let parsed = try PairingPayload.parse(JSONEncoder().encode(full), nowMs: now)
        #expect(parsed == full)
        #expect(parsed.relay == "https://relay.example")
        #expect(parsed.lan == .init(host: "192.168.1.2", port: 8787))

        // relay/lan 缺席也能解（可选字段）
        let minimal = try PairingPayload.parse(
            JSONEncoder().encode(host.pairingPayload()), nowMs: now)
        #expect(minimal.relay == nil && minimal.lan == nil)

        var expired = full
        expired.expiresAtMs = now - 61_000
        #expect(throws: PairingPayloadError.expired(expiresAtMs: now - 61_000, nowMs: now)) {
            _ = try PairingPayload.parse(JSONEncoder().encode(expired), nowMs: now)
        }
        // 过期 59s 仍在时钟偏移容忍内
        var nearlyExpired = full
        nearlyExpired.expiresAtMs = now - 59_000
        #expect(
            (try? PairingPayload.parse(JSONEncoder().encode(nearlyExpired), nowMs: now)) != nil)

        var wrongKind = full
        wrongKind.kind = "other"
        #expect(throws: PairingPayloadError.wrongKind("other")) {
            _ = try PairingPayload.parse(JSONEncoder().encode(wrongKind), nowMs: now)
        }
        var wrongVersion = full
        wrongVersion.v = 2
        #expect(throws: PairingPayloadError.unsupportedVersion(2)) {
            _ = try PairingPayload.parse(JSONEncoder().encode(wrongVersion), nowMs: now)
        }
    }
}

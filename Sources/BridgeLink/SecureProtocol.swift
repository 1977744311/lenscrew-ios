import CryptoKit
import Foundation

// LensCrew E2EE 的 iOS 侧密码学与帧编解码。协议判定权在 bridge/src/secure/crypto.ts，
// 这里是它的 CryptoKit 忠实镜像：transcript 构造、签名域分隔、HKDF 参数、
// 信封 nonce/AAD 全部逐字节对齐，由 protocol/fixtures/e2ee-handshake.json 双向钉死。
// 本文件零 I/O、零网络：网络层在 SecureBridgeConnection，密钥落盘（Keychain）是后续任务。

// MARK: - 配对 payload（二维码内容）

public enum PairingPayloadError: Error, Equatable {
    case malformed(String)
    case unsupportedVersion(Int)
    case wrongKind(String)
    case expired(expiresAtMs: Int, nowMs: Int)
}

/// 二维码里的配对引导信息，由 bridge `buildPairPayload` 生成。
/// macIdentityPublicKey 是 qr_bootstrap 模式的信任根——配对安全性全押在
/// 「二维码只有本人扫得到」上，所以必须校验 serverHello 回显与它一致。
public struct PairingPayload: Sendable, Equatable, Codable {
    public struct LanEndpoint: Sendable, Equatable, Codable {
        public var host: String
        public var port: Int

        public init(host: String, port: Int) {
            self.host = host
            self.port = port
        }

        private enum CodingKeys: String, CodingKey {
            case host, port
        }
    }

    public var v: Int
    public var kind: String
    public var macDeviceId: String
    public var macIdentityPublicKey: String
    public var displayName: String
    public var expiresAtMs: Int
    public var relay: String?
    public var lan: LanEndpoint?

    private enum CodingKeys: String, CodingKey {
        case v, kind, macDeviceId, macIdentityPublicKey, displayName, expiresAtMs, relay, lan
    }

    public init(
        v: Int, kind: String, macDeviceId: String, macIdentityPublicKey: String,
        displayName: String, expiresAtMs: Int, relay: String? = nil, lan: LanEndpoint? = nil
    ) {
        self.v = v
        self.kind = kind
        self.macDeviceId = macDeviceId
        self.macIdentityPublicKey = macIdentityPublicKey
        self.displayName = displayName
        self.expiresAtMs = expiresAtMs
        self.relay = relay
        self.lan = lan
    }

    /// 解析并校验扫码结果。过期判定放宽 60 秒：手机与 Mac 的时钟不保证同步，
    /// 边界上宁可放行让握手侧（有签名保护）把关，也不要让用户对着刚生成的码报"已过期"。
    public static func parse(_ data: Data, nowMs: Int) throws -> PairingPayload {
        let payload: PairingPayload
        do {
            payload = try JSONDecoder().decode(PairingPayload.self, from: data)
        } catch {
            throw PairingPayloadError.malformed(String(describing: error))
        }
        guard payload.v == 1 else { throw PairingPayloadError.unsupportedVersion(payload.v) }
        guard payload.kind == "lenscrew-pair" else {
            throw PairingPayloadError.wrongKind(payload.kind)
        }
        guard nowMs <= payload.expiresAtMs + 60_000 else {
            throw PairingPayloadError.expired(expiresAtMs: payload.expiresAtMs, nowMs: nowMs)
        }
        return payload
    }
}

// MARK: - 帧类型（字段名与 bridge/src/secure/channel.ts 完全一致）

public enum HandshakeMode: String, Sendable, Equatable, Codable {
    case qrBootstrap = "qr_bootstrap"
    case trustedReconnect = "trusted_reconnect"
}

public enum EnvelopeSender: String, Sendable, Equatable, Codable {
    case mac, phone
}

public enum SecureErrorCode: String, Sendable, Equatable, Codable {
    case protocolMismatch = "protocol_mismatch"
    case pairingExpired = "pairing_expired"
    case phoneNotTrusted = "phone_not_trusted"
    case phoneIdentityChanged = "phone_identity_changed"
    case invalidSignature = "invalid_signature"
    case decryptFailed = "decrypt_failed"
    case unexpectedFrame = "unexpected_frame"
}

public struct ClientHelloFrame: Sendable, Equatable, Codable {
    public var protocolVersion: Int
    public var roomId: String
    public var handshakeMode: HandshakeMode
    public var phoneDeviceId: String
    /// Ed25519 raw 32B base64
    public var phoneIdentityPublicKey: String
    /// X25519 raw 32B base64
    public var phoneEphemeralPublicKey: String
    public var clientNonce: String

    private enum CodingKeys: String, CodingKey {
        case kind, protocolVersion, roomId, handshakeMode, phoneDeviceId
        case phoneIdentityPublicKey, phoneEphemeralPublicKey, clientNonce
    }

    public init(
        protocolVersion: Int, roomId: String, handshakeMode: HandshakeMode,
        phoneDeviceId: String, phoneIdentityPublicKey: String,
        phoneEphemeralPublicKey: String, clientNonce: String
    ) {
        self.protocolVersion = protocolVersion
        self.roomId = roomId
        self.handshakeMode = handshakeMode
        self.phoneDeviceId = phoneDeviceId
        self.phoneIdentityPublicKey = phoneIdentityPublicKey
        self.phoneEphemeralPublicKey = phoneEphemeralPublicKey
        self.clientNonce = clientNonce
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        roomId = try container.decode(String.self, forKey: .roomId)
        handshakeMode = try container.decode(HandshakeMode.self, forKey: .handshakeMode)
        phoneDeviceId = try container.decode(String.self, forKey: .phoneDeviceId)
        phoneIdentityPublicKey = try container.decode(String.self, forKey: .phoneIdentityPublicKey)
        phoneEphemeralPublicKey = try container.decode(
            String.self, forKey: .phoneEphemeralPublicKey)
        clientNonce = try container.decode(String.self, forKey: .clientNonce)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("clientHello", forKey: .kind)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(roomId, forKey: .roomId)
        try container.encode(handshakeMode, forKey: .handshakeMode)
        try container.encode(phoneDeviceId, forKey: .phoneDeviceId)
        try container.encode(phoneIdentityPublicKey, forKey: .phoneIdentityPublicKey)
        try container.encode(phoneEphemeralPublicKey, forKey: .phoneEphemeralPublicKey)
        try container.encode(clientNonce, forKey: .clientNonce)
    }
}

public struct ServerHelloFrame: Sendable, Equatable, Codable {
    public var protocolVersion: Int
    public var roomId: String
    public var handshakeMode: HandshakeMode
    public var macDeviceId: String
    public var macIdentityPublicKey: String
    public var macEphemeralPublicKey: String
    public var serverNonce: String
    public var keyEpoch: Int
    /// qr_bootstrap = 配对窗口截止时刻；trusted_reconnect 恒为 0
    public var pairingExpiresAtMs: Int
    /// mac 对 transcript 的 Ed25519 签名 base64
    public var macSignature: String
    /// 原样回显，phone 据此把响应对回自己的请求
    public var clientNonce: String
    public var displayName: String

    private enum CodingKeys: String, CodingKey {
        case kind, protocolVersion, roomId, handshakeMode, macDeviceId
        case macIdentityPublicKey, macEphemeralPublicKey, serverNonce, keyEpoch
        case pairingExpiresAtMs, macSignature, clientNonce, displayName
    }

    public init(
        protocolVersion: Int, roomId: String, handshakeMode: HandshakeMode,
        macDeviceId: String, macIdentityPublicKey: String, macEphemeralPublicKey: String,
        serverNonce: String, keyEpoch: Int, pairingExpiresAtMs: Int,
        macSignature: String, clientNonce: String, displayName: String
    ) {
        self.protocolVersion = protocolVersion
        self.roomId = roomId
        self.handshakeMode = handshakeMode
        self.macDeviceId = macDeviceId
        self.macIdentityPublicKey = macIdentityPublicKey
        self.macEphemeralPublicKey = macEphemeralPublicKey
        self.serverNonce = serverNonce
        self.keyEpoch = keyEpoch
        self.pairingExpiresAtMs = pairingExpiresAtMs
        self.macSignature = macSignature
        self.clientNonce = clientNonce
        self.displayName = displayName
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        roomId = try container.decode(String.self, forKey: .roomId)
        handshakeMode = try container.decode(HandshakeMode.self, forKey: .handshakeMode)
        macDeviceId = try container.decode(String.self, forKey: .macDeviceId)
        macIdentityPublicKey = try container.decode(String.self, forKey: .macIdentityPublicKey)
        macEphemeralPublicKey = try container.decode(String.self, forKey: .macEphemeralPublicKey)
        serverNonce = try container.decode(String.self, forKey: .serverNonce)
        keyEpoch = try container.decode(Int.self, forKey: .keyEpoch)
        pairingExpiresAtMs = try container.decode(Int.self, forKey: .pairingExpiresAtMs)
        macSignature = try container.decode(String.self, forKey: .macSignature)
        clientNonce = try container.decode(String.self, forKey: .clientNonce)
        displayName = try container.decode(String.self, forKey: .displayName)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("serverHello", forKey: .kind)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(roomId, forKey: .roomId)
        try container.encode(handshakeMode, forKey: .handshakeMode)
        try container.encode(macDeviceId, forKey: .macDeviceId)
        try container.encode(macIdentityPublicKey, forKey: .macIdentityPublicKey)
        try container.encode(macEphemeralPublicKey, forKey: .macEphemeralPublicKey)
        try container.encode(serverNonce, forKey: .serverNonce)
        try container.encode(keyEpoch, forKey: .keyEpoch)
        try container.encode(pairingExpiresAtMs, forKey: .pairingExpiresAtMs)
        try container.encode(macSignature, forKey: .macSignature)
        try container.encode(clientNonce, forKey: .clientNonce)
        try container.encode(displayName, forKey: .displayName)
    }
}

public struct ClientAuthFrame: Sendable, Equatable, Codable {
    public var roomId: String
    public var phoneDeviceId: String
    public var keyEpoch: Int
    /// phone 对 transcript‖lengthPrefixed("client-auth") 的 Ed25519 签名 base64
    public var phoneSignature: String

    private enum CodingKeys: String, CodingKey {
        case kind, roomId, phoneDeviceId, keyEpoch, phoneSignature
    }

    public init(roomId: String, phoneDeviceId: String, keyEpoch: Int, phoneSignature: String) {
        self.roomId = roomId
        self.phoneDeviceId = phoneDeviceId
        self.keyEpoch = keyEpoch
        self.phoneSignature = phoneSignature
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        roomId = try container.decode(String.self, forKey: .roomId)
        phoneDeviceId = try container.decode(String.self, forKey: .phoneDeviceId)
        keyEpoch = try container.decode(Int.self, forKey: .keyEpoch)
        phoneSignature = try container.decode(String.self, forKey: .phoneSignature)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("clientAuth", forKey: .kind)
        try container.encode(roomId, forKey: .roomId)
        try container.encode(phoneDeviceId, forKey: .phoneDeviceId)
        try container.encode(keyEpoch, forKey: .keyEpoch)
        try container.encode(phoneSignature, forKey: .phoneSignature)
    }
}

public struct SecureReadyFrame: Sendable, Equatable, Codable {
    public var roomId: String
    public var keyEpoch: Int
    public var macDeviceId: String

    private enum CodingKeys: String, CodingKey {
        case kind, roomId, keyEpoch, macDeviceId
    }

    public init(roomId: String, keyEpoch: Int, macDeviceId: String) {
        self.roomId = roomId
        self.keyEpoch = keyEpoch
        self.macDeviceId = macDeviceId
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        roomId = try container.decode(String.self, forKey: .roomId)
        keyEpoch = try container.decode(Int.self, forKey: .keyEpoch)
        macDeviceId = try container.decode(String.self, forKey: .macDeviceId)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("secureReady", forKey: .kind)
        try container.encode(roomId, forKey: .roomId)
        try container.encode(keyEpoch, forKey: .keyEpoch)
        try container.encode(macDeviceId, forKey: .macDeviceId)
    }
}

public struct SecureErrorFrame: Sendable, Equatable, Codable {
    public var code: SecureErrorCode
    public var message: String

    private enum CodingKeys: String, CodingKey {
        case kind, code, message
    }

    public init(code: SecureErrorCode, message: String) {
        self.code = code
        self.message = message
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(SecureErrorCode.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("secureError", forKey: .kind)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
    }
}

/// TS 信封把 ciphertext 与认证 tag 分开 base64，正好对应
/// AES.GCM.SealedBox 的 ciphertext/tag 两段。
public struct EncryptedEnvelope: Sendable, Equatable, Codable {
    public var v: Int
    public var roomId: String
    public var keyEpoch: Int
    public var sender: EnvelopeSender
    public var counter: Int
    public var ciphertext: String
    public var tag: String

    private enum CodingKeys: String, CodingKey {
        case kind, v, roomId, keyEpoch, sender, counter, ciphertext, tag
    }

    public init(
        v: Int, roomId: String, keyEpoch: Int, sender: EnvelopeSender,
        counter: Int, ciphertext: String, tag: String
    ) {
        self.v = v
        self.roomId = roomId
        self.keyEpoch = keyEpoch
        self.sender = sender
        self.counter = counter
        self.ciphertext = ciphertext
        self.tag = tag
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try container.decode(Int.self, forKey: .v)
        roomId = try container.decode(String.self, forKey: .roomId)
        keyEpoch = try container.decode(Int.self, forKey: .keyEpoch)
        sender = try container.decode(EnvelopeSender.self, forKey: .sender)
        counter = try container.decode(Int.self, forKey: .counter)
        ciphertext = try container.decode(String.self, forKey: .ciphertext)
        tag = try container.decode(String.self, forKey: .tag)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("encryptedEnvelope", forKey: .kind)
        try container.encode(v, forKey: .v)
        try container.encode(roomId, forKey: .roomId)
        try container.encode(keyEpoch, forKey: .keyEpoch)
        try container.encode(sender, forKey: .sender)
        try container.encode(counter, forKey: .counter)
        try container.encode(ciphertext, forKey: .ciphertext)
        try container.encode(tag, forKey: .tag)
    }
}

/// 线上帧的判别联合，按 `kind` 分派。未知 kind 抛错，
/// 由传输层决定跳过（不让新帧类型打断整条流）。
public enum SecureFrame: Sendable, Equatable, Codable {
    case clientHello(ClientHelloFrame)
    case serverHello(ServerHelloFrame)
    case clientAuth(ClientAuthFrame)
    case secureReady(SecureReadyFrame)
    case secureError(SecureErrorFrame)
    case encryptedEnvelope(EncryptedEnvelope)

    private enum KindKey: String, CodingKey {
        case kind
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: KindKey.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "clientHello": self = .clientHello(try ClientHelloFrame(from: decoder))
        case "serverHello": self = .serverHello(try ServerHelloFrame(from: decoder))
        case "clientAuth": self = .clientAuth(try ClientAuthFrame(from: decoder))
        case "secureReady": self = .secureReady(try SecureReadyFrame(from: decoder))
        case "secureError": self = .secureError(try SecureErrorFrame(from: decoder))
        case "encryptedEnvelope": self = .encryptedEnvelope(try EncryptedEnvelope(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "未知的帧 kind: \(kind)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case let .clientHello(frame): try frame.encode(to: encoder)
        case let .serverHello(frame): try frame.encode(to: encoder)
        case let .clientAuth(frame): try frame.encode(to: encoder)
        case let .secureReady(frame): try frame.encode(to: encoder)
        case let .secureError(frame): try frame.encode(to: encoder)
        case let .encryptedEnvelope(frame): try frame.encode(to: encoder)
        }
    }
}

// MARK: - 密码学纯函数（镜像 bridge/src/secure/crypto.ts）

public enum SecureCryptoError: Error, Equatable {
    case invalidKeyLength(String)
    case invalidBase64(String)
    case invalidCounter(Int)
    case decryptFailed
}

public struct TranscriptParams: Sendable, Equatable {
    public var roomId: String
    public var protocolVersion: Int
    public var handshakeMode: HandshakeMode
    public var keyEpoch: Int
    public var macDeviceId: String
    public var phoneDeviceId: String
    /// 四个密钥字段与两个 nonce 都是 base64 字符串原文，不解码——跨语言只比字符串
    public var macIdentityPublicKey: String
    public var phoneIdentityPublicKey: String
    public var macEphemeralPublicKey: String
    public var phoneEphemeralPublicKey: String
    public var clientNonce: String
    public var serverNonce: String
    public var pairingExpiresAtMs: Int

    public init(
        roomId: String, protocolVersion: Int, handshakeMode: HandshakeMode, keyEpoch: Int,
        macDeviceId: String, phoneDeviceId: String,
        macIdentityPublicKey: String, phoneIdentityPublicKey: String,
        macEphemeralPublicKey: String, phoneEphemeralPublicKey: String,
        clientNonce: String, serverNonce: String, pairingExpiresAtMs: Int
    ) {
        self.roomId = roomId
        self.protocolVersion = protocolVersion
        self.handshakeMode = handshakeMode
        self.keyEpoch = keyEpoch
        self.macDeviceId = macDeviceId
        self.phoneDeviceId = phoneDeviceId
        self.macIdentityPublicKey = macIdentityPublicKey
        self.phoneIdentityPublicKey = phoneIdentityPublicKey
        self.macEphemeralPublicKey = macEphemeralPublicKey
        self.phoneEphemeralPublicKey = phoneEphemeralPublicKey
        self.clientNonce = clientNonce
        self.serverNonce = serverNonce
        self.pairingExpiresAtMs = pairingExpiresAtMs
    }
}

public struct DirectionalKeys: Sendable, Equatable {
    public var phoneToMac: Data
    public var macToPhone: Data
}

public enum SecureCrypto {
    public static let secureProtocolVersion = 1
    public static let protocolLabel = "lenscrew-e2ee-v1"
    public static let clientAuthLabel = "client-auth"

    // MARK: transcript

    /// 每字段 4 字节大端长度前缀再拼接。长度前缀让字段边界无歧义，
    /// 否则 ("ab","c") 与 ("a","bc") 会拼出同一串字节，签名就能被跨字段挪移。
    public static func lengthPrefixed(_ fields: [Data]) -> Data {
        var out = Data()
        for field in fields {
            withUnsafeBytes(of: UInt32(field.count).bigEndian) { out.append(contentsOf: $0) }
            out.append(field)
        }
        return out
    }

    /// 14 字段定序 transcript，双方各自重建，任何一字段不一致签名即失效
    public static func buildTranscript(_ p: TranscriptParams) -> Data {
        let fields = [
            protocolLabel,
            p.roomId,
            String(p.protocolVersion),
            p.handshakeMode.rawValue,
            String(p.keyEpoch),
            p.macDeviceId,
            p.phoneDeviceId,
            p.macIdentityPublicKey,
            p.phoneIdentityPublicKey,
            p.macEphemeralPublicKey,
            p.phoneEphemeralPublicKey,
            p.clientNonce,
            p.serverNonce,
            String(p.pairingExpiresAtMs),
        ]
        return lengthPrefixed(fields.map { Data($0.utf8) })
    }

    /// clientAuth 的签名域分隔：phone 签的不是裸 transcript，防止与 mac 签名互相冒用
    public static func buildClientAuthMessage(transcript: Data) -> Data {
        transcript + lengthPrefixed([Data(clientAuthLabel.utf8)])
    }

    // MARK: Ed25519 / X25519

    public static func ed25519PublicKeyRaw(seed: Data) throws -> Data {
        guard seed.count == 32 else {
            throw SecureCryptoError.invalidKeyLength("ed25519 seed 必须 32 字节")
        }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            .publicKey.rawRepresentation
    }

    public static func signTranscript(seed: Data, message: Data) throws -> Data {
        guard seed.count == 32 else {
            throw SecureCryptoError.invalidKeyLength("ed25519 seed 必须 32 字节")
        }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: seed).signature(for: message)
    }

    /// 畸形签名/公钥按验签失败处理，不让网络输入把异常抛进状态机
    public static func verifyTranscript(publicKeyRaw: Data, message: Data, signature: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyRaw) else {
            return false
        }
        return key.isValidSignature(signature, for: message)
    }

    public static func x25519PublicKeyRaw(privateKeyRaw: Data) throws -> Data {
        guard privateKeyRaw.count == 32 else {
            throw SecureCryptoError.invalidKeyLength("x25519 私钥必须 32 字节")
        }
        return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyRaw)
            .publicKey.rawRepresentation
    }

    public static func x25519SharedSecret(privateKeyRaw: Data, peerPublicRaw: Data) throws -> Data {
        guard privateKeyRaw.count == 32, peerPublicRaw.count == 32 else {
            throw SecureCryptoError.invalidKeyLength("x25519 密钥必须 32 字节")
        }
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyRaw)
        let peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicRaw)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        return secret.withUnsafeBytes { Data($0) }
    }

    // MARK: HKDF 密钥派生

    /// salt 绑定完整 transcript，info 绑定会话身份与方向：两个方向的密钥完全独立
    public static func deriveKeys(
        sharedSecret: Data, transcript: Data,
        roomId: String, macDeviceId: String, phoneDeviceId: String, keyEpoch: Int
    ) -> DirectionalKeys {
        let salt = Data(SHA256.hash(data: transcript))
        let infoBase = "\(protocolLabel)|\(roomId)|\(macDeviceId)|\(phoneDeviceId)|\(keyEpoch)"
        func derive(_ direction: String) -> Data {
            let key = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: sharedSecret),
                salt: salt,
                info: Data("\(infoBase)|\(direction)".utf8),
                outputByteCount: 32
            )
            return key.withUnsafeBytes { Data($0) }
        }
        return DirectionalKeys(phoneToMac: derive("phoneToMac"), macToPhone: derive("macToPhone"))
    }

    // MARK: AES-256-GCM 信封

    /// nonce 12B = [方向字节, 3 字节 0, counter 的 8 字节大端]。方向字节隔开双方 nonce 空间，
    /// counter 单调递增保证同 key 下 nonce 永不重复（GCM 的硬性要求）。
    static func envelopeNonce(sender: EnvelopeSender, counter: Int) throws -> Data {
        guard counter >= 0 else { throw SecureCryptoError.invalidCounter(counter) }
        var nonce = Data(count: 12)
        nonce[0] = sender == .mac ? 1 : 2
        withUnsafeBytes(of: UInt64(counter).bigEndian) { bytes in
            nonce.replaceSubrange(4..<12, with: bytes)
        }
        return nonce
    }

    /// AAD 把路由元数据绑进认证标签：改动任何一个明文头字段都会解密失败
    static func envelopeAad(
        roomId: String, keyEpoch: Int, sender: EnvelopeSender, counter: Int
    ) -> Data {
        Data("\(roomId)|\(keyEpoch)|\(sender.rawValue)|\(counter)".utf8)
    }

    public static func sealEnvelope(
        key: Data, roomId: String, keyEpoch: Int,
        sender: EnvelopeSender, counter: Int, plaintext: String
    ) throws -> EncryptedEnvelope {
        let nonce = try AES.GCM.Nonce(data: envelopeNonce(sender: sender, counter: counter))
        let sealed = try AES.GCM.seal(
            Data(plaintext.utf8),
            using: SymmetricKey(data: key),
            nonce: nonce,
            authenticating: envelopeAad(
                roomId: roomId, keyEpoch: keyEpoch, sender: sender, counter: counter)
        )
        return EncryptedEnvelope(
            v: 1, roomId: roomId, keyEpoch: keyEpoch, sender: sender, counter: counter,
            ciphertext: sealed.ciphertext.base64EncodedString(),
            tag: sealed.tag.base64EncodedString()
        )
    }

    /// 按信封自带的头字段重建 nonce/AAD 解密；认证失败（含任何头字段被篡改）统一抛 decryptFailed
    public static func openEnvelope(key: Data, envelope: EncryptedEnvelope) throws -> String {
        guard let ciphertext = Data(base64Encoded: envelope.ciphertext) else {
            throw SecureCryptoError.invalidBase64("ciphertext")
        }
        guard let tag = Data(base64Encoded: envelope.tag) else {
            throw SecureCryptoError.invalidBase64("tag")
        }
        let nonceData = try envelopeNonce(sender: envelope.sender, counter: envelope.counter)
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonceData), ciphertext: ciphertext, tag: tag)
            let plaintext = try AES.GCM.open(
                box,
                using: SymmetricKey(data: key),
                authenticating: envelopeAad(
                    roomId: envelope.roomId, keyEpoch: envelope.keyEpoch,
                    sender: envelope.sender, counter: envelope.counter)
            )
            guard let text = String(data: plaintext, encoding: .utf8) else {
                throw SecureCryptoError.decryptFailed
            }
            return text
        } catch {
            // tag 长度不对、认证失败、明文非 UTF-8 都归为一类：会话已不可信
            throw SecureCryptoError.decryptFailed
        }
    }

    // MARK: 随机数

    public static func randomBytes(_ count: Int) -> Data {
        SymmetricKey(size: .init(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }
}

// MARK: - PhoneIdentity

/// phone 的 Ed25519 身份密钥。只提供内存构造 + raw base64 出入，
/// Keychain 持久化由后续任务接（seed 即完整私钥材料，出入都是 32 字节）。
public struct PhoneIdentity: Sendable, Equatable {
    /// Ed25519 私钥种子 raw 32B
    public let seed: Data
    /// Ed25519 公钥 raw 32B base64，构造时派生并缓存
    public let publicKeyRawBase64: String

    public init() {
        // 生成路径不会抛：刚生成的 rawRepresentation 必然是合法 seed
        try! self.init(seed: Curve25519.Signing.PrivateKey().rawRepresentation)
    }

    public init(seed: Data) throws {
        guard seed.count == 32 else {
            throw SecureCryptoError.invalidKeyLength("PhoneIdentity seed 必须 32 字节")
        }
        self.seed = seed
        self.publicKeyRawBase64 = try SecureCrypto.ed25519PublicKeyRaw(seed: seed)
            .base64EncodedString()
    }

    public init(seedBase64: String) throws {
        guard let seed = Data(base64Encoded: seedBase64) else {
            throw SecureCryptoError.invalidBase64("PhoneIdentity seed")
        }
        try self.init(seed: seed)
    }

    public var seedBase64: String { seed.base64EncodedString() }
}

// MARK: - Phone 侧握手状态机

public enum SecureSessionError: Error, Equatable {
    case unexpectedFrame(String)
    case protocolMismatch(Int)
    /// macDeviceId 或 mac 身份公钥与信任根不符——qr_bootstrap 要求回显二维码里的公钥，
    /// trusted_reconnect 要求与配对时记下的一致
    case identityMismatch(String)
    case invalidSignature
    case decryptFailed
    case notEstablished
    case remoteError(code: SecureErrorCode, message: String)
}

/// phone 侧握手状态机，与 SecureChannelHost（TS，mac 侧）互为镜像。
/// 纯逻辑：不碰网络与时钟，帧的收发由 SecureBridgeConnection 驱动，因此可以单测全流程。
public final class SecurePhoneSession {
    public enum Phase: Sendable, Equatable {
        case idle
        case awaitingServerHello
        case awaitingSecureReady
        case established
        case failed
    }

    public let mode: HandshakeMode
    public let roomId: String
    public let phoneDeviceId: String
    public private(set) var phase: Phase = .idle
    /// serverHello 才定下来（mac 侧 per-phone 单调递增）
    public private(set) var keyEpoch = 0
    /// serverHello 带来的 mac 显示名，qr_bootstrap 成功后由调用方存进信任记录
    public private(set) var macDisplayName: String?

    private let identity: PhoneIdentity
    private let expectedMacDeviceId: String
    /// 信任根：qr_bootstrap 用二维码 payload 里的公钥，trusted_reconnect 用配对时记下的公钥。
    /// serverHello 的验签只认它，回显不一致直接拒绝。
    private let trustRootMacIdentityPublicKey: String
    private let ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey
    private let phoneEphemeralPublicKeyBase64: String
    private let clientNonceBase64: String

    private var keyPhoneToMac = Data()
    private var keyMacToPhone = Data()
    /// phone→mac 已用到的 counter，发送前自增，首帧为 1
    private var outboundCounter = 0
    /// mac→phone 已接受的最大 counter，重放判定基准
    private var lastInboundCounter = 0

    /// ephemeralPrivateKeyRaw/clientNonce 仅供测试注入固定值；生产路径留 nil 取随机。
    public init(
        mode: HandshakeMode,
        roomId: String,
        phoneDeviceId: String,
        identity: PhoneIdentity,
        macDeviceId: String,
        macIdentityPublicKey: String,
        ephemeralPrivateKeyRaw: Data? = nil,
        clientNonce: Data? = nil
    ) throws {
        self.mode = mode
        self.roomId = roomId
        self.phoneDeviceId = phoneDeviceId
        self.identity = identity
        self.expectedMacDeviceId = macDeviceId
        self.trustRootMacIdentityPublicKey = macIdentityPublicKey
        if let raw = ephemeralPrivateKeyRaw {
            self.ephemeralPrivateKey = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: raw)
        } else {
            self.ephemeralPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        }
        self.phoneEphemeralPublicKeyBase64 =
            ephemeralPrivateKey.publicKey.rawRepresentation.base64EncodedString()
        self.clientNonceBase64 = (clientNonce ?? SecureCrypto.randomBytes(32))
            .base64EncodedString()
    }

    public func makeClientHello() throws -> ClientHelloFrame {
        guard phase == .idle else {
            throw SecureSessionError.unexpectedFrame("clientHello 每个会话只能发一次")
        }
        phase = .awaitingServerHello
        return ClientHelloFrame(
            protocolVersion: SecureCrypto.secureProtocolVersion,
            roomId: roomId,
            handshakeMode: mode,
            phoneDeviceId: phoneDeviceId,
            phoneIdentityPublicKey: identity.publicKeyRawBase64,
            phoneEphemeralPublicKey: phoneEphemeralPublicKeyBase64,
            clientNonce: clientNonceBase64
        )
    }

    /// 核心校验点：mac 身份公钥必须等于信任根，且 macSignature 对 transcript 验签通过。
    /// 任何失败都把会话打进 failed——半信任的会话没有继续的价值。
    public func handleServerHello(_ frame: ServerHelloFrame) throws -> ClientAuthFrame {
        guard phase == .awaitingServerHello else {
            try failed(throwing: .unexpectedFrame("当前阶段不接受 serverHello"))
        }
        guard frame.protocolVersion == SecureCrypto.secureProtocolVersion else {
            try failed(throwing: .protocolMismatch(frame.protocolVersion))
        }
        guard frame.roomId == roomId, frame.handshakeMode == mode,
            frame.clientNonce == clientNonceBase64
        else {
            try failed(throwing: .unexpectedFrame("serverHello 与本次 clientHello 不匹配"))
        }
        guard frame.macDeviceId == expectedMacDeviceId else {
            try failed(throwing: .identityMismatch("macDeviceId 与预期不符"))
        }
        guard frame.macIdentityPublicKey == trustRootMacIdentityPublicKey else {
            try failed(throwing: .identityMismatch("mac 身份公钥与信任根不符"))
        }
        guard let macIdentityRaw = decodeBase64Exact(frame.macIdentityPublicKey, count: 32) else {
            try failed(throwing: .identityMismatch("mac 身份公钥不是 32 字节 base64"))
        }
        guard let macEphemeralRaw = decodeBase64Exact(frame.macEphemeralPublicKey, count: 32)
        else {
            try failed(throwing: .unexpectedFrame("macEphemeralPublicKey 不是 32 字节 base64"))
        }

        let transcript = SecureCrypto.buildTranscript(
            TranscriptParams(
                roomId: roomId,
                protocolVersion: SecureCrypto.secureProtocolVersion,
                handshakeMode: mode,
                keyEpoch: frame.keyEpoch,
                macDeviceId: expectedMacDeviceId,
                phoneDeviceId: phoneDeviceId,
                macIdentityPublicKey: frame.macIdentityPublicKey,
                phoneIdentityPublicKey: identity.publicKeyRawBase64,
                macEphemeralPublicKey: frame.macEphemeralPublicKey,
                phoneEphemeralPublicKey: phoneEphemeralPublicKeyBase64,
                clientNonce: clientNonceBase64,
                serverNonce: frame.serverNonce,
                pairingExpiresAtMs: frame.pairingExpiresAtMs
            ))

        guard let signature = Data(base64Encoded: frame.macSignature),
            SecureCrypto.verifyTranscript(
                publicKeyRaw: macIdentityRaw, message: transcript, signature: signature)
        else {
            try failed(throwing: .invalidSignature)
        }

        let sharedSecret: Data
        let phoneSignature: Data
        do {
            let peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: macEphemeralRaw)
            sharedSecret = try ephemeralPrivateKey.sharedSecretFromKeyAgreement(with: peerKey)
                .withUnsafeBytes { Data($0) }
            phoneSignature = try SecureCrypto.signTranscript(
                seed: identity.seed,
                message: SecureCrypto.buildClientAuthMessage(transcript: transcript)
            )
        } catch {
            try failed(throwing: .unexpectedFrame("密钥协商失败: \(error)"))
        }

        let keys = SecureCrypto.deriveKeys(
            sharedSecret: sharedSecret, transcript: transcript,
            roomId: roomId, macDeviceId: expectedMacDeviceId,
            phoneDeviceId: phoneDeviceId, keyEpoch: frame.keyEpoch
        )
        keyPhoneToMac = keys.phoneToMac
        keyMacToPhone = keys.macToPhone
        keyEpoch = frame.keyEpoch
        macDisplayName = frame.displayName
        phase = .awaitingSecureReady

        return ClientAuthFrame(
            roomId: roomId,
            phoneDeviceId: phoneDeviceId,
            keyEpoch: frame.keyEpoch,
            phoneSignature: phoneSignature.base64EncodedString()
        )
    }

    public func handleSecureReady(_ frame: SecureReadyFrame) throws {
        guard phase == .awaitingSecureReady else {
            try failed(throwing: .unexpectedFrame("当前阶段不接受 secureReady"))
        }
        guard frame.roomId == roomId, frame.keyEpoch == keyEpoch,
            frame.macDeviceId == expectedMacDeviceId
        else {
            try failed(throwing: .unexpectedFrame("secureReady 与本次握手不匹配"))
        }
        phase = .established
    }

    /// secureError 意味着 mac 侧已放弃本会话，phone 侧同步作废并把错误交给调用方决定重试策略
    public func handleSecureError(_ frame: SecureErrorFrame) -> SecureSessionError {
        phase = .failed
        return .remoteError(code: frame.code, message: frame.message)
    }

    public func seal(_ plaintext: String) throws -> EncryptedEnvelope {
        guard phase == .established else { throw SecureSessionError.notEstablished }
        outboundCounter += 1
        return try SecureCrypto.sealEnvelope(
            key: keyPhoneToMac, roomId: roomId, keyEpoch: keyEpoch,
            sender: .phone, counter: outboundCounter, plaintext: plaintext
        )
    }

    /// 重放/乱序旧帧返回 nil（静默丢弃，镜像 mac 侧不回帧防放大）；
    /// 认证失败抛 decryptFailed 并作废会话——密钥失同步或有人篡改，只能重新握手。
    public func open(_ envelope: EncryptedEnvelope) throws -> String? {
        guard phase == .established else { throw SecureSessionError.notEstablished }
        guard envelope.v == 1, envelope.sender == .mac,
            envelope.roomId == roomId, envelope.keyEpoch == keyEpoch, envelope.counter >= 1
        else {
            throw SecureSessionError.unexpectedFrame("信封头字段与本会话不匹配")
        }
        if envelope.counter <= lastInboundCounter { return nil }
        let plaintext: String
        do {
            plaintext = try SecureCrypto.openEnvelope(key: keyMacToPhone, envelope: envelope)
        } catch {
            phase = .failed
            throw SecureSessionError.decryptFailed
        }
        lastInboundCounter = envelope.counter
        return plaintext
    }

    /// 握手失败一律不可恢复：置 failed 再抛，`Never` 返回值保证没有漏置状态的分支
    private func failed(throwing error: SecureSessionError) throws -> Never {
        phase = .failed
        throw error
    }
}

func decodeBase64Exact(_ value: String, count: Int) -> Data? {
    guard let data = Data(base64Encoded: value), data.count == count else { return nil }
    return data
}

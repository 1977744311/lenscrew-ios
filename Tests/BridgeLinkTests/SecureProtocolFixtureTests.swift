import CryptoKit
import Foundation
import Testing

@testable import BridgeLink

/// 跨语言 E2EE 黄金样本对齐。
///
/// protocol/fixtures/e2ee-handshake.json 由 bridge/src/secure/fixture.ts 生成，
/// TS 侧断言自己能逐字节重现；Swift 侧在这里对同样的固定输入断言 CryptoKit
/// 产出逐字节一致。谁改了协议细节没同步另一侧，两边总有一边会红。
///
/// 唯一例外是两个 Ed25519 签名字段：CryptoKit 的 Ed25519 签名带随机化
/// （抗侧信道，同输入每次输出不同，实测确认），无法与 Node 的 RFC 8032 确定性
/// 签名逐字节比对。但 Ed25519 验签绑定精确的消息字节与公钥——fixture 签名能被
/// Swift 重建的 transcript 验过，就证明 transcript 逐字节一致；再配一条
/// 「篡改一字节即验签失败」的反向断言钉死绑定性。互通性由「Swift 产签名可被
/// 同一公钥验证」保证（Node 侧 verify 接受任何合法签名）。
private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // BridgeLinkTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // 仓库根
        .appendingPathComponent("protocol/fixtures/\(name)")
}

private struct E2eeFixture: Decodable {
    struct Inputs: Decodable {
        let protocolVersion: Int
        let handshakeMode: String
        let roomId: String
        let macDeviceId: String
        let phoneDeviceId: String
        let displayName: String
        let keyEpoch: Int
        let pairingExpiresAtMs: Int
        let macIdentitySeedBase64: String
        let phoneIdentitySeedBase64: String
        let macEphemeralPrivateKeyBase64: String
        let phoneEphemeralPrivateKeyBase64: String
        let clientNonceBase64: String
        let serverNonceBase64: String
    }

    struct ExpectedEnvelope: Decodable {
        let plaintextUtf8: String
        let envelope: EncryptedEnvelope
    }

    struct Expected: Decodable {
        let macIdentityPublicKeyBase64: String
        let phoneIdentityPublicKeyBase64: String
        let macEphemeralPublicKeyBase64: String
        let phoneEphemeralPublicKeyBase64: String
        let transcriptSha256Hex: String
        let macSignatureBase64: String
        let phoneSignatureBase64: String
        let sharedSecretHex: String
        let keyPhoneToMacHex: String
        let keyMacToPhoneHex: String
        let envelopes: [ExpectedEnvelope]
    }

    let inputs: Inputs
    let expected: Expected
}

@Suite("E2EE 跨语言 fixture 对齐")
struct SecureProtocolFixtureTests {
    private let fixture: E2eeFixture

    init() throws {
        let data = try Data(contentsOf: fixtureURL("e2ee-handshake.json"))
        fixture = try JSONDecoder().decode(E2eeFixture.self, from: data)
    }

    private func base64Data(_ value: String) throws -> Data {
        try #require(Data(base64Encoded: value))
    }

    /// 重建 fixture 的 transcript（全部素材来自 inputs + 派生公钥）
    private func rebuildTranscript() throws -> Data {
        let inputs = fixture.inputs
        let handshakeMode = try #require(HandshakeMode(rawValue: inputs.handshakeMode))
        return SecureCrypto.buildTranscript(
            TranscriptParams(
                roomId: inputs.roomId,
                protocolVersion: inputs.protocolVersion,
                handshakeMode: handshakeMode,
                keyEpoch: inputs.keyEpoch,
                macDeviceId: inputs.macDeviceId,
                phoneDeviceId: inputs.phoneDeviceId,
                macIdentityPublicKey: try SecureCrypto.ed25519PublicKeyRaw(
                    seed: base64Data(inputs.macIdentitySeedBase64)
                ).base64EncodedString(),
                phoneIdentityPublicKey: try SecureCrypto.ed25519PublicKeyRaw(
                    seed: base64Data(inputs.phoneIdentitySeedBase64)
                ).base64EncodedString(),
                macEphemeralPublicKey: try SecureCrypto.x25519PublicKeyRaw(
                    privateKeyRaw: base64Data(inputs.macEphemeralPrivateKeyBase64)
                ).base64EncodedString(),
                phoneEphemeralPublicKey: try SecureCrypto.x25519PublicKeyRaw(
                    privateKeyRaw: base64Data(inputs.phoneEphemeralPrivateKeyBase64)
                ).base64EncodedString(),
                clientNonce: inputs.clientNonceBase64,
                serverNonce: inputs.serverNonceBase64,
                pairingExpiresAtMs: inputs.pairingExpiresAtMs
            ))
    }

    @Test("身份/临时公钥从私钥材料逐字节派生一致")
    func derivesPublicKeys() throws {
        #expect(
            try SecureCrypto.ed25519PublicKeyRaw(
                seed: base64Data(fixture.inputs.macIdentitySeedBase64)
            ).base64EncodedString() == fixture.expected.macIdentityPublicKeyBase64
        )
        #expect(
            try SecureCrypto.ed25519PublicKeyRaw(
                seed: base64Data(fixture.inputs.phoneIdentitySeedBase64)
            ).base64EncodedString() == fixture.expected.phoneIdentityPublicKeyBase64
        )
        #expect(
            try SecureCrypto.x25519PublicKeyRaw(
                privateKeyRaw: base64Data(fixture.inputs.macEphemeralPrivateKeyBase64)
            ).base64EncodedString() == fixture.expected.macEphemeralPublicKeyBase64
        )
        #expect(
            try SecureCrypto.x25519PublicKeyRaw(
                privateKeyRaw: base64Data(fixture.inputs.phoneEphemeralPrivateKeyBase64)
            ).base64EncodedString() == fixture.expected.phoneEphemeralPublicKeyBase64
        )
        // PhoneIdentity 走同一条派生路径
        let identity = try PhoneIdentity(seedBase64: fixture.inputs.phoneIdentitySeedBase64)
        #expect(identity.publicKeyRawBase64 == fixture.expected.phoneIdentityPublicKeyBase64)
        #expect(identity.seedBase64 == fixture.inputs.phoneIdentitySeedBase64)
    }

    @Test("transcript 14 字段长度前缀拼接的 SHA-256 逐字节一致")
    func transcriptMatches() throws {
        let transcript = try rebuildTranscript()
        #expect(Data(SHA256.hash(data: transcript)).hexString == fixture.expected.transcriptSha256Hex)
    }

    @Test("mac 签名对 transcript 严格验签；篡改一字节即失败")
    func macSignatureVerifies() throws {
        let transcript = try rebuildTranscript()
        let macPublicKey = try base64Data(fixture.expected.macIdentityPublicKeyBase64)
        let macSignature = try base64Data(fixture.expected.macSignatureBase64)
        #expect(
            SecureCrypto.verifyTranscript(
                publicKeyRaw: macPublicKey, message: transcript, signature: macSignature)
        )
        var tampered = transcript
        tampered[tampered.count - 1] ^= 0x01
        #expect(
            !SecureCrypto.verifyTranscript(
                publicKeyRaw: macPublicKey, message: tampered, signature: macSignature)
        )
        // CryptoKit 自产签名（随机化）同样要能过同一公钥验签，保证 Node 侧也验得过
        let ownSignature = try SecureCrypto.signTranscript(
            seed: base64Data(fixture.inputs.macIdentitySeedBase64), message: transcript)
        #expect(
            SecureCrypto.verifyTranscript(
                publicKeyRaw: macPublicKey, message: transcript, signature: ownSignature)
        )
    }

    @Test("phone 签名对 transcript‖client-auth 域分隔消息严格验签")
    func phoneSignatureVerifies() throws {
        let message = SecureCrypto.buildClientAuthMessage(transcript: try rebuildTranscript())
        let phonePublicKey = try base64Data(fixture.expected.phoneIdentityPublicKeyBase64)
        let phoneSignature = try base64Data(fixture.expected.phoneSignatureBase64)
        #expect(
            SecureCrypto.verifyTranscript(
                publicKeyRaw: phonePublicKey, message: message, signature: phoneSignature)
        )
        // 域分隔必须生效：同一把钥匙对裸 transcript 的签名不能与 clientAuth 消息互换
        #expect(
            !SecureCrypto.verifyTranscript(
                publicKeyRaw: phonePublicKey,
                message: try rebuildTranscript(),
                signature: phoneSignature)
        )
        let ownSignature = try SecureCrypto.signTranscript(
            seed: base64Data(fixture.inputs.phoneIdentitySeedBase64), message: message)
        #expect(
            SecureCrypto.verifyTranscript(
                publicKeyRaw: phonePublicKey, message: message, signature: ownSignature)
        )
    }

    @Test("X25519 共享密钥两个方向算出同一值且与 fixture 一致")
    func sharedSecretMatches() throws {
        let phoneSide = try SecureCrypto.x25519SharedSecret(
            privateKeyRaw: base64Data(fixture.inputs.phoneEphemeralPrivateKeyBase64),
            peerPublicRaw: base64Data(fixture.expected.macEphemeralPublicKeyBase64)
        )
        let macSide = try SecureCrypto.x25519SharedSecret(
            privateKeyRaw: base64Data(fixture.inputs.macEphemeralPrivateKeyBase64),
            peerPublicRaw: base64Data(fixture.expected.phoneEphemeralPublicKeyBase64)
        )
        #expect(phoneSide.hexString == fixture.expected.sharedSecretHex)
        #expect(macSide.hexString == fixture.expected.sharedSecretHex)
    }

    @Test("HKDF 两方向密钥逐字节一致")
    func derivedKeysMatch() throws {
        let keys = SecureCrypto.deriveKeys(
            sharedSecret: try SecureCrypto.x25519SharedSecret(
                privateKeyRaw: base64Data(fixture.inputs.phoneEphemeralPrivateKeyBase64),
                peerPublicRaw: base64Data(fixture.expected.macEphemeralPublicKeyBase64)),
            transcript: try rebuildTranscript(),
            roomId: fixture.inputs.roomId,
            macDeviceId: fixture.inputs.macDeviceId,
            phoneDeviceId: fixture.inputs.phoneDeviceId,
            keyEpoch: fixture.inputs.keyEpoch
        )
        #expect(keys.phoneToMac.hexString == fixture.expected.keyPhoneToMacHex)
        #expect(keys.macToPhone.hexString == fixture.expected.keyMacToPhoneHex)
    }

    @Test("三条信封 ciphertext/tag 逐字节一致，且解密回原文")
    func envelopesMatch() throws {
        let keyPhoneToMac = Data(hexStringExact: fixture.expected.keyPhoneToMacHex)
        let keyMacToPhone = Data(hexStringExact: fixture.expected.keyMacToPhoneHex)
        for item in fixture.expected.envelopes {
            let expected = item.envelope
            let key = expected.sender == .phone ? keyPhoneToMac : keyMacToPhone
            let sealed = try SecureCrypto.sealEnvelope(
                key: key, roomId: expected.roomId, keyEpoch: expected.keyEpoch,
                sender: expected.sender, counter: expected.counter,
                plaintext: item.plaintextUtf8
            )
            #expect(sealed == expected)
            #expect(try SecureCrypto.openEnvelope(key: key, envelope: expected) == item.plaintextUtf8)
        }
    }

    @Test("信封编码的线上字段名与 fixture 原始 JSON 完全一致（含 kind）")
    func envelopeWireFormatMatches() throws {
        let raw = try Data(contentsOf: fixtureURL("e2ee-handshake.json"))
        let root = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let expected = try #require(root["expected"] as? [String: Any])
        let rawEnvelopes = try #require(expected["envelopes"] as? [[String: Any]])

        for (index, item) in fixture.expected.envelopes.enumerated() {
            let encoded = try JSONEncoder().encode(item.envelope)
            let reencoded = try #require(
                JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            let original = try #require(rawEnvelopes[index]["envelope"] as? [String: Any])
            #expect(
                NSDictionary(dictionary: reencoded) == NSDictionary(dictionary: original),
                "第 \(index) 条信封线上格式漂移"
            )
        }
    }

    @Test("信封 AAD 绑定头字段：改 counter 即解密失败；counter 防重放由会话层测")
    func envelopeAadBindsHeader() throws {
        let key = Data(hexStringExact: fixture.expected.keyPhoneToMacHex)
        var envelope = fixture.expected.envelopes[0].envelope
        envelope.counter += 1
        #expect(throws: SecureCryptoError.decryptFailed) {
            _ = try SecureCrypto.openEnvelope(key: key, envelope: envelope)
        }
    }
}

extension Data {
    /// 测试专用：十六进制字符串还原（fixture 值保证偶数长度合法 hex）
    fileprivate init(hexStringExact hex: String) {
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self = data
    }
}

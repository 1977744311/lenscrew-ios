import Testing

@testable import LensCrew

@Suite("humanizeSecureError")
struct HumanizeSecureErrorTests {

    @Test(
        "每个安全通道错误码翻成对应的可行动人话",
        arguments: [
            ("pairing_expired", "二维码已过期，在 Mac 上运行 lenscrew qr 重新生成"),
            ("phone_identity_changed", "Mac 记录的手机身份对不上，在 Mac 上移除这台手机后重新扫码"),
            ("phone_not_trusted", "Mac 还不信任这台手机，重新扫码配对"),
            ("invalid_signature", "身份校验失败，在 Mac 上重新生成二维码再试"),
            ("protocol_mismatch", "App 与 Mac 端协议版本不一致，两边都升级后重试"),
        ]
    )
    func mapsKnownCodes(code: String, expected: String) {
        // SecureBridgeConnection 只给嵌着码名的 transport 文案，翻译靠子串匹配
        #expect(humanizeSecureError("安全通道错误 \(code): boom") == expected)
        #expect(humanizeSecureError(code) == expected, "裸码名同样命中")
    }

    @Test("未认出的文案原样透传，不吞也不猜")
    func passesThroughUnknownMessages() {
        #expect(humanizeSecureError("连接已断开") == "连接已断开")
        #expect(humanizeSecureError("") == "")
        #expect(
            humanizeSecureError("E2EE 事件流 HTTP 502") == "E2EE 事件流 HTTP 502",
            "不含任何已知码名的 transport 文案保持原样"
        )
    }
}

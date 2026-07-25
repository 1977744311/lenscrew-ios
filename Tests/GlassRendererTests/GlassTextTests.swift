import Testing

@testable import GlassRenderer

@Suite("眼镜屏文字度量与折行")
struct GlassTextTests {

    @Test("中英混排按显示宽度计，不按字符数")
    func measuresDisplayWidth() {
        #expect(GlassText.width("abc") == 3)
        #expect(GlassText.width("中文") == 4)
        #expect(GlassText.width("a中b") == 4)
        #expect(GlassText.width("") == 0)
    }

    @Test("英文在空格处断行")
    func wrapsLatinAtSpaces() {
        let lines = GlassText.wrap("npm run build and test", width: 10)
        #expect(lines.allSatisfy { GlassText.width($0) <= 10 })
        #expect(lines.first == "npm run")
    }

    @Test("中文任意处断行且不超宽")
    func wrapsCJKAnywhere() {
        let lines = GlassText.wrap("这是一段没有空格的中文句子", width: 8)
        #expect(lines.count > 1)
        #expect(lines.allSatisfy { GlassText.width($0) <= 8 })
        #expect(lines.joined() == "这是一段没有空格的中文句子")
    }

    @Test("超宽单词强制切开而不是溢出")
    func breaksOverlongToken() {
        let lines = GlassText.wrap("aaaaaaaaaaaaaaaaaaaa", width: 6)
        #expect(lines.allSatisfy { GlassText.width($0) <= 6 })
        #expect(lines.joined() == "aaaaaaaaaaaaaaaaaaaa")
    }

    @Test("保留原有换行")
    func keepsExplicitNewlines() {
        #expect(GlassText.wrap("a\nb", width: 10) == ["a", "b"])
        #expect(GlassText.wrap("a\n\nb", width: 10) == ["a", "", "b"])
    }

    @Test("截断加省略号且不超宽")
    func truncatesToWidth() {
        #expect(GlassText.truncate("abc", to: 10) == "abc")
        let truncated = GlassText.truncate("这是一个很长的会话标题", to: 8)
        #expect(GlassText.width(truncated) <= 8)
        #expect(truncated.hasSuffix("…"))
    }
}

import GlassesKit

/// 眼镜会话的来源：真机上用 DAT，模拟器上用 Mock。
/// 判断放在这一处，其余代码只认 GlassesSessionProviding。
enum GlassesRuntime {
    static func makeSession() -> any GlassesSessionProviding {
        #if targetEnvironment(simulator)
        return MockGlassesSession()
        #elseif canImport(MWDATCore) && canImport(MWDATDisplay)
        return DATGlassesSessionAdapter()
        #else
        return MockGlassesSession()
        #endif
    }

    static var isMock: Bool {
        #if targetEnvironment(simulator)
        return true
        #elseif canImport(MWDATCore) && canImport(MWDATDisplay)
        return false
        #else
        return true
        #endif
    }
}

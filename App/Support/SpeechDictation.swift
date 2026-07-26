import AVFoundation
import Foundation
import Speech

/// 手机端语音输入：SFSpeechRecognizer 实时听写，识别文本流式进 composer 草稿。
/// 点一下开始、再点结束——发送与否仍由发送键决定，语音只负责把话变成字。
/// 识别语言跟随系统 Locale；权限在第一次点击时才请求，不在启动期打扰。
@MainActor
@Observable
final class SpeechDictation {
    private(set) var isListening = false
    /// 本次听写的累计识别文本。partial 结果是全量替换式，
    /// 消费方应以"起点快照 + transcript"拼草稿，而不是逐段追加。
    private(set) var transcript = ""
    private(set) var lastError: String?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func start() {
        guard !isListening else { return }
        lastError = nil
        Task { await begin() }
    }

    /// 结束听写并让识别收尾：final 结果可能在几百毫秒后到达，
    /// 届时 transcript 还会更新最后一次
    func stop() {
        guard isListening else { return }
        isListening = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        deactivateAudioSession()
    }

    /// 立即作废本次听写（发送、离开页面）：不再产出任何文本
    func cancel() {
        guard isListening || task != nil else { return }
        isListening = false
        transcript = ""
        task?.cancel()
        task = nil
        request = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        deactivateAudioSession()
    }

    // MARK: - 内部

    private func begin() async {
        let speechAuth = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speechAuth == .authorized else {
            lastError = "没有语音识别权限，去 设置 › LensCrew 打开"
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            lastError = "没有麦克风权限，去 设置 › LensCrew 打开"
            return
        }
        do {
            try startEngine()
        } catch {
            lastError = "听写启动失败：\((error as NSError).localizedDescription)"
            cancel()
        }
    }

    private func startEngine() throws {
        guard
            let recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(),
            recognizer.isAvailable
        else {
            lastError = "语音识别暂不可用（离线或语言不支持）"
            return
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) {
            buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        try engine.start()

        transcript = ""
        isListening = true
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result.map(\.bestTranscription.formattedString)
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor [weak self] in
                self?.handle(text: text, isFinal: isFinal, failed: failed)
            }
        }
    }

    private func handle(text: String?, isFinal: Bool, failed: Bool) {
        if let text {
            transcript = text
        }
        if isFinal {
            finish()
            return
        }
        if failed {
            // 主动 stop/cancel 之后系统会补一个错误回调，那不是故障；
            // 只有听写进行中且一个字都没识别出来才值得提示
            if isListening, transcript.isEmpty {
                lastError = "没听清，再试一次"
            }
            finish()
        }
    }

    private func finish() {
        isListening = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        task = nil
        request = nil
        deactivateAudioSession()
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
    }
}

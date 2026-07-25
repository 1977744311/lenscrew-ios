import AVFoundation
import BridgeLink
import SwiftUI

/// 扫码配对：相机扫 Mac 上 lenscrew qr 出的二维码 → 确认卡 → qr_bootstrap 握手入库。
/// 相机不可用（模拟器没硬件 / 权限被拒）自动换手动粘贴，走同一条解析确认流程。
struct PairingScanView: View {
    let model: CrewViewModel
    /// 配对成功回调：由 AddComputerSheet 把整条 sheet 链收掉、回设置页
    let onPaired: () -> Void
    @Environment(\.dismiss) private var dismiss

    /// nil = 还在扫/粘；非 nil = 已解析成功，停在确认卡
    @State private var payload: PairingPayload?
    @State private var pairing = false
    @State private var failure: String?
    /// nil = 相机可用性还没判定完
    @State private var cameraReady: Bool?
    @State private var pasted = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("扫码配对")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(LC.text)
                Spacer()
                Button("取消") { dismiss() }
                    .font(.system(size: 15))
                    .foregroundStyle(LC.text3)
                    .disabled(pairing)
            }

            if let payload {
                confirmCard(payload)
                Button("换一个二维码") {
                    self.payload = nil
                    failure = nil
                }
                .font(.system(size: 13))
                .foregroundStyle(LC.lightBlue)
                .disabled(pairing)
                .frame(maxWidth: .infinity)
            } else {
                scanArea
            }

            if let failure {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 12))
                    Text(failure).lineLimit(3)
                }
                .font(.system(size: 12.5))
                .foregroundStyle(LC.red)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(LC.bg.ignoresSafeArea())
        .task { await resolveCameraAccess() }
    }

    // MARK: - 扫描 / 粘贴

    @ViewBuilder private var scanArea: some View {
        if cameraReady == nil {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 320)
        } else if cameraReady == true {
            VStack(spacing: 10) {
                QRCameraView { handle(code: $0) }
                    .frame(maxWidth: .infinity)
                    .frame(height: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                Text("在 Mac 上运行 lenscrew qr，把二维码对进取景框。")
                    .font(.system(size: 12))
                    .foregroundStyle(LC.text3)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("相机不可用（模拟器或权限被拒）。把 Mac 上 lenscrew qr 输出的配对内容（JSON）粘到这里：")
                    .font(.system(size: 13))
                    .foregroundStyle(LC.text2)
                TextEditor(text: $pasted)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(LC.text)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 180)
                    .background(LC.elev, in: RoundedRectangle(cornerRadius: 14))
                LCButton(title: "解析配对信息", kind: .tinted) {
                    handle(code: pasted)
                }
            }
        }
    }

    /// 扫到 / 粘到的内容统一从这里过：解析失败留在原地展示原因，可以继续扫
    private func handle(code: String) {
        guard payload == nil, !pairing else { return }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let parsed = try PairingPayload.parse(
                Data(trimmed.utf8),
                nowMs: Int(Date.now.timeIntervalSince1970 * 1000)
            )
            failure = nil
            payload = parsed
        } catch {
            failure = Self.parseFailureText(error)
        }
    }

    // MARK: - 确认卡

    private func confirmCard(_ payload: PairingPayload) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 22))
                    .foregroundStyle(LC.lightBlue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(payload.displayName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(LC.text)
                    Text("设备 \(String(payload.macDeviceId.prefix(8)))")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(LC.text3)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                pathRow(
                    available: payload.lan != nil,
                    label: payload.lan.map { "局域网直连 \($0.host):\($0.port)" } ?? "局域网直连"
                )
                pathRow(available: payload.relay != nil, label: "云端中继")
            }

            // 倒计时和配对按钮绑在同一个 TimelineView 里：过期瞬间按钮同步失效
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining =
                    Int(Double(payload.expiresAtMs) / 1000 - context.date.timeIntervalSince1970)
                VStack(alignment: .leading, spacing: 10) {
                    Text(
                        remaining > 0
                            ? "二维码 \(remaining)s 后过期"
                            : "二维码已过期，在 Mac 上运行 lenscrew qr 重新生成"
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(remaining > 0 ? LC.text3 : LC.red)
                    LCButton(title: pairing ? "配对中…" : "配对这台 Mac", kind: .primary) {
                        Task { await pair(payload) }
                    }
                    .disabled(pairing || remaining <= 0)
                    .opacity(pairing || remaining <= 0 ? 0.5 : 1)
                }
            }
        }
        .padding(16)
        .background(LC.elev, in: RoundedRectangle(cornerRadius: 20))
    }

    private func pathRow(available: Bool, label: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: available ? "checkmark.circle.fill" : "minus.circle")
                .font(.system(size: 13))
                .foregroundStyle(available ? LC.green : LC.text3)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(available ? LC.text2 : LC.text3)
        }
    }

    private func pair(_ payload: PairingPayload) async {
        pairing = true
        failure = nil
        do {
            try await model.pair(with: payload)
            pairing = false
            onPaired()
        } catch let error as PairingFlowError {
            pairing = false
            failure = error.message
        } catch {
            pairing = false
            failure = String(describing: error)
        }
    }

    // MARK: - 相机可用性与错误文案

    private func resolveCameraAccess() async {
        guard AVCaptureDevice.default(for: .video) != nil else {
            // 模拟器没有相机硬件，直接落到粘贴通道
            cameraReady = false
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraReady = true
        case .notDetermined:
            cameraReady = await AVCaptureDevice.requestAccess(for: .video)
        default:
            cameraReady = false
        }
    }

    private static func parseFailureText(_ error: any Error) -> String {
        guard let payloadError = error as? PairingPayloadError else {
            return String(describing: error)
        }
        switch payloadError {
        case .malformed, .wrongKind:
            return "这不是 LensCrew 的配对二维码"
        case .unsupportedVersion:
            return "二维码版本太新，先升级 App"
        case .expired:
            return "二维码已过期，在 Mac 上运行 lenscrew qr 重新生成"
        }
    }
}

// MARK: - 相机取景

/// AVFoundation 取景 + QR 元数据回调的 SwiftUI 包装。
/// 会话的配置与启停全部锁在专用串行队列上，扫到的字符串抛回主线程。
private struct QRCameraView: UIViewRepresentable {
    let onCode: @MainActor @Sendable (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {}

    static func dismantleUIView(_ uiView: CameraPreviewUIView, coordinator: Coordinator) {
        coordinator.stop()
    }

    /// AVCaptureSession 只在 sessionQueue 上碰，据此声明 @unchecked Sendable
    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate,
        @unchecked Sendable {
        private let sessionQueue = DispatchQueue(label: "dev.steven.LensCrew.qr-scan")
        private let session = AVCaptureSession()
        private let onCode: @MainActor @Sendable (String) -> Void
        private var configured = false

        init(onCode: @escaping @MainActor @Sendable (String) -> Void) {
            self.onCode = onCode
        }

        @MainActor func attach(to view: CameraPreviewUIView) {
            // 先把 session 挂上预览层再去后台配置，是 AVCam 的标准顺序
            view.previewLayer.session = session
            view.previewLayer.videoGravity = .resizeAspectFill
            sessionQueue.async { [self] in configureAndStart() }
        }

        func stop() {
            sessionQueue.async { [self] in
                if session.isRunning { session.stopRunning() }
            }
        }

        /// sessionQueue 上执行：startRunning 会阻塞，不能占主线程
        private func configureAndStart() {
            if !configured {
                configured = true
                session.beginConfiguration()
                if let device = AVCaptureDevice.default(for: .video),
                   let input = try? AVCaptureDeviceInput(device: device),
                   session.canAddInput(input) {
                    session.addInput(input)
                }
                let output = AVCaptureMetadataOutput()
                if session.canAddOutput(output) {
                    session.addOutput(output)
                    output.setMetadataObjectsDelegate(self, queue: sessionQueue)
                    // 要在 addOutput 之后设置，否则可用类型列表是空的
                    if output.availableMetadataObjectTypes.contains(.qr) {
                        output.metadataObjectTypes = [.qr]
                    }
                }
                session.commitConfiguration()
            }
            if !session.isRunning { session.startRunning() }
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard
                let code = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?
                    .stringValue
            else { return }
            let handler = onCode
            Task { @MainActor in handler(code) }
        }
    }
}

/// layer 直接就是预览层，省掉手动同步 frame
private final class CameraPreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

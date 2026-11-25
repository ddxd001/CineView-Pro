//
//  ContentView.swift
//  CineView Pro
//
//  纯原生 iOS 17+ / Swift 6 专业横屏监视器主界面 (Monitor+ 极简风格)
//  - 强制锁定横屏、隐藏状态栏与 Home 指示条
//  - 底层：全屏 60fps MTKView，支持双指捏合缩放、单指拖动巡检、单击精准触控对焦 (自动反算缩放/偏移/反挤压坐标)
//  - 顶部悬浮状态栏：连接模式与延迟 | 实时曝光参数胶囊 (快门/光圈/ISO/白平衡，点击弹出底部滚轮调节) | 电量与录制状态
//  - 侧边/底部悬浮工具栏：3D LUT 导入与开关、可拖动波形图/RGB直方图浮窗、12段假色、Sobel峰值对焦、斑马纹、安全框、反挤压
//

import AVFoundation
import MetalKit
import Observation
import OSLog
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import os

// MARK: - 1. 横屏锁定 AppDelegate 适配器

/// 在 Xcode 工程的 `@main struct CineViewProApp: App` 中挂载：
/// `@UIApplicationDelegateAdaptor(CineViewAppDelegate.self) var appDelegate`
/// 即可在系统级全局强制锁定横屏方向。
@MainActor
public final class CineViewAppDelegate: NSObject, UIApplicationDelegate {
    public func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        .landscape
    }
}

// MARK: - 2. 监视器 UI 枚举定义

/// 信号接入与控制模式
public enum MonitorConnectionMode: String, CaseIterable, Sendable, Identifiable {
    case uvcWired   = "UVC 有线"
    case wifiPTP    = "Wi-Fi"
    case hybridDual = "混合双模"

    public var id: String { rawValue }

    public var symbolName: String {
        switch self {
        case .uvcWired:   return "cable.connector"
        case .wifiPTP:    return "wifi"
        case .hybridDual: return "link.circle.fill"
        }
    }

    public var subtitle: String {
        switch self {
        case .uvcWired:   return "USB-C HDMI 采集卡 60fps 零压缩画面"
        case .wifiPTP:    return "5GHz Wi-Fi / USB-LAN 图传 + 遥控"
        case .hybridDual: return "UVC 60fps 视频监看 + Wi-Fi PTP 遥控对焦"
        }
    }
}

/// 画面安全框 / 裁切参考线比例
public enum FrameGuideAspect: String, CaseIterable, Sendable, Identifiable {
    case off         = "关闭"
    case scope239    = "2.39:1"
    case scope235    = "2.35:1"
    case wide169     = "16:9"
    case classic43   = "4:3"
    case square11    = "1:1"
    case vertical916 = "9:16"

    public var id: String { rawValue }

    public var aspectRatio: CGFloat? {
        switch self {
        case .off:         return nil
        case .scope239:    return 2.39
        case .scope235:    return 2.35
        case .wide169:     return 16.0 / 9.0
        case .classic43:   return 4.0 / 3.0
        case .square11:    return 1.0
        case .vertical916: return 9.0 / 16.0
        }
    }

    public var next: FrameGuideAspect {
        let all = Self.allCases
        guard let idx = all.firstIndex(of: self) else { return .off }
        return all[(idx + 1) % all.count]
    }
}

/// 顶部曝光胶囊当前选中的调节项
public enum ActiveExposureControl: String, Sendable, Identifiable {
    case shutter
    case aperture
    case iso
    case exposureBias
    case whiteBalance

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .shutter:      return "快门速度 SHUTTER"
        case .aperture:     return "光圈 APERTURE"
        case .iso:          return "感光度 ISO"
        case .exposureBias: return "曝光补偿 EV (0x5010)"
        case .whiteBalance: return "白平衡 & 色温 (0x5005 / 0xD20F)"
        }
    }
}

/// 示波器浮窗展示模式
public enum ScopeDisplayMode: String, CaseIterable, Sendable {
    case waveform    = "波形"
    case parade      = "分量"
    case vectorscope = "矢量"
    case histogram   = "直方图"
    case dual        = "双显"
}

/// 触控对焦视觉反馈标记
public struct FocusReticleState: Equatable, Sendable {
    public let id = UUID()
    public let screenPoint: CGPoint
    public let normalizedPoint: TouchFocusPoint
    public var isLocked: Bool = false
}

// MARK: - 3. UVC 外部 HDMI 采集卡控制器 (AVCaptureDevice.DeviceType.external)

private final class UVCCaptureController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "com.cineviewpro.uvc.capture", qos: .userInteractive)
    private let renderer: MonitorRenderer
    private let onFrameIntervalMs: @Sendable (Int) -> Void
    private let lastFrameTimeLock = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)

    init(renderer: MonitorRenderer, onFrameIntervalMs: @escaping @Sendable (Int) -> Void) {
        self.renderer = renderer
        self.onFrameIntervalMs = onFrameIntervalMs
        super.init()
    }

    func start() throws {
        guard let device = ExternalUVCCaptureDiscovery.discoverExternalCaptureDevices().first else {
            throw NSError(
                domain: "com.cineviewpro.uvc",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "未检测到外部 USB-C UVC HDMI 采集卡，请检查线缆连接与相机 HDMI 输出。"]
            )
        }

        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = ExternalUVCCaptureDiscovery.recommendedVideoSettings
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)

        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }
        if session.canAddInput(input) {
            session.addInput(input)
        }
        if session.canAddOutput(output) {
            session.addOutput(output)
        }
        session.commitConfiguration()

        captureQueue.async { [self] in
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    func stop() {
        captureQueue.async { [self] in
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
        lastFrameTimeLock.withLock { $0 = nil }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // 零拷贝直投 MonitorRenderer (非主线程安全调用)
        renderer.update(sampleBuffer: sampleBuffer)

        let now = ContinuousClock.now
        let intervalMs: Int? = lastFrameTimeLock.withLock { prev in
            defer { prev = now }
            guard let prev else { return nil }
            let diff = prev.duration(to: now)
            return Int(diff.components.seconds * 1000) + Int(diff.components.attoseconds / 1_000_000_000_000_000)
        }
        if let ms = intervalMs {
            onFrameIntervalMs(ms)
        }
    }
}

// MARK: - 4. 主界面状态管理 ViewModel (iOS 17+ @Observable + Swift 6 @MainActor)

@MainActor
@Observable
public final class MonitorViewModel {
    // --- 核心引擎 ---
    public let renderer: MonitorRenderer?
    public let rendererInitError: String?
    private var ptpClient: SonyPTPIPClient?
    private var uvcController: UVCCaptureController?
    private var testPatternGenerator: TestPatternGenerator?

    // --- 连接与信号状态 ---
    public var connectionMode: MonitorConnectionMode = .wifiPTP
    public var cameraIP: String = "192.168.122.1"
    public var liveViewQuality: SonyLiveViewImageQuality = .low
    public var isCameraConnected: Bool = false
    public var isUVCActive: Bool = false
    public var isTestPatternActive: Bool = false
    public var isConnecting: Bool = false
    public var signalLatencyMs: Int = 0
    public var currentFPS: Int = 0
    public var currentResolutionLabel: String = ""
    public var currentFrameKB: Int = 0
    public var statusBannerMessage: String?

    // --- 相机实时遥测参数 (A6700) ---
    public var currentShutter: SonyShutterSpeed = .fraction(1, 50)
    public var isShutterWritable: Bool = true
    public var currentAperture: SonyAperture = SonyAperture(fStop: 2.8)
    public var isApertureWritable: Bool = true
    public var currentISO: SonyISOValue = .manual(800)
    public var isISOWritable: Bool = true
    public var currentExposureBias: SonyExposureBias = SonyExposureBias(rawMilliEV: 0)
    public var currentWhiteBalance: SonyWhiteBalance = .daylight
    public var currentColorTemp: UInt16 = 5600
    public var batteryPercent: Int = 86
    public var isRecording: Bool = false
    public var recordingSeconds: Int = 0

    // --- 专业监看工具状态 (双向同步至 MonitorRenderer.settings) ---
    public var renderSettings = MonitorRenderSettings() {
        didSet { renderer?.settings = renderSettings }
    }
    public var loadedLUTName: String?
    public var savedLUTs: [SavedLUTItem] = []
    public var activeSavedLUTID: String?
    public var frameGuide: FrameGuideAspect = .off
    public var isGridEnabled: Bool = false
    public var isScopesVisible: Bool = false
    public var scopeDisplayMode: ScopeDisplayMode = .dual
    public var latestScope: ScopeAnalysisResult?

    // --- 界面交互状态 ---
    public var activeExposureControl: ActiveExposureControl?
    public var activeToolInspector: ToolInspectorKind?
    public var focusReticle: FocusReticleState?
    public var isConnectionSheetPresented: Bool = false
    public var isLUTImporterPresented: Bool = false
    public var isHUDHidden: Bool = false

    // --- 内部后台任务 ---
    private var liveViewTask: Task<Void, Never>?
    private var telemetryTask: Task<Void, Never>?
    private var recordingTimerTask: Task<Void, Never>?
    private var reticleDismissTask: Task<Void, Never>?
    private var bannerDismissTask: Task<Void, Never>?

    private let logger = Logger(subsystem: "com.cineviewpro.ui", category: "MonitorViewModel")

    public enum ToolInspectorKind: String, Sendable, Identifiable {
        case lut
        case peaking
        case zebra
        case guides
        case flip
        public var id: String { rawValue }
    }

    // 离线/仿真模式默认快捷挡位表；联机后由 A6700 0x9209 动态枚举表实时替换
    private static let fallbackShutterPresets: [SonyShutterSpeed] = [
        .fraction(1, 24), .fraction(1, 25), .fraction(1, 30), .fraction(1, 48),
        .fraction(1, 50), .fraction(1, 60), .fraction(1, 100), .fraction(1, 120),
        .fraction(1, 125), .fraction(1, 200), .fraction(1, 250), .fraction(1, 500),
        .fraction(1, 1000), .fraction(1, 2000), .fraction(1, 4000)
    ]

    private static let fallbackAperturePresets: [SonyAperture] = [
        1.4, 1.8, 2.0, 2.2, 2.5, 2.8, 3.2, 3.5, 4.0, 4.5, 5.0, 5.6, 6.3, 7.1, 8.0, 9.0, 11.0, 13.0, 16.0
    ].map(SonyAperture.init(fStop:))

    private static let fallbackISOPresets: [SonyISOValue] = [
        .auto, .manual(100), .manual(160), .manual(200), .manual(320), .manual(400),
        .manual(640), .manual(800), .manual(1250), .manual(1600), .manual(2500),
        .manual(3200), .manual(6400), .manual(12800), .manual(25600)
    ]

    /// 动态快门候选表：联机后严格同步 A6700 当前拍摄模式可用的快门档位 (来自 0x9209 属性 0xD20D)
    public var shutterPresets: [SonyShutterSpeed] = MonitorViewModel.fallbackShutterPresets

    /// 动态光圈候选表：联机后严格只展示当前镜头在当前焦段支持的光圈值 (来自 0x9209 属性 0x5007)
    public var aperturePresets: [SonyAperture] = MonitorViewModel.fallbackAperturePresets

    /// 动态 ISO 候选表：联机后严格同步 A6700 当前图像配置（如 S-Log3）下可用的 ISO 档位 (来自 0x9209 属性 0xD21E)
    public var isoPresets: [SonyISOValue] = MonitorViewModel.fallbackISOPresets

    public let exposureBiasPresets: [SonyExposureBias] = SonyExposureBias.standardThirdStopPresets

    public let whiteBalancePresets: [SonyWhiteBalance] = [
        .auto, .daylight, .shade, .cloudy, .incandescent,
        .fluorescentDayWhite, .fluorescentDaylight, .colorTempFilter, .custom1, .custom2
    ]

    /// 精准色温 K 值常用表 (2500K...9900K，步进 100K/200K 常用电影色温)
    public let colorTempPresets: [UInt16] = [
        2500, 2800, 3000, 3200, 3500, 3800, 4000, 4300, 4500, 4800,
        5000, 5200, 5400, 5600, 5800, 6000, 6500, 7000, 7500, 8000, 9000, 9900
    ]

    public init() {
        do {
            let r = try MonitorRenderer()
            self.renderer = r
            self.rendererInitError = nil
            renderSettings.isScopesEnabled = isScopesVisible
            r.settings = renderSettings
            r.onScopeUpdate = { [weak self] result in
                self?.latestScope = result
            }
        } catch {
            self.renderer = nil
            self.rendererInitError = error.localizedDescription
            renderSettings.isScopesEnabled = isScopesVisible
        }
        reloadSavedLUTsAndRestoreLast()
    }

    // MARK: - 连接与信号源切换

    public func connectCurrentMode() async {
        guard !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }

        await disconnectAll()

        switch connectionMode {
        case .uvcWired:
            startUVCStream()

        case .wifiPTP:
            await connectPTP(enableLiveView: true)

        case .hybridDual:
            // 混合双模：UVC 提供 60fps 零压缩 HDMI 画面，Wi-Fi PTP 仅负责低开销参数遥测与触控对焦/录制
            startUVCStream()
            await connectPTP(enableLiveView: false)
        }
    }

    public func disconnectAll() async {
        liveViewTask?.cancel()
        liveViewTask = nil
        telemetryTask?.cancel()
        telemetryTask = nil
        recordingTimerTask?.cancel()
        recordingTimerTask = nil

        uvcController?.stop()
        uvcController = nil
        isUVCActive = false

        testPatternGenerator?.stop()
        testPatternGenerator = nil
        isTestPatternActive = false

        if let client = ptpClient {
            await client.disconnect()
        }
        ptpClient = nil
        isCameraConnected = false
        signalLatencyMs = 0
        currentFPS = 0
        currentResolutionLabel = ""
        currentFrameKB = 0
        shutterPresets = Self.fallbackShutterPresets
        isShutterWritable = true
        aperturePresets = Self.fallbackAperturePresets
        isApertureWritable = true
        isoPresets = Self.fallbackISOPresets
        isISOWritable = true
    }

    /// 启动内置动态 SMPTE 彩条 + 0-100 IRE 斜坡 + 西门子对焦标板测试信号（模拟器离线仿真专用）
    public func startTestPattern() async {
        await disconnectAll()
        guard let renderer else {
            showBanner("Metal 渲染器未就绪: \(rendererInitError ?? "未知错误")")
            return
        }
        let gen = TestPatternGenerator(width: 1280, height: 720)
        self.testPatternGenerator = gen
        self.isTestPatternActive = true
        gen.start(fps: 30.0) { [weak self] pixelBuffer, ms in
            renderer.update(pixelBuffer: pixelBuffer)
            Task { @MainActor [weak self] in
                self?.signalLatencyMs = ms
            }
        }
        // 自动预载内置演示 3D LUT（默认关闭，用户可一键点击 LUT 按钮对比还原前后效果）
        if loadedLUTName == nil, let demoLUT = try? TestPatternGenerator.makeBuiltInDemoCubeLUT() {
            try? renderer.applyCubeLUT(demoLUT, autoEnable: false)
            self.loadedLUTName = demoLUT.title
        }
        showBanner("已启动内置 1280×720 动态测试信号源 (支持全套示波器/假色/峰值/LUT)")
    }

    /// 一键加载内置演示 S-Log3 -> Cine709 3D LUT
    public func loadBuiltInDemoLUT() {
        guard let renderer else { return }
        do {
            let demoLUT = try TestPatternGenerator.makeBuiltInDemoCubeLUT()
            try renderer.applyCubeLUT(demoLUT, autoEnable: true)
            self.loadedLUTName = demoLUT.title
            self.renderSettings.isLUTEnabled = true
            showBanner("已启用演示 LUT: \(demoLUT.title)")
        } catch {
            showBanner("演示 LUT 加载失败: \(error.localizedDescription)")
        }
    }

    private func startUVCStream() {
        guard let renderer else {
            showBanner("Metal 渲染器未就绪")
            return
        }
        let controller = UVCCaptureController(renderer: renderer) { [weak self] intervalMs in
            Task { @MainActor [weak self] in
                // UVC 采集卡每帧间隔近似代表链路响应基线
                self?.signalLatencyMs = max(8, intervalMs)
            }
        }
        do {
            try controller.start()
            self.uvcController = controller
            self.isUVCActive = true
            showBanner("已接入外部 UVC HDMI 采集卡")
        } catch {
            self.isUVCActive = false
            showBanner(error.localizedDescription)
        }
    }

    private func connectPTP(enableLiveView: Bool) async {
        let clientGUID = Self.loadOrCreatePersistedGUID()
        let config = SonyPTPIPConfig(
            host: cameraIP.trimmingCharacters(in: .whitespacesAndNewlines),
            clientName: "CineView Pro",
            clientGUID: clientGUID,
            requiredInterfaceType: nil,
            preferredSDIOVersion: .v3,
            connectTimeout: .seconds(6),
            enableHexPacketLogging: false
        )
        let client = SonyPTPIPClient(config: config)
        do {
            let session = try await client.connect()
            self.ptpClient = client
            self.isCameraConnected = true
            showBanner("已连接 \(session.cameraName.isEmpty ? "Sony A6700" : session.cameraName)")

            // 同步首帧状态
            if let snapshot = try? await client.fetchCameraState() {
                applySnapshot(snapshot)
            }

            // 启动周期遥测同步与延迟测量 (每 2 秒同步一次)
            telemetryTask = Task { [weak self] in
                let clock = ContinuousClock()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled, let self, let activeClient = self.ptpClient else { break }
                    let t0 = clock.now
                    if let snap = try? await activeClient.fetchCameraState() {
                        let rtt = t0.duration(to: clock.now)
                        let rttMs = Int(rtt.components.seconds * 1000) + Int(rtt.components.attoseconds / 1_000_000_000_000_000)
                        self.applySnapshot(snap)
                        if !self.isUVCActive {
                            self.signalLatencyMs = max(1, rttMs)
                        }
                    }
                }
            }

            // 仅 Wi-Fi 模式下开启 PTP LiveView 拉流；混合双模下视频源由 UVC HDMI 提供
            if enableLiveView, let renderer {
                liveViewTask = Task.detached(priority: .userInitiated) { [weak self] in
                    let stream = await client.liveViewStream(targetFPS: 30)
                    let clock = ContinuousClock()
                    var windowStart = clock.now
                    var frameCount = 0
                    for await jpegData in stream {
                        if Task.isCancelled { break }
                        renderer.update(jpegData: jpegData)
                        frameCount += 1
                        let elapsed = windowStart.duration(to: clock.now)
                        if elapsed >= .seconds(1) {
                            let fps = frameCount
                            let kb = max(1, jpegData.count / 1024)
                            frameCount = 0
                            windowStart = clock.now
                            Task { @MainActor [weak self] in
                                self?.currentFPS = fps
                                self?.currentFrameKB = kb
                            }
                        }
                        if frameCount == 1 {
                            Task { @MainActor [weak self] in
                                let sz = renderer.currentSourceSize
                                if sz.width > 0 && sz.height > 0 {
                                    self?.currentResolutionLabel = "\(Int(sz.width))×\(Int(sz.height))"
                                }
                            }
                        }
                    }
                    if !Task.isCancelled {
                        Task { @MainActor [weak self] in
                            self?.currentFPS = 0
                            self?.showBanner("LiveView 推流已中断，请检查相机或重新连接")
                        }
                    }
                }
            }
        } catch {
            self.isCameraConnected = false
            showBanner("PTP 连接失败: \(error.localizedDescription)")
            logger.error("PTP connect failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func applySnapshot(_ snap: CameraStateSnapshot) {
        if let shutter = snap.shutterSpeed { currentShutter = shutter }
        isShutterWritable = snap.isShutterWritable
        if !snap.availableShutterSpeeds.isEmpty {
            shutterPresets = snap.availableShutterSpeeds
        } else if !snap.isShutterWritable {
            shutterPresets = []
        }

        if let aperture = snap.aperture { currentAperture = aperture }
        isApertureWritable = snap.isApertureWritable
        if !snap.availableApertures.isEmpty {
            aperturePresets = snap.availableApertures
        } else if !snap.isApertureWritable {
            aperturePresets = []
        }

        if let iso = snap.iso { currentISO = iso }
        isISOWritable = snap.isISOWritable
        if !snap.availableISOs.isEmpty {
            isoPresets = snap.availableISOs
        } else if !snap.isISOWritable {
            isoPresets = []
        }
        if let wb = snap.whiteBalance { currentWhiteBalance = wb }
        if let k = snap.colorTemperature, k >= 2500, k <= 9900 { currentColorTemp = k }
        if let ev = snap.exposureBias { currentExposureBias = ev }

        // 解析标准 PTP BatteryLevel (0x5001, UInt8 0...100)
        if let bat = snap.rawProperties[0x5001]?.uint8Value {
            batteryPercent = min(100, Int(bat))
        }

        if snap.isRecording != isRecording {
            isRecording = snap.isRecording
            updateRecordingTimer(active: isRecording)
        }
    }

    // MARK: - 相机遥控动作 (曝光调节 / 触控对焦 / 录制启停)

    public func setShutter(_ value: SonyShutterSpeed) {
        currentShutter = value
        guard let client = ptpClient else { return }
        Task {
            do { try await client.setShutterSpeed(value) }
            catch { showBanner("快门设置失败: \(error.localizedDescription)") }
        }
    }

    public func setAperture(_ value: SonyAperture) {
        currentAperture = value
        guard let client = ptpClient else { return }
        Task {
            do { try await client.setAperture(value) }
            catch { showBanner("光圈设置失败: \(error.localizedDescription)") }
        }
    }

    public func setISO(_ value: SonyISOValue) {
        currentISO = value
        guard let client = ptpClient else { return }
        Task {
            do { try await client.setISO(value) }
            catch { showBanner("ISO 设置失败: \(error.localizedDescription)") }
        }
    }

    public func setWhiteBalance(_ value: SonyWhiteBalance) {
        currentWhiteBalance = value
        guard let client = ptpClient else { return }
        Task {
            do { try await client.setWhiteBalance(value) }
            catch { showBanner("白平衡设置失败: \(error.localizedDescription)") }
        }
    }

    public func setColorTemperature(_ kelvin: UInt16) {
        currentColorTemp = kelvin
        currentWhiteBalance = .colorTempFilter
        guard let client = ptpClient else { return }
        Task {
            do { try await client.setColorTemperature(kelvin, ensureColorTempMode: true) }
            catch { showBanner("色温设置失败: \(error.localizedDescription)") }
        }
    }

    public func setExposureBias(_ bias: SonyExposureBias) {
        currentExposureBias = bias
        guard let client = ptpClient else { return }
        Task {
            do { try await client.setExposureBias(bias) }
            catch { showBanner("曝光补偿设置失败: \(error.localizedDescription)") }
        }
    }

    public func setLiveViewQuality(_ quality: SonyLiveViewImageQuality) {
        liveViewQuality = quality
        guard let client = ptpClient else { return }
        Task {
            do {
                try await client.setLiveViewImageQuality(quality)
                showBanner(quality == .high ? "LiveView 已切换高画质 (0xD26A=High)" : "LiveView 已切换流畅模式 (0xD26A=Low)")
            } catch {
                showBanner("画质切换失败: \(error.localizedDescription)")
            }
        }
    }

    public func toggleRecording() {
        let feedback = UIImpactFeedbackGenerator(style: .heavy)
        feedback.impactOccurred()

        guard let client = ptpClient else {
            // 离线演示/预览模式仍给出清晰提示
            showBanner("未连接相机 PTP 通道，无法控制录制")
            return
        }
        Task {
            do {
                if isRecording {
                    try await client.stopRecording()
                    isRecording = false
                } else {
                    try await client.startRecording()
                    isRecording = true
                }
                updateRecordingTimer(active: isRecording)
            } catch {
                showBanner("录制指令失败: \(error.localizedDescription)")
            }
        }
    }

    /// 响应画面单击：将精准反算出的归一化坐标 [0...1, 0...1] 发送给 SonyPTPIPClient
    public func handleTouchFocus(screenPoint: CGPoint, normalizedPoint: TouchFocusPoint) {
        let feedback = UIImpactFeedbackGenerator(style: .light)
        feedback.impactOccurred()

        focusReticle = FocusReticleState(
            screenPoint: screenPoint,
            normalizedPoint: normalizedPoint,
            isLocked: false
        )

        reticleDismissTask?.cancel()
        reticleDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            if !Task.isCancelled {
                self?.focusReticle?.isLocked = true
            }
            try? await Task.sleep(for: .milliseconds(1200))
            if !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.25)) {
                    self?.focusReticle = nil
                }
            }
        }

        guard let client = ptpClient else { return }
        Task {
            do {
                try await client.setTouchFocus(at: normalizedPoint, triggerHalfPressAF: true)
            } catch {
                showBanner("触控对焦失败: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - 3D LUT 多文件本地收藏夹与导入

    public func reloadSavedLUTsAndRestoreLast() {
        savedLUTs = LUTLibraryManager.listSavedLUTs()
        if let lastID = LUTLibraryManager.lastSelectedLUTID,
           let item = savedLUTs.first(where: { $0.id == lastID }),
           let renderer {
            do {
                try renderer.loadCubeLUT(from: item.fileURL, autoEnable: false)
                self.loadedLUTName = item.displayName
                self.activeSavedLUTID = item.id
            } catch {
                logger.warning("恢复上次 LUT 失败: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    public func importCubeLUT(result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            showBanner("LUT 选择失败: \(error.localizedDescription)")
        case .success(let urls):
            guard let url = urls.first, let renderer else { return }
            let didStartAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let saved = try LUTLibraryManager.importLUT(from: url)
                savedLUTs = LUTLibraryManager.listSavedLUTs()
                try renderer.loadCubeLUT(from: saved.fileURL, autoEnable: true)
                self.loadedLUTName = saved.displayName
                self.activeSavedLUTID = saved.id
                self.renderSettings.isLUTEnabled = true
                showBanner("已收藏并启用 LUT: \(saved.displayName)")
            } catch {
                showBanner(error.localizedDescription)
            }
        }
    }

    public func selectSavedLUT(_ item: SavedLUTItem) {
        guard let renderer else { return }
        do {
            try renderer.loadCubeLUT(from: item.fileURL, autoEnable: true)
            LUTLibraryManager.setLastSelectedLUTID(item.id)
            self.loadedLUTName = item.displayName
            self.activeSavedLUTID = item.id
            self.renderSettings.isLUTEnabled = true
            showBanner("已切换 LUT: \(item.displayName)")
        } catch {
            showBanner("LUT 加载失败: \(error.localizedDescription)")
        }
    }

    public func deleteSavedLUT(_ item: SavedLUTItem) {
        do {
            try LUTLibraryManager.deleteLUT(item)
            savedLUTs = LUTLibraryManager.listSavedLUTs()
            if activeSavedLUTID == item.id {
                activeSavedLUTID = nil
                loadedLUTName = nil
                renderer?.clearLUT()
                renderSettings.isLUTEnabled = false
            }
            showBanner("已移除 LUT: \(item.displayName)")
        } catch {
            showBanner("删除 LUT 失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 辅助逻辑

    private func updateRecordingTimer(active: Bool) {
        recordingTimerTask?.cancel()
        if active {
            recordingSeconds = 0
            recordingTimerTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    if !Task.isCancelled {
                        self?.recordingSeconds += 1
                    }
                }
            }
        } else {
            recordingSeconds = 0
        }
    }

    public var formattedRecordingTimecode: String {
        let hrs = recordingSeconds / 3600
        let mins = (recordingSeconds % 3600) / 60
        let secs = recordingSeconds % 60
        return String(format: "%02d:%02d:%02d", hrs, mins, secs)
    }

    public func showBanner(_ text: String) {
        statusBannerMessage = text
        bannerDismissTask?.cancel()
        bannerDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.8))
            if !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.25)) {
                    self?.statusBannerMessage = nil
                }
            }
        }
    }

    private static func loadOrCreatePersistedGUID() -> UUID {
        let key = "com.cineviewpro.ptpip.clientGUID"
        if let saved = UserDefaults.standard.string(forKey: key), let uuid = UUID(uuidString: saved) {
            return uuid
        }
        let created = UUID()
        UserDefaults.standard.set(created.uuidString, forKey: key)
        return created
    }
}

// MARK: - 5. MTKView SwiftUI 桥接封装

private struct MonitorMetalView: UIViewRepresentable {
    let renderer: MonitorRenderer?

    func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.backgroundColor = .black
        mtkView.isOpaque = true
        mtkView.contentMode = .scaleAspectFit
        renderer?.attach(to: mtkView, preferredFPS: 60)
        return mtkView
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        if uiView.delegate == nil, let renderer {
            renderer.attach(to: uiView, preferredFPS: 60)
        }
    }
}

// MARK: - 6. 主界面 ContentView (Monitor+ 极简专业横屏监视器)

public struct ContentView: View {
    @State private var vm = MonitorViewModel()

    // 视频缩放与拖动状态
    @State private var zoomScale: CGFloat = 1.0
    @State private var gestureZoomScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var gesturePanOffset: CGSize = .zero

    // 可拖动示波器浮窗偏移
    @State private var scopesDragOffset: CGSize = .zero
    @State private var scopesGestureOffset: CGSize = .zero

    public init() {}

    private var effectiveZoom: CGFloat {
        min(max(zoomScale * gestureZoomScale, 1.0), 4.0)
    }

    private var effectivePan: CGSize {
        CGSize(
            width: panOffset.width + gesturePanOffset.width,
            height: panOffset.height + gesturePanOffset.height
        )
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                // ---------------------------------------------------------
                // LAYER 0: 全屏 60fps MTKView 视频画面 + 安全框 + 缩放/拖动/触控对焦手势
                // ---------------------------------------------------------
                videoCanvasLayer(containerSize: geo.size)

                // 假色 12 段 IRE 色标尺（仅开启假色时显示在最左侧，不遮挡构图）
                if vm.renderSettings.isFalseColorEnabled && !vm.isHUDHidden {
                    HStack {
                        FalseColorLegendBar()
                            .padding(.leading, 14)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }

                // 触控对焦角标框动画
                if let reticle = vm.focusReticle {
                    FocusReticleView(isLocked: reticle.isLocked)
                        .position(reticle.screenPoint)
                        .allowsHitTesting(false)
                }

                // ---------------------------------------------------------
                // LAYER 1: 可拖动实时波形图 / RGB 直方图浮窗
                // ---------------------------------------------------------
                if vm.isScopesVisible && !vm.isHUDHidden {
                    VStack {
                        Spacer()
                        HStack {
                            ScopesFloatingWidget(
                                scope: vm.latestScope,
                                mode: $vm.scopeDisplayMode,
                                applyLUT: Binding(
                                    get: { vm.renderSettings.scopesApplyLUT },
                                    set: { vm.renderSettings.scopesApplyLUT = $0 }
                                ),
                                onClose: { withAnimation(.snappy) { vm.isScopesVisible = false } }
                            )
                            .offset(
                                x: scopesDragOffset.width + scopesGestureOffset.width,
                                y: scopesDragOffset.height + scopesGestureOffset.height
                            )
                            .gesture(
                                DragGesture()
                                    .onChanged { value in
                                        scopesGestureOffset = value.translation
                                    }
                                    .onEnded { value in
                                        scopesDragOffset.width += value.translation.width
                                        scopesDragOffset.height += value.translation.height
                                        scopesGestureOffset = .zero
                                    }
                            )
                            Spacer()
                        }
                        .padding(.leading, 16)
                        .padding(.bottom, vm.activeExposureControl != nil || vm.activeToolInspector != nil ? 104 : 20)
                    }
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
                }

                // ---------------------------------------------------------
                // LAYER 2: 顶部悬浮状态栏 + 右侧专业工具栏 + 底部快捷滚轮/子菜单
                // ---------------------------------------------------------
                if !vm.isHUDHidden {
                    VStack(spacing: 0) {
                        topStatusBar
                            .padding(.horizontal, 16)
                            .padding(.top, 10)

                        // 状态提示吐司
                        if let msg = vm.statusBannerMessage {
                            Text(msg)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(.black.opacity(0.75), in: Capsule())
                                .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 0.5))
                                .padding(.top, 6)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        Spacer()

                        // 底部弹出区：曝光快捷滚轮 或 辅助工具细调面板
                        bottomContextualDrawer
                            .padding(.bottom, 12)
                    }

                    // 右侧悬浮垂直工具栏
                    HStack {
                        Spacer()
                        rightFloatingToolbar
                            .padding(.trailing, 14)
                    }
                }

                // 缩放倍率微标（放大巡检细节时显示，点击一键复位 1.0x）
                if effectiveZoom > 1.02 {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Button {
                                resetZoomAndPan()
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "viewfinder")
                                    Text(String(format: "%.1fx 复位", effectiveZoom))
                                }
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.yellow, in: Capsule())
                            }
                            .padding(.trailing, 74)
                            .padding(.bottom, 16)
                        }
                    }
                    .transition(.opacity)
                }

                // 无画面待机提示
                if !vm.isCameraConnected && !vm.isUVCActive && !vm.isTestPatternActive && !vm.isHUDHidden {
                    standbyOverlay
                }
            }
            .contentShape(Rectangle())
        }
        // 隐藏系统状态栏与底部 Home 指示条，真正做到全屏无干扰监看
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onAppear {
            enforceLandscapeOrientation()
            UIApplication.shared.isIdleTimerDisabled = true // 监看时保持屏幕常亮
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            Task { await vm.disconnectAll() }
        }
        // 标准 .cube 3D LUT 文件导入器
        .fileImporter(
            isPresented: $vm.isLUTImporterPresented,
            allowedContentTypes: [
                UTType(filenameExtension: "cube") ?? .data,
                .data
            ],
            allowsMultipleSelection: false
        ) { result in
            vm.importCubeLUT(result: result)
        }
        // 连接模式设置弹窗
        .sheet(isPresented: $vm.isConnectionSheetPresented) {
            ConnectionSettingsSheet(vm: vm)
                .presentationDetents([.medium])
                .preferredColorScheme(.dark)
        }
    }

    // MARK: - LAYER 0: 全屏视频画布与手势系统

    private func videoCanvasLayer(containerSize: CGSize) -> some View {
        let videoRect = computeActiveVideoRect(in: containerSize)

        return ZStack {
            MonitorMetalView(renderer: vm.renderer)
                .frame(width: containerSize.width, height: containerSize.height)

            // 构图安全框参考线 + 三分九宫格（精准贴合当前有效视频区域）
            if vm.frameGuide.aspectRatio != nil || vm.isGridEnabled {
                FrameGuideOverlay(
                    videoRect: videoRect,
                    guideAspect: vm.frameGuide.aspectRatio,
                    showRuleOfThirds: vm.isGridEnabled,
                    label: vm.frameGuide.rawValue
                )
                .allowsHitTesting(false)
            }
        }
        .scaleEffect(effectiveZoom, anchor: .center)
        .offset(effectivePan)
        .frame(width: containerSize.width, height: containerSize.height)
        .clipped()
        .contentShape(Rectangle())
        // 1. 双击复位缩放
        .highPriorityGesture(
            TapGesture(count: 2)
                .onEnded {
                    if effectiveZoom > 1.02 {
                        resetZoomAndPan()
                    } else {
                        withAnimation(.snappy(duration: 0.25)) {
                            zoomScale = 2.0
                        }
                    }
                }
        )
        // 2. 单击画面精准触控对焦（将屏幕点击坐标反算为未缩放视频画幅内的归一化 [0...1, 0...1]）
        .simultaneousGesture(
            SpatialTapGesture(count: 1)
                .onEnded { value in
                    // 若当前正打开底部调节抽屉，单击画面优先收起抽屉避免误触对焦
                    if vm.activeExposureControl != nil || vm.activeToolInspector != nil {
                        withAnimation(.snappy(duration: 0.2)) {
                            vm.activeExposureControl = nil
                            vm.activeToolInspector = nil
                        }
                        return
                    }

                    if let normalized = mapTapToNormalizedFocusPoint(
                        tapLocation: value.location,
                        containerSize: containerSize,
                        videoRect: videoRect
                    ) {
                        vm.handleTouchFocus(screenPoint: value.location, normalizedPoint: normalized)
                    }
                }
        )
        // 3. 双指捏合缩放 (1.0x ... 4.0x)
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    gestureZoomScale = value.magnification
                }
                .onEnded { value in
                    let finalScale = min(max(zoomScale * value.magnification, 1.0), 4.0)
                    zoomScale = finalScale
                    gestureZoomScale = 1.0
                    if finalScale <= 1.01 {
                        resetZoomAndPan()
                    } else {
                        panOffset = clampedPanOffset(panOffset, scale: finalScale, containerSize: containerSize)
                    }
                }
        )
        // 4. 放大状态下支持单指拖动巡检焦点与细节
        .simultaneousGesture(
            DragGesture(minimumDistance: 6)
                .onChanged { value in
                    guard effectiveZoom > 1.02 else { return }
                    gesturePanOffset = value.translation
                }
                .onEnded { value in
                    guard effectiveZoom > 1.02 else { return }
                    let proposed = CGSize(
                        width: panOffset.width + value.translation.width,
                        height: panOffset.height + value.translation.height
                    )
                    panOffset = clampedPanOffset(proposed, scale: zoomScale, containerSize: containerSize)
                    gesturePanOffset = .zero
                }
        )
    }

    /// 计算与 `MonitorShaders.metal` 完全一致的有效视频矩形 (含变形镜头反挤压倍率)
    private func computeActiveVideoRect(in containerSize: CGSize) -> CGRect {
        let src = vm.renderer?.currentSourceSize ?? CGSize(width: 1920, height: 1080)
        let srcW = max(src.width, 1)
        let srcH = max(src.height, 1)
        let effectiveAspect = (srcW / srcH) * CGFloat(max(vm.renderSettings.desqueeze.rawValue, 1.0))
        let viewportAspect = containerSize.width / max(containerSize.height, 1)

        if viewportAspect > effectiveAspect {
            // Pillarbox: 左右黑边
            let videoH = containerSize.height
            let videoW = videoH * effectiveAspect
            return CGRect(
                x: (containerSize.width - videoW) * 0.5,
                y: 0,
                width: videoW,
                height: videoH
            )
        } else {
            // Letterbox: 上下黑边
            let videoW = containerSize.width
            let videoH = videoW / effectiveAspect
            return CGRect(
                x: 0,
                y: (containerSize.height - videoH) * 0.5,
                width: videoW,
                height: videoH
            )
        }
    }

    /// 将屏幕触摸点反算回 Sony 画面归一化坐标 [0...1, 0...1]
    private func mapTapToNormalizedFocusPoint(
        tapLocation: CGPoint,
        containerSize: CGSize,
        videoRect: CGRect
    ) -> TouchFocusPoint? {
        let cx = containerSize.width * 0.5
        let cy = containerSize.height * 0.5
        let scale = max(effectiveZoom, 1.0)
        let pan = effectivePan

        // 反向撤销 scaleEffect + offset
        let unzoomedX = (tapLocation.x - cx - pan.width) / scale + cx
        let unzoomedY = (tapLocation.y - cy - pan.height) / scale + cy
        let unzoomedPt = CGPoint(x: unzoomedX, y: unzoomedY)

        guard videoRect.contains(unzoomedPt), videoRect.width > 0, videoRect.height > 0 else {
            return nil
        }

        var normX = (unzoomedPt.x - videoRect.minX) / videoRect.width
        var normY = (unzoomedPt.y - videoRect.minY) / videoRect.height
        // 画面处于水平镜像 / 垂直翻转时，自动同步反向映射触控对焦坐标，确保指哪打哪
        if vm.renderSettings.flipHorizontal {
            normX = 1.0 - normX
        }
        if vm.renderSettings.flipVertical {
            normY = 1.0 - normY
        }
        return TouchFocusPoint(x: Double(normX), y: Double(normY))
    }

    private func clampedPanOffset(_ offset: CGSize, scale: CGFloat, containerSize: CGSize) -> CGSize {
        let maxX = max(0, (containerSize.width * (scale - 1.0)) * 0.5)
        let maxY = max(0, (containerSize.height * (scale - 1.0)) * 0.5)
        return CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
    }

    private func resetZoomAndPan() {
        withAnimation(.snappy(duration: 0.25)) {
            zoomScale = 1.0
            gestureZoomScale = 1.0
            panOffset = .zero
            gesturePanOffset = .zero
        }
    }

    // MARK: - LAYER 2A: 顶部悬浮状态栏 (Monitor+ 极简风格)

    private var topStatusBar: some View {
        HStack(spacing: 12) {
            // 左侧：连接模式 + 实时延迟胶囊
            Button {
                vm.isConnectionSheetPresented = true
            } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(connectionStatusColor)
                        .frame(width: 7, height: 7)
                    Image(systemName: vm.connectionMode.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                    Text(vm.isTestPatternActive ? "测试信号" : vm.connectionMode.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                    Divider()
                        .frame(height: 11)
                        .background(.white.opacity(0.25))
                    if !vm.currentResolutionLabel.isEmpty {
                        Text(vm.currentFrameKB > 0 ? "\(vm.currentResolutionLabel) · \(vm.currentFrameKB)KB" : vm.currentResolutionLabel)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.75))
                        Divider()
                            .frame(height: 11)
                            .background(.white.opacity(0.25))
                    }
                    if vm.currentFPS > 0 {
                        Text("\(vm.currentFPS) fps")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.cyan)
                        Divider()
                            .frame(height: 11)
                            .background(.white.opacity(0.25))
                    }
                    Text(vm.signalLatencyMs > 0 ? "\(vm.signalLatencyMs) ms" : "-- ms")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(vm.signalLatencyMs > 80 ? .orange : .green)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial.opacity(0.85), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 0.5))
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            // 中间：实时曝光参数胶囊 (快门 | 光圈 | ISO | 曝光补偿 | 白平衡/色温)
            HStack(spacing: 2) {
                exposurePillCell(
                    label: "SS",
                    value: vm.currentShutter.description,
                    control: .shutter
                )
                pillDivider
                exposurePillCell(
                    label: "F",
                    value: vm.currentAperture.description.replacingOccurrences(of: "F", with: ""),
                    control: .aperture
                )
                pillDivider
                exposurePillCell(
                    label: "ISO",
                    value: vm.currentISO.description.replacingOccurrences(of: "ISO ", with: ""),
                    control: .iso
                )
                pillDivider
                exposurePillCell(
                    label: "EV",
                    value: vm.currentExposureBias.description,
                    control: .exposureBias
                )
                pillDivider
                exposurePillCell(
                    label: "WB",
                    value: vm.currentWhiteBalance == .colorTempFilter ? "\(vm.currentColorTemp)K" : vm.currentWhiteBalance.description,
                    control: .whiteBalance
                )
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.72), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 0.6))

            Spacer(minLength: 8)

            // 右侧：机身电量 + 录制红点状态 + 快捷录制按钮
            HStack(spacing: 10) {
                // 机身电量
                HStack(spacing: 4) {
                    Image(systemName: batteryIconName)
                        .font(.system(size: 12))
                        .foregroundStyle(vm.batteryPercent <= 20 ? .red : .white.opacity(0.9))
                    Text("\(vm.batteryPercent)%")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                }

                Divider()
                    .frame(height: 12)
                    .background(.white.opacity(0.25))

                // 录制状态红点 + 时间码 / 录制触发按钮
                Button {
                    vm.toggleRecording()
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(vm.isRecording ? Color.red : Color.red.opacity(0.45))
                            .frame(width: 9, height: 9)
                            .shadow(color: vm.isRecording ? .red.opacity(0.9) : .clear, radius: 4)
                        Text(vm.isRecording ? vm.formattedRecordingTimecode : "STBY")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(vm.isRecording ? .red : .white.opacity(0.85))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(vm.isRecording ? Color.red.opacity(0.18) : Color.white.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial.opacity(0.85), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 0.5))
        }
    }

    private var connectionStatusColor: Color {
        if vm.isConnecting { return .yellow }
        if vm.isCameraConnected || vm.isUVCActive { return .green }
        if vm.isTestPatternActive { return .cyan }
        return .gray
    }

    private var batteryIconName: String {
        switch vm.batteryPercent {
        case 80...100: return "battery.100"
        case 55..<80:  return "battery.75"
        case 30..<55:  return "battery.50"
        case 11..<30:  return "battery.25"
        default:       return "battery.0"
        }
    }

    private var pillDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.16))
            .frame(width: 0.5, height: 16)
    }

    private func exposurePillCell(label: String, value: String, control: ActiveExposureControl) -> some View {
        let isSelected = vm.activeExposureControl == control
        return Button {
            withAnimation(.snappy(duration: 0.2)) {
                vm.activeToolInspector = nil
                vm.activeExposureControl = isSelected ? nil : control
            }
        } label: {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(isSelected ? .black.opacity(0.75) : .white.opacity(0.5))
                Text(value)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isSelected ? .black : .white)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(isSelected ? Color.yellow : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - LAYER 2B: 右侧悬浮专业工具栏

    private var rightFloatingToolbar: some View {
        VStack(spacing: 5) {
            // 1. 3D LUT 开关 / 本地收藏夹
            toolButton(
                title: "LUT",
                icon: "cube.transparent",
                isActive: vm.renderSettings.isLUTEnabled,
                action: {
                    if vm.loadedLUTName == nil {
                        toggleInspector(.lut)
                    } else {
                        vm.renderSettings.isLUTEnabled.toggle()
                    }
                },
                onLongPress: { toggleInspector(.lut) }
            )

            // 2. 专业示波器浮窗 (波形 / RGB分量 / 矢量 / 直方图)
            toolButton(
                title: "示波器",
                icon: "waveform.path.ecg",
                isActive: vm.isScopesVisible,
                action: {
                    withAnimation(.snappy(duration: 0.2)) {
                        vm.isScopesVisible.toggle()
                        vm.renderSettings.isScopesEnabled = vm.isScopesVisible
                    }
                }
            )

            // 3. 12 段假色
            toolButton(
                title: "假色",
                icon: "paintpalette",
                isActive: vm.renderSettings.isFalseColorEnabled,
                action: {
                    vm.renderSettings.isFalseColorEnabled.toggle()
                }
            )

            // 4. Sobel 峰值对焦
            toolButton(
                title: "峰值",
                icon: "camera.metering.center.weighted",
                isActive: vm.renderSettings.isPeakingEnabled,
                action: {
                    vm.renderSettings.isPeakingEnabled.toggle()
                },
                onLongPress: { toggleInspector(.peaking) }
            )

            // 5. 动态斑马纹
            toolButton(
                title: "斑马",
                icon: "line.3.horizontal.decrease",
                isActive: vm.renderSettings.isZebraEnabled,
                action: {
                    vm.renderSettings.isZebraEnabled.toggle()
                },
                onLongPress: { toggleInspector(.zebra) }
            )

            // 6. 安全框比例 & 三分九宫格
            toolButton(
                title: vm.frameGuide == .off ? (vm.isGridEnabled ? "三分线" : "安全框") : vm.frameGuide.rawValue,
                icon: "viewfinder.rectangular",
                isActive: vm.frameGuide != .off || vm.isGridEnabled,
                action: {
                    vm.frameGuide = vm.frameGuide.next
                },
                onLongPress: { toggleInspector(.guides) }
            )

            // 7. 画面水平镜像 / 垂直翻转 (单击切换水平镜像，长按展开 H/V 面板)
            toolButton(
                title: flipButtonTitle,
                icon: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                isActive: vm.renderSettings.flipHorizontal || vm.renderSettings.flipVertical,
                action: {
                    vm.renderSettings.flipHorizontal.toggle()
                },
                onLongPress: { toggleInspector(.flip) }
            )

            // 8. 变形镜头反挤压 (1.0x / 1.33x / 1.5x / 2.0x)
            toolButton(
                title: vm.renderSettings.desqueeze.displayName,
                icon: "arrow.left.and.right.square",
                isActive: vm.renderSettings.desqueeze != .off,
                action: {
                    let all = AnamorphicDesqueeze.allCases
                    if let idx = all.firstIndex(of: vm.renderSettings.desqueeze) {
                        vm.renderSettings.desqueeze = all[(idx + 1) % all.count]
                    }
                }
            )
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 5)
        .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 0.6)
        )
    }

    private var flipButtonTitle: String {
        switch (vm.renderSettings.flipHorizontal, vm.renderSettings.flipVertical) {
        case (true, true):  return "H+V"
        case (true, false): return "镜像H"
        case (false, true): return "翻转V"
        case (false, false): return "翻转"
        }
    }

    private func toolButton(
        title: String,
        icon: String,
        isActive: Bool,
        action: @escaping () -> Void,
        onLongPress: (() -> Void)? = nil
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(isActive ? .black : .white.opacity(0.88))
            .frame(width: 42, height: 32)
            .background(isActive ? Color.yellow : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.35)
                .onEnded { _ in
                    onLongPress?()
                }
        )
    }

    private func toggleInspector(_ kind: MonitorViewModel.ToolInspectorKind) {
        let feedback = UIImpactFeedbackGenerator(style: .medium)
        feedback.impactOccurred()
        withAnimation(.snappy(duration: 0.2)) {
            vm.activeExposureControl = nil
            vm.activeToolInspector = (vm.activeToolInspector == kind) ? nil : kind
        }
    }

    // MARK: - LAYER 2C: 底部弹出快捷滚轮与工具细调面板

    @ViewBuilder
    private var bottomContextualDrawer: some View {
        if let control = vm.activeExposureControl {
            exposureWheelDrawer(for: control)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let inspector = vm.activeToolInspector {
            toolInspectorDrawer(for: inspector)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func exposureWheelDrawer(for control: ActiveExposureControl) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text(control.title)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.yellow)
                Spacer()
                Button {
                    withAnimation(.snappy(duration: 0.2)) { vm.activeExposureControl = nil }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    switch control {
                    case .shutter:
                        if vm.isCameraConnected && (!vm.isShutterWritable || vm.shutterPresets.isEmpty) {
                            Text("当前拍摄模式不支持手动调节快门（请切至 S / M 模式）")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.65))
                                .padding(.vertical, 6)
                        } else {
                            ForEach(vm.shutterPresets, id: \.self) { preset in
                                wheelChip(
                                    title: preset.description,
                                    isSelected: vm.currentShutter == preset
                                ) {
                                    vm.setShutter(preset)
                                }
                            }
                        }

                    case .aperture:
                        if vm.isCameraConnected && (!vm.isApertureWritable || vm.aperturePresets.isEmpty) {
                            Text("当前镜头或拍摄模式不支持电控光圈（请检查光圈环置于 A 档或切至 A/M 模式）")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.65))
                                .padding(.vertical, 6)
                        } else {
                            ForEach(vm.aperturePresets, id: \.self) { preset in
                                wheelChip(
                                    title: preset.description,
                                    isSelected: vm.currentAperture == preset
                                ) {
                                    vm.setAperture(preset)
                                }
                            }
                        }

                    case .iso:
                        if vm.isCameraConnected && (!vm.isISOWritable || vm.isoPresets.isEmpty) {
                            Text("当前拍摄模式或机身设置不支持手动调节 ISO")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.65))
                                .padding(.vertical, 6)
                        } else {
                            ForEach(vm.isoPresets, id: \.self) { preset in
                                wheelChip(
                                    title: preset.description.replacingOccurrences(of: "ISO ", with: ""),
                                    isSelected: vm.currentISO == preset
                                ) {
                                    vm.setISO(preset)
                                }
                            }
                        }

                    case .exposureBias:
                        ForEach(vm.exposureBiasPresets, id: \.self) { preset in
                            wheelChip(
                                title: preset.description,
                                isSelected: vm.currentExposureBias == preset
                            ) {
                                vm.setExposureBias(preset)
                            }
                        }

                    case .whiteBalance:
                        ForEach(vm.whiteBalancePresets, id: \.self) { preset in
                            wheelChip(
                                title: preset.description,
                                isSelected: vm.currentWhiteBalance == preset
                            ) {
                                vm.setWhiteBalance(preset)
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
            }

            // 当选中白平衡时，下方附加 2500K–9900K 精准色温滚轮 (0xD20F)
            if control == .whiteBalance {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("K")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.cyan)
                        ForEach(vm.colorTempPresets, id: \.self) { kelvin in
                            let selected = vm.currentWhiteBalance == .colorTempFilter && vm.currentColorTemp == kelvin
                            Button("\(kelvin)K") {
                                let haptic = UISelectionFeedbackGenerator()
                                haptic.selectionChanged()
                                vm.setColorTemperature(kelvin)
                            }
                            .font(.system(size: 11, weight: selected ? .bold : .medium, design: .monospaced))
                            .foregroundStyle(selected ? .black : .cyan)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(selected ? Color.cyan : Color.cyan.opacity(0.14), in: Capsule())
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                }
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: 520)
        .background(.black.opacity(0.84), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 0.6)
        )
    }

    private func wheelChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            let haptic = UISelectionFeedbackGenerator()
            haptic.selectionChanged()
            action()
        } label: {
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .bold : .medium, design: .monospaced))
                    .foregroundStyle(isSelected ? .black : .white.opacity(0.9))
                Rectangle()
                    .fill(isSelected ? Color.black.opacity(0.6) : Color.white.opacity(0.25))
                    .frame(width: 2, height: isSelected ? 8 : 5)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.yellow : Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// 长按工具栏按钮呼出的专业参数细调条（LUT 导入与强度、峰值颜色与灵敏度、斑马纹 IRE 阈值、安全框选择）
    private func toolInspectorDrawer(for inspector: MonitorViewModel.ToolInspectorKind) -> some View {
        HStack(spacing: 14) {
            switch inspector {
            case .lut:
                Button {
                    vm.isLUTImporterPresented = true
                } label: {
                    Label("导入", systemImage: "folder.badge.plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.yellow, in: Capsule())
                }
                .buttonStyle(.plain)

                // 本地持久化多 .cube LUT 收藏夹横向切换条
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Button("演示 LUT") {
                            vm.activeSavedLUTID = nil
                            vm.loadBuiltInDemoLUT()
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(vm.activeSavedLUTID == nil && vm.renderSettings.isLUTEnabled ? .black : .white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            vm.activeSavedLUTID == nil && vm.renderSettings.isLUTEnabled ? Color.yellow : Color.white.opacity(0.14),
                            in: Capsule()
                        )
                        .buttonStyle(.plain)

                        ForEach(vm.savedLUTs) { item in
                            let isCurrent = vm.activeSavedLUTID == item.id && vm.renderSettings.isLUTEnabled
                            HStack(spacing: 4) {
                                Button(item.displayName) {
                                    vm.selectSavedLUT(item)
                                }
                                .font(.system(size: 11, weight: isCurrent ? .bold : .medium, design: .monospaced))
                                .foregroundStyle(isCurrent ? .black : .white)
                                .lineLimit(1)
                                .buttonStyle(.plain)

                                Button {
                                    vm.deleteSavedLUT(item)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(isCurrent ? .black.opacity(0.7) : .white.opacity(0.55))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(isCurrent ? Color.yellow : Color.white.opacity(0.14), in: Capsule())
                        }
                    }
                }
                .frame(maxWidth: 260)

                HStack(spacing: 6) {
                    Text("\(Int(vm.renderSettings.lutIntensity * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                    Slider(value: $vm.renderSettings.lutIntensity, in: 0...1)
                        .tint(.yellow)
                        .frame(width: 90)
                }

            case .peaking:
                Text("峰值颜色")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                ForEach(FocusPeakingColor.allCases) { color in
                    Button(color.displayName) {
                        vm.renderSettings.peakingColor = color
                        vm.renderSettings.isPeakingEnabled = true
                    }
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(vm.renderSettings.peakingColor == color ? .black : .white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        vm.renderSettings.peakingColor == color ? Color.yellow : Color.white.opacity(0.14),
                        in: Capsule()
                    )
                    .buttonStyle(.plain)
                }
                HStack(spacing: 6) {
                    Text("灵敏度 \(Int(vm.renderSettings.peakingSensitivity * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                    Slider(value: $vm.renderSettings.peakingSensitivity, in: 0...1)
                        .tint(.yellow)
                        .frame(width: 110)
                }

            case .zebra:
                Text("斑马纹阈值")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                ForEach([Float(70), 80, 90, 95, 100], id: \.self) { ire in
                    Button("\(Int(ire)) IRE") {
                        vm.renderSettings.zebraThresholdIRE = ire
                        vm.renderSettings.isZebraEnabled = true
                    }
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(vm.renderSettings.zebraThresholdIRE == ire ? .black : .white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        vm.renderSettings.zebraThresholdIRE == ire ? Color.yellow : Color.white.opacity(0.14),
                        in: Capsule()
                    )
                    .buttonStyle(.plain)
                }

            case .guides:
                Button {
                    vm.isGridEnabled.toggle()
                } label: {
                    Label("三分线", systemImage: "grid")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(vm.isGridEnabled ? .black : .white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(vm.isGridEnabled ? Color.cyan : Color.white.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(FrameGuideAspect.allCases) { guide in
                            Button(guide.rawValue) {
                                vm.frameGuide = guide
                            }
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(vm.frameGuide == guide ? .black : .white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                vm.frameGuide == guide ? Color.yellow : Color.white.opacity(0.14),
                                in: Capsule()
                            )
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: 340)

            case .flip:
                Text("画面翻转")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))

                Button("水平镜像 H") {
                    vm.renderSettings.flipHorizontal.toggle()
                }
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(vm.renderSettings.flipHorizontal ? .black : .white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(vm.renderSettings.flipHorizontal ? Color.yellow : Color.white.opacity(0.14), in: Capsule())
                .buttonStyle(.plain)

                Button("垂直翻转 V") {
                    vm.renderSettings.flipVertical.toggle()
                }
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(vm.renderSettings.flipVertical ? .black : .white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(vm.renderSettings.flipVertical ? Color.yellow : Color.white.opacity(0.14), in: Capsule())
                .buttonStyle(.plain)

                if vm.renderSettings.flipHorizontal || vm.renderSettings.flipVertical {
                    Button("复位") {
                        vm.renderSettings.flipHorizontal = false
                        vm.renderSettings.flipVertical = false
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.14), in: Capsule())
                    .buttonStyle(.plain)
                }
            }

            Button {
                withAnimation(.snappy(duration: 0.2)) { vm.activeToolInspector = nil }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.black.opacity(0.84), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 0.6))
    }

    // MARK: - 无信号待机引导浮层

    private var standbyOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.white.opacity(0.45))
            Text("CineView Pro · Sony A6700")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
            Text("未检测到视频输入，请连接 UVC 采集卡或 Sony 5GHz Wi-Fi / USB-LAN")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
            HStack(spacing: 12) {
                Button {
                    Task { await vm.startTestPattern() }
                } label: {
                    Label("启动测试信号 (仿真)", systemImage: "tv.and.mediabox")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.yellow, in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    vm.isConnectionSheetPresented = true
                } label: {
                    Label("连接真机相机", systemImage: "bolt.horizontal.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
        .padding(22)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 0.6)
        )
    }

    // MARK: - 强制请求横屏几何方向 (iOS 16+)

    private func enforceLandscapeOrientation() {
        for scene in UIApplication.shared.connectedScenes {
            if let windowScene = scene as? UIWindowScene {
                windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { _ in }
            }
        }
    }
}

// MARK: - 7. 专业辅助叠加组件 (安全框 / 对焦框 / 假色标尺 / 实时示波器浮窗 / 连接弹窗)

/// 安全框与三分构图九宫格叠加层 (2.39:1 / 2.35:1 / 16:9 / 4:3 / 1:1 / 9:16 + 三分线)
private struct FrameGuideOverlay: View {
    let videoRect: CGRect
    let guideAspect: CGFloat?
    let showRuleOfThirds: Bool
    let label: String

    var body: some View {
        Canvas { context, _ in
            guard videoRect.width > 1, videoRect.height > 1 else { return }

            let targetRect: CGRect
            if let guideAspect {
                let currentAspect = videoRect.width / videoRect.height
                if currentAspect > guideAspect {
                    let w = videoRect.height * guideAspect
                    targetRect = CGRect(
                        x: videoRect.midX - w * 0.5,
                        y: videoRect.minY,
                        width: w,
                        height: videoRect.height
                    )
                } else {
                    let h = videoRect.width / guideAspect
                    targetRect = CGRect(
                        x: videoRect.minX,
                        y: videoRect.midY - h * 0.5,
                        width: videoRect.width,
                        height: h
                    )
                }

                // 1. 裁切外区半透明暗幕 (55% 遮罩，保留周围视野构图)
                var mattePath = Path(videoRect)
                mattePath.addRect(targetRect)
                context.fill(mattePath, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))

                // 2. 精细安全框边界线
                context.stroke(Path(targetRect), with: .color(.white.opacity(0.85)), lineWidth: 1.0)

                // 3. 90% 动作安全区虚线框
                let safeRect = targetRect.insetBy(dx: targetRect.width * 0.05, dy: targetRect.height * 0.05)
                context.stroke(
                    Path(safeRect),
                    with: .color(.white.opacity(0.32)),
                    style: StrokeStyle(lineWidth: 0.6, dash: [4, 4])
                )
            } else {
                targetRect = videoRect
            }

            // 4. 三分构图九宫格 (Rule of Thirds)
            if showRuleOfThirds {
                var grid = Path()
                for i in 1...2 {
                    let x = targetRect.minX + targetRect.width * (CGFloat(i) / 3.0)
                    let y = targetRect.minY + targetRect.height * (CGFloat(i) / 3.0)
                    grid.move(to: CGPoint(x: x, y: targetRect.minY))
                    grid.addLine(to: CGPoint(x: x, y: targetRect.maxY))
                    grid.move(to: CGPoint(x: targetRect.minX, y: y))
                    grid.addLine(to: CGPoint(x: targetRect.maxX, y: y))
                }
                context.stroke(grid, with: .color(.white.opacity(0.45)), lineWidth: 0.7)
            }

            // 5. 中心十字准星
            var cross = Path()
            cross.move(to: CGPoint(x: targetRect.midX - 8, y: targetRect.midY))
            cross.addLine(to: CGPoint(x: targetRect.midX + 8, y: targetRect.midY))
            cross.move(to: CGPoint(x: targetRect.midX, y: targetRect.midY - 8))
            cross.addLine(to: CGPoint(x: targetRect.midX, y: targetRect.midY + 8))
            context.stroke(cross, with: .color(.white.opacity(0.5)), lineWidth: 0.8)
        }
    }
}

/// 触控对焦电影机风格角标框
private struct FocusReticleView: View {
    let isLocked: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .stroke(isLocked ? Color.green : Color.yellow, lineWidth: 1.8)
                .frame(width: isLocked ? 52 : 64, height: isLocked ? 52 : 64)
            Circle()
                .fill(isLocked ? Color.green : Color.yellow)
                .frame(width: 4, height: 4)
        }
        .shadow(color: .black.opacity(0.8), radius: 2)
        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isLocked)
    }
}

/// 12 段假色 IRE 色标图例条
private struct FalseColorLegendBar: View {
    var body: some View {
        VStack(spacing: 1) {
            ForEach(FalseColorBand.standard12Bands.reversed()) { band in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(red: Double(band.rgb.x), green: Double(band.rgb.y), blue: Double(band.rgb.z)))
                        .frame(width: 10, height: 14)
                    Text("\(Int(band.rangeIRE.upperBound))")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 20, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 5)
        .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.15), lineWidth: 0.5)
        )
    }
}

/// 可拖动实时波形图 (Waveform) & RGB 直方图浮窗 (由 MonitorShaders.metal Compute Shader 驱动)
private struct ScopesFloatingWidget: View {
    let scope: ScopeAnalysisResult?
    @Binding var mode: ScopeDisplayMode
    @Binding var applyLUT: Bool
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            // 顶部小标题栏
            HStack(spacing: 8) {
                ForEach(ScopeDisplayMode.allCases, id: \.self) { m in
                    Button(m.rawValue) {
                        mode = m
                    }
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(mode == m ? .black : .white.opacity(0.7))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(mode == m ? Color.yellow : Color.white.opacity(0.1), in: Capsule())
                    .buttonStyle(.plain)
                }

                Button(applyLUT ? "Post-LUT" : "Log") {
                    applyLUT.toggle()
                }
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(.cyan)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.cyan.opacity(0.15), in: Capsule())
                .buttonStyle(.plain)

                Spacer(minLength: 4)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }

            // 示波器 Canvas 绘制区：支持 亮度波形 / RGB 分量波形 (Parade) / 矢量示波器 (Vectorscope) / RGB 直方图 / 双显
            HStack(spacing: 8) {
                switch mode {
                case .waveform:
                    waveformCanvas
                        .frame(width: 240, height: 100)
                case .parade:
                    paradeCanvas
                        .frame(width: 252, height: 100)
                case .vectorscope:
                    vectorscopeCanvas
                        .frame(width: 118, height: 118)
                case .histogram:
                    histogramCanvas
                        .frame(width: 220, height: 100)
                case .dual:
                    waveformCanvas
                        .frame(width: 168, height: 106)
                    vectorscopeCanvas
                        .frame(width: 106, height: 106)
                }
            }
        }
        .padding(8)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 0.6)
        )
    }

    private var paradeCanvas: some View {
        Canvas { context, size in
            // 0 / 25 / 50 / 75 / 100 IRE 参考线 + 3 分区竖线
            for ire in [0.0, 0.25, 0.5, 0.75, 1.0] {
                let y = size.height * (1.0 - ire)
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(.white.opacity(0.14)), lineWidth: 0.5)
            }
            let thirdW = size.width / 3.0
            for idx in 1...2 {
                var sep = Path()
                sep.move(to: CGPoint(x: thirdW * CGFloat(idx), y: 0))
                sep.addLine(to: CGPoint(x: thirdW * CGFloat(idx), y: size.height))
                context.stroke(sep, with: .color(.white.opacity(0.22)), lineWidth: 0.6)
            }

            guard let scope, scope.paradeSize > 0 else { return }
            let s = scope.paradeSize
            let cellW = thirdW / CGFloat(s)
            let cellH = size.height / CGFloat(s)

            let channels: [([Float], Color, CGFloat)] = [
                (scope.redParade,   Color(red: 1.0, green: 0.22, blue: 0.22), 0),
                (scope.greenParade, Color(red: 0.20, green: 0.96, blue: 0.36), thirdW),
                (scope.blueParade,  Color(red: 0.26, green: 0.58, blue: 1.0), thirdW * 2.0)
            ]

            for (data, color, xBase) in channels {
                guard data.count == s * s else { continue }
                for row in stride(from: 0, to: s, by: 2) {
                    let py = size.height - (CGFloat(row + 1) * cellH)
                    let rowOffset = row * s
                    for col in stride(from: 0, to: s, by: 2) {
                        let intensity = data[rowOffset + col]
                        if intensity > 0.05 {
                            let rect = CGRect(x: xBase + CGFloat(col) * cellW, y: py, width: max(cellW * 2, 1.1), height: max(cellH * 2, 1.1))
                            context.fill(Path(rect), with: .color(color.opacity(Double(intensity))))
                        }
                    }
                }
            }
        }
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
    }

    private var vectorscopeCanvas: some View {
        Canvas { context, size in
            let cx = size.width * 0.5
            let cy = size.height * 0.5
            let radius = min(size.width, size.height) * 0.46

            // 1. 外圈 & 75% 饱和度内圈
            let outerCircle = CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)
            let innerR = radius * 0.75
            let innerCircle = CGRect(x: cx - innerR, y: cy - innerR, width: innerR * 2, height: innerR * 2)
            context.stroke(Path(ellipseIn: outerCircle), with: .color(.white.opacity(0.28)), lineWidth: 0.7)
            context.stroke(Path(ellipseIn: innerCircle), with: .color(.white.opacity(0.14)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))

            // 2. 十字轴线 (Cb 水平, Cr 垂直)
            var axes = Path()
            axes.move(to: CGPoint(x: cx - radius, y: cy))
            axes.addLine(to: CGPoint(x: cx + radius, y: cy))
            axes.move(to: CGPoint(x: cx, y: cy - radius))
            axes.addLine(to: CGPoint(x: cx, y: cy + radius))
            context.stroke(axes, with: .color(.white.opacity(0.16)), lineWidth: 0.5)

            // 3. 专业肤色校准线 (Skin Tone / I-Line，约 123° 方向，位于第二象限左上)
            let skinAngle = 123.0 * .pi / 180.0
            var skinLine = Path()
            skinLine.move(to: CGPoint(x: cx, y: cy))
            skinLine.addLine(to: CGPoint(
                x: cx + CGFloat(cos(skinAngle)) * radius,
                y: cy - CGFloat(sin(skinAngle)) * radius
            ))
            context.stroke(skinLine, with: .color(Color(red: 1.0, green: 0.62, blue: 0.42).opacity(0.75)), lineWidth: 0.9)

            // 4. Rec.709 75% 六原色目标点 (R, Mg, B, Cy, G, Yl)
            let targets: [(CGFloat, CGFloat, Color)] = [
                (-0.1146,  0.5000, .red),
                ( 0.3854,  0.4542, .purple),
                ( 0.5000, -0.0458, .blue),
                ( 0.1146, -0.5000, .cyan),
                (-0.3854, -0.4542, .green),
                (-0.5000,  0.0458, .yellow)
            ]
            for (cb, cr, col) in targets {
                let tx = cx + cb * 1.5 * radius
                let ty = cy - cr * 1.5 * radius
                let box = CGRect(x: tx - 2.5, y: ty - 2.5, width: 5, height: 5)
                context.stroke(Path(box), with: .color(col.opacity(0.75)), lineWidth: 0.9)
            }

            // 5. 绘制实时 Cb/Cr 散点云
            guard let scope, scope.vectorscopeSize > 0 else { return }
            let s = scope.vectorscopeSize
            let data = scope.vectorscopeIntensities
            guard data.count == s * s else { return }

            for row in stride(from: 0, to: s, by: 2) {
                let cr = (CGFloat(row) / CGFloat(s - 1)) - 0.5
                let py = cy - cr * 2.0 * radius
                let rowOffset = row * s
                for col in stride(from: 0, to: s, by: 2) {
                    let intensity = data[rowOffset + col]
                    if intensity > 0.05 {
                        let cb = (CGFloat(col) / CGFloat(s - 1)) - 0.5
                        let px = cx + cb * 2.0 * radius
                        // 根据 Cb/Cr 方向近似着色，呈现电影级彩色矢量散点
                        let rr = min(max(0.5 + 1.4 * cr, 0.15), 1.0)
                        let gg = min(max(0.5 - 0.34 * cb - 0.71 * cr, 0.15), 1.0)
                        let bb = min(max(0.5 + 1.77 * cb, 0.15), 1.0)
                        let dot = CGRect(x: px - 0.9, y: py - 0.9, width: 1.8, height: 1.8)
                        context.fill(Path(dot), with: .color(Color(red: Double(rr), green: Double(gg), blue: Double(bb)).opacity(Double(intensity))))
                    }
                }
            }
        }
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
    }

    private var waveformCanvas: some View {
        Canvas { context, size in
            // 绘制 0 / 25 / 50 / 75 / 100 IRE 参考标尺线
            for ire in [0.0, 0.25, 0.5, 0.75, 1.0] {
                let y = size.height * (1.0 - ire)
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(.white.opacity(ire == 0.5 ? 0.28 : 0.14)), lineWidth: 0.5)
            }

            guard let scope, scope.waveformWidth > 0, scope.waveformHeight > 0 else { return }
            let w = scope.waveformWidth
            let h = scope.waveformHeight
            let cellW = size.width / CGFloat(w)
            let cellH = size.height / CGFloat(h)
            let data = scope.waveformIntensities

            // 步长 2 采样绘制高密度荧光绿波形迹线，保证 60fps 极低 CPU 占用
            for row in stride(from: 0, to: h, by: 2) {
                let py = size.height - (CGFloat(row + 1) * cellH)
                let rowOffset = row * w
                for col in stride(from: 0, to: w, by: 2) {
                    let intensity = data[rowOffset + col]
                    if intensity > 0.04 {
                        let rect = CGRect(x: CGFloat(col) * cellW, y: py, width: max(cellW * 2, 1.2), height: max(cellH * 2, 1.2))
                        context.fill(Path(rect), with: .color(Color(red: 0.18, green: 0.96, blue: 0.42).opacity(Double(intensity))))
                    }
                }
            }
        }
        .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private var histogramCanvas: some View {
        Canvas { context, size in
            guard let scope else { return }

            func drawChannel(_ bins: [Float], color: Color) {
                guard bins.count == 256 else { return }
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height))
                for i in stride(from: 0, to: 256, by: 2) {
                    let x = (CGFloat(i) / 255.0) * size.width
                    let y = size.height * (1.0 - CGFloat(min(max(bins[i], 0), 1)))
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                context.fill(path, with: .color(color.opacity(0.32)))
                context.stroke(path, with: .color(color.opacity(0.85)), lineWidth: 0.9)
            }

            drawChannel(scope.redHistogram, color: .red)
            drawChannel(scope.greenHistogram, color: .green)
            drawChannel(scope.blueHistogram, color: .blue)
            drawChannel(scope.lumaHistogram, color: .white.opacity(0.7))
        }
        .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// 连接配置 Sheet (支持 Wi-Fi / USB-LAN IP 配置、UVC 有线采集卡切换、混合双模)
private struct ConnectionSettingsSheet: View {
    @Bindable var vm: MonitorViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("选择监看模式") {
                    Picker("模式", selection: $vm.connectionMode) {
                        ForEach(MonitorConnectionMode.allCases) { mode in
                            Label(mode.rawValue, systemImage: mode.symbolName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(vm.connectionMode.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if vm.connectionMode != .uvcWired {
                    Section("Sony A6700 PTP/IP 地址 (TCP 15740)") {
                        TextField("相机 IP (默认 192.168.122.1)", text: $vm.cameraIP)
                            .keyboardType(.decimalPad)
                            .font(.system(.body, design: .monospaced))

                        Picker("Wi-Fi 预览画质 (0xD26A)", selection: Binding(
                            get: { vm.liveViewQuality },
                            set: { vm.setLiveViewQuality($0) }
                        )) {
                            Text("流畅优先 (Low)").tag(SonyLiveViewImageQuality.low)
                            Text("清晰优先 (High)").tag(SonyLiveViewImageQuality.high)
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Section {
                    Button {
                        Task {
                            await vm.connectCurrentMode()
                            dismiss()
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if vm.isConnecting {
                                ProgressView().padding(.trailing, 6)
                            }
                            Text(vm.isCameraConnected || vm.isUVCActive ? "重新连接" : "立即连接")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }

                    Button {
                        Task {
                            await vm.startTestPattern()
                            dismiss()
                        }
                    } label: {
                        HStack {
                            Spacer()
                            Label("启用内置动态测试信号 (模拟器仿真)", systemImage: "tv.and.mediabox")
                            Spacer()
                        }
                    }

                    if vm.isCameraConnected || vm.isUVCActive || vm.isTestPatternActive {
                        Button("断开当前信号", role: .destructive) {
                            Task {
                                await vm.disconnectAll()
                                dismiss()
                            }
                        }
                    }
                }
            }
            .navigationTitle("信号源与相机连接")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

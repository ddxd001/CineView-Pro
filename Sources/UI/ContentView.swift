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

    public var shortTitle: String {
        switch self {
        case .shutter:      return "SS"
        case .aperture:     return "F"
        case .iso:          return "ISO"
        case .exposureBias: return "EV"
        case .whiteBalance: return "WB"
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
    public var videoSourceSize: CGSize = CGSize(width: 1920, height: 1080)
    public var ptpDiagnosticText: String = ""
    public var statusBannerMessage: String?

    // --- 相机实时遥测参数 (A6700) ---
    public var currentExposureMode: SonyExposureProgramMode?
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
    public var focusReticle: FocusReticleState?
    public var isSettingsDrawerPresented: Bool = false
    public var settingsDrawerTab: SettingsDrawerTab = .assist
    public var isGalleryPresented: Bool = false
    public var isLUTImporterPresented: Bool = false
    public var isHUDHidden: Bool = false

    // --- 刚拍照片缓存相册 (0xFFFFC001) ---
    public var capturedPhotos: [CapturedPhotoItem] = []
    public var hasUnreadCapturedPhoto: Bool = false
    public var isFetchingCapturedPhoto: Bool = false

    public func openSettings(tab: SettingsDrawerTab) {
        settingsDrawerTab = tab
        withAnimation(.snappy(duration: 0.22)) {
            activeExposureControl = nil
            isGalleryPresented = false
            isSettingsDrawerPresented = true
        }
    }

    public func closeSettings() {
        withAnimation(.snappy(duration: 0.2)) {
            isSettingsDrawerPresented = false
        }
    }

    public func openGallery() {
        hasUnreadCapturedPhoto = false
        withAnimation(.snappy(duration: 0.22)) {
            activeExposureControl = nil
            isSettingsDrawerPresented = false
            isGalleryPresented = true
        }
        // 打开相册时若相机已连且暂未拉取到照片，顺手静默探测一次 0xFFFFC001
        if isCameraConnected && !isFetchingCapturedPhoto {
            Task { await pullCapturedPhotoFromCamera(manual: false) }
        }
    }

    public func closeGallery() {
        withAnimation(.snappy(duration: 0.2)) {
            isGalleryPresented = false
        }
    }

    // --- 内部后台任务 ---
    private var liveViewTask: Task<Void, Never>?
    private var telemetryTask: Task<Void, Never>?
    private var eventSyncTask: Task<Void, Never>?
    private var eventDebounceTask: Task<Void, Never>?
    private var recordingTimerTask: Task<Void, Never>?
    private var recordingTransitionDeadline: ContinuousClock.Instant?
    private var expectedRecordingState: Bool?
    private var reticleDismissTask: Task<Void, Never>?
    private var bannerDismissTask: Task<Void, Never>?

    private let logger = Logger(subsystem: "com.cineviewpro.ui", category: "MonitorViewModel")

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
            r.onSourceSizeChange = { [weak self] size in
                guard let self, size.width > 0, size.height > 0 else { return }
                self.videoSourceSize = size
                self.currentResolutionLabel = "\(Int(size.width))×\(Int(size.height))"
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
        eventSyncTask?.cancel()
        eventSyncTask = nil
        eventDebounceTask?.cancel()
        eventDebounceTask = nil
        recordingTimerTask?.cancel()
        recordingTimerTask = nil
        recordingTransitionDeadline = nil
        expectedRecordingState = nil
        isRecording = false
        recordingSeconds = 0

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
        renderer?.resetAspectStabilizer()
        ptpDiagnosticText = ""
        currentExposureMode = nil
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

            // 同步首帧状态（记录诊断信息，不再静默吞掉 0x9209 错误）
            do {
                let snapshot = try await client.fetchCameraState()
                applySnapshot(snapshot)
            } catch {
                self.ptpDiagnosticText = "0x9209 失败: \(error.localizedDescription)"
            }

            // 监听 Sony Event 通道 (0xC203 属性变更 / 0xC21B 镜头变更 / 0x4006 / 0xC201 & 0x4002 新拍照片就绪)
            eventSyncTask = Task { [weak self] in
                let stream = await client.events()
                for await event in stream {
                    guard !Task.isCancelled, let self else { break }
                    let code = event.eventCode
                    if code == SonyPTPEventCode.sonyObjectAdded.rawValue
                        || code == SonyPTPEventCode.objectAdded.rawValue {
                        let handle = event.parameters.first ?? SonyVirtualObjectHandle.capturedImage.rawValue
                        Task { @MainActor [weak self] in
                            await self?.pullCapturedPhotoFromCamera(handle: handle, manual: false)
                        }
                    } else if code == SonyPTPEventCode.sonyDevicePropChanged.rawValue
                        || code == SonyPTPEventCode.sonyLensInformationChanged.rawValue
                        || code == SonyPTPEventCode.devicePropChanged.rawValue {
                        self.scheduleDebouncedStateSync(delayMs: 120)
                    }
                }
            }

            // 启动周期遥测同步与延迟测量 (每 2 秒兜底同步一次)
            telemetryTask = Task { [weak self] in
                let clock = ContinuousClock()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled, let self, let activeClient = self.ptpClient else { break }
                    let t0 = clock.now
                    do {
                        let snap = try await activeClient.fetchCameraState()
                        let rtt = t0.duration(to: clock.now)
                        let rttMs = Int(rtt.components.seconds * 1000) + Int(rtt.components.attoseconds / 1_000_000_000_000_000)
                        self.applySnapshot(snap)
                        if !self.isUVCActive {
                            self.signalLatencyMs = max(1, rttMs)
                        }
                    } catch {
                        self.ptpDiagnosticText = "0x9209 轮询异常: \(error.localizedDescription)"
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

    private func scheduleDebouncedStateSync(delayMs: Int) {
        eventDebounceTask?.cancel()
        eventDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(delayMs))
            } catch {
                return // 仅在防抖等待阶段响应取消，进入网络拉取后不再被取消打断
            }
            guard let self, let activeClient = self.ptpClient else { return }
            // 在独立任务中拉取快照，确保后续新事件只重置防抖计时器而绝不中断正在进行的 0x9209
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let snap = try await activeClient.fetchCameraState()
                    self.applySnapshot(snap)
                } catch {
                    self.ptpDiagnosticText = "0x9209 事件同步异常: \(error.localizedDescription)"
                }
            }
        }
    }

    private func applySnapshot(_ snap: CameraStateSnapshot) {
        ptpDiagnosticText = snap.diagnosticSummary
        if let mode = snap.exposureProgramMode {
            currentExposureMode = mode
        }

        if let shutter = snap.shutterSpeed { currentShutter = shutter }
        if let writable = snap.isShutterWritable {
            isShutterWritable = writable
            if !writable {
                shutterPresets = []
                if activeExposureControl == .shutter {
                    activeExposureControl = nil
                }
            } else if !snap.availableShutterSpeeds.isEmpty {
                shutterPresets = snap.availableShutterSpeeds
            }
        }

        if let aperture = snap.aperture { currentAperture = aperture }
        if let writable = snap.isApertureWritable {
            isApertureWritable = writable
            if !writable {
                aperturePresets = []
                if activeExposureControl == .aperture {
                    activeExposureControl = nil
                }
            } else if !snap.availableApertures.isEmpty {
                aperturePresets = snap.availableApertures
            }
        }

        if let iso = snap.iso { currentISO = iso }
        if let writable = snap.isISOWritable {
            isISOWritable = writable
            if !writable {
                isoPresets = []
                if activeExposureControl == .iso {
                    activeExposureControl = nil
                }
            } else if !snap.availableISOs.isEmpty {
                isoPresets = snap.availableISOs
            }
        }
        if let wb = snap.whiteBalance { currentWhiteBalance = wb }
        if let k = snap.colorTemperature, k >= 2500, k <= 9900 { currentColorTemp = k }
        if let ev = snap.exposureBias { currentExposureBias = ev }

        // 优先解析 Sony 私有 BatteryLevel (0xD218, Int8 -1...100)，回退至标准 PTP 0x5001 (UInt8 0...100)
        if let sonyBat = snap.rawProperties[0xD218]?.int8Value, sonyBat >= 0 {
            batteryPercent = min(100, Int(sonyBat))
        } else if let bat = snap.rawProperties[0x5001]?.uint8Value {
            batteryPercent = min(100, Int(bat))
        }

        if let remoteRec = snap.isRecording {
            if let deadline = recordingTransitionDeadline, let expected = expectedRecordingState {
                if remoteRec == expected {
                    // 相机已确认进入目标录制状态，结束保护期
                    recordingTransitionDeadline = nil
                    expectedRecordingState = nil
                } else if ContinuousClock.now < deadline {
                    // 相机起录/停录切换窗口期（约 0.3~1.0s）内暂不把刚点亮的状态覆盖回去
                } else {
                    recordingTransitionDeadline = nil
                    expectedRecordingState = nil
                    if remoteRec != isRecording {
                        isRecording = remoteRec
                        updateRecordingTimer(active: isRecording)
                    }
                }
            } else if remoteRec != isRecording {
                isRecording = remoteRec
                updateRecordingTimer(active: isRecording)
            }
        }

        // 兜底检测 ObjectInMemory (0xD215 >= 0x8000)：即使错过 0xC201 事件也能自动拉取刚拍照片
        if let inMem = snap.objectInMemory, inMem >= 0x8000, !isFetchingCapturedPhoto {
            Task { @MainActor [weak self] in
                await self?.pullCapturedPhotoFromCamera(
                    handle: SonyVirtualObjectHandle.capturedImage.rawValue,
                    manual: false
                )
            }
        }
    }

    // MARK: - 相机遥控动作 (曝光调节 / 触控对焦 / 录制启停)

    public func setShutter(_ value: SonyShutterSpeed) {
        currentShutter = value
        guard let client = ptpClient else { return }
        Task {
            do {
                try await client.setShutterSpeed(value)
                scheduleDebouncedStateSync(delayMs: 180)
            } catch {
                showBanner("快门设置失败: \(error.localizedDescription)")
                scheduleDebouncedStateSync(delayMs: 150)
            }
        }
    }

    public func setAperture(_ value: SonyAperture) {
        currentAperture = value
        guard let client = ptpClient else { return }
        Task {
            do {
                try await client.setAperture(value)
                scheduleDebouncedStateSync(delayMs: 180)
            } catch {
                showBanner("光圈设置失败: \(error.localizedDescription)")
                scheduleDebouncedStateSync(delayMs: 150)
            }
        }
    }

    public func setISO(_ value: SonyISOValue) {
        currentISO = value
        guard let client = ptpClient else { return }
        Task {
            do {
                try await client.setISO(value)
                scheduleDebouncedStateSync(delayMs: 180)
            } catch {
                showBanner("ISO 设置失败: \(error.localizedDescription)")
                scheduleDebouncedStateSync(delayMs: 150)
            }
        }
    }

    public func setWhiteBalance(_ value: SonyWhiteBalance) {
        currentWhiteBalance = value
        guard let client = ptpClient else { return }
        Task {
            do {
                try await client.setWhiteBalance(value)
                scheduleDebouncedStateSync(delayMs: 180)
            } catch {
                showBanner("白平衡设置失败: \(error.localizedDescription)")
            }
        }
    }

    public func setColorTemperature(_ kelvin: UInt16) {
        currentColorTemp = kelvin
        currentWhiteBalance = .colorTempFilter
        guard let client = ptpClient else { return }
        Task {
            do {
                try await client.setColorTemperature(kelvin, ensureColorTempMode: true)
                scheduleDebouncedStateSync(delayMs: 180)
            } catch {
                showBanner("色温设置失败: \(error.localizedDescription)")
            }
        }
    }

    public func setExposureBias(_ bias: SonyExposureBias) {
        currentExposureBias = bias
        guard let client = ptpClient else { return }
        Task {
            do {
                try await client.setExposureBias(bias)
                scheduleDebouncedStateSync(delayMs: 180)
            } catch {
                showBanner("曝光补偿设置失败: \(error.localizedDescription)")
            }
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
            let targetState = !isRecording
            do {
                // 先设置 1.8s 起录/停录状态过渡保护，避免 0xC203 在机身起录准备阶段（0.3~0.6s）短暂回读 0 把红框冲掉
                expectedRecordingState = targetState
                recordingTransitionDeadline = ContinuousClock.now.advanced(by: .milliseconds(1800))

                if targetState {
                    try await client.startRecording()
                    isRecording = true
                } else {
                    try await client.stopRecording()
                    isRecording = false
                }
                updateRecordingTimer(active: isRecording)
                // 延迟 700ms 主动拉取一次 0x9209 校验机身真实录制状态
                scheduleDebouncedStateSync(delayMs: 700)
            } catch {
                recordingTransitionDeadline = nil
                expectedRecordingState = nil
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

    // MARK: - 刚拍照片自动拉取与本地缓存管理 (PTP 0xFFFFC001)

    public func pullCapturedPhotoFromCamera(
        handle: UInt32 = SonyVirtualObjectHandle.capturedImage.rawValue,
        manual: Bool = false
    ) async {
        guard !isFetchingCapturedPhoto else { return }
        guard let client = ptpClient else {
            if manual {
                showBanner("未连接相机 PTP 通道，无法拉取照片")
            }
            return
        }

        isFetchingCapturedPhoto = true
        defer { isFetchingCapturedPhoto = false }

        do {
            guard let captured = try await client.fetchCapturedPhoto(handle: handle) else {
                if manual {
                    showBanner("相机缓冲区暂无新拍照片（请确认保存目的地含 PC）")
                }
                return
            }

            // 后台线程通过 ImageIO 高效解码 2048px 预览图与缩略图，避免卡顿 60fps 监看
            let decoded: CapturedPhotoItem? = await Task.detached(priority: .userInitiated) {
                CapturedPhotoItem.decode(from: captured)
            }.value

            guard let item = decoded else {
                if manual {
                    showBanner("照片格式解码失败 (\(captured.info.formatDisplayName))")
                }
                return
            }

            capturedPhotos.insert(item, at: 0)
            // 最多保留最近 30 张刚拍照片，超出时自动清理最早的临时缓存文件
            while capturedPhotos.count > 30 {
                let removed = capturedPhotos.removeLast()
                if let url = removed.fileURL {
                    try? FileManager.default.removeItem(at: url)
                }
            }

            if !isGalleryPresented {
                hasUnreadCapturedPhoto = true
                showBanner("已接收新照片 \(item.filename)")
            }
        } catch {
            if manual {
                showBanner("照片拉取失败: \(error.localizedDescription)")
            } else {
                logger.warning("自动拉取刚拍照片失败: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    public func deleteCapturedPhoto(_ item: CapturedPhotoItem) {
        capturedPhotos.removeAll { $0.id == item.id }
        if let url = item.fileURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 仿真测试模式下生成一张测试照片，便于离线体验相册预览与缩放交互
    public func captureSimulatedTestPhoto() {
        let size = CGSize(width: 1280, height: 854)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { ctx in
            let colors: [UIColor] = [
                UIColor(red: 0.75, green: 0.75, blue: 0.75, alpha: 1),
                UIColor(red: 0.75, green: 0.75, blue: 0.0, alpha: 1),
                UIColor(red: 0.0, green: 0.75, blue: 0.75, alpha: 1),
                UIColor(red: 0.0, green: 0.75, blue: 0.0, alpha: 1),
                UIColor(red: 0.75, green: 0.0, blue: 0.75, alpha: 1),
                UIColor(red: 0.75, green: 0.0, blue: 0.0, alpha: 1),
                UIColor(red: 0.0, green: 0.0, blue: 0.75, alpha: 1)
            ]
            let barW = size.width / CGFloat(colors.count)
            for (idx, col) in colors.enumerated() {
                col.setFill()
                ctx.fill(CGRect(x: CGFloat(idx) * barW, y: 0, width: barW + 1, height: size.height * 0.72))
            }
            UIColor(white: 0.12, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: size.height * 0.72, width: size.width, height: size.height * 0.28))

            let title = "CineView Pro · Test Capture #\(capturedPhotos.count + 1)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: RobotoFlexFont.uiFont(size: 38, weight: 700),
                .foregroundColor: UIColor.white
            ]
            let textSize = title.size(withAttributes: attrs)
            title.draw(
                at: CGPoint(x: (size.width - textSize.width) * 0.5, y: size.height * 0.82),
                withAttributes: attrs
            )
        }

        guard let jpegData = image.jpegData(compressionQuality: 0.9) else { return }
        let idx = capturedPhotos.count + 1
        let info = SonyCapturedObjectInfo(
            handle: SonyVirtualObjectHandle.capturedImage.rawValue,
            storageID: 0,
            objectFormat: 0x3801,
            compressedSize: UInt32(jpegData.count),
            thumbFormat: 0,
            thumbCompressedSize: 0,
            imageWidth: UInt32(size.width),
            imageHeight: UInt32(size.height),
            filename: String(format: "SIM_%04d.JPG", idx),
            captureDate: ""
        )
        let captured = SonyCapturedPhoto(info: info, imageData: jpegData, thumbnailData: nil)
        if let item = CapturedPhotoItem.decode(from: captured) {
            capturedPhotos.insert(item, at: 0)
        }
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

struct MonitorMetalView: UIViewRepresentable {
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

// MARK: - 6. 主界面 ContentView (双侧边栏零遮挡极简横屏监视器)

public struct ContentView: View {
    @State private var vm = MonitorViewModel()

    public init() {}

    public var body: some View {
        MonitorWorkspaceView(vm: vm)
            // 隐藏系统状态栏与底部 Home 指示条，实现全屏无干扰监看
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
struct FrameGuideOverlay: View {
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
struct FocusReticleView: View {
    let isLocked: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .stroke(isLocked ? MonitorTheme.statusGreen : MonitorTheme.accentAmber, lineWidth: 1.8)
                .frame(width: isLocked ? 52 : 64, height: isLocked ? 52 : 64)
            Circle()
                .fill(isLocked ? MonitorTheme.statusGreen : MonitorTheme.accentAmber)
                .frame(width: 4, height: 4)
        }
        .shadow(color: .black.opacity(0.8), radius: 2)
        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isLocked)
    }
}

/// 12 段假色 IRE 色标图例条
struct FalseColorLegendBar: View {
    var body: some View {
        VStack(spacing: 1) {
            ForEach(FalseColorBand.standard12Bands.reversed()) { band in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(red: Double(band.rgb.x), green: Double(band.rgb.y), blue: Double(band.rgb.z)))
                        .frame(width: 10, height: 14)
                    Text("\(Int(band.rangeIRE.upperBound))")
                        .font(.robotoFlex(size: 8.5, weight: 600))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 20, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 5)
        .background(MonitorTheme.drawerBackground.opacity(0.82), in: RoundedRectangle(cornerRadius: MonitorTheme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MonitorTheme.cardRadius, style: .continuous)
                .stroke(MonitorTheme.border, lineWidth: 0.5)
        )
    }
}

/// 可拖动实时波形图 (Waveform) & RGB 直方图浮窗 (由 MonitorShaders.metal Compute Shader 驱动)
struct ScopesFloatingWidget: View {
    let scope: ScopeAnalysisResult?
    @Binding var mode: ScopeDisplayMode
    @Binding var applyLUT: Bool
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            // 顶部小标题栏
            HStack(spacing: 6) {
                ForEach(ScopeDisplayMode.allCases, id: \.self) { m in
                    Button(m.rawValue) {
                        mode = m
                    }
                    .font(.robotoFlex(size: 9.5, weight: mode == m ? 700 : 500))
                    .foregroundStyle(mode == m ? .black : .white.opacity(0.72))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(mode == m ? MonitorTheme.accentAmber : Color.white.opacity(0.10), in: Capsule())
                    .buttonStyle(.plain)
                }

                Button(applyLUT ? "Post-LUT" : "Log") {
                    applyLUT.toggle()
                }
                .font(.robotoFlex(size: 8.5, weight: 650))
                .foregroundStyle(MonitorTheme.diagnosticCyan)
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(MonitorTheme.diagnosticCyan.opacity(0.15), in: Capsule())
                .buttonStyle(.plain)

                Spacer(minLength: 4)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
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

//
//  MonitorRenderer.swift
//  CineView Pro
//
//  专业级 Metal / MetalKit (MTKView) 60fps 实时视频监视器渲染管线 (iOS 17+ / Swift 6)
//  - 双源统一输入：AVFoundation UVC HDMI 采集卡 (CVPixelBuffer: BGRA / 8-bit & 10-bit YCbCr)
//                + SonyPTPIPClient 解码图像 (CGImage / UIImage / JPEG Data)
//  - 片元着色器：3D LUT (.cube 解析 + 硬件三线性插值)、12 段 Rec.709 假色、Sobel 峰值对焦、
//               动态斜纹斑马纹、变形镜头反挤压 (1.0x / 1.33x / 1.5x / 2.0x)
//  - 计算着色器：三缓冲零阻塞并行统计 亮度波形图 (Waveform) + RGB/Luma 直方图 (Histogram)
//

import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Metal
import MetalKit
import OSLog
import os
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 1. 监视器配置模型与专业参数枚举 (Swift 6 Sendable)

/// 变形镜头反挤压比例 (Anamorphic De-squeeze)
public enum AnamorphicDesqueeze: Float, CaseIterable, Sendable, Identifiable {
    case off  = 1.0
    case x133 = 1.33
    case x150 = 1.50
    case x200 = 2.00

    public var id: Float { rawValue }

    public var displayName: String {
        switch self {
        case .off:  return "1.0x"
        case .x133: return "1.33x"
        case .x150: return "1.5x"
        case .x200: return "2.0x"
        }
    }
}

/// 峰值对焦高亮配色 (红 / 绿 / 黄)
public enum FocusPeakingColor: UInt32, CaseIterable, Sendable, Identifiable {
    case red    = 0
    case green  = 1
    case yellow = 2

    public var id: UInt32 { rawValue }

    public var displayName: String {
        switch self {
        case .red:    return "红"
        case .green:  return "绿"
        case .yellow: return "黄"
        }
    }
}

/// 12 段假色图例条目 (与 MonitorShaders.metal 的 mapFalseColor12Band 严格一致，便于 UI 绘制色标尺)
public struct FalseColorBand: Sendable, Identifiable {
    public let id: Int
    public let rangeIRE: ClosedRange<Float>
    public let label: String
    public let rgb: SIMD3<Float>

    public static let standard12Bands: [FalseColorBand] = [
        FalseColorBand(id: 0,  rangeIRE: 0...2,   label: "0-2 IRE 死黑裁切",   rgb: SIMD3(0.32, 0.00, 0.58)),
        FalseColorBand(id: 1,  rangeIRE: 2...10,  label: "2-10 IRE 极暗部",    rgb: SIMD3(0.05, 0.10, 0.65)),
        FalseColorBand(id: 2,  rangeIRE: 10...20, label: "10-20 IRE 暗部",     rgb: SIMD3(0.00, 0.38, 0.92)),
        FalseColorBand(id: 3,  rangeIRE: 20...30, label: "20-30 IRE 暗中灰",   rgb: SIMD3(0.00, 0.72, 0.88)),
        FalseColorBand(id: 4,  rangeIRE: 30...40, label: "30-40 IRE S-Log3 灰", rgb: SIMD3(0.08, 0.56, 0.52)),
        FalseColorBand(id: 5,  rangeIRE: 40...48, label: "40-48 IRE 中暗灰",   rgb: SIMD3(0.38, 0.38, 0.38)),
        FalseColorBand(id: 6,  rangeIRE: 48...55, label: "48-55 IRE 18% 中灰", rgb: SIMD3(0.16, 0.82, 0.24)),
        FalseColorBand(id: 7,  rangeIRE: 55...65, label: "55-65 IRE 浅灰",     rgb: SIMD3(0.58, 0.58, 0.58)),
        FalseColorBand(id: 8,  rangeIRE: 65...73, label: "65-73 IRE 肤色基准", rgb: SIMD3(0.98, 0.45, 0.68)),
        FalseColorBand(id: 9,  rangeIRE: 73...85, label: "73-85 IRE 亮灰",     rgb: SIMD3(0.80, 0.80, 0.80)),
        FalseColorBand(id: 10, rangeIRE: 85...95, label: "85-95 IRE 高光预警", rgb: SIMD3(0.98, 0.84, 0.08)),
        FalseColorBand(id: 11, rangeIRE: 95...100, label: "95-100 IRE 过曝裁切", rgb: SIMD3(0.95, 0.08, 0.08))
    ]
}

/// 监视器实时画面辅助工具开关与参数集合
public struct MonitorRenderSettings: Equatable, Sendable {
    /// 是否启用 3D LUT 还原 (如 Sony S-Log3 -> Rec.709)
    public var isLUTEnabled: Bool = false
    /// 3D LUT 混合强度 [0.0, 1.0]
    public var lutIntensity: Float = 1.0
    /// 是否启用 12 段专业假色
    public var isFalseColorEnabled: Bool = false
    /// 是否启用 Sobel 峰值对焦
    public var isPeakingEnabled: Bool = false
    /// 峰值对焦高亮颜色
    public var peakingColor: FocusPeakingColor = .red
    /// 峰值对焦灵敏度 [0.0, 1.0]
    public var peakingSensitivity: Float = 0.5
    /// 是否启用过曝动态斑马纹
    public var isZebraEnabled: Bool = false
    /// 斑马纹触发阈值 (IRE, 默认 95.0，可调 50.0...100.0)
    public var zebraThresholdIRE: Float = 95.0
    /// 变形镜头反挤压倍率
    public var desqueeze: AnamorphicDesqueeze = .off
    /// 水平镜像翻转 (自拍 / 提词器场景)
    public var flipHorizontal: Bool = false
    /// 垂直上下翻转 (倒装兔笼场景)
    public var flipVertical: Bool = false
    /// 是否开启计算着色器实时计算示波器
    public var isScopesEnabled: Bool = true
    /// 示波器计算是否基于 LUT 还原后的色彩 (false = 监控原始 Log 曝光, true = 监控还原后 Rec.709)
    public var scopesApplyLUT: Bool = true

    public init() {}
}

/// 计算着色器输出的单帧全套示波器统计结果 (波形图 / RGB 分量波形 / 矢量示波器 / RGB 直方图)
public struct ScopeAnalysisResult: Sendable {
    /// 256 档归一化 Red 直方图 [0.0, 1.0]
    public let redHistogram: [Float]
    /// 256 档归一化 Green 直方图 [0.0, 1.0]
    public let greenHistogram: [Float]
    /// 256 档归一化 Blue 直方图 [0.0, 1.0]
    public let blueHistogram: [Float]
    /// 256 档归一化 Rec.709 亮度直方图 [0.0, 1.0]
    public let lumaHistogram: [Float]
    /// 亮度波形图水平列数 (默认 256)
    public let waveformWidth: Int
    /// 亮度波形图垂直 IRE 级数 (默认 128, index 0 = 0 IRE 底部, height-1 = 100 IRE 顶部)
    public let waveformHeight: Int
    /// 行主序归一化亮度波形密度矩阵 (`waveformHeight * waveformWidth`, 范围 [0.0, 1.0])
    public let waveformIntensities: [Float]
    /// RGB 分量波形单通道边长 (默认 128: 每通道 128×128)
    public let paradeSize: Int
    public let redParade: [Float]
    public let greenParade: [Float]
    public let blueParade: [Float]
    /// 矢量示波器边长 (默认 128: X=Cb ∈ [-0.5, +0.5], Y=Cr ∈ [-0.5, +0.5])
    public let vectorscopeSize: Int
    public let vectorscopeIntensities: [Float]
    /// 统计完成时间戳
    public let timestamp: ContinuousClock.Instant
}

/// 渲染器错误类型
public enum MonitorRendererError: Error, LocalizedError, Sendable {
    case metalDeviceUnavailable
    case commandQueueCreationFailed
    case shaderLibraryNotFound
    case shaderFunctionNotFound(String)
    case textureCacheCreationFailed(CVReturn)
    case invalidCubeLUT(String)
    case lutTextureAllocationFailed

    public var errorDescription: String? {
        switch self {
        case .metalDeviceUnavailable:
            return "当前设备不支持 Metal。"
        case .commandQueueCreationFailed:
            return "无法创建 MTLCommandQueue。"
        case .shaderLibraryNotFound:
            return "无法加载 MonitorShaders.metal 对应的默认 MTLLibrary。"
        case .shaderFunctionNotFound(let name):
            return "在 MTLLibrary 中找不到着色器函数: \(name)。"
        case .textureCacheCreationFailed(let status):
            return "CVMetalTextureCacheCreate 失败 (CVReturn: \(status))。"
        case .invalidCubeLUT(let reason):
            return "标准 .cube LUT 文件解析失败: \(reason)"
        case .lutTextureAllocationFailed:
            return "无法分配 3D LUT MTLTexture。"
        }
    }
}

// MARK: - 2. 标准 .cube 3D LUT 解析器与 3D 纹理构建

/// 解析后的 3D LUT 数据模型
public struct CubeLUT: Sendable {
    public let title: String
    /// 立方体边长 N (常见为 17 / 33 / 65)，总条目数为 N³
    public let dimension: Int
    /// 输入域下限 (默认 0, 0, 0)
    public let domainMin: SIMD3<Float>
    /// 输入域上限 (默认 1, 1, 1)
    public let domainMax: SIMD3<Float>
    /// 按 RGBA Float16 交错排布的 3D 纹理数据 (长度 = N³ × 4 × 2 字节)
    /// .cube 规范定义 R 变化最快、其次 G、最后 B，恰好对应 Metal 3D Texture 的 (x, y, z) 内存布局
    public let rgba16FloatData: Data

    /// 解析标准 Adobe / Sony `.cube` 文件内容
    public static func parse(contentsOf url: URL) throws -> CubeLUT {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parse(string: text)
    }

    public static func parse(data: Data) throws -> CubeLUT {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            throw MonitorRendererError.invalidCubeLUT("文件编码不是有效的 UTF-8/ASCII 文本。")
        }
        return try parse(string: text)
    }

    public static func parse(string: String) throws -> CubeLUT {
        var title = "Untitled LUT"
        var dimension = 0
        var domainMin = SIMD3<Float>(0, 0, 0)
        var domainMax = SIMD3<Float>(1, 1, 1)
        var halfValues: [UInt16] = []

        let oneHalf = Float16(1.0).bitPattern

        string.enumerateLines { rawLine, stop in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") {
                return
            }

            if line.hasPrefix("TITLE") {
                let rest = line.dropFirst("TITLE".count)
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if !rest.isEmpty { title = rest }
                return
            }

            if line.hasPrefix("LUT_3D_SIZE") {
                let tokens = line.split(whereSeparator: \.isWhitespace)
                if tokens.count >= 2, let size = Int(tokens[1]) {
                    dimension = size
                    if size >= 2 && size <= 128 {
                        halfValues.reserveCapacity(size * size * size * 4)
                    }
                }
                return
            }

            if line.hasPrefix("LUT_1D_SIZE") {
                // 明确忽略或标记不支持纯 1D LUT，以 LUT_3D_SIZE 校验为准
                return
            }

            if line.hasPrefix("DOMAIN_MIN") {
                let tokens = line.split(whereSeparator: \.isWhitespace)
                if tokens.count >= 4,
                   let r = Float(tokens[1]), let g = Float(tokens[2]), let b = Float(tokens[3]) {
                    domainMin = SIMD3<Float>(r, g, b)
                }
                return
            }

            if line.hasPrefix("DOMAIN_MAX") {
                let tokens = line.split(whereSeparator: \.isWhitespace)
                if tokens.count >= 4,
                   let r = Float(tokens[1]), let g = Float(tokens[2]), let b = Float(tokens[3]) {
                    domainMax = SIMD3<Float>(r, g, b)
                }
                return
            }

            // 数值行: R G B (三个浮点数)
            let tokens = line.split(whereSeparator: \.isWhitespace)
            if tokens.count >= 3,
               let r = Float(tokens[0]), let g = Float(tokens[1]), let b = Float(tokens[2]) {
                // 转换为 IEEE-754 Float16 (RGBA16Float 在所有 iOS Apple GPU 上均支持原生硬件三线性插值)
                halfValues.append(Float16(r).bitPattern)
                halfValues.append(Float16(g).bitPattern)
                halfValues.append(Float16(b).bitPattern)
                halfValues.append(oneHalf)
            }
        }

        guard dimension >= 2 && dimension <= 128 else {
            throw MonitorRendererError.invalidCubeLUT("缺少有效的 LUT_3D_SIZE (支持 2...128，实得 \(dimension))。")
        }

        let expectedCount = dimension * dimension * dimension * 4
        guard halfValues.count == expectedCount else {
            throw MonitorRendererError.invalidCubeLUT(
                "3D LUT 采样点数量不匹配: 期望 \(dimension)³ = \(dimension * dimension * dimension) 行，实际解析 \(halfValues.count / 4) 行。"
            )
        }

        let data = halfValues.withUnsafeBufferPointer { Data(buffer: $0) }
        return CubeLUT(
            title: title,
            dimension: dimension,
            domainMin: domainMin,
            domainMax: domainMax,
            rgba16FloatData: data
        )
    }

    /// 上传至 Metal 3D 纹理 (`type3D`, `rgba16Float`)，供硬件三线性插值采样
    public func makeMetalTexture(device: MTLDevice) throws -> MTLTexture {
        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = .rgba16Float
        desc.width = dimension
        desc.height = dimension
        desc.depth = dimension
        desc.mipmapLevelCount = 1
        desc.usage = [.shaderRead]
        desc.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: desc) else {
            throw MonitorRendererError.lutTextureAllocationFailed
        }

        let bytesPerRow = dimension * 4 * MemoryLayout<UInt16>.stride
        let bytesPerImage = bytesPerRow * dimension
        let region = MTLRegionMake3D(0, 0, 0, dimension, dimension, dimension)

        rgba16FloatData.withUnsafeBytes { rawPtr in
            guard let base = rawPtr.baseAddress else { return }
            texture.replace(
                region: region,
                mipmapLevel: 0,
                slice: 0,
                withBytes: base,
                bytesPerRow: bytesPerRow,
                bytesPerImage: bytesPerImage
            )
        }

        return texture
    }
}

// MARK: - 3. 与 MonitorShaders.metal 逐字节对齐的 Uniform 结构体 (112 字节)

/// 与 Metal 端 `struct MonitorUniforms` 严格一致的 16 字节对齐布局
struct MonitorUniforms {
    // Block 0 (0...15)
    var sourceSize: SIMD2<Float> = .zero
    var viewportSize: SIMD2<Float> = .zero

    // Block 1 (16...31)
    var desqueezeFactor: Float = 1.0
    var time: Float = 0.0
    var inputFormat: UInt32 = 0
    var lutEnabled: UInt32 = 0

    // Block 2 (32...47)
    var lutIntensity: Float = 1.0
    var lutDimension: Float = 2.0
    var falseColorEnabled: UInt32 = 0
    var peakingEnabled: UInt32 = 0

    // Block 3 (48...63)
    var peakingSensitivity: Float = 0.5
    var peakingColorMode: UInt32 = 0
    var zebraEnabled: UInt32 = 0
    var zebraThresholdIRE: Float = 95.0

    // Block 4 (64...79)
    var lutDomainMin: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 0)

    // Block 5 (80...95)
    var lutDomainMax: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)

    // Block 6 (96...111)
    var scopesApplyLUT: UInt32 = 1
    var waveformWidth: UInt32 = 256
    var waveformHeight: UInt32 = 128
    var sampleStride: UInt32 = 2

    // Block 7 (112...127)
    var flipHorizontal: UInt32 = 0
    var flipVertical: UInt32 = 0
    var paradeSize: UInt32 = 128
    var vectorscopeSize: UInt32 = 128
}

// MARK: - 4. 线程安全跨队列帧递交箱

/// 跨线程传递 CVPixelBuffer 的轻量 Sendable 包装（写入方提交后不再修改像素缓冲）
private final class PixelBufferBox: @unchecked Sendable {
    let buffer: CVPixelBuffer
    init(_ buffer: CVPixelBuffer) {
        self.buffer = buffer
    }
}

/// 供 GPU CommandBuffer 完成前保活 CVMetalTexture 的只读 Sendable 容器
private final class CVTextureRetainer: @unchecked Sendable {
    let textures: [CVMetalTexture]
    init(_ textures: [CVMetalTexture]) {
        self.textures = textures
    }
}

private enum PendingVideoFrame: Sendable {
    case pixelBuffer(PixelBufferBox)
    case cgImage(CGImage)
}

/// 三缓冲 Compute Scope 槽位，避免 waitUntilCompleted 阻塞 60fps 渲染
private final class ScopeBufferSlot: @unchecked Sendable {
    let histogramBuffer: MTLBuffer   // 4 * 256 * UInt32
    let waveformBuffer: MTLBuffer    // waveformWidth * waveformHeight * UInt32
    let paradeBuffer: MTLBuffer      // 3 * paradeSize * paradeSize * UInt32
    let vectorscopeBuffer: MTLBuffer // vectorscopeSize * vectorscopeSize * UInt32
    let waveformWidth: Int
    let waveformHeight: Int
    let paradeSize: Int
    let vectorscopeSize: Int

    init?(device: MTLDevice, waveformWidth: Int, waveformHeight: Int, paradeSize: Int, vectorscopeSize: Int) {
        self.waveformWidth = waveformWidth
        self.waveformHeight = waveformHeight
        self.paradeSize = paradeSize
        self.vectorscopeSize = vectorscopeSize

        let histSize = 4 * 256 * MemoryLayout<UInt32>.stride
        let waveSize = waveformWidth * waveformHeight * MemoryLayout<UInt32>.stride
        let parSize = 3 * paradeSize * paradeSize * MemoryLayout<UInt32>.stride
        let vecSize = vectorscopeSize * vectorscopeSize * MemoryLayout<UInt32>.stride

        guard let hBuf = device.makeBuffer(length: histSize, options: .storageModeShared),
              let wBuf = device.makeBuffer(length: waveSize, options: .storageModeShared),
              let pBuf = device.makeBuffer(length: parSize, options: .storageModeShared),
              let vBuf = device.makeBuffer(length: vecSize, options: .storageModeShared) else {
            return nil
        }
        self.histogramBuffer = hBuf
        self.waveformBuffer = wBuf
        self.paradeBuffer = pBuf
        self.vectorscopeBuffer = vBuf
    }

    private static func normalizeLog1p(_ ptr: UnsafePointer<UInt32>, count: Int) -> [Float] {
        var maxVal: UInt32 = 1
        for i in 0..<count {
            let v = ptr[i]
            if v > maxVal { maxVal = v }
        }
        let denom = log1p(Float(maxVal))
        let inv = denom > 0 ? (1.0 / denom) : 0.0
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let v = ptr[i]
            if v > 0 {
                out[i] = min(1.0, log1p(Float(v)) * inv)
            }
        }
        return out
    }

    /// 在 GPU CommandBuffer 完成后于后台线程提取并归一化 4 套示波器数据
    func extractNormalizedResult() -> ScopeAnalysisResult {
        let histPtr = histogramBuffer.contents().bindMemory(to: UInt32.self, capacity: 1024)
        let waveCount = waveformWidth * waveformHeight
        let wavePtr = waveformBuffer.contents().bindMemory(to: UInt32.self, capacity: waveCount)
        let paradePlane = paradeSize * paradeSize
        let paradePtr = paradeBuffer.contents().bindMemory(to: UInt32.self, capacity: 3 * paradePlane)
        let vecCount = vectorscopeSize * vectorscopeSize
        let vecPtr = vectorscopeBuffer.contents().bindMemory(to: UInt32.self, capacity: vecCount)

        // 1. 归一化 RGB + Luma 直方图
        var maxHist: UInt32 = 1
        for i in 0..<1024 {
            let v = histPtr[i]
            if v > maxHist { maxHist = v }
        }
        let invMaxHist = 1.0 / Float(maxHist)

        var red   = [Float](repeating: 0, count: 256)
        var green = [Float](repeating: 0, count: 256)
        var blue  = [Float](repeating: 0, count: 256)
        var luma  = [Float](repeating: 0, count: 256)

        for i in 0..<256 {
            red[i]   = Float(histPtr[i]) * invMaxHist
            green[i] = Float(histPtr[256 + i]) * invMaxHist
            blue[i]  = Float(histPtr[512 + i]) * invMaxHist
            luma[i]  = Float(histPtr[768 + i]) * invMaxHist
        }

        // 2. 归一化亮度波形、RGB 分量波形与矢量示波器 (采用 log1p 模拟专业示波器荧光辉度)
        let waveform = Self.normalizeLog1p(wavePtr, count: waveCount)
        let redParade = Self.normalizeLog1p(paradePtr, count: paradePlane)
        let greenParade = Self.normalizeLog1p(paradePtr.advanced(by: paradePlane), count: paradePlane)
        let blueParade = Self.normalizeLog1p(paradePtr.advanced(by: 2 * paradePlane), count: paradePlane)
        let vectorscope = Self.normalizeLog1p(vecPtr, count: vecCount)

        return ScopeAnalysisResult(
            redHistogram: red,
            greenHistogram: green,
            blueHistogram: blue,
            lumaHistogram: luma,
            waveformWidth: waveformWidth,
            waveformHeight: waveformHeight,
            waveformIntensities: waveform,
            paradeSize: paradeSize,
            redParade: redParade,
            greenParade: greenParade,
            blueParade: blueParade,
            vectorscopeSize: vectorscopeSize,
            vectorscopeIntensities: vectorscope,
            timestamp: .now
        )
    }
}

// MARK: - 5. 核心专业监视器渲染器 (MonitorRenderer)

/// 基于 MetalKit (MTKView) 的 60fps 专业监视器渲染引擎
@MainActor
public final class MonitorRenderer: NSObject, MTKViewDelegate {

    // --- 公共配置与回调 ---
    public var settings = MonitorRenderSettings()

    /// 当前已加载的 3D LUT 标题 (nil 表示尚未加载)
    public private(set) var loadedLUTTitle: String?

    /// 当前输入视频帧的物理分辨率 (用于触控对焦坐标反算与安全框精准对齐)
    public var currentSourceSize: CGSize {
        CGSize(width: CGFloat(activeSourceSize.x), height: CGFloat(activeSourceSize.y))
    }

    /// 波形图 & RGB 直方图实时回调 (在主线程回调，便于直接更新 SwiftUI / UIKit 示波器视图)
    public var onScopeUpdate: (@MainActor @Sendable (ScopeAnalysisResult) -> Void)?

    // --- Metal 核心管线对象 ---
    public let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let renderPipelineState: MTLRenderPipelineState
    private let clearScopesPipeline: MTLComputePipelineState
    private let analyzeScopesPipeline: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache

    // --- 占位纹理 (确保着色器绑定槽位永不为 nil) ---
    private let dummy2DTexture: MTLTexture
    private let dummy3DLUTTexture: MTLTexture

    // --- 当前激活的帧纹理状态 ---
    private var activePrimaryTexture: MTLTexture?
    private var activeChromaTexture: MTLTexture?
    /// 持有当前帧的 CVMetalTexture，防止 CVPixelBuffer 提前归还造成 GPU 读野指针
    private var retainedCVTextures: [CVMetalTexture] = []
    private var activeInputFormat: UInt32 = 0 // 0=RGB, 1=YCbCr Video, 2=YCbCr Full
    private var activeSourceSize: SIMD2<Float> = SIMD2<Float>(1920, 1080)

    /// 复用的 CGImage 上传纹理与像素暂存区 (避免 30~60fps LiveView 频繁创建 MTLTexture)
    private var reusableRGBTexture: MTLTexture?
    private var reusableRGBBytes: [UInt8] = []

    // --- 3D LUT 状态 ---
    private var activeLUTTexture: MTLTexture?
    private var activeLUTDimension: Float = 2.0
    private var activeLUTDomainMin = SIMD4<Float>(0, 0, 0, 0)
    private var activeLUTDomainMax = SIMD4<Float>(1, 1, 1, 1)

    // --- 三缓冲并行控制与 Compute Scope 槽位 ---
    private static let maxFramesInFlight = 3
    private let inFlightSemaphore = DispatchSemaphore(value: maxFramesInFlight)
    private let scopeSlots: [ScopeBufferSlot]
    private var currentSlotIndex = 0
    private let waveformWidth = 256
    private let waveformHeight = 128
    private let paradeSize = 128
    private let vectorscopeSize = 128

    // --- 跨线程帧递交锁 (允许 AVFoundation 采集线程 / PTP 后台任务无锁阻塞写入) ---
    private let pendingFrameLock = OSAllocatedUnfairLock<PendingVideoFrame?>(initialState: nil)
    private var hasNewFrameForScopes = false

    // --- 异步示波器流广播 ---
    private let scopeStreamsLock = OSAllocatedUnfairLock<[UUID: AsyncStream<ScopeAnalysisResult>.Continuation]>(initialState: [:])

    // --- 时间基准 (驱动斑马纹动画) ---
    private let startClock = ContinuousClock.now
    private let logger = Logger(subsystem: "com.cineviewpro.renderer", category: "MonitorRenderer")

    // MARK: - 初始化与 MTKView 绑定

    /// 初始化专业视频渲染器
    /// - Parameters:
    ///   - device: 可选 Metal 设备，默认使用系统默认 GPU
    ///   - colorPixelFormat: 目标 `MTKView` 色彩格式，默认 `.bgra8Unorm`
    ///   - shaderLibrary: 可选自定义 `MTLLibrary`（默认加载 App Bundle 中的 `MonitorShaders.metal`）
    public init(
        device: MTLDevice? = MTLCreateSystemDefaultDevice(),
        colorPixelFormat: MTLPixelFormat = .bgra8Unorm,
        shaderLibrary: MTLLibrary? = nil
    ) throws {
        guard let metalDevice = device else {
            throw MonitorRendererError.metalDeviceUnavailable
        }
        guard let queue = metalDevice.makeCommandQueue() else {
            throw MonitorRendererError.commandQueueCreationFailed
        }

        let library: MTLLibrary
        if let customLib = shaderLibrary {
            library = customLib
        } else if let defaultLib = metalDevice.makeDefaultLibrary() {
            library = defaultLib
        } else if let metalURL = Bundle.main.url(forResource: "MonitorShaders", withExtension: "metal"),
                  let source = try? String(contentsOf: metalURL, encoding: .utf8) {
            library = try metalDevice.makeLibrary(source: source, options: nil)
        } else {
            throw MonitorRendererError.shaderLibraryNotFound
        }

        guard let vertexFn = library.makeFunction(name: "monitorVertexShader") else {
            throw MonitorRendererError.shaderFunctionNotFound("monitorVertexShader")
        }
        guard let fragmentFn = library.makeFunction(name: "monitorFragmentShader") else {
            throw MonitorRendererError.shaderFunctionNotFound("monitorFragmentShader")
        }
        guard let clearFn = library.makeFunction(name: "clearScopesKernel") else {
            throw MonitorRendererError.shaderFunctionNotFound("clearScopesKernel")
        }
        guard let analyzeFn = library.makeFunction(name: "analyzeScopesKernel") else {
            throw MonitorRendererError.shaderFunctionNotFound("analyzeScopesKernel")
        }

        // 1. 构建图形渲染管线
        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.label = "CineViewPro.MonitorRenderPipeline"
        pipelineDesc.vertexFunction = vertexFn
        pipelineDesc.fragmentFunction = fragmentFn
        pipelineDesc.colorAttachments[0].pixelFormat = colorPixelFormat
        let renderPSO = try metalDevice.makeRenderPipelineState(descriptor: pipelineDesc)

        // 2. 构建 Compute 示波器管线
        let clearPSO = try metalDevice.makeComputePipelineState(function: clearFn)
        let analyzePSO = try metalDevice.makeComputePipelineState(function: analyzeFn)

        // 3. 创建零拷贝 CVMetalTextureCache (供 UVC HDMI 采集卡 CVPixelBuffer 使用)
        var cacheOut: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, metalDevice, nil, &cacheOut)
        guard cacheStatus == kCVReturnSuccess, let cache = cacheOut else {
            throw MonitorRendererError.textureCacheCreationFailed(cacheStatus)
        }

        // 4. 创建占位 2D / 3D 恒等纹理
        guard let dummy2D = Self.makeDummy2DTexture(device: metalDevice),
              let dummy3D = Self.makeIdentity3DLUTTexture(device: metalDevice) else {
            throw MonitorRendererError.lutTextureAllocationFailed
        }

        // 5. 预分配三缓冲 Compute Scope 槽位
        var slots: [ScopeBufferSlot] = []
        slots.reserveCapacity(Self.maxFramesInFlight)
        for _ in 0..<Self.maxFramesInFlight {
            guard let slot = ScopeBufferSlot(
                device: metalDevice,
                waveformWidth: 256,
                waveformHeight: 128,
                paradeSize: 128,
                vectorscopeSize: 128
            ) else {
                throw MonitorRendererError.lutTextureAllocationFailed
            }
            slots.append(slot)
        }

        self.device = metalDevice
        self.commandQueue = queue
        self.renderPipelineState = renderPSO
        self.clearScopesPipeline = clearPSO
        self.analyzeScopesPipeline = analyzePSO
        self.textureCache = cache
        self.dummy2DTexture = dummy2D
        self.dummy3DLUTTexture = dummy3D
        self.scopeSlots = slots

        super.init()
    }

    /// 一键配置 `MTKView` 为 60fps 专业监视器模式并绑定 delegate
    public func attach(to mtkView: MTKView, preferredFPS: Int = 60) {
        mtkView.device = device
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = true
        mtkView.preferredFramesPerSecond = preferredFPS
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        mtkView.delegate = self
    }

    // MARK: - 3D LUT 加载与卸载

    /// 从本地 `.cube` 文件加载 3D LUT 并上传到 GPU 3D 纹理（用于 A6700 S-Log3 实时还原）
    public func loadCubeLUT(from url: URL, autoEnable: Bool = true) throws {
        let lut = try CubeLUT.parse(contentsOf: url)
        try applyCubeLUT(lut, autoEnable: autoEnable)
    }

    /// 从内存 `.cube` Data 加载 3D LUT
    public func loadCubeLUT(data: Data, autoEnable: Bool = true) throws {
        let lut = try CubeLUT.parse(data: data)
        try applyCubeLUT(lut, autoEnable: autoEnable)
    }

    public func applyCubeLUT(_ lut: CubeLUT, autoEnable: Bool = true) throws {
        let texture = try lut.makeMetalTexture(device: device)
        self.activeLUTTexture = texture
        self.activeLUTDimension = Float(lut.dimension)
        self.activeLUTDomainMin = SIMD4<Float>(lut.domainMin.x, lut.domainMin.y, lut.domainMin.z, 0)
        self.activeLUTDomainMax = SIMD4<Float>(lut.domainMax.x, lut.domainMax.y, lut.domainMax.z, 1)
        self.loadedLUTTitle = lut.title
        if autoEnable {
            self.settings.isLUTEnabled = true
        }
        self.hasNewFrameForScopes = true
        logger.info("3D LUT 已加载: \(lut.title, privacy: .public) (\(lut.dimension)³)")
    }

    /// 清除当前 3D LUT
    public func clearLUT() {
        activeLUTTexture = nil
        activeLUTDimension = 2.0
        activeLUTDomainMin = SIMD4<Float>(0, 0, 0, 0)
        activeLUTDomainMax = SIMD4<Float>(1, 1, 1, 1)
        loadedLUTTitle = nil
        settings.isLUTEnabled = false
        hasNewFrameForScopes = true
    }

    // MARK: - 双源统一帧输入 API (全线程安全，可从任意后台队列高频调用)

    /// 【输入源 A】接收来自 AVFoundation（外部 UVC HDMI 采集卡 `AVCaptureDevice.DeviceType.external`）的 `CVPixelBuffer`
    /// - 支持格式：`32BGRA`、`420v` (BiPlanar 8-bit Video)、`420f` (BiPlanar 8-bit Full)、`x420`/`xf20` (10-bit BiPlanar)
    nonisolated public func update(pixelBuffer: CVPixelBuffer) {
        let box = PixelBufferBox(pixelBuffer)
        pendingFrameLock.withLock { $0 = .pixelBuffer(box) }
    }

    /// 【输入源 A 便捷方法】直接接收 `AVCaptureVideoDataOutputSampleBufferDelegate` 回调的 `CMSampleBuffer`
    nonisolated public func update(sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        update(pixelBuffer: pixelBuffer)
    }

    /// 【输入源 B】接收来自 `SonyPTPIPClient` 解码得到的 `CGImage`
    nonisolated public func update(cgImage: CGImage) {
        pendingFrameLock.withLock { $0 = .cgImage(cgImage) }
    }

    /// 【输入源 B 便捷方法】直接接收 `SonyPTPIPClient.liveViewStream()` 抛出的纯 JPEG `Data`
    /// - 开启 `kCGImageSourceShouldCacheImmediately: true`，强制在调用方后台线程完成硬件加速 JPEG 解码，
    ///   绝不把解码拖延到主线程 `draw(in:)` 中，显著提升帧率与主线程响应速度。
    nonisolated public func update(jpegData: Data) {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false
        ]
        guard let source = CGImageSourceCreateWithData(jpegData as CFData, options as CFDictionary),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else {
            return
        }
        update(cgImage: cgImage)
    }

    #if canImport(UIKit)
    /// 【输入源 B 便捷方法】接收 `UIImage`
    nonisolated public func update(uiImage: UIImage) {
        guard let cgImage = uiImage.cgImage else { return }
        update(cgImage: cgImage)
    }
    #endif

    // MARK: - 示波器异步流订阅 (波形图 + RGB 直方图)

    /// 以 `AsyncStream` 订阅实时示波器统计结果（`.bufferingNewest(1)`，避免 UI 积压）
    nonisolated public func scopeStream() -> AsyncStream<ScopeAnalysisResult> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            scopeStreamsLock.withLock { $0[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.scopeStreamsLock.withLock { _ = $0.removeValue(forKey: id) }
            }
        }
    }

    // MARK: - MTKViewDelegate (60fps 渲染与并行计算循环)

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // 视口尺寸变化时下一帧 Uniforms 会自动携带最新 drawableSize，无需额外操作
    }

    public func draw(in view: MTKView) {
        // 1. 拉取最新待渲染帧并上传/映射为 Metal 纹理
        if let pending = pendingFrameLock.withLock({ frame -> PendingVideoFrame? in
            let current = frame
            frame = nil
            return current
        }) {
            ingestPendingFrame(pending)
            hasNewFrameForScopes = true
        }

        guard let primaryTexture = activePrimaryTexture,
              let renderPassDesc = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else {
            return
        }

        // 三缓冲非阻塞等待：若 GPU 积压满 3 帧则安全丢弃本次绘制，严防主线程卡顿
        guard inFlightSemaphore.wait(timeout: .now() + .milliseconds(16)) == .success else {
            return
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }
        commandBuffer.label = "CineViewPro.MonitorFrame"

        let slot = scopeSlots[currentSlotIndex]
        currentSlotIndex = (currentSlotIndex + 1) % Self.maxFramesInFlight

        // 2. 组装 112 字节共享 Uniforms
        let elapsed = startClock.duration(to: .now)
        let elapsedSeconds = Float(elapsed.components.seconds) + Float(elapsed.components.attoseconds) * 1e-18

        // 自适应 Compute 采样步长：保证 4K / 1080p / LiveView 均在 <0.3ms 内完成波形图与直方图统计
        let maxDim = max(activeSourceSize.x, activeSourceSize.y)
        let adaptiveStride: UInt32 = maxDim >= 3000 ? 4 : (maxDim >= 1400 ? 2 : 1)

        var uniforms = MonitorUniforms(
            sourceSize: activeSourceSize,
            viewportSize: SIMD2<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            desqueezeFactor: settings.desqueeze.rawValue,
            time: elapsedSeconds,
            inputFormat: activeInputFormat,
            lutEnabled: (settings.isLUTEnabled && activeLUTTexture != nil) ? 1 : 0,
            lutIntensity: settings.lutIntensity,
            lutDimension: activeLUTDimension,
            falseColorEnabled: settings.isFalseColorEnabled ? 1 : 0,
            peakingEnabled: settings.isPeakingEnabled ? 1 : 0,
            peakingSensitivity: settings.peakingSensitivity,
            peakingColorMode: settings.peakingColor.rawValue,
            zebraEnabled: settings.isZebraEnabled ? 1 : 0,
            zebraThresholdIRE: settings.zebraThresholdIRE,
            lutDomainMin: activeLUTDomainMin,
            lutDomainMax: activeLUTDomainMax,
            scopesApplyLUT: (settings.scopesApplyLUT && settings.isLUTEnabled && activeLUTTexture != nil) ? 1 : 0,
            waveformWidth: UInt32(waveformWidth),
            waveformHeight: UInt32(waveformHeight),
            sampleStride: adaptiveStride,
            flipHorizontal: settings.flipHorizontal ? 1 : 0,
            flipVertical: settings.flipVertical ? 1 : 0,
            paradeSize: UInt32(paradeSize),
            vectorscopeSize: UInt32(vectorscopeSize)
        )

        let chromaTexture = activeChromaTexture ?? dummy2DTexture
        let lutTexture = activeLUTTexture ?? dummy3DLUTTexture

        // 3. Compute Pass：单次并行计算亮度波形图、RGB 分量波形、矢量示波器与 RGB+Luma 直方图
        let shouldRunScopes = settings.isScopesEnabled && hasNewFrameForScopes
        if shouldRunScopes {
            hasNewFrameForScopes = false
            if let computeEncoder = commandBuffer.makeComputeCommandEncoder() {
                computeEncoder.label = "CineViewPro.ScopesComputePass"

                // 3a. 清零 4 组示波器缓冲
                computeEncoder.setComputePipelineState(clearScopesPipeline)
                computeEncoder.setBuffer(slot.histogramBuffer, offset: 0, index: 0)
                computeEncoder.setBuffer(slot.waveformBuffer, offset: 0, index: 1)
                computeEncoder.setBytes(&uniforms, length: MemoryLayout<MonitorUniforms>.stride, index: 2)
                computeEncoder.setBuffer(slot.paradeBuffer, offset: 0, index: 3)
                computeEncoder.setBuffer(slot.vectorscopeBuffer, offset: 0, index: 4)

                let clearTotal = max(
                    max(4 * 256, waveformWidth * waveformHeight),
                    max(3 * paradeSize * paradeSize, vectorscopeSize * vectorscopeSize)
                )
                let clearTGWidth = min(clearScopesPipeline.maxTotalThreadsPerThreadgroup, 256)
                computeEncoder.dispatchThreads(
                    MTLSize(width: clearTotal, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: clearTGWidth, height: 1, depth: 1)
                )

                // 3b. 单遍并行统计 4 套专业示波器
                computeEncoder.setComputePipelineState(analyzeScopesPipeline)
                computeEncoder.setTexture(primaryTexture, index: 0)
                computeEncoder.setTexture(chromaTexture, index: 1)
                computeEncoder.setTexture(lutTexture, index: 2)
                computeEncoder.setBuffer(slot.histogramBuffer, offset: 0, index: 0)
                computeEncoder.setBuffer(slot.waveformBuffer, offset: 0, index: 1)
                computeEncoder.setBytes(&uniforms, length: MemoryLayout<MonitorUniforms>.stride, index: 2)
                computeEncoder.setBuffer(slot.paradeBuffer, offset: 0, index: 3)
                computeEncoder.setBuffer(slot.vectorscopeBuffer, offset: 0, index: 4)

                let sampleGridW = max(1, (Int(activeSourceSize.x) + Int(adaptiveStride) - 1) / Int(adaptiveStride))
                let sampleGridH = max(1, (Int(activeSourceSize.y) + Int(adaptiveStride) - 1) / Int(adaptiveStride))
                computeEncoder.dispatchThreads(
                    MTLSize(width: sampleGridW, height: sampleGridH, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
                )

                computeEncoder.endEncoding()
            }
        }

        // 4. Render Pass：片元着色器全屏绘制 (反挤压 + 3D LUT + 假色 + 斑马纹 + Sobel 峰值对焦)
        if let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) {
            renderEncoder.label = "CineViewPro.MonitorRenderPass"
            renderEncoder.setRenderPipelineState(renderPipelineState)
            renderEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<MonitorUniforms>.stride, index: 0)
            renderEncoder.setFragmentTexture(primaryTexture, index: 0)
            renderEncoder.setFragmentTexture(chromaTexture, index: 1)
            renderEncoder.setFragmentTexture(lutTexture, index: 2)
            // 全屏单三角形绘制 (3 顶点，无需 VertexBuffer)
            renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            renderEncoder.endEncoding()
        }

        // 5. 异步回收信号量与非阻塞示波器结果回读
        let semaphore = inFlightSemaphore
        let streamsLock = scopeStreamsLock
        let scopeCallback = onScopeUpdate
        let cvTexturesKeepAlive = CVTextureRetainer(retainedCVTextures)

        commandBuffer.addCompletedHandler { _ in
            // 释放本帧持有的 CVMetalTexture 引用与三缓冲信号量
            _ = cvTexturesKeepAlive
            semaphore.signal()

            guard shouldRunScopes else { return }
            let result = slot.extractNormalizedResult()

            // 广播给所有 AsyncStream 订阅者
            let continuations = streamsLock.withLock { Array($0.values) }
            for cont in continuations {
                cont.yield(result)
            }

            // 回调主线程闭包
            if let scopeCallback {
                Task { @MainActor in
                    scopeCallback(result)
                }
            }
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - 内部双源纹理转换实现

    private func ingestPendingFrame(_ frame: PendingVideoFrame) {
        switch frame {
        case .pixelBuffer(let box):
            ingestCVPixelBuffer(box.buffer)
        case .cgImage(let cgImage):
            ingestCGImage(cgImage)
        }
    }

    /// 零拷贝将 AVFoundation UVC HDMI 采集卡输出的 `CVPixelBuffer` 映射为 Metal 纹理
    private func ingestCVPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return }

        // 定期刷新 CVMetalTextureCache，避免长时运行缓存膨胀
        CVMetalTextureCacheFlush(textureCache, 0)

        switch pixelFormat {
        case kCVPixelFormatType_32BGRA:
            guard let cvTex = makeCVMetalTexture(
                pixelBuffer: pixelBuffer,
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                planeIndex: 0
            ), let mtlTex = CVMetalTextureGetTexture(cvTex) else { return }

            self.activePrimaryTexture = mtlTex
            self.activeChromaTexture = nil
            self.retainedCVTextures = [cvTex]
            self.activeInputFormat = 0
            self.activeSourceSize = SIMD2<Float>(Float(width), Float(height))

        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            let yWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            let yHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            let uvWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
            let uvHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)

            guard let cvY = makeCVMetalTexture(
                pixelBuffer: pixelBuffer,
                pixelFormat: .r8Unorm,
                width: yWidth,
                height: yHeight,
                planeIndex: 0
            ),
            let cvUV = makeCVMetalTexture(
                pixelBuffer: pixelBuffer,
                pixelFormat: .rg8Unorm,
                width: uvWidth,
                height: uvHeight,
                planeIndex: 1
            ),
            let yTex = CVMetalTextureGetTexture(cvY),
            let uvTex = CVMetalTextureGetTexture(cvUV) else { return }

            self.activePrimaryTexture = yTex
            self.activeChromaTexture = uvTex
            self.retainedCVTextures = [cvY, cvUV]
            self.activeInputFormat = (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) ? 1 : 2
            self.activeSourceSize = SIMD2<Float>(Float(yWidth), Float(yHeight))

        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            // 专业 10-bit HDMI 采集卡 (P010 / x420 / xf20) 零拷贝直通支持
            let yWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            let yHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            let uvWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
            let uvHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)

            guard let cvY = makeCVMetalTexture(
                pixelBuffer: pixelBuffer,
                pixelFormat: .r16Unorm,
                width: yWidth,
                height: yHeight,
                planeIndex: 0
            ),
            let cvUV = makeCVMetalTexture(
                pixelBuffer: pixelBuffer,
                pixelFormat: .rg16Unorm,
                width: uvWidth,
                height: uvHeight,
                planeIndex: 1
            ),
            let yTex = CVMetalTextureGetTexture(cvY),
            let uvTex = CVMetalTextureGetTexture(cvUV) else { return }

            self.activePrimaryTexture = yTex
            self.activeChromaTexture = uvTex
            self.retainedCVTextures = [cvY, cvUV]
            self.activeInputFormat = (pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) ? 1 : 2
            self.activeSourceSize = SIMD2<Float>(Float(yWidth), Float(yHeight))

        default:
            logger.warning("未识别的 CVPixelBuffer 像素格式: \(pixelFormat)，建议在 AVCaptureVideoDataOutput 指定 420YpCbCr8BiPlanarVideoRange 或 32BGRA。")
        }
    }

    private func makeCVMetalTexture(
        pixelBuffer: CVPixelBuffer,
        pixelFormat: MTLPixelFormat,
        width: Int,
        height: Int,
        planeIndex: Int
    ) -> CVMetalTexture? {
        var textureOut: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            planeIndex,
            &textureOut
        )
        return status == kCVReturnSuccess ? textureOut : nil
    }

    /// 将来自 `SonyPTPIPClient` 的 `CGImage` 高效上传到复用的 `MTLTexture` (零每帧纹理重分配)
    private func ingestCGImage(_ cgImage: CGImage) {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return }

        let bytesPerRow = width * 4
        let totalBytes = bytesPerRow * height

        // 仅在首帧或 LiveView 分辨率切换时重建纹理与暂存区
        if reusableRGBTexture?.width != width || reusableRGBTexture?.height != height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            desc.usage = [.shaderRead]
            desc.storageMode = .shared
            guard let newTex = device.makeTexture(descriptor: desc) else { return }
            reusableRGBTexture = newTex
            reusableRGBBytes = [UInt8](repeating: 0, count: totalBytes)
        }

        guard let targetTexture = reusableRGBTexture else { return }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue

        reusableRGBBytes.withUnsafeMutableBytes { rawBuffer in
            guard let basePtr = rawBuffer.baseAddress,
                  let ctx = CGContext(
                    data: basePtr,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                  ) else {
                return
            }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

            let region = MTLRegionMake2D(0, 0, width, height)
            targetTexture.replace(
                region: region,
                mipmapLevel: 0,
                withBytes: basePtr,
                bytesPerRow: bytesPerRow
            )
        }

        self.activePrimaryTexture = targetTexture
        self.activeChromaTexture = nil
        self.retainedCVTextures = []
        self.activeInputFormat = 0
        self.activeSourceSize = SIMD2<Float>(Float(width), Float(height))
    }

    // MARK: - 占位纹理生成辅助

    private static func makeDummy2DTexture(device: MTLDevice) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        var neutralUV: [UInt8] = [128, 128]
        tex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &neutralUV, bytesPerRow: 2)
        return tex
    }

    private static func makeIdentity3DLUTTexture(device: MTLDevice) -> MTLTexture? {
        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = .rgba16Float
        desc.width = 2
        desc.height = 2
        desc.depth = 2
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }

        var pixels: [UInt16] = []
        pixels.reserveCapacity(2 * 2 * 2 * 4)
        for b in 0..<2 {
            for g in 0..<2 {
                for r in 0..<2 {
                    pixels.append(Float16(Float(r)).bitPattern)
                    pixels.append(Float16(Float(g)).bitPattern)
                    pixels.append(Float16(Float(b)).bitPattern)
                    pixels.append(Float16(1.0).bitPattern)
                }
            }
        }
        pixels.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            tex.replace(
                region: MTLRegionMake3D(0, 0, 0, 2, 2, 2),
                mipmapLevel: 0,
                slice: 0,
                withBytes: base,
                bytesPerRow: 2 * 4 * MemoryLayout<UInt16>.stride,
                bytesPerImage: 2 * 2 * 4 * MemoryLayout<UInt16>.stride
            )
        }
        return tex
    }
}

// MARK: - 6. iOS 17+ 外部 UVC HDMI 采集卡发现辅助 (AVCaptureDevice.DeviceType.external)

public enum ExternalUVCCaptureDiscovery {
    /// 发现当前通过 USB-C 接入 iPad/iPhone 的外部 UVC HDMI 采集卡 (iOS 17+)
    public static func discoverExternalCaptureDevices() -> [AVCaptureDevice] {
        #if os(iOS)
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        )
        return session.devices
        #else
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        )
        return session.devices
        #endif
    }

    /// 为外部 UVC 采集卡创建推荐的零拷贝 `AVCaptureVideoDataOutput` 像素设置
    /// - 优先使用 `420YpCbCr8BiPlanarVideoRange` (硬件零拷贝最优)，配合 `MonitorRenderer.update(sampleBuffer:)`
    public static var recommendedVideoSettings: [String: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
    }
}

// MARK: - 7. 多 .cube 3D LUT 本地收藏夹管理器 (持久化到 Documents/CineViewLUTs)

/// 保存在本地收藏夹中的 3D LUT 条目
public struct SavedLUTItem: Identifiable, Equatable, Hashable, Sendable {
    public let id: String          // 文件名（唯一键）
    public let displayName: String // 显示名称（不含 .cube 后缀）
    public let fileURL: URL
}

/// 负责将用户导入的 `.cube` 文件持久化复制到 App 沙盒 `Documents/CineViewLUTs/`，支持多 LUT 快速切换与删除
public enum LUTLibraryManager {
    private static let folderName = "CineViewLUTs"
    private static let lastSelectedKey = "com.cineviewpro.lut.lastSelectedID"

    public static var libraryDirectoryURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = docs.appendingPathComponent(folderName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 列出本地收藏夹中所有已保存的 `.cube` 文件（按名称排序）
    public static func listSavedLUTs() -> [SavedLUTItem] {
        let dir = libraryDirectoryURL
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls
            .filter { $0.pathExtension.lowercased() == "cube" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { url in
                SavedLUTItem(
                    id: url.lastPathComponent,
                    displayName: url.deletingPathExtension().lastPathComponent,
                    fileURL: url
                )
            }
    }

    /// 导入外部 `.cube` 文件：先校验格式合法性，再拷贝至本地收藏夹目录持久化
    public static func importLUT(from sourceURL: URL) throws -> SavedLUTItem {
        // 先解析校验，防止把损坏文件写入收藏夹
        _ = try CubeLUT.parse(contentsOf: sourceURL)

        let dir = libraryDirectoryURL
        var fileName = sourceURL.lastPathComponent
        if !fileName.lowercased().hasSuffix(".cube") {
            fileName += ".cube"
        }
        let destURL = dir.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destURL)

        let item = SavedLUTItem(
            id: destURL.lastPathComponent,
            displayName: destURL.deletingPathExtension().lastPathComponent,
            fileURL: destURL
        )
        setLastSelectedLUTID(item.id)
        return item
    }

    /// 删除指定收藏夹 LUT
    public static func deleteLUT(_ item: SavedLUTItem) throws {
        if FileManager.default.fileExists(atPath: item.fileURL.path) {
            try FileManager.default.removeItem(at: item.fileURL)
        }
        if lastSelectedLUTID == item.id {
            setLastSelectedLUTID(nil)
        }
    }

    public static var lastSelectedLUTID: String? {
        UserDefaults.standard.string(forKey: lastSelectedKey)
    }

    public static func setLastSelectedLUTID(_ id: String?) {
        if let id {
            UserDefaults.standard.set(id, forKey: lastSelectedKey)
        } else {
            UserDefaults.standard.removeObject(forKey: lastSelectedKey)
        }
    }
}

//
//  TestPatternGenerator.swift
//  CineView Pro
//
//  内置电影监视器动态测试信号源 (供 MacBook iOS 模拟器离线仿真使用)：
//  - 上半区：SMPTE 7 色标准彩条 (检验 3D LUT、RGB 直方图、12 段假色)
//  - 中央区：高锐度西门子星形对焦标板 + 细密网格 + 模拟皮肤色块 (~70 IRE 粉红假色校验)
//  - 下半区：0–100 IRE 连续亮度渐变条 + 动态扫过的高光脉冲条 (检验实时波形图与动态斑马纹)
//

import CoreGraphics
import CoreVideo
import Foundation

public final class TestPatternGenerator: @unchecked Sendable {
    private let width: Int
    private let height: Int
    private var frameIndex: Int = 0
    private var task: Task<Void, Never>?

    public init(width: Int = 1280, height: Int = 720) {
        self.width = width
        self.height = height
    }

    public func start(fps: Double = 30.0, onFrame: @escaping @Sendable (CVPixelBuffer, Int) -> Void) {
        stop()
        let intervalNanos = UInt64(1_000_000_000.0 / max(fps, 1.0))

        task = Task.detached(priority: .userInitiated) { [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                guard let self else { break }
                let t0 = clock.now
                if let pb = self.renderNextPixelBuffer() {
                    let elapsed = t0.duration(to: clock.now)
                    let ms = max(4, Int(elapsed.components.seconds * 1000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000))
                    onFrame(pb, ms)
                }
                let spent = t0.duration(to: clock.now)
                let target = Duration.nanoseconds(Int64(intervalNanos))
                if spent < target {
                    try? await Task.sleep(for: target - spent)
                }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// 生成内置演示用 17×17×17 `.cube` 3D LUT (模拟 S-Log3 -> 高对比电影胶片青橙色调)
    public static func makeBuiltInDemoCubeLUT() throws -> CubeLUT {
        let size = 17
        var lines: [String] = [
            "TITLE \"Sony S-Log3 -> Cine709 Demo\"",
            "DOMAIN_MIN 0.0 0.0 0.0",
            "DOMAIN_MAX 1.0 1.0 1.0",
            "LUT_3D_SIZE \(size)"
        ]
        lines.reserveCapacity(size * size * size + 4)

        // 按 .cube 规范: B 最外层, G 中间层, R 最内层
        for bi in 0..<size {
            let b = Double(bi) / Double(size - 1)
            for gi in 0..<size {
                let g = Double(gi) / Double(size - 1)
                for ri in 0..<size {
                    let r = Double(ri) / Double(size - 1)
                    // S 曲线对比度增强 + 轻微暖高光 / 青阴影电影风格
                    func sCurve(_ x: Double) -> Double {
                        let c = x * x * (3.0 - 2.0 * x)
                        return min(max(x * 0.35 + c * 0.65, 0.0), 1.0)
                    }
                    let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    let rOut = min(max(sCurve(r) + 0.05 * luma - 0.02 * (1.0 - luma), 0.0), 1.0)
                    let gOut = min(max(sCurve(g) + 0.01 * luma, 0.0), 1.0)
                    let bOut = min(max(sCurve(b) - 0.04 * luma + 0.05 * (1.0 - luma), 0.0), 1.0)
                    lines.append(String(format: "%.5f %.5f %.5f", rOut, gOut, bOut))
                }
            }
        }
        return try CubeLUT.parse(string: lines.joined(separator: "\n"))
    }

    private func renderNextPixelBuffer() -> CVPixelBuffer? {
        frameIndex &+= 1
        let phase = Double(frameIndex) * 0.045

        var pixelBufferOut: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBufferOut
        )
        guard status == kCVReturnSuccess, let pb = pixelBufferOut else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let baseAddr = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        guard let ctx = CGContext(
            data: baseAddr,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        let w = CGFloat(width)
        let h = CGFloat(height)

        // CoreGraphics 原点在左下角：翻转坐标系至左上角原点，与屏幕方向一致
        ctx.translateBy(x: 0, y: h)
        ctx.scaleBy(x: 1, y: -1)

        // 背景纯黑
        ctx.setFillColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // 1. 顶部 SMPTE 7 色彩条 (高度 36%)
        let barHeight = h * 0.36
        let smpteColors: [(CGFloat, CGFloat, CGFloat)] = [
            (0.75, 0.75, 0.75), // 75% 灰白
            (0.75, 0.75, 0.00), // 黄
            (0.00, 0.75, 0.75), // 青
            (0.00, 0.75, 0.00), // 绿
            (0.75, 0.00, 0.75), // 品红
            (0.75, 0.00, 0.00), // 红
            (0.00, 0.00, 0.75)  // 蓝
        ]
        let barW = w / CGFloat(smpteColors.count)
        for (idx, c) in smpteColors.enumerated() {
            ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
            ctx.fill(CGRect(x: CGFloat(idx) * barW, y: 0, width: barW + 1, height: barHeight))
        }

        // 2. 中间专业校验区 (y: 36%...76%)
        let midTop = barHeight
        let midH = h * 0.40

        // 2a. 左侧：18% 中灰 (50 IRE -> 绿假色) + 标准肤色块 (70 IRE -> 粉红假色)
        ctx.setFillColor(red: 0.50, green: 0.50, blue: 0.50, alpha: 1)
        ctx.fill(CGRect(x: w * 0.06, y: midTop + 20, width: w * 0.16, height: midH - 40))

        ctx.setFillColor(red: 0.80, green: 0.67, blue: 0.58, alpha: 1)
        ctx.fill(CGRect(x: w * 0.24, y: midTop + 20, width: w * 0.16, height: midH - 40))

        // 2b. 中央：高锐度西门子星形对焦标板 (让 Sobel 峰值对焦清晰点亮边缘!)
        let starCenter = CGPoint(x: w * 0.56, y: midTop + midH * 0.5)
        let starRadius = min(w * 0.13, midH * 0.44)
        let spokes = 24
        for i in 0..<spokes {
            let a0 = CGFloat(i) * (2.0 * .pi / CGFloat(spokes)) + CGFloat(phase * 0.25)
            let a1 = a0 + (.pi / CGFloat(spokes))
            ctx.beginPath()
            ctx.move(to: starCenter)
            ctx.addArc(center: starCenter, radius: starRadius, startAngle: a0, endAngle: a1, clockwise: false)
            ctx.closePath()
            ctx.setFillColor(red: 0.94, green: 0.94, blue: 0.94, alpha: 1)
            ctx.fillPath()
        }
        // 精细同心圆环
        ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 0.9)
        ctx.setLineWidth(1.5)
        for rFactor in [0.35, 0.70, 1.0] as [CGFloat] {
            let r = starRadius * rFactor
            ctx.strokeEllipse(in: CGRect(x: starCenter.x - r, y: starCenter.y - r, width: r * 2, height: r * 2))
        }

        // 2c. 右侧：动态高光过曝测试窗 (96-100 IRE，专门触发动态斑马纹与纯红假色)
        let pulse = CGFloat(0.5 + 0.5 * sin(phase))
        let zebraBoxW = w * 0.18
        let zebraBoxH = midH - 48
        let zebraX = w * 0.76
        let zebraY = midTop + 24
        ctx.setFillColor(red: 0.98, green: 0.98, blue: 0.98, alpha: 1)
        ctx.fill(CGRect(x: zebraX, y: zebraY, width: zebraBoxW, height: zebraBoxH * 0.55))

        // 动态呼吸亮度方块 (60 IRE <-> 100 IRE 来回摆动，方便观察波形图实时跳动)
        let dynLuma = 0.55 + 0.45 * pulse
        ctx.setFillColor(red: dynLuma, green: dynLuma, blue: dynLuma, alpha: 1)
        ctx.fill(CGRect(x: zebraX, y: zebraY + zebraBoxH * 0.60, width: zebraBoxW, height: zebraBoxH * 0.40))

        // 3. 底部：0–100 IRE 连续亮度斜坡 (在波形图上呈现完美 45° 斜线，在假色中呈现完整 12 色阶!)
        let rampTop = midTop + midH
        let rampH = h - rampTop
        let steps = 128
        let stepW = w / CGFloat(steps)
        for i in 0..<steps {
            let t = CGFloat(i) / CGFloat(steps - 1)
            ctx.setFillColor(red: t, green: t, blue: t, alpha: 1)
            ctx.fill(CGRect(x: CGFloat(i) * stepW, y: rampTop, width: stepW + 1, height: rampH))
        }

        // 4. 在亮度斜坡上叠加一条水平来回扫动的高亮指示竖条 (检验 60fps 流畅度与波形实时追踪)
        let sweepX = (0.1 + 0.8 * CGFloat(0.5 + 0.5 * sin(phase * 0.8))) * w
        ctx.setFillColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.95)
        ctx.fill(CGRect(x: sweepX - 18, y: rampTop + 10, width: 36, height: rampH - 20))

        return pb
    }
}

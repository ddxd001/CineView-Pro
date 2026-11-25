//
//  MonitorTheme.swift
//  CineView Pro
//
//  统一电影机监看视觉体系 (Design Tokens) + Roboto Flex 可变字体引擎
//

import CoreText
import SwiftUI
import UIKit
import os

// MARK: - 1. 统一视觉语义色与圆角规范

public enum MonitorTheme {
    /// 纯黑画框背景（与 OLED 屏幕边框融为一体）
    public static let canvasBlack = Color.black

    /// 统一控件深炭灰底面 (#141416)
    public static let surface = Color(red: 0.078, green: 0.078, blue: 0.086)

    /// 抽屉与浮层深色面板底面 (#111113)
    public static let drawerBackground = Color(red: 0.067, green: 0.067, blue: 0.075)

    /// 常规微弱描边
    public static let border = Color.white.opacity(0.10)

    /// 悬停 / 高亮描边
    public static let borderStrong = Color.white.opacity(0.22)

    /// 琥珀黄：激活工具 / 当前选中参数 (#F5C400)
    public static let accentAmber = Color(red: 0.961, green: 0.769, blue: 0.0)

    /// 警戒红：录制 REC / Tally 边框 / 低电量预警 (#FF3B30)
    public static let tallyRed = Color(red: 1.0, green: 0.231, blue: 0.188)

    /// 诊断青：色温 K / 连接速率辅助信息 (#32D7FF)
    public static let diagnosticCyan = Color(red: 0.196, green: 0.843, blue: 1.0)

    /// 在线翠绿 (#34D399)
    public static let statusGreen = Color(red: 0.204, green: 0.827, blue: 0.600)

    /// 统一圆角尺度
    public static let cardRadius: CGFloat = 9
    public static let chipRadius: CGFloat = 7
    public static let drawerRadius: CGFloat = 14
}

// MARK: - 2. Roboto Flex 可变字体引擎 (CoreText wght / wdth / opsz 轴精确驱动)

public enum RobotoFlexFont {
    /// 四字符 OpenType 轴标识符（对应 RobotoFlex.ttf 的 fvar 表）
    private static let weightAxisID: Int = 0x77676874 // 'wght' (100...1000)
    private static let widthAxisID: Int  = 0x77647468 // 'wdth' (25...151)
    private static let opszAxisID: Int   = 0x6F70737A // 'opsz' (8...144)

    private struct CacheKey: Hashable {
        let sizeTenths: Int
        let weightInt: Int
        let widthInt: Int
    }

    private static let cache = OSAllocatedUnfairLock<[CacheKey: UIFont]>(initialState: [:])
    private static let fontAvailable: Bool = {
        if UIFont(name: "RobotoFlex-Regular", size: 14) != nil {
            return true
        }
        // 兜底：若 Info.plist 尚未加载（例如 Xcode Preview），尝试主动从 Bundle 注册
        if let url = Bundle.main.url(forResource: "RobotoFlex", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            return UIFont(name: "RobotoFlex-Regular", size: 14) != nil
        }
        return false
    }()

    /// 生成指定字号、字重 (100...1000) 与字宽 (25...151) 的 Roboto Flex UIFont
    public static func uiFont(size: CGFloat, weight: CGFloat = 500, width: CGFloat = 98) -> UIFont {
        let clampedWeight = min(max(weight, 100), 1000)
        let clampedWidth = min(max(width, 25), 151)
        let key = CacheKey(
            sizeTenths: Int((size * 10).rounded()),
            weightInt: Int(clampedWeight.rounded()),
            widthInt: Int(clampedWidth.rounded())
        )

        if let cached = cache.withLock({ $0[key] }) {
            return cached
        }

        let resolved: UIFont
        if fontAvailable {
            let opsz = min(max(size, 8), 144)
            let variations: [NSNumber: NSNumber] = [
                NSNumber(value: weightAxisID): NSNumber(value: Double(clampedWeight)),
                NSNumber(value: widthAxisID): NSNumber(value: Double(clampedWidth)),
                NSNumber(value: opszAxisID): NSNumber(value: Double(opsz))
            ]
            let attributes: [UIFontDescriptor.AttributeName: Any] = [
                .name: "RobotoFlex-Regular",
                UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): variations
            ]
            let descriptor = UIFontDescriptor(fontAttributes: attributes)
            resolved = UIFont(descriptor: descriptor, size: size)
        } else {
            resolved = UIFont.systemFont(ofSize: size, weight: fallbackSystemWeight(for: clampedWeight))
        }

        cache.withLock { $0[key] = resolved }
        return resolved
    }

    private static func fallbackSystemWeight(for numericWeight: CGFloat) -> UIFont.Weight {
        switch numericWeight {
        case ..<350: return .light
        case ..<450: return .regular
        case ..<550: return .medium
        case ..<650: return .semibold
        case ..<750: return .bold
        case ..<850: return .heavy
        default:     return .black
        }
    }
}

public extension Font {
    /// 统一使用 Roboto Flex 可变字体
    static func robotoFlex(size: CGFloat, weight: CGFloat = 500, width: CGFloat = 98) -> Font {
        Font(RobotoFlexFont.uiFont(size: size, weight: weight, width: width))
    }
}

//
//  SonyPTPIPClient.swift
//  CineView Pro
//
//  纯原生 iOS 17+ / Swift 6 Sony A6700 (ILCE-6700, BIONZ XR / SDI3) PTP/IP 客户端模块
//  严格基于 Foundation + Network.framework (NWConnection) + OSLog，零第三方依赖。
//
//  参考规范：
//  - CIPA DC-X005-2005 (PTP/IP, ISO 15740 over TCP/IP, 端口 15740, 全字段 Little-Endian)
//  - Sony SDIO Vendor Extensions v3 (0x012C / 300, BIONZ XR 架构：A6700 / A7IV / FX3 / ZV-E1)
//

import Foundation
import Network
import OSLog

// MARK: - 1. 协议常量定义 (PTP/IP + Sony SDIO v3)

/// PTP/IP 基础包类型 (位于每个 TCP 帧 Offset 0x04...0x07, UInt32 Little-Endian)
public enum PTPIPPacketType: UInt32, Sendable {
    /// Initiator -> Responder (指令通道): 发送 GUID、客户端名称、协议版本
    case initCommandRequest  = 0x0000_0001
    /// Responder -> Initiator (指令通道): 返回 ConnectionNumber、相机 GUID、相机名称
    case initCommandAck      = 0x0000_0002
    /// Initiator -> Responder (事件通道): 携带 ConnectionNumber 绑定到同一会话
    case initEventRequest    = 0x0000_0003
    /// Responder -> Initiator (事件通道): 确认事件通道握手成功 (总长 8 字节)
    case initEventAck        = 0x0000_0004
    /// Responder -> Initiator: 初始化失败，后跟 4 字节 Reason Code
    case initFail            = 0x0000_0005
    /// Initiator -> Responder (指令通道): PTP 操作请求 (Operation Request)
    case operationRequest    = 0x0000_0006
    /// Responder -> Initiator (指令通道): PTP 操作响应 (Operation Response)
    case operationResponse   = 0x0000_0007
    /// Responder -> Initiator (事件通道): 异步相机事件推送 (Event)
    case event               = 0x0000_0008
    /// 双向 (指令通道): 数据阶段开始包，声明 TransactionID 和 UInt64 总字节数
    case startData           = 0x0000_0009
    /// 双向 (指令通道): 中间分片数据包 (非最后一片)
    case data                = 0x0000_000A
    /// 双向: 取消当前事务
    case cancel              = 0x0000_000B
    /// 双向 (指令通道): 最后一个数据包 (或单包数据传输直接用 EndData)
    case endData             = 0x0000_000C
    /// 双向 (事件通道): 链路保活探测请求 (总长 8 字节)
    case probeRequest        = 0x0000_000D
    /// 双向 (事件通道): 链路保活探测响应 (总长 8 字节)
    case probeResponse       = 0x0000_000E
}

/// PTP/IP Operation_Request 包中的 Data Phase Info 字段 (Offset 0x08...0x0B, UInt32 LE)
/// ⚠️ 注意：依据 CIPA DC-X005-2005 规范，发错此值会导致 Sony 机身阻塞等待数据或直接断开！
public enum PTPIPDataPhaseInfo: UInt32, Sendable {
    /// 无数据阶段，或数据由相机发往主机 (Data-In: Responder -> Initiator)
    case noDataOrDataIn = 0x0000_0001
    /// 数据由主机发往相机 (Data-Out: Initiator -> Responder，必须紧跟 StartData + EndData)
    case dataOut        = 0x0000_0002
    /// 未知数据方向 (一般不使用)
    case unknown        = 0x0000_0003
}

/// 标准 PTP + Sony SDIO 私有操作码 (Operation Code, UInt16 LE)
public enum SonyPTPOpCode: UInt16, Sendable {
    // --- 标准 ISO 15740 PTP OpCodes ---
    case getDeviceInfo              = 0x1001
    case openSession                = 0x1002
    case closeSession               = 0x1003
    case getObjectInfo              = 0x1008
    case getObject                  = 0x1009
    case getThumb                   = 0x100A

    // --- Sony 私有 SDIO 扩展 OpCodes (0x92xx) ---
    /// Sony SDIO 握手状态机 (Phase 1 -> Phase 2 -> [0x9202] -> Phase 3)
    case sdioConnect                = 0x9201
    /// 获取 Sony 扩展设备信息与协商 SDI 协议版本 (A6700 / BIONZ XR 为 0x012C = 300)
    case sdioGetExtDeviceInfo       = 0x9202
    /// 设置单个扩展设备属性值 (又称 SetControlDeviceA, Data-Out, Param1 = PropCode)
    case sdioSetExtDevicePropValue  = 0x9205
    /// 执行按键/瞬时控制指令 (又称 SetControlDeviceB, Data-Out, Param1 = ControlCode)
    case sdioControlDevice          = 0x9207
    /// 一次性全量拉取所有 Sony 扩展属性描述与当前值 (Data-In)
    case sdioGetAllExtDevicePropInfo = 0x9209
}

/// PTP 响应码 (Response Code, UInt16 LE)
public enum PTPResponseCode: UInt16, Sendable, CustomStringConvertible {
    case ok                    = 0x2001
    case generalError          = 0x2002
    case sessionNotOpen        = 0x2003
    case invalidTransactionID  = 0x2004
    case operationNotSupported = 0x2005
    case parameterNotSupported = 0x2006
    case incompleteTransfer    = 0x2007
    case invalidObjectHandle   = 0x2009
    case devicePropNotSupported = 0x200A
    case deviceBusy            = 0x2019
    case invalidDevicePropFormat = 0x201B
    case invalidDevicePropValue  = 0x201C
    case invalidParameter      = 0x201D
    case sessionAlreadyOpen    = 0x201E
    case transactionCancelled  = 0x201F
    case accessDenied          = 0x200F

    public var description: String {
        String(format: "0x%04X", rawValue)
    }
}

/// Sony 常用设备属性码与控制码 (Device Property Code / Control Code, UInt16 LE)
public enum SonyPTPPropCode: UInt16, Sendable {
    // --- 标准 PTP 属性码 ---
    /// 白平衡模式 (UInt16 枚举，如 0x0002=Auto, 0x0004=Daylight, 0x8012=ColorTemp)
    case whiteBalance      = 0x5005
    /// 光圈值 F-Number (UInt16，实际值 × 100，例如 f/2.8 -> 280 = 0x0118)
    case fNumber           = 0x5007
    /// 拍摄曝光模式 Exposure Program Mode (SDI2: UInt16 / SDI3: UInt32，低 16 位对应 M/P/A/S/Movie/S&Q)
    case exposureProgramMode = 0x500E
    /// 曝光补偿 Exposure Bias Compensation (Int16，单位 1/1000 EV，如 -1000 = -1.0 EV, +300 = +0.3 EV)
    case exposureBias      = 0x5010

    // --- Sony 私有属性码 (0xD2xx) ---
    /// 快门速度 (UInt32: 高 16 位为分子，低 16 位为分母，如 1/125s -> 0x0001_007D)
    case shutterSpeed      = 0xD20D
    /// 精准色温值 Color Temperature (UInt16: 开尔文 K，2500...9900 步进 100K，如 5600K = 0x15E0)
    case colorTemperature  = 0xD20F
    /// 相机内存待传输照片数 ObjectInMemory (UInt16: 0x0000 = 无, >= 0x8000 = 有刚拍照片在 0xFFFFC001 待拉取)
    case objectInMemory    = 0xD215
    /// 录制状态只读属性 (UInt16: 0x0000 = 未录制, 0x0001 = 录制中)
    case recordingState    = 0xD21D
    /// ISO 感光度 (UInt32: 0x00FF_FFFF = Auto; 低 24 位为数值如 800 = 0x0000_0320)
    case isoSensitivity    = 0xD21E
    /// LiveView 使能状态 (UInt8: 0x00 = 关闭, 0x01 = 开启)
    case liveViewStatus    = 0xD221
    /// LiveView 图像画质档位 (UInt8: 0x01 = Low 低画质/省带宽, 0x02 = High 高画质/高分辨率)
    case liveViewImageQuality = 0xD26A
    /// 触控对焦 / 对焦点坐标 (UInt32: (X << 16) | Y，坐标系为 640×480: X∈0...639, Y∈0...479)
    case afAreaPosition    = 0xD2DC

    // --- Sony 私有瞬时控制码 (通过 0x9207 SDIO_ControlDevice 下发 UInt16: 0x0002=按下 / 0x0001=松开) ---
    /// 半按快门对焦 S1 (AF/AE Lock)
    case autoFocusS1       = 0xD2C1
    /// 全按快门拍照 S2
    case shutterReleaseS2  = 0xD2C2
    /// 视频录制按键触发 (按下 0x0002 -> 延迟 -> 松开 0x0001)
    case movieRecord       = 0xD2C8
}

/// Sony 虚拟对象句柄 (用于 0x1008 GetObjectInfo / 0x1009 GetObject / 0x100A GetThumb)
public enum SonyVirtualObjectHandle: UInt32, Sendable {
    /// 相机刚拍摄完成、驻留在内存缓冲区待传输的照片对象句柄 (`ObjectInMemory` 对应句柄)
    case capturedImage = 0xFFFF_C001
    /// LiveView 实时取景图像帧对象句柄 (含 Sony 私有头部 + 纯 JPEG 数据)
    case liveViewImage = 0xFFFF_C002

    public static let liveViewInfo: SonyVirtualObjectHandle = .capturedImage
}

/// Sony 按键控制状态值 (用于 0x9207 SDIO_ControlDevice 负载，UInt16 LE)
public enum SonyControlButtonState: UInt16, Sendable {
    case up   = 0x0001 // 释放/松开
    case down = 0x0002 // 按下/触发
}

/// Sony LiveView 图像画质挡位 (PropCode: 0xD26A, UInt8)
public enum SonyLiveViewImageQuality: UInt8, Sendable {
    case low  = 0x01 // 低画质（低分辨率、高压缩，Sony Wi-Fi 常见默认档）
    case high = 0x02 // 高画质（高分辨率、更高 JPEG 码率）
}

/// PTP 基础数据类型标识 (用于解析 0x9209 返回的 DevicePropDesc 二进制流)
public enum PTPDataType: UInt16, Sendable {
    case undefined = 0x0000
    case int8      = 0x0001
    case uint8     = 0x0002
    case int16     = 0x0003
    case uint16    = 0x0004
    case int32     = 0x0005
    case uint32    = 0x0006
    case int64     = 0x0007
    case uint64    = 0x0008
    case int128    = 0x0009
    case uint128   = 0x000A
    // 数组类型 (0x4000 | baseType)
    case arrayInt8   = 0x4001
    case arrayUInt8  = 0x4002
    case arrayInt16  = 0x4003
    case arrayUInt16 = 0x4004
    case arrayInt32  = 0x4005
    case arrayUInt32 = 0x4006
    case arrayInt64  = 0x4007
    case arrayUInt64 = 0x4008
    /// PTP Unicode 字符串 (1 字节字符数 + N × UTF-16LE，含末尾 0x0000)
    case string      = 0xFFFF
}

/// Sony 扩展协议版本号 (用于 0x9202 SDIO_GetExtDeviceInfo Param1)
public enum SonySDIOVersion: UInt32, Sendable {
    /// SDI2 (200): 老一代 BIONZ X 机型 (如 A7III / A6400)
    case v2 = 0x0000_00C8
    /// SDI3 (300): BIONZ XR 机型 (A6700 / A7IV / FX3 / ZV-E1)，支持 0xD2DC 触控对焦等新特性
    case v3 = 0x0000_012C
}

// MARK: - 2. 强类型业务模型与配置 (Swift 6 Sendable)

/// 连接配置
public struct SonyPTPIPConfig: Sendable {
    /// 相机 IP 地址
    /// - Wi-Fi (5GHz 热点直连) 默认常见为 "192.168.122.1"（或局域网路由器分配 IP）
    /// - USB-LAN (USB-C 转网口 / RNDIS / NCM) 为链路本地或手动配置的静态 IP
    public var host: String
    /// PTP/IP 标准端口，固定为 15740 (0x3D7C)
    public var port: UInt16
    /// 写入 Init_Command_Request 的客户端友好名称 (UTF-16LE)
    public var clientName: String
    /// 16 字节客户端唯一标识 GUID (建议持久化存储，避免相机反复弹出配对确认)
    public var clientGUID: UUID
    /// 可选：强制绑定网络接口类型
    /// - `.wifi` 强制走 Wi-Fi (5GHz)
    /// - `.wiredEthernet` 强制走 USB-LAN 有线网卡
    /// - `nil` 由 iOS 路由表自动选择
    public var requiredInterfaceType: NWInterface.InterfaceType?
    /// 优先协商的 Sony SDIO 协议版本，A6700 默认使用 SDI3 (0x012C)
    public var preferredSDIOVersion: SonySDIOVersion
    /// 单次建连或握手超时时间
    public var connectTimeout: Duration
    /// 是否输出十六进制收发包日志 (方便真机 Wireshark 抓包比对)
    public var enableHexPacketLogging: Bool

    public init(
        host: String,
        port: UInt16 = 15740,
        clientName: String = "CineView Pro",
        clientGUID: UUID = UUID(),
        requiredInterfaceType: NWInterface.InterfaceType? = nil,
        preferredSDIOVersion: SonySDIOVersion = .v3,
        connectTimeout: Duration = .seconds(8),
        enableHexPacketLogging: Bool = false
    ) {
        self.host = host
        self.port = port
        self.clientName = clientName
        self.clientGUID = clientGUID
        self.requiredInterfaceType = requiredInterfaceType
        self.preferredSDIOVersion = preferredSDIOVersion
        self.connectTimeout = connectTimeout
        self.enableHexPacketLogging = enableHexPacketLogging
    }
}

/// 握手完成后的会话元数据
public struct SonyPTPIPSessionInfo: Sendable {
    public let connectionNumber: UInt32
    public let cameraGUID: UUID
    public let cameraName: String
    public let responderProtocolVersion: UInt32
    public let negotiatedSDIOVersion: SonySDIOVersion
    public let sessionID: UInt32
}

/// ISO 感光度编码封装 (PropCode: 0xD21E, UInt32 LE)
/// - Auto ISO: `0x00FF_FFFF`
/// - 标准手动 ISO: 低 24 位直接存十进制值 (例: ISO 800 -> `0x0000_0320`)
/// - 扩展低感/高感: 最高字节为 `0x10` (例: 扩展 ISO 50 -> `0x1000_0032`)
public enum SonyISOValue: Equatable, Hashable, Sendable, CustomStringConvertible {
    case auto
    case manual(UInt32)
    case extended(UInt32)
    case raw(UInt32)

    public init(wireValue: UInt32) {
        if wireValue == 0x00FF_FFFF {
            self = .auto
        } else {
            let flag = (wireValue & 0xFF00_0000) >> 24
            let value = wireValue & 0x00FF_FFFF
            switch flag {
            case 0x00: self = .manual(value)
            case 0x10: self = .extended(value)
            default:   self = .raw(wireValue)
            }
        }
    }

    public var wireValue: UInt32 {
        switch self {
        case .auto:              return 0x00FF_FFFF
        case .manual(let iso):   return iso & 0x00FF_FFFF
        case .extended(let iso): return 0x1000_0000 | (iso & 0x00FF_FFFF)
        case .raw(let raw):      return raw
        }
    }

    public var description: String {
        switch self {
        case .auto:              return "ISO AUTO"
        case .manual(let iso):   return "ISO \(iso)"
        case .extended(let iso): return "ISO \(iso) (Ext)"
        case .raw(let raw):      return String(format: "ISO 0x%08X", raw)
        }
    }
}

/// 快门速度编码封装 (PropCode: 0xD20D, UInt32 LE)
/// - 编码规则: `(UInt32(numerator) << 16) | UInt32(denominator)`
///   - 例: `1/50s`  -> `numerator = 1, denominator = 50`  -> `0x0001_0032`
///   - 例: `1/125s` -> `numerator = 1, denominator = 125` -> `0x0001_007D`
///   - 例: `2.5"`   -> `numerator = 25, denominator = 10` -> `0x0019_000A`
///   - 例: `Bulb`   -> `0x0000_0000`
public struct SonyShutterSpeed: Equatable, Hashable, Sendable, CustomStringConvertible {
    public let numerator: UInt16
    public let denominator: UInt16

    public static let bulb = SonyShutterSpeed(numerator: 0, denominator: 0)
    public static let auto = SonyShutterSpeed(numerator: 0xFFFF, denominator: 0xFFFF)

    public init(numerator: UInt16, denominator: UInt16) {
        self.numerator = numerator
        self.denominator = denominator
    }

    /// 便捷构造分数快门，如 `.fraction(1, 100)` 表示 1/100s
    public static func fraction(_ numerator: UInt16, _ denominator: UInt16) -> SonyShutterSpeed {
        SonyShutterSpeed(numerator: numerator, denominator: denominator)
    }

    public init(wireValue: UInt32) {
        self.numerator = UInt16((wireValue >> 16) & 0xFFFF)
        self.denominator = UInt16(wireValue & 0xFFFF)
    }

    public var wireValue: UInt32 {
        (UInt32(numerator) << 16) | UInt32(denominator)
    }

    /// 曝光时长（秒），用于 Range 区间过滤与排序（Bulb/Auto 返回 nil）
    public var seconds: Double? {
        guard self != .bulb, self != .auto, denominator > 0 else { return nil }
        return Double(numerator) / Double(denominator)
    }

    public var description: String {
        if self == .bulb { return "BULB" }
        if self == .auto { return "AUTO" }
        if denominator == 1 { return "\(numerator)\"" }
        if numerator == 1 { return "1/\(denominator)" }
        if denominator == 10 {
            if numerator % 10 == 0 {
                return "\(numerator / 10)\""
            }
            return String(format: "%.1f\"", Double(numerator) / 10.0)
        }
        return "\(numerator)/\(denominator)"
    }

    /// Sony Alpha 标准 1/3 档全量快门表（用于 A6700 0xD20D 返回 Range [min..max] 时按实机范围裁剪）
    public static let sonyStandardThirdStopTable: [SonyShutterSpeed] = [
        .fraction(1, 8000), .fraction(1, 6400), .fraction(1, 5000), .fraction(1, 4000),
        .fraction(1, 3200), .fraction(1, 2500), .fraction(1, 2000), .fraction(1, 1600),
        .fraction(1, 1250), .fraction(1, 1000), .fraction(1, 800), .fraction(1, 640),
        .fraction(1, 500), .fraction(1, 400), .fraction(1, 320), .fraction(1, 250),
        .fraction(1, 200), .fraction(1, 160), .fraction(1, 125), .fraction(1, 100),
        .fraction(1, 80), .fraction(1, 60), .fraction(1, 50), .fraction(1, 40),
        .fraction(1, 30), .fraction(1, 25), .fraction(1, 20), .fraction(1, 15),
        .fraction(1, 13), .fraction(1, 10), .fraction(1, 8), .fraction(1, 6),
        .fraction(1, 5), .fraction(1, 4), .fraction(1, 3), .fraction(4, 10),
        .fraction(5, 10), .fraction(6, 10), .fraction(8, 10), .fraction(10, 10),
        .fraction(13, 10), .fraction(16, 10), .fraction(20, 10), .fraction(25, 10),
        .fraction(32, 10), .fraction(40, 10), .fraction(50, 10), .fraction(60, 10),
        .fraction(80, 10), .fraction(100, 10), .fraction(130, 10), .fraction(150, 10),
        .fraction(200, 10), .fraction(250, 10), .fraction(300, 10)
    ]
}

/// 光圈值 F-Number 编码封装 (PropCode: 0x5007, UInt16 LE)
/// - 编码规则: `UInt16(round(fStop * 100))`
///   - 例: `f/1.4` -> `140` (`0x008C`)
///   - 例: `f/2.8` -> `280` (`0x0118`)
///   - 例: `f/8.0` -> `800` (`0x0320`)
public struct SonyAperture: Equatable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public init(fStop: Double) {
        self.rawValue = UInt16(max(0, min(65535, Int((fStop * 100.0).rounded()))))
    }

    public var fStop: Double {
        Double(rawValue) / 100.0
    }

    public var description: String {
        if rawValue == 0 || rawValue == 0xFFFF { return "F--" }
        return String(format: "F%.1f", fStop)
    }

    /// Sony Alpha 标准 1/3 档光圈表（对照 libgphoto2 `sony_fnumbers[]`，用于 A6700 0x5007 返回 Range [min..max] 时精准裁剪当前镜头支持范围）
    public static let sonyStandardThirdStopTable: [SonyAperture] = [
        100, 110, 120, 140, 160, 170, 180, 200, 220, 250, 280, 320, 350,
        400, 450, 500, 560, 630, 710, 800, 900, 1000, 1100, 1300, 1400,
        1600, 1800, 2000, 2200, 2500, 2900, 3200, 3600, 4000, 4500, 5000, 5700, 6400
    ].map(SonyAperture.init(rawValue:))
}

/// 白平衡模式编码封装 (PropCode: 0x5005, UInt16 LE)
public enum SonyWhiteBalance: Equatable, Hashable, Sendable, CustomStringConvertible {
    case auto                    // 0x0002
    case daylight                // 0x0004
    case incandescent            // 0x0006
    case flash                   // 0x0007
    case fluorescentWarmWhite    // 0x8001
    case fluorescentCoolWhite    // 0x8002
    case fluorescentDayWhite     // 0x8003
    case fluorescentDaylight     // 0x8004
    case cloudy                  // 0x8010
    case shade                   // 0x8011
    case colorTempFilter         // 0x8012 (C.Temp./Filter, 色温由 0xD20F 控制)
    case custom1                 // 0x8020
    case custom2                 // 0x8021
    case custom3                 // 0x8022
    case underwaterAuto          // 0x8030
    case raw(UInt16)

    public init(wireValue: UInt16) {
        switch wireValue {
        case 0x0002: self = .auto
        case 0x0004: self = .daylight
        case 0x0006: self = .incandescent
        case 0x0007: self = .flash
        case 0x8001: self = .fluorescentWarmWhite
        case 0x8002: self = .fluorescentCoolWhite
        case 0x8003: self = .fluorescentDayWhite
        case 0x8004: self = .fluorescentDaylight
        case 0x8010: self = .cloudy
        case 0x8011: self = .shade
        case 0x8012: self = .colorTempFilter
        case 0x8020: self = .custom1
        case 0x8021: self = .custom2
        case 0x8022: self = .custom3
        case 0x8030: self = .underwaterAuto
        default:     self = .raw(wireValue)
        }
    }

    public var wireValue: UInt16 {
        switch self {
        case .auto:                 return 0x0002
        case .daylight:             return 0x0004
        case .incandescent:         return 0x0006
        case .flash:                return 0x0007
        case .fluorescentWarmWhite: return 0x8001
        case .fluorescentCoolWhite: return 0x8002
        case .fluorescentDayWhite:  return 0x8003
        case .fluorescentDaylight:  return 0x8004
        case .cloudy:               return 0x8010
        case .shade:                return 0x8011
        case .colorTempFilter:      return 0x8012
        case .custom1:              return 0x8020
        case .custom2:              return 0x8021
        case .custom3:              return 0x8022
        case .underwaterAuto:       return 0x8030
        case .raw(let value):       return value
        }
    }

    public var description: String {
        switch self {
        case .auto:                 return "AWB"
        case .daylight:             return "Daylight"
        case .incandescent:         return "Incandescent"
        case .flash:                return "Flash"
        case .fluorescentWarmWhite: return "Fluor Warm"
        case .fluorescentCoolWhite: return "Fluor Cool"
        case .fluorescentDayWhite:  return "Fluor DayWhite"
        case .fluorescentDaylight:  return "Fluor Daylight"
        case .cloudy:               return "Cloudy"
        case .shade:                return "Shade"
        case .colorTempFilter:      return "C.Temp/Filter"
        case .custom1:              return "Custom 1"
        case .custom2:              return "Custom 2"
        case .custom3:              return "Custom 3"
        case .underwaterAuto:       return "Underwater Auto"
        case .raw(let v):           return String(format: "WB 0x%04X", v)
        }
    }
}

/// 曝光补偿编码封装 (PropCode: 0x5010, Int16 LE，单位 1/1000 EV)
/// - Sony 标准 1/3 档步进示例：`-2000` (-2.0), `-1700` (-1.7), `-300` (-0.3), `0` (±0.0), `+300` (+0.3), `+1000` (+1.0)
public struct SonyExposureBias: Equatable, Hashable, Sendable, CustomStringConvertible {
    public let rawMilliEV: Int16

    public init(rawMilliEV: Int16) {
        self.rawMilliEV = rawMilliEV
    }

    public var ev: Double {
        Double(rawMilliEV) / 1000.0
    }

    public var description: String {
        if rawMilliEV == 0 { return "±0.0" }
        return String(format: "%+.1f", ev)
    }

    /// Sony A6700 标准 1/3 档曝光补偿表 (-3.0 EV ... +3.0 EV)
    public static let standardThirdStopPresets: [SonyExposureBias] = [
        -3000, -2700, -2300, -2000, -1700, -1300, -1000, -700, -300,
        0,
        300, 700, 1000, 1300, 1700, 2000, 2300, 2700, 3000
    ].map(SonyExposureBias.init(rawMilliEV:))
}

/// Sony 拍摄模式 / 曝光档位 (`0x500E` ExposureProgramMode)
/// - 参考 `libgphoto2` (`sony_exposure_program_32_modes` / `exposure_program_modes`)：
///   SDI3 (A6700 / BIONZ XR) 为 `UInt32`（如 `0x00020003` = A 档, `0x00078051` = 视频 A 档），
///   SDI2 为 `UInt16`（如 `0x0003` = A 档, `0x8051` = 视频 A 档），两者低 16 位编码完全一致。
public struct SonyExposureProgramMode: Equatable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public init(rawValue16: UInt16) {
        self.rawValue = UInt32(rawValue16)
    }

    /// 统一低 16 位模式码（兼容 SDI2 UInt16 与 SDI3 UInt32）
    public var modeCode: UInt16 {
        UInt16(rawValue & 0xFFFF)
    }

    /// 高 16 位分组/槽位码（仅 SDI3 UInt32 有效，例如 MR 记忆调出槽位或拍摄组别）
    public var groupCode: UInt16 {
        UInt16((rawValue >> 16) & 0xFFFF)
    }

    /// 是否处于视频 / S&Q / HFR 摄像模式
    public var isMovieMode: Bool {
        switch modeCode {
        case 0x8050...0x8054, 0x8059...0x805D, 0x8080...0x8088, 0x808A, 0x8090...0x8097:
            return true
        default:
            return false
        }
    }

    /// 档位短名称（如 `A`, `M`, `S`, `P`, `AUTO`, `1`, `2`, `3`, `MR`, `MOVIE M`, `S&Q M`）
    public var shortBadge: String {
        switch modeCode {
        case 0x0000: return "--"
        case 0x0001: return "M"
        case 0x0002: return "P"
        case 0x0003: return "A"
        case 0x0004: return "S"
        case 0x8000: return "AUTO"
        case 0x8001: return "AUTO+"
        case 0x8008: return "P·A"
        case 0x8009: return "P·S"
        case 0x8011...0x801C: return "SCN"
        case 0x8020:
            if (1...3).contains(groupCode) { return "\(groupCode)" }
            return "MR"
        case 0x8021: return "1"
        case 0x8022: return "2"
        case 0x8023: return "3"
        case 0x8024: return "M1"
        case 0x8025: return "M2"
        case 0x8026: return "M3"
        case 0x8027: return "M4"
        case 0x8040, 0x8041: return "PANO"
        case 0x8050: return "MOVIE P"
        case 0x8051: return "MOVIE A"
        case 0x8052: return "MOVIE S"
        case 0x8053: return "MOVIE M"
        case 0x8054: return "MOVIE AUTO"
        case 0x8059, 0x8084: return "S&Q P"
        case 0x805A, 0x8085: return "S&Q A"
        case 0x805B, 0x8086: return "S&Q S"
        case 0x805C, 0x8087: return "S&Q M"
        case 0x805D: return "S&Q AUTO"
        case 0x8080: return "HFR P"
        case 0x8081: return "HFR A"
        case 0x8082: return "HFR S"
        case 0x8083: return "HFR M"
        case 0x8088: return "MOVIE"
        case 0x8089: return "STILL"
        case 0x808A, 0x8090: return "MOVIE F"
        case 0x8091: return "S&Q F"
        case 0x8092: return "INT F"
        case 0x8093: return "INT P"
        case 0x8094: return "INT A"
        case 0x8095: return "INT S"
        case 0x8096: return "INT M"
        case 0x8097: return "INT AUTO"
        default:
            return String(format: "0x%04X", modeCode)
        }
    }

    /// 中文可读说明
    public var displayName: String {
        switch modeCode {
        case 0x0000: return "--"
        case 0x0001: return "M 手动曝光"
        case 0x0002: return "P 程序自动"
        case 0x0003: return "A 光圈优先"
        case 0x0004: return "S 快门优先"
        case 0x8000: return "AUTO 智能自动"
        case 0x8001: return "AUTO+ 增强自动"
        case 0x8011...0x801C: return "SCN 场景选择"
        case 0x8020:
            if (1...3).contains(groupCode) { return "调出存储 \(groupCode)" }
            return "MR 调出存储"
        case 0x8021: return "调出存储 1"
        case 0x8022: return "调出存储 2"
        case 0x8023: return "调出存储 3"
        case 0x8024: return "存储卡记忆 M1"
        case 0x8025: return "存储卡记忆 M2"
        case 0x8026: return "存储卡记忆 M3"
        case 0x8027: return "存储卡记忆 M4"
        case 0x8050: return "视频 P"
        case 0x8051: return "视频 A"
        case 0x8052: return "视频 S"
        case 0x8053: return "视频 M"
        case 0x8054: return "视频 AUTO"
        case 0x8059, 0x8084: return "S&Q P"
        case 0x805A, 0x8085: return "S&Q A"
        case 0x805B, 0x8086: return "S&Q S"
        case 0x805C, 0x8087: return "S&Q M"
        case 0x805D: return "S&Q AUTO"
        case 0x808A, 0x8090: return "视频灵活曝光"
        case 0x8091: return "S&Q 灵活曝光"
        default: return shortBadge
        }
    }

    public var description: String { shortBadge }

    /// 当前曝光档位从物理定义上是否允许手动调节光圈（`nil` 表示未知/灵活模式，以机身 isEnabled 为准）
    public var allowsManualAperture: Bool? {
        switch modeCode {
        case 0x0001, 0x0003,
             0x8051, 0x8053,
             0x805A, 0x805C, 0x8081, 0x8083, 0x8085, 0x8087,
             0x8094, 0x8096:
            return true
        case 0x0002, 0x0004,
             0x8000, 0x8001, 0x8011...0x801C, 0x8040, 0x8041,
             0x8050, 0x8052, 0x8054,
             0x8059, 0x805B, 0x805D, 0x8080, 0x8082, 0x8084, 0x8086,
             0x8093, 0x8095, 0x8097:
            return false
        default:
            return nil
        }
    }

    /// 当前曝光档位从物理定义上是否允许手动调节快门（`nil` 表示未知/灵活模式，以机身 isEnabled 为准）
    public var allowsManualShutter: Bool? {
        switch modeCode {
        case 0x0001, 0x0004,
             0x8052, 0x8053,
             0x805B, 0x805C, 0x8082, 0x8083, 0x8086, 0x8087,
             0x8095, 0x8096:
            return true
        case 0x0002, 0x0003,
             0x8000, 0x8001, 0x8011...0x801C, 0x8040, 0x8041,
             0x8050, 0x8051, 0x8054,
             0x8059, 0x805A, 0x805D, 0x8080, 0x8081, 0x8084, 0x8085,
             0x8093, 0x8094, 0x8097:
            return false
        default:
            return nil
        }
    }
}

/// 触控对焦归一化坐标 (0.0...1.0) -> 映射为 Sony LiveView 640×480 坐标系
public struct TouchFocusPoint: Equatable, Sendable {
    /// 归一化水平坐标，0.0 = 最左，1.0 = 最右
    public let x: Double
    /// 归一化垂直坐标，0.0 = 最上，1.0 = 最下
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = min(max(x, 0.0), 1.0)
        self.y = min(max(y, 0.0), 1.0)
    }

    /// 转换为 Sony 0xD2DC (AF Area Position) 协议要求的高低 16 位拼装值
    /// - 坐标系基准: X ∈ [0, 639], Y ∈ [0, 479]
    /// - Wire 编码: `(UInt32(pixelX) << 16) | UInt32(pixelY)` (随后按 UInt32 Little-Endian 发出)
    public func toSonyWireValue(width: UInt16 = 639, height: UInt16 = 479) -> UInt32 {
        let px = UInt16((x * Double(width)).rounded())
        let py = UInt16((y * Double(height)).rounded())
        return (UInt32(px) << 16) | UInt32(py)
    }
}

/// 单项 Sony 设备属性描述符 (从 0x9209 二进制块解析)
public struct SonyDevicePropertyDescriptor: Sendable {
    public let propertyCode: UInt16
    public let dataType: UInt16
    /// 0x00 = Get Only, 0x01 = Get/Set
    public let getSet: UInt8
    /// Sony 私有字段: 0x00 = Disabled, 0x01 = Enabled, 0x02 = DisplayOnly
    public let isEnabled: UInt8
    /// FormFlag: 0x00 = None, 0x01 = Range, 0x02 = Enumeration
    public let formFlag: UInt8
    /// 当前值的原始 Little-Endian 字节
    public let currentValueBytes: Data
    /// 默认值的原始 Little-Endian 字节
    public let defaultValueBytes: Data
    /// Range 最小值 / 最大值 / 步长 (当 formFlag == 0x01，如 A6700 的 F-Number 0x5007 & Shutter 0xD20D)
    public let rangeMinBytes: Data?
    public let rangeMaxBytes: Data?
    public let rangeStepBytes: Data?
    /// Enumeration List 1：该属性支持的全部候选值 (原始 LE 字节数组)
    public let supportedValuesBytes: [Data]
    /// Enumeration List 2 (Sony SDI3 / 2023+ 机型)：当前机身档位与当前镜头焦段下「实际可设置」的候选值
    public let settableValuesBytes: [Data]
    /// 是否实际解析到了第二张枚举表（若为 true 且 settableValuesBytes 为空，表示当前档位下 0 项可调，绝不回退到 List 1）
    public let hasSettableList: Bool

    /// 若存在第二张当前可用枚举表则严格使用它；否则使用 List 1 支持表
    public var activeEnumValuesBytes: [Data] {
        hasSettableList ? settableValuesBytes : supportedValuesBytes
    }

    public var uint16EnumValues: [UInt16] {
        activeEnumValuesBytes.compactMap { $0.count >= 2 ? $0.readUInt16LE(at: 0) : nil }
    }

    public var uint32EnumValues: [UInt32] {
        activeEnumValuesBytes.compactMap { $0.count >= 4 ? $0.readUInt32LE(at: 0) : nil }
    }

    public var rangeMinUInt16: UInt16? {
        guard let d = rangeMinBytes, d.count >= 2 else { return nil }
        return d.readUInt16LE(at: 0)
    }

    public var rangeMaxUInt16: UInt16? {
        guard let d = rangeMaxBytes, d.count >= 2 else { return nil }
        return d.readUInt16LE(at: 0)
    }

    public var rangeMinUInt32: UInt32? {
        guard let d = rangeMinBytes, d.count >= 4 else { return nil }
        return d.readUInt32LE(at: 0)
    }

    public var rangeMaxUInt32: UInt32? {
        guard let d = rangeMaxBytes, d.count >= 4 else { return nil }
        return d.readUInt32LE(at: 0)
    }

    public var uint8Value: UInt8? {
        currentValueBytes.count >= 1 ? currentValueBytes[currentValueBytes.startIndex] : nil
    }

    public var int8Value: Int8? {
        guard let u = uint8Value else { return nil }
        return Int8(bitPattern: u)
    }

    public var uint16Value: UInt16? {
        guard currentValueBytes.count >= 2 else { return nil }
        return currentValueBytes.readUInt16LE(at: 0)
    }

    public var int16Value: Int16? {
        guard let u = uint16Value else { return nil }
        return Int16(bitPattern: u)
    }

    public var uint32Value: UInt32? {
        guard currentValueBytes.count >= 4 else { return nil }
        return currentValueBytes.readUInt32LE(at: 0)
    }

    /// 按属性实际字节宽度自动读取无符号整数值（兼容 UInt8 / UInt16 / UInt32，例如 Sony 0xD21D 录制状态在部分固件为 UInt8、部分为 UInt16）
    public var unsignedIntValue: UInt32? {
        switch currentValueBytes.count {
        case 1: return uint8Value.map(UInt32.init)
        case 2: return uint16Value.map(UInt32.init)
        case 4...: return uint32Value
        default: return nil
        }
    }
}

    /// 相机常用曝光与状态快照
public struct CameraStateSnapshot: Sendable {
    public let iso: SonyISOValue?
    /// 当前机身/图像配置（如 S-Log3 最低原生 ISO 800）下实际可用的 ISO 列表 (来自 0x9209 属性 0xD21E)
    public let availableISOs: [SonyISOValue]
    /// nil 表示本次未解析到该属性描述符；true/false 表示相机明确回报是否可写
    public let isISOWritable: Bool?
    public let shutterSpeed: SonyShutterSpeed?
    /// 当前拍摄模式（如视频 24p/60p 档位）下实际可用的快门速度列表 (来自 0x9209 属性 0xD20D)
    public let availableShutterSpeeds: [SonyShutterSpeed]
    public let isShutterWritable: Bool?
    public let aperture: SonyAperture?
    /// 当前挂载镜头在当前焦段下实际支持调节的全部光圈档位 (来自 0x9209 属性 0x5007 动态枚举表)
    public let availableApertures: [SonyAperture]
    /// nil 表示未解析到 0x5007；false 表示相机明确回报不可电控（如手动镜头或实体光圈环未拧到 A）
    public let isApertureWritable: Bool?
    public let whiteBalance: SonyWhiteBalance?
    public let colorTemperature: UInt16?
    public let exposureBias: SonyExposureBias?
    /// 当前机身拍摄曝光档位 (来自 0x500E ExposureProgramMode，如 A / S / M / P / Movie M)
    public let exposureProgramMode: SonyExposureProgramMode?
    /// nil 表示本次 0x9209 未包含 0xD21D；true/false 表示相机明确回报录制状态 (0xD21D == 1)
    public let isRecording: Bool?
    public let isLiveViewEnabled: Bool
    /// 相机内存待拉取的新拍照片状态 (`0xD215`, >= 0x8000 表示 `0xFFFFC001` 有新照片就绪)
    public let objectInMemory: UInt16?
    /// 调试诊断摘要（记录 0x9209 返回字节数与解析属性个数，便于真机排查）
    public let diagnosticSummary: String
    public let rawProperties: [UInt16: SonyDevicePropertyDescriptor]
}

/// Sony 刚拍摄照片的 PTP ObjectInfo 元数据 (0x1008 GetObjectInfo)
public struct SonyCapturedObjectInfo: Sendable {
    public let handle: UInt32
    public let storageID: UInt32
    /// 0x3801 = JPEG, 0x3812 = HEIF, 0xB101 = Sony ARW RAW
    public let objectFormat: UInt16
    public let compressedSize: UInt32
    public let thumbFormat: UInt16
    public let thumbCompressedSize: UInt32
    public let imageWidth: UInt32
    public let imageHeight: UInt32
    public let filename: String
    public let captureDate: String

    public var formatDisplayName: String {
        switch objectFormat {
        case 0x3801: return "JPEG"
        case 0x3812: return "HEIF"
        case 0xB101: return "ARW"
        default:     return String(format: "0x%04X", objectFormat)
        }
    }
}

/// 通过 PTP/IP 拉取到的刚拍摄照片载荷与元数据
public struct SonyCapturedPhoto: Sendable {
    public let info: SonyCapturedObjectInfo
    public let imageData: Data
    public let thumbnailData: Data?
}

/// Sony / 标准 PTP 常用异步事件码
public enum SonyPTPEventCode: UInt16, Sendable {
    /// 标准 PTP: 新对象添加
    case objectAdded                 = 0x4002
    /// 标准 PTP: 设备属性变更
    case devicePropChanged           = 0x4006
    /// Sony 私有: 新对象添加 (如连拍/拍照完成)
    case sonyObjectAdded             = 0xC201
    /// Sony 私有: 设备属性变更 (用户转动实体光圈/快门/ISO/模式波轮时立刻触发)
    case sonyDevicePropChanged       = 0xC203
    /// Sony 私有: 镜头信息变更 (变焦导致最大光圈变化或更换镜头)
    case sonyLensInformationChanged  = 0xC21B
}

/// 异步事件通道收到的相机事件
public struct SonyPTPEvent: Sendable {
    public let eventCode: UInt16
    public let transactionID: UInt32
    public let parameters: [UInt32]
}

/// 错误定义
public enum SonyPTPIPError: Error, LocalizedError, Sendable {
    case notConnected
    case alreadyConnected
    case invalidPort(UInt16)
    case connectionFailed(String)
    case connectionClosed
    case timeout(String)
    case initFailed(reasonCode: UInt32)
    case unexpectedPacketType(expected: UInt32, actual: UInt32)
    case malformedPacket(String)
    case ptpOperationFailed(opCode: UInt16, responseCode: UInt16)
    case liveViewJPEGNotFound
    case propertyNotAvailable(UInt16)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "PTP/IP 客户端尚未连接相机。"
        case .alreadyConnected:
            return "PTP/IP 客户端已处于连接状态。"
        case .invalidPort(let port):
            return "无效的 TCP 端口: \(port)。"
        case .connectionFailed(let msg):
            return "TCP 连接失败: \(msg)"
        case .connectionClosed:
            return "相机已关闭 TCP 连接。"
        case .timeout(let stage):
            return "操作超时 (\(stage))。"
        case .initFailed(let reason):
            return String(format: "PTP/IP 握手被相机拒绝 (Init_Fail Reason: 0x%08X)。", reason)
        case .unexpectedPacketType(let expected, let actual):
            return String(format: "收到非预期 PTP/IP 包类型: 期望 0x%08X，实际 0x%08X。", expected, actual)
        case .malformedPacket(let msg):
            return "PTP/IP 数据包格式非法: \(msg)"
        case .ptpOperationFailed(let op, let resp):
            return String(format: "PTP 指令 0x%04X 执行失败，相机返回 ResponseCode: 0x%04X。", op, resp)
        case .liveViewJPEGNotFound:
            return "LiveView 数据包中未提取到有效的 JPEG 帧 (FF D8 ... FF D9)。"
        case .propertyNotAvailable(let code):
            return String(format: "相机未返回属性 0x%04X。", code)
        }
    }
}

// MARK: - 3. 原生 NWConnection 异步 TCP 通道封装 (零第三方库，Swift 6 并发安全)

/// 内部原始 PTP/IP 帧结构
struct PTPIPRawPacket: Sendable {
    /// Offset 0x04...0x07 的 PacketType (UInt32 LE)
    let typeRawValue: UInt32
    /// Offset 0x08 之后的载荷 (不含 8 字节公共包头)
    let payload: Data

    var packetType: PTPIPPacketType? {
        PTPIPPacketType(rawValue: typeRawValue)
    }
}

/// 防止 NWConnection.stateUpdateHandler 重复 resume Continuation 的线程安全盒
private final class OnceContinuation<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(throwing: error)
    }
}

/// 封装单条基于 NWConnection 的 PTP/IP TCP 链路 (分别实例化为指令通道 & 事件通道)
private actor PTPIPTCPChannel {
    private let name: String
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let logger: Logger
    private let enableHexLogging: Bool

    /// 内部 TCP 流式接收缓冲区，用于处理拆包与粘包
    private var receiveBuffer = Data()
    private var isClosed = false

    /// 单个 PTP/IP 包最大允许长度 (32 MB 安全上限，足以容纳 LiveView 与大属性表)
    private static let maxPacketLength = 96 * 1024 * 1024

    init(
        name: String,
        host: String,
        port: UInt16,
        requiredInterfaceType: NWInterface.InterfaceType?,
        enableHexLogging: Bool,
        logger: Logger
    ) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw SonyPTPIPError.invalidPort(port)
        }

        // 配置原生 TCP 参数：关闭 Nagle 算法 (TCP_NODELAY) 以压低 LiveView 帧间延迟
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 5
        tcpOptions.keepaliveInterval = 2
        tcpOptions.keepaliveCount = 3

        let params = NWParameters(tls: nil, tcp: tcpOptions)
        if let requiredInterfaceType {
            params.requiredInterfaceType = requiredInterfaceType
        }
        // 允许本地网络直连 (iOS 17+ 需在 Info.plist 配置 NSLocalNetworkUsageDescription)
        params.includePeerToPeer = false

        self.name = name
        self.queue = DispatchQueue(label: "com.cineviewpro.ptpip.\(name)", qos: .userInteractive)
        self.connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        self.enableHexLogging = enableHexLogging
        self.logger = logger
    }

    /// 异步建立 TCP 连接并等待 `.ready` 状态，支持超时取消
    func start(timeout: Duration) async throws {
        let conn = self.connection
        let q = self.queue

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    let once = OnceContinuation(cont)
                    conn.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            conn.stateUpdateHandler = nil
                            once.resume(returning: ())
                        case .failed(let error):
                            conn.stateUpdateHandler = nil
                            once.resume(throwing: SonyPTPIPError.connectionFailed(error.localizedDescription))
                        case .cancelled:
                            conn.stateUpdateHandler = nil
                            once.resume(throwing: SonyPTPIPError.connectionClosed)
                        case .waiting(let error):
                            // 等待网络就绪时不立刻失败，交由外层 timeout 兜底
                            _ = error
                        default:
                            break
                        }
                    }
                    conn.start(queue: q)
                }
            }

            group.addTask { [name] in
                try await Task.sleep(for: timeout)
                conn.cancel()
                throw SonyPTPIPError.timeout("TCP \(name) 通道建连超时")
            }

            try await group.next()
            group.cancelAll()
        }
    }

    /// 发送完整字节块 (已含 8 字节 PTP/IP 包头)
    func send(_ data: Data) async throws {
        guard !isClosed else { throw SonyPTPIPError.connectionClosed }

        if enableHexLogging {
            let preview = data.prefix(64).hexString
            logger.debug("[\(self.name, privacy: .public)] TX (\(data.count) B): \(preview, privacy: .public)")
        }

        let conn = self.connection
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: SonyPTPIPError.connectionFailed(error.localizedDescription))
                } else {
                    cont.resume(returning: ())
                }
            })
        }
    }

    /// 从 TCP 流中精确读取一个完整的 PTP/IP 协议包
    ///
    /// PTP/IP 公共包头 (固定 8 字节，Little-Endian):
    /// ```
    /// +--------+--------+--------+--------+--------+--------+--------+--------+
    /// | 0x00   | 0x01   | 0x02   | 0x03   | 0x04   | 0x05   | 0x06   | 0x07   |
    /// +--------+--------+--------+--------+--------+--------+--------+--------+
    /// |       Total Packet Length (UInt32 LE, 包含本 8 字节包头)                 |
    /// |                                   |       Packet Type (UInt32 LE)     |
    /// +-----------------------------------+-----------------------------------+
    /// ```
    /// 精确读取一个完整的 PTP/IP 协议包，支持可选超时防止 Wi-Fi 丢包死等
    /// - 注意：绝不因外部 Task 取消而中断进行中的 TCP 读包（避免残留半包导致整条指令通道永久错位）
    func readPacket(timeout: Duration? = nil) async throws -> PTPIPRawPacket {
        guard let timeout else {
            return try await readPacketUnbounded()
        }

        // 用独立的不可取消超时监控 Task，仅在真正超时时关闭连接释放挂起的 conn.receive
        let timerTask = Task { [weak self] in
            try await Task.sleep(for: timeout)
            await self?.close()
        }
        defer { timerTask.cancel() }

        do {
            return try await readPacketUnbounded()
        } catch {
            if timerTask.isCancelled == false && isClosed {
                throw SonyPTPIPError.timeout("TCP \(name) 通道读包超时")
            }
            throw error
        }
    }

    private func readPacketUnbounded() async throws -> PTPIPRawPacket {
        let header = try await readExact(byteCount: 8)
        let totalLength = Int(header.readUInt32LE(at: 0))
        let packetType = header.readUInt32LE(at: 4)

        guard totalLength >= 8, totalLength <= Self.maxPacketLength else {
            throw SonyPTPIPError.malformedPacket(
                String(format: "非法包长 %d (PacketType: 0x%08X)", totalLength, packetType)
            )
        }

        let payloadLength = totalLength - 8
        let payload = payloadLength > 0 ? try await readExact(byteCount: payloadLength) : Data()

        if enableHexLogging {
            let headHex = header.hexString
            let bodyHex = payload.prefix(48).hexString
            logger.debug("[\(self.name, privacy: .public)] RX (\(totalLength) B): \(headHex, privacy: .public) | \(bodyHex, privacy: .public)")
        }

        return PTPIPRawPacket(typeRawValue: packetType, payload: payload)
    }

    /// 精确读取指定字节数，自动处理 TCP 粘包与分片
    private func readExact(byteCount: Int) async throws -> Data {
        while receiveBuffer.count < byteCount {
            guard !isClosed else { throw SonyPTPIPError.connectionClosed }

            let needed = byteCount - receiveBuffer.count
            let maxRead = max(needed, 256 * 1024)
            let chunk = try await receiveChunk(maxLength: maxRead)
            receiveBuffer.append(chunk)
        }

        let result = Data(receiveBuffer.prefix(byteCount))
        receiveBuffer.removeFirst(byteCount)
        return result
    }

    private func receiveChunk(maxLength: Int) async throws -> Data {
        let conn = self.connection
        return try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: 1, maximumLength: maxLength) { content, _, isComplete, error in
                if let error {
                    cont.resume(throwing: SonyPTPIPError.connectionFailed(error.localizedDescription))
                } else if let content, !content.isEmpty {
                    cont.resume(returning: content)
                } else if isComplete {
                    cont.resume(throwing: SonyPTPIPError.connectionClosed)
                } else {
                    cont.resume(throwing: SonyPTPIPError.connectionClosed)
                }
            }
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        receiveBuffer.removeAll(keepingCapacity: false)
    }
}

// MARK: - 4. 核心 SonyPTPIPClient Actor

/// Sony A6700 纯原生 PTP/IP 客户端 (Swift 6 Actor，保证指令通道事务严格串行与无数据竞争)
public actor SonyPTPIPClient {
    private let config: SonyPTPIPConfig
    private let logger = Logger(subsystem: "com.cineviewpro.ptpip", category: "SonyPTPIPClient")

    /// 指令与数据通道 (TCP 15740 #1)
    private var commandChannel: PTPIPTCPChannel?
    /// 异步事件与保活通道 (TCP 15740 #2)
    private var eventChannel: PTPIPTCPChannel?
    /// 事件通道后台监听任务
    private var eventLoopTask: Task<Void, Never>?

    /// 当前会话信息
    public private(set) var sessionInfo: SonyPTPIPSessionInfo?
    /// 递增事务 ID (OpenSession 固定为 0，随后从 1 开始递增)
    private var nextTransactionID: UInt32 = 1

    /// 缓存最近一次 0x9209 解析出的属性表
    private var latestProperties: [UInt16: SonyDevicePropertyDescriptor] = [:]
    /// 自动探测并缓存当前机身接受的 0x9209 参数格式（SDI3 为 [0, 1] 或 [0, 0]，老固件为 []）
    private var cachedPropInfoParams: [UInt32]?

    /// 异步事件广播流管理
    private var eventContinuations: [UUID: AsyncStream<SonyPTPEvent>.Continuation] = [:]

    /// 严格非重入 FIFO 事务锁（防止 Swift Actor 在 await 处重入导致 Command TCP 通道多事务交错错乱）
    private var isTransactionInFlight: Bool = false
    private var transactionWaiters: [CheckedContinuation<Void, Never>] = []

    public init(config: SonyPTPIPConfig) {
        self.config = config
    }

    deinit {
        eventLoopTask?.cancel()
    }

    public var isConnected: Bool {
        sessionInfo != nil && commandChannel != nil && eventChannel != nil
    }

    // MARK: - 4.1 双通道握手、GUID 初始化与 Sony SDIO 激活

    /// 完整执行 A6700 的 PTP/IP 双通道握手与 Sony SDI3 初始化流程：
    /// 1. 建立 TCP 指令通道 (端口 15740) -> 发送 `Init_Command_Request (0x0001)` (含 16B GUID + UTF-16LE 客户端名)
    /// 2. 接收 `Init_Command_Ack (0x0002)` -> 提取 4B `ConnectionNumber` 与相机信息
    /// 3. 建立 TCP 事件通道 (端口 15740) -> 发送 `Init_Event_Request (0x0003)` (携带 `ConnectionNumber`)
    /// 4. 接收 `Init_Event_Ack (0x0004)` -> 启动后台事件监听与 `Probe_Request (0x000D)` 自动保活应答
    /// 5. 执行 PTP `OpenSession (0x1002)`
    /// 6. 执行 Sony SDIO 4 步握手：`0x9201(Phase 1)` -> `0x9201(Phase 2)` -> `0x9202(SDI3: 0x012C)` -> `0x9201(Phase 3)`
    @discardableResult
    public func connect() async throws -> SonyPTPIPSessionInfo {
        guard !isConnected else { throw SonyPTPIPError.alreadyConnected }

        do {
            // === STEP 1: 建立指令通道 (TCP 15740) ===
            let cmdChannel = try PTPIPTCPChannel(
                name: "Command",
                host: config.host,
                port: config.port,
                requiredInterfaceType: config.requiredInterfaceType,
                enableHexLogging: config.enableHexPacketLogging,
                logger: logger
            )
            try await cmdChannel.start(timeout: config.connectTimeout)
            self.commandChannel = cmdChannel

            // === STEP 2: 发送 Init_Command_Request (0x0000_0001) ===
            let initCmdPacket = Self.buildInitCommandRequestPacket(
                guid: config.clientGUID,
                friendlyName: config.clientName
            )
            try await cmdChannel.send(initCmdPacket)

            let initCmdAck = try await cmdChannel.readPacket()
            let ackInfo = try Self.parseInitCommandAck(initCmdAck)

            logger.info("Command 通道握手成功: ConnectionNumber=\(ackInfo.connectionNumber), Camera=\(ackInfo.cameraName, privacy: .public)")

            // === STEP 3: 建立事件通道 (第二条 TCP 15740) ===
            let evtChannel = try PTPIPTCPChannel(
                name: "Event",
                host: config.host,
                port: config.port,
                requiredInterfaceType: config.requiredInterfaceType,
                enableHexLogging: config.enableHexPacketLogging,
                logger: logger
            )
            try await evtChannel.start(timeout: config.connectTimeout)
            self.eventChannel = evtChannel

            // === STEP 4: 发送 Init_Event_Request (0x0000_0003) 绑定 ConnectionNumber ===
            let initEvtPacket = Self.buildInitEventRequestPacket(connectionNumber: ackInfo.connectionNumber)
            try await evtChannel.send(initEvtPacket)

            let initEvtAck = try await evtChannel.readPacket()
            try Self.validateInitEventAck(initEvtAck)

            logger.info("Event 通道握手成功 (ConnectionNumber=\(ackInfo.connectionNumber))")

            // 启动事件通道后台监听 + Probe 保活循环
            startEventChannelLoop(channel: evtChannel)

            // === STEP 5: 打开 PTP 会话 OpenSession (0x1002) ===
            // 规范要求 OpenSession 的 TransactionID 必须为 0x0000_0000，Param1 = SessionID (0x0000_0001)
            let sessionID: UInt32 = 0x0000_0001
            self.nextTransactionID = 1
            let openResp = try await performTransaction(
                opCode: .openSession,
                dataPhase: .noDataOrDataIn,
                parameters: [sessionID],
                explicitTransactionID: 0x0000_0000
            )
            guard openResp.responseCode == PTPResponseCode.ok.rawValue ||
                  openResp.responseCode == PTPResponseCode.sessionAlreadyOpen.rawValue else {
                throw SonyPTPIPError.ptpOperationFailed(
                    opCode: SonyPTPOpCode.openSession.rawValue,
                    responseCode: openResp.responseCode
                )
            }

            // === STEP 6: Sony SDIO 4 步私有握手 ===
            // 6.1 SDIO_Connect Phase 1: OpCode 0x9201, Params = [0x00000001, 0x00000000, 0x00000000]
            try await executeExpectOK(
                opCode: .sdioConnect,
                parameters: [0x0000_0001, 0x0000_0000, 0x0000_0000]
            )

            // 6.2 SDIO_Connect Phase 2: OpCode 0x9201, Params = [0x00000002, 0x00000000, 0x00000000]
            try await executeExpectOK(
                opCode: .sdioConnect,
                parameters: [0x0000_0002, 0x0000_0000, 0x0000_0000]
            )

            // 6.3 SDIO_GetExtDeviceInfo: OpCode 0x9202, Params = [0x0000012C (SDI3=300), 0x00000001]
            // 参考 libgphoto2 (ptp.c:4390): 必须传双参数 [0x012C, 1]，并读取返回载荷前 2 字节确认相机实际协商版本
            var negotiatedVersion = config.preferredSDIOVersion
            var extInfoResp = try await performTransaction(
                opCode: .sdioGetExtDeviceInfo,
                dataPhase: .noDataOrDataIn,
                parameters: [negotiatedVersion.rawValue, 0x0000_0001]
            )
            if extInfoResp.responseCode != PTPResponseCode.ok.rawValue {
                // 兼容仅接受单参数的旧机型
                extInfoResp = try await performTransaction(
                    opCode: .sdioGetExtDeviceInfo,
                    dataPhase: .noDataOrDataIn,
                    parameters: [negotiatedVersion.rawValue]
                )
            }
            if extInfoResp.responseCode != PTPResponseCode.ok.rawValue && negotiatedVersion == .v3 {
                logger.warning("相机拒绝 SDI3 (0x012C)，尝试回退至 SDI2 (0x00C8)")
                negotiatedVersion = .v2
                extInfoResp = try await performTransaction(
                    opCode: .sdioGetExtDeviceInfo,
                    dataPhase: .noDataOrDataIn,
                    parameters: [negotiatedVersion.rawValue]
                )
            }
            guard extInfoResp.responseCode == PTPResponseCode.ok.rawValue else {
                throw SonyPTPIPError.ptpOperationFailed(
                    opCode: SonyPTPOpCode.sdioGetExtDeviceInfo.rawValue,
                    responseCode: extInfoResp.responseCode
                )
            }
            // 读取相机实际回应的协议版本 (xdata[0..1] UInt16 LE: 0x012C = SDI3, 0x00C8 = SDI2)
            if extInfoResp.data.count >= 2 {
                let reportedVer = extInfoResp.data.readUInt16LE(at: 0)
                negotiatedVersion = (reportedVer >= 0x012C) ? .v3 : .v2
            }

            // 6.4 SDIO_Connect Phase 3: OpCode 0x9201, Params = [0x00000003, 0x00000000, 0x00000000]
            // 至此相机屏幕进入遥控拍摄就绪状态，LiveView 0xFFFFC002 与控制指令全部解锁
            try await executeExpectOK(
                opCode: .sdioConnect,
                parameters: [0x0000_0003, 0x0000_0000, 0x0000_0000]
            )

            let info = SonyPTPIPSessionInfo(
                connectionNumber: ackInfo.connectionNumber,
                cameraGUID: ackInfo.cameraGUID,
                cameraName: ackInfo.cameraName,
                responderProtocolVersion: ackInfo.protocolVersion,
                negotiatedSDIOVersion: negotiatedVersion,
                sessionID: sessionID
            )
            self.sessionInfo = info

            // 不再在握手阶段强行覆盖 0xD26A = High（Wi-Fi 下强开 High 会令单帧体积暴涨 3 倍、帧率腰斩）；
            // 保持机身默认最优 Wi-Fi 码率，由用户在界面按需切换 Low / High。

            // 首次同步一次属性快照，便于立即可用
            _ = try? await fetchCameraState()

            logger.info("Sony A6700 PTP/IP 初始化完成 (SDI 版本: 0x\(String(negotiatedVersion.rawValue, radix: 16)))")
            return info
        } catch {
            await disconnect()
            throw error
        }
    }

    /// 优雅断开连接并释放双通道 TCP 资源
    public func disconnect() async {
        if sessionInfo != nil, commandChannel != nil, !isTransactionInFlight {
            // 仅在通道空闲时尽力发送 CloseSession (0x1003)，避免断开重连被阻塞
            _ = try? await performTransaction(
                opCode: .closeSession,
                dataPhase: .noDataOrDataIn,
                parameters: []
            )
        }

        eventLoopTask?.cancel()
        eventLoopTask = nil

        await commandChannel?.close()
        await eventChannel?.close()
        commandChannel = nil
        eventChannel = nil
        sessionInfo = nil
        latestProperties.removeAll()
        cachedPropInfoParams = nil

        for (_, cont) in eventContinuations {
            cont.finish()
        }
        eventContinuations.removeAll()
    }

    /// 订阅相机事件通道推送的异步事件流
    public func events() -> AsyncStream<SonyPTPEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            self.eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventContinuation(id: id) }
            }
        }
    }

    private func removeEventContinuation(id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    private func broadcastEvent(_ event: SonyPTPEvent) {
        for (_, cont) in eventContinuations {
            cont.yield(event)
        }
    }

    // MARK: - 4.2 事件通道监听与 Probe 保活

    private func startEventChannelLoop(channel: PTPIPTCPChannel) {
        eventLoopTask?.cancel()
        eventLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let packet = try await channel.readPacket()
                    guard let self else { break }

                    switch packet.packetType {
                    case .event:
                        // Event Packet (0x0000_0008) 载荷布局:
                        // [0x00...0x01] EventCode     (UInt16 LE)
                        // [0x02...0x05] TransactionID (UInt32 LE)
                        // [0x06...]     Parameters    (0~3 个 UInt32 LE)
                        if let event = Self.parseEventPacket(packet.payload) {
                            await self.broadcastEvent(event)
                        }

                    case .probeRequest:
                        // 收到相机 Probe_Request (0x0000_000D)，立即回发 Probe_Response (0x0000_000E)
                        // 8 字节固定帧: [08 00 00 00] [0E 00 00 00]
                        let probeResp = Self.buildProbeResponsePacket()
                        try await channel.send(probeResp)

                    case .probeResponse:
                        break

                    default:
                        break
                    }
                } catch {
                    if !Task.isCancelled {
                        self?.logger.error("Event 通道监听退出: \(error.localizedDescription, privacy: .public)")
                    }
                    break
                }
            }
        }
    }

    // MARK: - 4.3 LiveView 实时取景流循环拉取与纯 JPEG 提取

    /// 启动 LiveView 实时取景流，持续向外部抛出已剥离 Sony 私有包头的纯 JPEG 图像 `Data`。
    ///
    /// - Parameter targetFPS: 目标拉取帧率上限（默认 30 fps；A6700 5GHz Wi-Fi / USB-LAN 实测可达 30~60 fps）。
    /// - Returns: 采用 `.bufferingNewest(1)` 背压策略的 `AsyncStream<Data>`，避免 UI 解码慢时积压延迟。
    /// - Note: 当消费端 `for await jpegData in stream` 退出或取消 Task 时，内部拉取循环会自动停止。
    public func liveViewStream(targetFPS: Double = 30.0) -> AsyncStream<Data> {
        let minFrameIntervalNanos = targetFPS > 0 ? UInt64(1_000_000_000.0 / targetFPS) : 0

        return AsyncStream<Data>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let pullTask = Task { [weak self] in
                let clock = ContinuousClock()
                var consecutiveErrors = 0

                while !Task.isCancelled {
                    guard let self else { break }
                    let frameStart = clock.now

                    do {
                        let jpegData = try await self.fetchSingleLiveViewJPEG()
                        consecutiveErrors = 0
                        continuation.yield(jpegData)
                    } catch is CancellationError {
                        break
                    } catch SonyPTPIPError.ptpOperationFailed(_, let code)
                        where code == PTPResponseCode.deviceBusy.rawValue ||
                              code == PTPResponseCode.invalidObjectHandle.rawValue {
                        try? await Task.sleep(for: .milliseconds(25))
                        continue
                    } catch SonyPTPIPError.liveViewJPEGNotFound {
                        try? await Task.sleep(for: .milliseconds(15))
                        continue
                    } catch {
                        consecutiveErrors += 1
                        self.logger.warning("LiveView 拉帧异常 (#\(consecutiveErrors)): \(error.localizedDescription, privacy: .public)")
                        let stillConnected = await self.isConnected
                        if consecutiveErrors >= 10 || !stillConnected {
                            break
                        }
                        try? await Task.sleep(for: .milliseconds(50))
                        continue
                    }

                    // 帧率节流控制，给控制指令留出指令通道间隙
                    if minFrameIntervalNanos > 0 {
                        let elapsed = frameStart.duration(to: clock.now)
                        let targetDuration = Duration.nanoseconds(Int64(minFrameIntervalNanos))
                        if elapsed < targetDuration {
                            try? await Task.sleep(for: targetDuration - elapsed)
                        }
                    }
                }

                continuation.finish()
            }

            continuation.onTermination = { _ in
                pullTask.cancel()
            }
        }
    }

    /// 拉取单帧 LiveView 图像并精确剥离 Sony 私有包头，返回纯 JPEG `Data` (SOI `FF D8` ... EOI `FF D9`)
    /// - 遵循 Sony BIONZ XR / libgphoto2 规范：先执行 `0x1008 GetObjectInfo(0xFFFFC002)` 刷新并确认帧就绪，
    ///   再执行 `0x1009 GetObject(0xFFFFC002)` 拉取该帧图像载荷。
    public func fetchSingleLiveViewJPEG() async throws -> Data {
        let infoResp = try await performTransaction(
            opCode: .getObjectInfo,
            dataPhase: .noDataOrDataIn,
            parameters: [SonyVirtualObjectHandle.liveViewImage.rawValue]
        )
        if infoResp.responseCode == PTPResponseCode.ok.rawValue {
            if infoResp.data.count >= 12 {
                let compressedSize = infoResp.data.readUInt32LE(at: 8)
                if compressedSize == 0 {
                    throw SonyPTPIPError.liveViewJPEGNotFound
                }
            }
        } else if infoResp.responseCode == PTPResponseCode.deviceBusy.rawValue ||
                  infoResp.responseCode == PTPResponseCode.invalidObjectHandle.rawValue {
            throw SonyPTPIPError.ptpOperationFailed(
                opCode: SonyPTPOpCode.getObjectInfo.rawValue,
                responseCode: infoResp.responseCode
            )
        }

        let response = try await performTransaction(
            opCode: .getObject,
            dataPhase: .noDataOrDataIn,
            parameters: [SonyVirtualObjectHandle.liveViewImage.rawValue]
        )

        guard response.responseCode == PTPResponseCode.ok.rawValue else {
            throw SonyPTPIPError.ptpOperationFailed(
                opCode: SonyPTPOpCode.getObject.rawValue,
                responseCode: response.responseCode
            )
        }

        return try Self.extractJPEGFromSonyLiveViewPayload(response.data)
    }

    /// 设置 LiveView 预览画质 (`0xD26A`, UInt8: `0x01` = Low, `0x02` = High)
    public func setLiveViewImageQuality(_ quality: SonyLiveViewImageQuality) async throws {
        let payload = Data([quality.rawValue])
        try await setExtDeviceProperty(.liveViewImageQuality, payload: payload)
    }

    /// 拉取相机刚拍摄并驻留在内存缓冲区 (`0xFFFFC001`) 的照片
    /// - 流程：`0x1008 GetObjectInfo(handle)` -> 解析文件名/尺寸/格式 -> （可选 `0x100A GetThumb`）-> `0x1009 GetObject(handle)`
    /// - 返回 `nil` 表示当前相机内存里没有待拉取的新拍照片（如返回 `0x2009 InvalidObjectHandle` 或长度为 0）
    public func fetchCapturedPhoto(
        handle: UInt32 = SonyVirtualObjectHandle.capturedImage.rawValue
    ) async throws -> SonyCapturedPhoto? {
        let infoResp = try await performTransaction(
            opCode: .getObjectInfo,
            dataPhase: .noDataOrDataIn,
            parameters: [handle],
            readTimeout: .seconds(8)
        )

        if infoResp.responseCode == PTPResponseCode.invalidObjectHandle.rawValue ||
           infoResp.responseCode == PTPResponseCode.generalError.rawValue {
            return nil
        }

        guard infoResp.responseCode == PTPResponseCode.ok.rawValue else {
            throw SonyPTPIPError.ptpOperationFailed(
                opCode: SonyPTPOpCode.getObjectInfo.rawValue,
                responseCode: infoResp.responseCode
            )
        }

        guard let info = Self.parseObjectInfo(infoResp.data, handle: handle),
              info.compressedSize > 0 else {
            return nil
        }

        // 若相机提供缩略图，顺带快速拉取作为兜底（失败不影响主图下载）
        var thumbData: Data?
        if info.thumbCompressedSize > 0 {
            if let thumbResp = try? await performTransaction(
                opCode: .getThumb,
                dataPhase: .noDataOrDataIn,
                parameters: [handle],
                readTimeout: .seconds(6)
            ), thumbResp.responseCode == PTPResponseCode.ok.rawValue, !thumbResp.data.isEmpty {
                thumbData = thumbResp.data
            }
        }

        // 执行 0x1009 GetObject 拉取完整图像载荷并自动清空相机 ObjectInMemory 队列
        let objResp = try await performTransaction(
            opCode: .getObject,
            dataPhase: .noDataOrDataIn,
            parameters: [handle],
            readTimeout: .seconds(25)
        )

        guard objResp.responseCode == PTPResponseCode.ok.rawValue else {
            throw SonyPTPIPError.ptpOperationFailed(
                opCode: SonyPTPOpCode.getObject.rawValue,
                responseCode: objResp.responseCode
            )
        }

        guard !objResp.data.isEmpty else {
            return nil
        }

        return SonyCapturedPhoto(info: info, imageData: objResp.data, thumbnailData: thumbData)
    }

    /// 解析标准 ISO 15740 PTP ObjectInfo 二进制数据集
    private static func parseObjectInfo(_ data: Data, handle: UInt32) -> SonyCapturedObjectInfo? {
        guard data.count >= 52 else { return nil }
        let storageID = data.readUInt32LE(at: 0)
        let objectFormat = data.readUInt16LE(at: 4)
        let compressedSize = data.readUInt32LE(at: 8)
        let thumbFormat = data.readUInt16LE(at: 12)
        let thumbCompressedSize = data.readUInt32LE(at: 14)
        let imageWidth = data.readUInt32LE(at: 26)
        let imageHeight = data.readUInt32LE(at: 30)

        var offset = 52
        let filename = readPTPString(from: data, offset: &offset)
        let captureDate = readPTPString(from: data, offset: &offset)

        return SonyCapturedObjectInfo(
            handle: handle,
            storageID: storageID,
            objectFormat: objectFormat,
            compressedSize: compressedSize,
            thumbFormat: thumbFormat,
            thumbCompressedSize: thumbCompressedSize,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            filename: filename.isEmpty ? "IMG_\(String(format: "%04X", handle & 0xFFFF)).JPG" : filename,
            captureDate: captureDate
        )
    }

    private static func readPTPString(from data: Data, offset: inout Int) -> String {
        guard offset < data.count else { return "" }
        let charCount = Int(data[offset])
        offset += 1
        guard charCount > 0 else { return "" }
        let byteCount = charCount * 2
        guard offset + byteCount <= data.count else {
            offset = data.count
            return ""
        }
        var units: [UInt16] = []
        units.reserveCapacity(charCount)
        for i in 0..<charCount {
            let u = data.readUInt16LE(at: offset + i * 2)
            if u != 0 { units.append(u) }
        }
        offset += byteCount
        return String(decoding: units, as: UTF16.self)
    }

    /// 精确剥离 Sony PTP LiveView (`0xFFFFC002`) 私有数据包头，提取纯 JPEG 图像 Data
    ///
    /// ### Sony PTP LiveView (`GetObject(0xFFFFC002)`) 数据段二进制结构：
    /// ```
    /// Offset (Hex) | Size | Type      | 说明
    /// -------------+------+-----------+--------------------------------------------------
    /// 0x00...0x03  | 4 B  | UInt32 LE | jpegOffset: JPEG 载荷起始偏移量 (常见为 0x000003F4=1012 或 0x00000008)
    /// 0x04...0x07  | 4 B  | UInt32 LE | jpegSize:   纯 JPEG 图像字节长度
    /// 0x08...      | Var  | Bytes     | Sony 私有元数据 / 对焦框 / OSD 扩展区 (⚠️ 内部可能含伪造 FF D8 字节！)
    /// [jpegOffset] | N B  | JPEG      | 真正的 JPEG 图像起始: FF D8 FF (E0/E1/DB) ... FF D9
    /// ```
    public static func extractJPEGFromSonyLiveViewPayload(_ rawPayload: Data) throws -> Data {
        guard rawPayload.count >= 8 else {
            throw SonyPTPIPError.liveViewJPEGNotFound
        }

        // 1. 优先按 Sony 官方 PTP LiveView 8 字节头 [offset: UInt32 LE][size: UInt32 LE] 精确切片
        let jpegOffset = Int(rawPayload.readUInt32LE(at: 0))
        let jpegSize   = Int(rawPayload.readUInt32LE(at: 4))

        if jpegOffset >= 8,
           jpegSize >= 4,
           jpegOffset + jpegSize <= rawPayload.count {
            let start = rawPayload.startIndex + jpegOffset
            let end   = start + jpegSize
            // 校验 JPEG 起始魔数 SOI (0xFF 0xD8)
            if rawPayload[start] == 0xFF && rawPayload[start + 1] == 0xD8 {
                return Data(rawPayload[start..<end])
            }
        }

        // 2. 兜底解析（兼容部分固件直接无头输出 JPEG 或扩展头偏移异常的场景）：
        // ⚠️ 避坑：不能盲目搜索第一个 FF D8（libgphoto2 已知 Sony 头部元数据里常含伪 FF D8），
        // 必须匹配严格 3~4 字节 JPEG SOI + 紧随标准段头 (FF D8 FF E0/E1/DB/FE/C0) 并定位末尾 FF D9。
        let bytes = [UInt8](rawPayload)
        let count = bytes.count
        var soiIndex: Int?

        // 如果 rawPayload 直接以标准 JPEG SOI+APP/DQT 开头则从 0 开始，否则跳过前 8 字节头再扫描
        let scanStart = (count >= 4 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) ? 0 : 8
        if scanStart < count - 4 {
            for i in scanStart..<(count - 3) {
                if bytes[i] == 0xFF && bytes[i + 1] == 0xD8 && bytes[i + 2] == 0xFF {
                    let marker = bytes[i + 3]
                    if marker == 0xE0 || marker == 0xE1 || marker == 0xDB || marker == 0xFE || marker == 0xC0 {
                        soiIndex = i
                        break
                    }
                }
            }
        }

        guard let startIdx = soiIndex else {
            throw SonyPTPIPError.liveViewJPEGNotFound
        }

        // 从尾部反向查找最后的 JPEG EOI 结束标记 (0xFF 0xD9)
        var eoiEndIndex = count
        if count >= startIdx + 4 {
            for i in stride(from: count - 2, through: startIdx + 2, by: -1) {
                if bytes[i] == 0xFF && bytes[i + 1] == 0xD9 {
                    eoiEndIndex = i + 2
                    break
                }
            }
        }

        return Data(bytes[startIdx..<eoiEndIndex])
    }

    // MARK: - 4.4 相机状态获取与常用控制指令封装

    /// 一次性拉取相机全部 Sony 扩展属性 (`0x9209 SDIO_GetAllExtDevicePropInfo`) 并解析常用参数快照
    /// - 参数探测顺序参考 `libgphoto2` (`ptp.c:4500`)：`[]` 优先，其次 `[0, 1]` / `[0, 0]` / `[0]`
    /// - 解析算法严格对照 `libgphoto2` (`ptp-pack.c:805-973`)：按单条属性动态判断是否存在第二张枚举表 (`nextWord < 0x200`)
    @discardableResult
    public func fetchCameraState() async throws -> CameraStateSnapshot {
        let candidateParamLists: [[UInt32]]
        if let cached = cachedPropInfoParams {
            candidateParamLists = [cached]
        } else {
            candidateParamLists = [
                [],                          // libgphoto2 标准：无参数 (A6700 / A7IV / A7RV 实测通用)
                [0x0000_0000, 0x0000_0001],  // 备选：Param1=0(全量), Param2=1(扩展)
                [0x0000_0000, 0x0000_0000],  // 备选：Param1=0, Param2=0
                [0x0000_0000]                // 备选：单参数
            ]
        }

        var chosenResp: PTPTransactionResult?
        for params in candidateParamLists {
            let attempt = try await performTransaction(
                opCode: .sdioGetAllExtDevicePropInfo,
                dataPhase: .noDataOrDataIn,
                parameters: params
            )
            if attempt.responseCode == PTPResponseCode.ok.rawValue && attempt.data.count > 8 {
                cachedPropInfoParams = params
                chosenResp = attempt
                break
            }
            chosenResp = attempt
        }

        guard let resp = chosenResp else {
            throw SonyPTPIPError.notConnected
        }
        guard resp.responseCode == PTPResponseCode.ok.rawValue else {
            throw SonyPTPIPError.ptpOperationFailed(
                opCode: SonyPTPOpCode.sdioGetAllExtDevicePropInfo.rawValue,
                responseCode: resp.responseCode
            )
        }

        let isSDI3 = (sessionInfo?.negotiatedSDIOVersion ?? .v3) == .v3
        let parseOutcome = Self.parseAllExtDevicePropInfo(resp.data)
        let props = parseOutcome.properties
        self.latestProperties = props

        // 解析当前曝光档位 0x500E (SDI3 为 UInt32 如 0x00020003=A，SDI2 为 UInt16 如 0x0003=A)
        let modeDesc = props[SonyPTPPropCode.exposureProgramMode.rawValue]
        let exposureMode: SonyExposureProgramMode? = {
            guard let desc = modeDesc else { return nil }
            if let u32 = desc.uint32Value {
                return SonyExposureProgramMode(rawValue: u32)
            }
            if let u16 = desc.uint16Value {
                return SonyExposureProgramMode(rawValue16: u16)
            }
            return nil
        }()

        // 参考 libgphoto2 (ptp-pack.c:822-874):
        // - SDI3 (mode 3): isEnabled == 1 且 getSet != 0 才可写；isEnabled == 0 (灰显) 或 2 (仅显示) 均为只读
        // - SDI2 (mode 2): isEnabled == 1 即视为可写（部分属性 getSet 为 0 但支持 0x9207 步进）
        func evaluateWritable(_ desc: SonyDevicePropertyDescriptor?) -> Bool? {
            guard let d = desc else { return nil }
            if isSDI3 {
                return d.isEnabled == 0x01 && d.getSet != 0x00
            } else {
                return d.isEnabled == 0x01
            }
        }

        let isoDesc = props[SonyPTPPropCode.isoSensitivity.rawValue]
        let iso = isoDesc?.uint32Value.map(SonyISOValue.init(wireValue:))
        let availableISOs: [SonyISOValue] = {
            guard let desc = isoDesc else { return [] }
            var seen = Set<UInt32>()
            return desc.uint32EnumValues
                .filter { $0 != 0 && seen.insert($0).inserted }
                .map(SonyISOValue.init(wireValue:))
        }()
        let isISOWritable: Bool? = evaluateWritable(isoDesc)

        let shutterDesc = props[SonyPTPPropCode.shutterSpeed.rawValue]
        let shutter = shutterDesc?.uint32Value.map(SonyShutterSpeed.init(wireValue:))
        let availableShutterSpeeds: [SonyShutterSpeed] = {
            guard let desc = shutterDesc else { return [] }
            var seen = Set<UInt32>()
            let enumVals = desc.uint32EnumValues
                .filter { seen.insert($0).inserted }
                .map(SonyShutterSpeed.init(wireValue:))
            if !enumVals.isEmpty {
                return enumVals
            }
            // A6700 实机 0xD20D 常为 FormFlag=0x01 Range [fastest..slowest]，按真实区间裁剪标准 1/3 档快门表
            if desc.formFlag == 0x01,
               let minWire = desc.rangeMinUInt32,
               let maxWire = desc.rangeMaxUInt32,
               let s1 = SonyShutterSpeed(wireValue: minWire).seconds,
               let s2 = SonyShutterSpeed(wireValue: maxWire).seconds {
                let lo = min(s1, s2) * 0.98
                let hi = max(s1, s2) * 1.02
                var list = SonyShutterSpeed.sonyStandardThirdStopTable.filter {
                    guard let sec = $0.seconds else { return false }
                    return sec >= lo && sec <= hi
                }
                if let cur = shutter, cur.seconds != nil, !list.contains(cur) {
                    list.append(cur)
                    list.sort { ($0.seconds ?? 0) < ($1.seconds ?? 0) }
                }
                return list
            }
            return []
        }()
        let rawShutterWritable = evaluateWritable(shutterDesc)
        let isShutterWritable: Bool? = {
            if exposureMode?.allowsManualShutter == false { return false }
            return rawShutterWritable
        }()

        let apertureDesc = props[SonyPTPPropCode.fNumber.rawValue]
        let aperture = apertureDesc?.uint16Value.map(SonyAperture.init(rawValue:))
        let availableApertures: [SonyAperture] = {
            guard let desc = apertureDesc else { return [] }
            var seen = Set<UInt16>()
            let enumVals = desc.uint16EnumValues
                .filter { $0 > 0 && $0 < 0xFFFF && seen.insert($0).inserted }
                .sorted()
                .map(SonyAperture.init(rawValue:))
            if !enumVals.isEmpty {
                return enumVals
            }
            // A6700 实机 0x5007 常为 FormFlag=0x01 Range [minF..maxF] (如 [280..2200] = F2.8~F22)
            // 严格按当前镜头在当前焦段的真实最小/最大光圈裁剪标准 1/3 档光圈表，绝不显示镜头不支持的光圈值
            if desc.formFlag == 0x01,
               let minRaw = desc.rangeMinUInt16,
               let maxRaw = desc.rangeMaxUInt16,
               minRaw > 0, maxRaw >= minRaw, maxRaw < 0xFFFF {
                var rawSet = Set<UInt16>()
                for preset in SonyAperture.sonyStandardThirdStopTable where preset.rawValue >= minRaw && preset.rawValue <= maxRaw {
                    rawSet.insert(preset.rawValue)
                }
                rawSet.insert(minRaw)
                rawSet.insert(maxRaw)
                if let cur = aperture, cur.rawValue >= minRaw, cur.rawValue <= maxRaw {
                    rawSet.insert(cur.rawValue)
                }
                return rawSet.sorted().map(SonyAperture.init(rawValue:))
            }
            return []
        }()
        let rawApertureWritable = evaluateWritable(apertureDesc)
        let isApertureWritable: Bool? = {
            if exposureMode?.allowsManualAperture == false { return false }
            return rawApertureWritable
        }()

        let wb = props[SonyPTPPropCode.whiteBalance.rawValue]?.uint16Value.map(SonyWhiteBalance.init(wireValue:))
        let colorTemp = props[SonyPTPPropCode.colorTemperature.rawValue]?.uint16Value
        let evBias = props[SonyPTPPropCode.exposureBias.rawValue]?.int16Value.map(SonyExposureBias.init(rawMilliEV:))
        // 0xD21D (MovieRecordingState): A6700/Sony PTP 为 UInt8 (1B) 或 UInt16 (2B)，0=待机, 1=录制中, 2=录制失败
        let recordingRaw = props[SonyPTPPropCode.recordingState.rawValue]?.unsignedIntValue
        let isRecording: Bool? = recordingRaw.map { $0 == 1 }
        let isLiveViewEnabled = (props[SonyPTPPropCode.liveViewStatus.rawValue]?.unsignedIntValue ?? 0) != 0
        let objectInMemory = props[SonyPTPPropCode.objectInMemory.rawValue]?.uint16Value

        func flagTag(_ desc: SonyDevicePropertyDescriptor?) -> String {
            guard let d = desc else { return "-" }
            let formTag: String
            switch d.formFlag {
            case 0x01: formTag = "Rng"
            case 0x02: formTag = d.hasSettableList ? "E2:\(d.settableValuesBytes.count)" : "E1:\(d.supportedValuesBytes.count)"
            default:   formTag = "None"
            }
            return "\(d.getSet)/\(d.isEnabled)/\(formTag)"
        }
        let modeLabel: String = {
            guard let m = exposureMode else { return "-" }
            return String(format: "%@(0x%08X)", m.shortBadge, m.rawValue)
        }()
        let recLabel = recordingRaw.map(String.init) ?? "-"
        let diagBase = "\(isSDI3 ? "SDI3" : "SDI2") 0x9209: \(resp.data.count)B, \(props.count)/\(parseOutcome.declaredCount)项 | 档位:\(modeLabel) REC:\(recLabel) | F:\(availableApertures.count)[\(flagTag(apertureDesc))] SS:\(availableShutterSpeeds.count)[\(flagTag(shutterDesc))] ISO:\(availableISOs.count)[\(flagTag(isoDesc))]"
        let diag = parseOutcome.stopReason.isEmpty ? diagBase : "\(diagBase) | \(parseOutcome.stopReason)"

        return CameraStateSnapshot(
            iso: iso,
            availableISOs: availableISOs,
            isISOWritable: isISOWritable,
            shutterSpeed: shutter,
            availableShutterSpeeds: availableShutterSpeeds,
            isShutterWritable: isShutterWritable,
            aperture: aperture,
            availableApertures: availableApertures,
            isApertureWritable: isApertureWritable,
            whiteBalance: wb,
            colorTemperature: colorTemp,
            exposureBias: evBias,
            exposureProgramMode: exposureMode,
            isRecording: isRecording,
            isLiveViewEnabled: isLiveViewEnabled,
            objectInMemory: objectInMemory,
            diagnosticSummary: diag,
            rawProperties: props
        )
    }

    // --- ISO (0xD21E, UInt32 LE) ---

    /// 获取当前 ISO 感光度
    public func getISO() async throws -> SonyISOValue {
        let state = try await fetchCameraState()
        guard let iso = state.iso else {
            throw SonyPTPIPError.propertyNotAvailable(SonyPTPPropCode.isoSensitivity.rawValue)
        }
        return iso
    }

    /// 修改 ISO 感光度 (通过 0x9205 SDIO_SetExtDevicePropValue 下发 4 字节 UInt32 LE)
    public func setISO(_ iso: SonyISOValue) async throws {
        var payload = Data(capacity: 4)
        payload.appendUInt32LE(iso.wireValue)
        try await setExtDeviceProperty(.isoSensitivity, payload: payload)
    }

    // --- 快门速度 Shutter Speed (0xD20D, UInt32 LE) ---

    /// 获取当前快门速度
    public func getShutterSpeed() async throws -> SonyShutterSpeed {
        let state = try await fetchCameraState()
        guard let shutter = state.shutterSpeed else {
            throw SonyPTPIPError.propertyNotAvailable(SonyPTPPropCode.shutterSpeed.rawValue)
        }
        return shutter
    }

    /// 修改快门速度 (通过 0x9205 下发 4 字节 UInt32 LE: `(numerator << 16) | denominator`)
    public func setShutterSpeed(_ shutterSpeed: SonyShutterSpeed) async throws {
        var payload = Data(capacity: 4)
        payload.appendUInt32LE(shutterSpeed.wireValue)
        try await setExtDeviceProperty(.shutterSpeed, payload: payload)
    }

    // --- 光圈值 F-Number (0x5007, UInt16 LE) ---

    /// 获取当前光圈值
    public func getAperture() async throws -> SonyAperture {
        let state = try await fetchCameraState()
        guard let aperture = state.aperture else {
            throw SonyPTPIPError.propertyNotAvailable(SonyPTPPropCode.fNumber.rawValue)
        }
        return aperture
    }

    /// 修改光圈值 (SDI3 通过 0x9205 直接设置，兼容 libgphoto2 的 UInt32 / UInt16 两种负载宽度)
    public func setAperture(_ aperture: SonyAperture) async throws {
        // 参考 libgphoto2 (config.c:4668): Sony SDI3 模式通过 0x9205 设置 0x5007 时部分固件要求 UInt32 (4B)，部分接受 UInt16 (2B)
        let reportedType = latestProperties[SonyPTPPropCode.fNumber.rawValue]?.dataType
        let prefer32 = (reportedType == PTPDataType.uint32.rawValue)

        var payload16 = Data(capacity: 2)
        payload16.appendUInt16LE(aperture.rawValue)
        var payload32 = Data(capacity: 4)
        payload32.appendUInt32LE(UInt32(aperture.rawValue))

        let firstPayload = prefer32 ? payload32 : payload16
        let fallbackPayload = prefer32 ? payload16 : payload32

        do {
            try await setExtDeviceProperty(.fNumber, payload: firstPayload)
        } catch SonyPTPIPError.ptpOperationFailed(_, let code)
            where code == PTPResponseCode.invalidDevicePropFormat.rawValue
               || code == PTPResponseCode.invalidDevicePropValue.rawValue
               || code == PTPResponseCode.generalError.rawValue {
            try await setExtDeviceProperty(.fNumber, payload: fallbackPayload)
        }
    }

    // --- 白平衡 White Balance (0x5005, UInt16 LE) ---

    /// 获取当前白平衡模式
    public func getWhiteBalance() async throws -> SonyWhiteBalance {
        let state = try await fetchCameraState()
        guard let wb = state.whiteBalance else {
            throw SonyPTPIPError.propertyNotAvailable(SonyPTPPropCode.whiteBalance.rawValue)
        }
        return wb
    }

    /// 修改白平衡模式 (通过 0x9205 下发 2 字节 UInt16 LE)
    public func setWhiteBalance(_ whiteBalance: SonyWhiteBalance) async throws {
        var payload = Data(capacity: 2)
        payload.appendUInt16LE(whiteBalance.wireValue)
        try await setExtDeviceProperty(.whiteBalance, payload: payload)
    }

    // --- 精准色温 Color Temperature (0xD20F, UInt16 LE: 2500...9900 K) ---

    /// 获取当前色温值 (K)
    public func getColorTemperature() async throws -> UInt16 {
        let state = try await fetchCameraState()
        guard let kelvin = state.colorTemperature else {
            throw SonyPTPIPError.propertyNotAvailable(SonyPTPPropCode.colorTemperature.rawValue)
        }
        return kelvin
    }

    /// 设置精准色温值 (2500K...9900K，步进 100K)
    /// - Parameter ensureColorTempMode: 是否先自动将白平衡切换至 `C.Temp./Filter (0x8012)`
    public func setColorTemperature(_ kelvin: UInt16, ensureColorTempMode: Bool = true) async throws {
        let clamped = min(max((kelvin / 100) * 100, 2500), 9900)
        if ensureColorTempMode {
            try? await setWhiteBalance(.colorTempFilter)
        }
        var payload = Data(capacity: 2)
        payload.appendUInt16LE(clamped)
        try await setExtDeviceProperty(.colorTemperature, payload: payload)
    }

    // --- 曝光补偿 Exposure Bias Compensation (0x5010, Int16 LE: 1/1000 EV) ---

    /// 获取当前曝光补偿
    public func getExposureBias() async throws -> SonyExposureBias {
        let state = try await fetchCameraState()
        guard let ev = state.exposureBias else {
            throw SonyPTPIPError.propertyNotAvailable(SonyPTPPropCode.exposureBias.rawValue)
        }
        return ev
    }

    /// 修改曝光补偿 (通过 0x9205 下发 2 字节 Int16 LE，如 -1000 = -1.0 EV, +300 = +0.3 EV)
    public func setExposureBias(_ bias: SonyExposureBias) async throws {
        var payload = Data(capacity: 2)
        payload.appendUInt16LE(UInt16(bitPattern: bias.rawMilliEV))
        try await setExtDeviceProperty(.exposureBias, payload: payload)
    }

    // --- 触控对焦坐标下发 Touch Focus (0xD2DC, UInt32 LE + 可选 S1 0xD2C1) ---

    /// 下发触控对焦坐标 (A6700 需处于支持坐标移动的对焦区域模式，如点/跟踪/区，且握手为 SDI3 0x012C)
    ///
    /// - Parameters:
    ///   - point: 归一化取景画面坐标 (`x: 0...1, y: 0...1`)，内部映射到 `640×480` 坐标系
    ///   - triggerHalfPressAF: 下发坐标后是否自动执行一次 S1 半按对焦 (`0xD2C1`: Down -> 延迟 -> Up)
    ///   - halfPressDuration: 半按对焦保持时长（默认 250ms）
    public func setTouchFocus(
        at point: TouchFocusPoint,
        triggerHalfPressAF: Bool = false,
        halfPressDuration: Duration = .milliseconds(250)
    ) async throws {
        // 坐标拼装: UInt32 = (UInt32(px) << 16) | UInt32(py)
        // 例: 画面正中心 (0.5, 0.5) -> px=320 (0x0140), py=240 (0x00F0) -> 0x0140_00F0
        // Little-Endian 字节序发出: [F0 00 40 01]
        var payload = Data(capacity: 4)
        payload.appendUInt32LE(point.toSonyWireValue())
        try await setExtDeviceProperty(.afAreaPosition, payload: payload)

        if triggerHalfPressAF {
            try await sendControlButton(.autoFocusS1, state: .down)
            try await Task.sleep(for: halfPressDuration)
            try await sendControlButton(.autoFocusS1, state: .up)
        }
    }

    // --- 视频录制启停 Movie Recording (0xD2C8 via 0x9207 ControlDevice + 0xD21D 状态校验) ---

    /// 模拟按下并释放实体 REC 键，切换视频录制启停 (`0x9207` ControlDevice, `Param1 = 0xD2C8`)
    public func toggleRecording(pressDuration: Duration = .milliseconds(80)) async throws {
        // 1. 按下 REC: Data-Out 负载 [02 00] (UInt16 LE = 0x0002)
        try await sendControlButton(.movieRecord, state: .down)
        try await Task.sleep(for: pressDuration)
        // 2. 释放 REC: Data-Out 负载 [01 00] (UInt16 LE = 0x0001)
        try await sendControlButton(.movieRecord, state: .up)
    }

    /// 幂等开始录制：先查询 `0xD21D` 录制状态，仅在未录制时触发 REC 按键
    public func startRecording() async throws {
        let state = try await fetchCameraState()
        guard state.isRecording != true else { return }
        try await toggleRecording()
    }

    /// 幂等停止录制：先查询 `0xD21D` 录制状态，仅在录制中时触发 REC 按键
    public func stopRecording() async throws {
        let state = try await fetchCameraState()
        guard state.isRecording != false else { return }
        try await toggleRecording()
    }

    // MARK: - 4.5 通用底层属性写入与按键控制辅助方法

    /// 通用 Sony 扩展属性设置 (`0x9205 SDIO_SetExtDevicePropValue`, Data-Out)
    public func setExtDeviceProperty(_ propCode: SonyPTPPropCode, payload: Data) async throws {
        let resp = try await performTransaction(
            opCode: .sdioSetExtDevicePropValue,
            dataPhase: .dataOut,
            parameters: [UInt32(propCode.rawValue)],
            outboundData: payload
        )
        guard resp.responseCode == PTPResponseCode.ok.rawValue else {
            throw SonyPTPIPError.ptpOperationFailed(
                opCode: SonyPTPOpCode.sdioSetExtDevicePropValue.rawValue,
                responseCode: resp.responseCode
            )
        }
    }

    /// 通用 Sony 按键/瞬时控制下发 (`0x9207 SDIO_ControlDevice`, Data-Out, 2 字节 UInt16 LE)
    public func sendControlButton(_ controlCode: SonyPTPPropCode, state: SonyControlButtonState) async throws {
        var payload = Data(capacity: 2)
        payload.appendUInt16LE(state.rawValue)

        let resp = try await performTransaction(
            opCode: .sdioControlDevice,
            dataPhase: .dataOut,
            parameters: [UInt32(controlCode.rawValue)],
            outboundData: payload
        )
        guard resp.responseCode == PTPResponseCode.ok.rawValue else {
            throw SonyPTPIPError.ptpOperationFailed(
                opCode: SonyPTPOpCode.sdioControlDevice.rawValue,
                responseCode: resp.responseCode
            )
        }
    }

    // MARK: - 4.6 PTP/IP 事务状态机引擎 (Request -> Data-Out / Data-In -> Response)

    private struct PTPTransactionResult: Sendable {
        let responseCode: UInt16
        let transactionID: UInt32
        let parameters: [UInt32]
        let data: Data
    }

    private func executeExpectOK(
        opCode: SonyPTPOpCode,
        parameters: [UInt32]
    ) async throws {
        let resp = try await performTransaction(
            opCode: opCode,
            dataPhase: .noDataOrDataIn,
            parameters: parameters
        )
        guard resp.responseCode == PTPResponseCode.ok.rawValue else {
            throw SonyPTPIPError.ptpOperationFailed(
                opCode: opCode.rawValue,
                responseCode: resp.responseCode
            )
        }
    }

    private func acquireTransactionLock() async {
        if !isTransactionInFlight {
            isTransactionInFlight = true
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            transactionWaiters.append(cont)
        }
    }

    private func releaseTransactionLock() {
        if !transactionWaiters.isEmpty {
            let next = transactionWaiters.removeFirst()
            next.resume()
        } else {
            isTransactionInFlight = false
        }
    }

    /// 在指令通道上执行一次完整的 PTP/IP 事务（受 FIFO 事务锁严格保护，且一旦发包即不可被外部 Task.cancel 截断，
    /// 彻底杜绝 TCP 流半途放弃导致的事务错位与 LiveView/0x9209 串包）
    private func performTransaction(
        opCode: SonyPTPOpCode,
        dataPhase: PTPIPDataPhaseInfo,
        parameters: [UInt32],
        outboundData: Data? = nil,
        explicitTransactionID: UInt32? = nil,
        readTimeout: Duration = .seconds(5)
    ) async throws -> PTPTransactionResult {
        await acquireTransactionLock()
        defer { releaseTransactionLock() }

        // 仅在尚未向 TCP 写入任何字节之前响应取消，绝不在发包后半途放弃读包！
        try Task.checkCancellation()

        guard let cmdChannel = self.commandChannel else {
            throw SonyPTPIPError.notConnected
        }

        let txID: UInt32
        if let explicitTransactionID {
            txID = explicitTransactionID
        } else {
            txID = nextTransactionID
            nextTransactionID = nextTransactionID == UInt32.max ? 1 : nextTransactionID + 1
        }

        // 在独立不可取消子任务中完成完整的一发一收，保证锁释放时指令通道必定处于干净边界
        let wireTask = Task<PTPTransactionResult, Error> {
            // 1. 发送 Operation_Request (0x0000_0006)
            let reqPacket = Self.buildOperationRequestPacket(
                dataPhase: dataPhase,
                opCode: opCode.rawValue,
                transactionID: txID,
                parameters: parameters
            )
            try await cmdChannel.send(reqPacket)

            // 2. 若为 Data-Out (主机 -> 相机)，按 CIPA 规范紧跟 Start_Data (0x0009) + End_Data (0x000C)
            if dataPhase == .dataOut, let outboundData {
                let startDataPacket = Self.buildStartDataPacket(
                    transactionID: txID,
                    totalDataLength: UInt64(outboundData.count)
                )
                try await cmdChannel.send(startDataPacket)

                let chunkSize = 64 * 1024
                if outboundData.count <= chunkSize {
                    let endPacket = Self.buildDataPacket(
                        type: .endData,
                        transactionID: txID,
                        chunk: outboundData
                    )
                    try await cmdChannel.send(endPacket)
                } else {
                    var offset = 0
                    while offset < outboundData.count {
                        let end = min(offset + chunkSize, outboundData.count)
                        let isLast = (end == outboundData.count)
                        let slice = outboundData.subdata(in: offset..<end)
                        let pkt = Self.buildDataPacket(
                            type: isLast ? .endData : .data,
                            transactionID: txID,
                            chunk: slice
                        )
                        try await cmdChannel.send(pkt)
                        offset = end
                    }
                }
            }

            // 3. 循环接收响应流，严格校验 TransactionID 一致性，自动忽略偶发迟到的旧事务残留包
            var inboundData = Data()
            var expectedInboundLength: UInt64?

            while true {
                let packet = try await cmdChannel.readPacket(timeout: readTimeout)

                switch packet.packetType {
                case .startData:
                    guard packet.payload.count >= 12 else {
                        throw SonyPTPIPError.malformedPacket("Start_Data 载荷不足 12 字节")
                    }
                    let pktTxID = packet.payload.readUInt32LE(at: 0)
                    guard pktTxID == txID else { continue }
                    let totalLen = packet.payload.readUInt64LE(at: 4)
                    expectedInboundLength = totalLen
                    inboundData.removeAll(keepingCapacity: true)
                    if totalLen > 0 && totalLen <= 16 * 1024 * 1024 {
                        inboundData.reserveCapacity(Int(totalLen))
                    }

                case .data:
                    guard packet.payload.count >= 4 else {
                        throw SonyPTPIPError.malformedPacket("Data 包载荷不足 4 字节")
                    }
                    let pktTxID = packet.payload.readUInt32LE(at: 0)
                    guard pktTxID == txID else { continue }
                    inboundData.append(packet.payload.dropFirst(4))

                case .endData:
                    guard packet.payload.count >= 4 else {
                        throw SonyPTPIPError.malformedPacket("End_Data 包载荷不足 4 字节")
                    }
                    let pktTxID = packet.payload.readUInt32LE(at: 0)
                    guard pktTxID == txID else { continue }
                    if packet.payload.count > 4 {
                        inboundData.append(packet.payload.dropFirst(4))
                    }
                    if let expected = expectedInboundLength, UInt64(inboundData.count) != expected {
                        self.logger.debug("Data-In 长度差异: 声明 \(expected) B，实收 \(inboundData.count) B")
                    }

                case .operationResponse:
                    guard packet.payload.count >= 6 else {
                        throw SonyPTPIPError.malformedPacket("Operation_Response 载荷不足 6 字节")
                    }
                    let responseCode = packet.payload.readUInt16LE(at: 0)
                    let respTxID = packet.payload.readUInt32LE(at: 2)
                    // 若收到旧事务迟到的 Response，丢弃继续等待本事务 (txID) 的真正 Response
                    guard respTxID == txID else {
                        inboundData.removeAll(keepingCapacity: true)
                        expectedInboundLength = nil
                        continue
                    }
                    var respParams: [UInt32] = []
                    var offset = 6
                    while offset + 4 <= packet.payload.count {
                        respParams.append(packet.payload.readUInt32LE(at: offset))
                        offset += 4
                    }
                    return PTPTransactionResult(
                        responseCode: responseCode,
                        transactionID: respTxID,
                        parameters: respParams,
                        data: inboundData
                    )

                case .cancel:
                    throw SonyPTPIPError.ptpOperationFailed(
                        opCode: opCode.rawValue,
                        responseCode: PTPResponseCode.transactionCancelled.rawValue
                    )

                default:
                    throw SonyPTPIPError.unexpectedPacketType(
                        expected: PTPIPPacketType.operationResponse.rawValue,
                        actual: packet.typeRawValue
                    )
                }
            }
        }

        return try await wireTask.value
    }
}

// MARK: - 5. 协议数据包构建与反序列化 (含完整十六进制字节偏移注释)

private extension SonyPTPIPClient {

    // MARK: 5.1 Init_Command_Request (0x0000_0001)

    /// 构造指令通道握手请求包 (`Init_Command_Request`)
    ///
    /// ### 二进制抓包对照布局 (全部 Little-Endian)：
    /// ```
    /// Offset          | Size     | Hex 示例                      | 字段说明
    /// ----------------+----------+-------------------------------+-----------------------------------------
    /// 0x00...0x03     | 4 B      | 36 00 00 00                   | Packet Length (整个包的总字节数)
    /// 0x04...0x07     | 4 B      | 01 00 00 00                   | Packet Type = 0x0000_0001
    /// 0x08...0x17     | 16 B     | XX XX ... XX (16 bytes)       | Initiator GUID (客户端唯一 16 字节标识)
    /// 0x18...(N-5)    | 2*(L+1)B | 43 00 69 00 ... 00 00         | Friendly Name (UTF-16LE + 0x0000 结束符)
    /// (N-4)...(N-1)   | 4 B      | 00 00 01 00                   | Protocol Version = 0x0001_0000 (PTP/IP 1.0)
    /// ```
    static func buildInitCommandRequestPacket(guid: UUID, friendlyName: String) -> Data {
        var payload = Data()

        // [0x08...0x17] 16 字节 Initiator GUID
        var uuidBytes = guid.uuid
        withUnsafeBytes(of: &uuidBytes) { rawBuf in
            payload.append(contentsOf: rawBuf)
        }

        // [0x18...] Friendly Name: UTF-16LE 编码，以 0x0000 双字节 Null 结尾
        for codeUnit in friendlyName.utf16 {
            payload.appendUInt16LE(codeUnit)
        }
        payload.appendUInt16LE(0x0000)

        // [尾部 4 字节] PTP/IP 协议版本: 0x0001_0000 -> 字节流 [00 00 01 00]
        payload.appendUInt32LE(0x0001_0000)

        return wrapPTPIPPacket(type: .initCommandRequest, payload: payload)
    }

    struct InitCommandAckInfo: Sendable {
        let connectionNumber: UInt32
        let cameraGUID: UUID
        let cameraName: String
        let protocolVersion: UInt32
    }

    /// 解析指令通道握手响应 (`Init_Command_Ack`, `0x0000_0002`)
    ///
    /// ### 二进制抓包对照布局 (Payload 从整包 Offset 0x08 开始)：
    /// ```
    /// Payload Offset  | 整包 Offset | Size | 字段说明
    /// ----------------+-------------+------+-------------------------------------------
    /// 0x00...0x03     | 0x08...0x0B | 4 B  | ConnectionNumber (UInt32 LE, 传给事件通道)
    /// 0x04...0x13     | 0x0C...0x1B | 16 B | Responder GUID (相机 16 字节 GUID)
    /// 0x14...(M-5)    | 0x1C...     | Var  | Responder Friendly Name (UTF-16LE + 0x0000)
    /// (M-4)...(M-1)   | 尾部 4 B     | 4 B  | Responder Protocol Version (0x0001_0000)
    /// ```
    static func parseInitCommandAck(_ packet: PTPIPRawPacket) throws -> InitCommandAckInfo {
        if packet.packetType == .initFail {
            let reason = packet.payload.count >= 4 ? packet.payload.readUInt32LE(at: 0) : 0
            throw SonyPTPIPError.initFailed(reasonCode: reason)
        }
        guard packet.packetType == .initCommandAck else {
            throw SonyPTPIPError.unexpectedPacketType(
                expected: PTPIPPacketType.initCommandAck.rawValue,
                actual: packet.typeRawValue
            )
        }
        // 最短长度 = 4 (ConnNum) + 16 (GUID) + 2 (空名 0x0000) + 4 (Version) = 26 字节
        guard packet.payload.count >= 26 else {
            throw SonyPTPIPError.malformedPacket("Init_Command_Ack 载荷过短 (\(packet.payload.count) B)")
        }

        let connNumber = packet.payload.readUInt32LE(at: 0)
        let guidData = packet.payload.subdata(in: 4..<20)
        let cameraGUID = UUID(data: guidData) ?? UUID()

        let versionOffset = packet.payload.count - 4
        let protocolVersion = packet.payload.readUInt32LE(at: versionOffset)

        let nameData = packet.payload.subdata(in: 20..<versionOffset)
        let cameraName = nameData.decodeNullTerminatedUTF16LE()

        return InitCommandAckInfo(
            connectionNumber: connNumber,
            cameraGUID: cameraGUID,
            cameraName: cameraName,
            protocolVersion: protocolVersion
        )
    }

    // MARK: 5.2 Init_Event_Request (0x0000_0003) & Ack (0x0000_0004)

    /// 构造事件通道握手请求包 (`Init_Event_Request`)，固定 12 字节 (`0x0C`)
    ///
    /// ### 二进制抓包对照布局：
    /// ```
    /// Offset      | Size | Hex 示例    | 字段说明
    /// ------------+------+-------------+---------------------------------------------
    /// 0x00...0x03 | 4 B  | 0C 00 00 00 | Packet Length = 12 (0x0000_000C)
    /// 0x04...0x07 | 4 B  | 03 00 00 00 | Packet Type   = 0x0000_0003
    /// 0x08...0x0B | 4 B  | XX XX XX XX | ConnectionNumber (来自 Init_Command_Ack)
    /// ```
    static func buildInitEventRequestPacket(connectionNumber: UInt32) -> Data {
        var payload = Data(capacity: 4)
        payload.appendUInt32LE(connectionNumber)
        return wrapPTPIPPacket(type: .initEventRequest, payload: payload)
    }

    /// 校验事件通道握手确认包 (`Init_Event_Ack`: `[08 00 00 00] [04 00 00 00]`)
    static func validateInitEventAck(_ packet: PTPIPRawPacket) throws {
        if packet.packetType == .initFail {
            let reason = packet.payload.count >= 4 ? packet.payload.readUInt32LE(at: 0) : 0
            throw SonyPTPIPError.initFailed(reasonCode: reason)
        }
        guard packet.packetType == .initEventAck else {
            throw SonyPTPIPError.unexpectedPacketType(
                expected: PTPIPPacketType.initEventAck.rawValue,
                actual: packet.typeRawValue
            )
        }
    }

    // MARK: 5.3 Operation_Request (0x0000_0006)

    /// 构造 PTP 操作请求包 (`Operation_Request`)
    ///
    /// ### 二进制抓包对照布局：
    /// ```
    /// Offset      | Size | Hex 示例 (以 GetObject 0xFFFFC002 为例) | 字段说明
    /// ------------+------+-------------------------------------------+------------------------------------
    /// 0x00...0x03 | 4 B  | 16 00 00 00                               | Packet Length = 18 + 4 * params.count
    /// 0x04...0x07 | 4 B  | 06 00 00 00                               | Packet Type   = 0x0000_0006
    /// 0x08...0x0B | 4 B  | 01 00 00 00                               | DataPhaseInfo = 0x01 (In/None) 或 0x02 (Out)
    /// 0x0C...0x0D | 2 B  | 09 10                                     | OperationCode = 0x1009 (UInt16 LE)
    /// 0x0E...0x11 | 4 B  | 0A 00 00 00                               | TransactionID (UInt32 LE)
    /// 0x12...0x15 | 4 B  | 02 C0 FF FF                               | Param1 = 0xFFFF_C002 (可选 0~5 个 UInt32 LE)
    /// ```
    static func buildOperationRequestPacket(
        dataPhase: PTPIPDataPhaseInfo,
        opCode: UInt16,
        transactionID: UInt32,
        parameters: [UInt32]
    ) -> Data {
        var payload = Data(capacity: 10 + parameters.count * 4)
        // [0x08...0x0B] Data Phase Info (UInt32 LE)
        payload.appendUInt32LE(dataPhase.rawValue)
        // [0x0C...0x0D] Operation Code (UInt16 LE)
        payload.appendUInt16LE(opCode)
        // [0x0E...0x11] Transaction ID (UInt32 LE)
        payload.appendUInt32LE(transactionID)
        // [0x12...]     Parameters (0~5 个 UInt32 LE)
        for param in parameters.prefix(5) {
            payload.appendUInt32LE(param)
        }
        return wrapPTPIPPacket(type: .operationRequest, payload: payload)
    }

    // MARK: 5.4 Start_Data (0x0000_0009) & Data/End_Data (0x0000_000A / 0x0000_000C)

    /// 构造 Data-Out 数据阶段起始包 (`Start_Data`), 固定 20 字节 (`0x14`)
    ///
    /// ### 二进制抓包对照布局：
    /// ```
    /// Offset      | Size | Hex 示例                | 字段说明
    /// ------------+------+-------------------------+-----------------------------------
    /// 0x00...0x03 | 4 B  | 14 00 00 00             | Packet Length   = 20 (0x0000_0014)
    /// 0x04...0x07 | 4 B  | 09 00 00 00             | Packet Type     = 0x0000_0009
    /// 0x08...0x0B | 4 B  | XX XX XX XX             | TransactionID   (UInt32 LE)
    /// 0x0C...0x13 | 8 B  | 04 00 00 00 00 00 00 00 | TotalDataLength (UInt64 LE)
    /// ```
    static func buildStartDataPacket(transactionID: UInt32, totalDataLength: UInt64) -> Data {
        var payload = Data(capacity: 12)
        payload.appendUInt32LE(transactionID)
        payload.appendUInt64LE(totalDataLength)
        return wrapPTPIPPacket(type: .startData, payload: payload)
    }

    /// 构造 Data (`0x0000_000A`) 或 End_Data (`0x0000_000C`) 载荷包
    ///
    /// ### 二进制抓包对照布局：
    /// ```
    /// Offset      | Size | Hex 示例    | 字段说明
    /// ------------+------+-------------+-----------------------------------------
    /// 0x00...0x03 | 4 B  | (12+N) LE   | Packet Length = 12 + chunk.count
    /// 0x04...0x07 | 4 B  | 0C 00 00 00 | Packet Type   = 0x000A (Data) / 0x000C (EndData)
    /// 0x08...0x0B | 4 B  | XX XX XX XX | TransactionID (UInt32 LE)
    /// 0x0C...     | N B  | ...         | 实际属性字节载荷 (如 ISO 4B / 光圈 2B)
    /// ```
    static func buildDataPacket(type: PTPIPPacketType, transactionID: UInt32, chunk: Data) -> Data {
        var payload = Data(capacity: 4 + chunk.count)
        payload.appendUInt32LE(transactionID)
        payload.append(chunk)
        return wrapPTPIPPacket(type: type, payload: payload)
    }

    // MARK: 5.5 Probe_Response (0x0000_000E) & Event (0x0000_0008)

    /// 构造 8 字节保活响应包: `[08 00 00 00] [0E 00 00 00]`
    static func buildProbeResponsePacket() -> Data {
        wrapPTPIPPacket(type: .probeResponse, payload: Data())
    }

    static func parseEventPacket(_ payload: Data) -> SonyPTPEvent? {
        guard payload.count >= 6 else { return nil }
        let eventCode = payload.readUInt16LE(at: 0)
        let txID = payload.readUInt32LE(at: 2)
        var params: [UInt32] = []
        var offset = 6
        while offset + 4 <= payload.count {
            params.append(payload.readUInt32LE(at: offset))
            offset += 4
        }
        return SonyPTPEvent(eventCode: eventCode, transactionID: txID, parameters: params)
    }

    /// 添加 8 字节公共包头: `[TotalLength: UInt32 LE][PacketType: UInt32 LE][Payload]`
    static func wrapPTPIPPacket(type: PTPIPPacketType, payload: Data) -> Data {
        let totalLength = UInt32(8 + payload.count)
        var packet = Data(capacity: Int(totalLength))
        packet.appendUInt32LE(totalLength)
        packet.appendUInt32LE(type.rawValue)
        packet.append(payload)
        return packet
    }

    // MARK: 5.6 Sony 0x9209 全量扩展属性表二进制解析器 (支持 SDI3 双枚举列表与严格边界校验)

    /// 解析 `0x9209 (SDIO_GetAllExtDevicePropInfo)` 返回的二进制属性表
    ///
    /// ### Sony 0x9209 二进制结构：
    /// ```
    /// [0x00...0x07] PropertyCount (UInt64 LE: 包含的属性描述符总个数)
    /// 紧随 PropertyCount 个 Sony DevicePropDesc 变长记录，每条记录结构：
    ///   - PropertyCode (UInt16 LE)  例: 0xD21E (ISO), 0xD20D (Shutter), 0x5007 (FNumber)
    ///   - DataType     (UInt16 LE)  例: 0x0004 (UInt16), 0x0006 (UInt32)
    ///   - GetSet       (UInt8)      0x00 = ReadOnly, 0x01 = GetSet
    ///   - IsEnable     (UInt8)      Sony 私有扩展字节 (标准 PTP 无此字段!)
    ///   - DefaultValue (按 DataType 定长或变长)
    ///   - CurrentValue (按 DataType 定长或变长)
    ///   - FormFlag     (UInt8):
    ///       0x00 = None
    ///       0x01 = Range (Min, Max, Step 三个同类型值)
    ///       0x02 = Enumeration:
    ///              - List 1: UInt16 Count1 + Count1 个值 (全部支持值)
    ///              - [仅 SDI3 / 0x012C 机型]: 紧跟 List 2: UInt16 Count2 + Count2 个值 (当前可用值)
    /// ```
    struct ExtPropParseOutcome: Sendable {
        let properties: [UInt16: SonyDevicePropertyDescriptor]
        let declaredCount: Int
        let stopReason: String
    }

    /// 严格对照 `libgphoto2` (`camlibs/ptp2/ptp-pack.c:805-973` `ptp_unpack_Sony_DPD`) 解析 `0x9209` 全量扩展属性表
    /// - 关键点：Sony 2023/2024+ SDI3 机型（A6700 / A7RV / ZV-E1）中，**并非所有** `FormFlag == 0x02` 属性都带有第二张枚举表！
    ///   必须在读取完 List 1 后窥视接下来的 2 字节 (`nextWord`)：
    ///   - 若 `nextWord < 0x200`，表示存在第二张“当前档位/当前镜头实际可设值”枚举表（`count2 = nextWord`，哪怕为 0 也须消费这 2 字节）；
    ///   - 否则 `nextWord` 就是下一条属性的 `DevicePropCode`（如 `0x5xxx` 或 `0xDxxx`），直接进入下一条解析。
    static func parseAllExtDevicePropInfo(_ data: Data) -> ExtPropParseOutcome {
        var result: [UInt16: SonyDevicePropertyDescriptor] = [:]
        guard data.count >= 8 else {
            return ExtPropParseOutcome(properties: result, declaredCount: 0, stopReason: "len<8")
        }

        // 8 字节计数头: [UInt32 count][UInt32 0] (兼容偶发 4 字节头)
        let lo32 = data.readUInt32LE(at: 0)
        let hi32 = data.readUInt32LE(at: 4)
        let totalCount = Int(lo32)
        var cursor = (hi32 == 0) ? 8 : 4
        var stopReason = ""
        var idx = 0

        while cursor + 6 <= data.count && idx < 4000 {
            let entryStart = cursor
            let propCode = data.readUInt16LE(at: cursor)
            let dataType = data.readUInt16LE(at: cursor + 2)
            let getSet   = data[data.startIndex + cursor + 4]
            let isEnable = data[data.startIndex + cursor + 5]
            cursor += 6

            guard let defaultBytes = readPTPValueBytes(from: data, dataType: dataType, cursor: &cursor),
                  let currentBytes = readPTPValueBytes(from: data, dataType: dataType, cursor: &cursor) else {
                let sample = data.subdata(in: entryStart..<min(entryStart + 14, data.count)).hexString
                stopReason = String(format: "val#\(idx)@\(entryStart) 0x%04X dt=0x%04X [%@]", propCode, dataType, sample)
                break
            }

            // 读取 FormFlag (严格越界保护)
            guard cursor < data.count else {
                result[propCode] = SonyDevicePropertyDescriptor(
                    propertyCode: propCode,
                    dataType: dataType,
                    getSet: getSet,
                    isEnabled: isEnable,
                    formFlag: 0x00,
                    currentValueBytes: currentBytes,
                    defaultValueBytes: defaultBytes,
                    rangeMinBytes: nil,
                    rangeMaxBytes: nil,
                    rangeStepBytes: nil,
                    supportedValuesBytes: [],
                    settableValuesBytes: [],
                    hasSettableList: false
                )
                break
            }
            let formFlag = data[data.startIndex + cursor]
            cursor += 1

            var rangeMinBytes: Data?
            var rangeMaxBytes: Data?
            var rangeStepBytes: Data?
            var supportedList: [Data] = []
            var settableList: [Data] = []
            var hasSettableList = false

            switch formFlag {
            case 0x00:
                // None: 无附加约束表单
                break

            case 0x01:
                // Range: Min, Max, Step (共 3 个同类型值 — A6700 的 F-Number 0x5007 与 Shutter 0xD20D 均使用 Range!)
                guard let rMin = readPTPValueBytes(from: data, dataType: dataType, cursor: &cursor),
                      let rMax = readPTPValueBytes(from: data, dataType: dataType, cursor: &cursor),
                      let rStep = readPTPValueBytes(from: data, dataType: dataType, cursor: &cursor) else {
                    stopReason = String(format: "rng#\(idx)@\(entryStart) 0x%04X dt=0x%04X", propCode, dataType)
                    return ExtPropParseOutcome(properties: result, declaredCount: totalCount, stopReason: stopReason)
                }
                rangeMinBytes = rMin
                rangeMaxBytes = rMax
                rangeStepBytes = rStep

            case 0x02:
                // Enumeration List 1 (全部支持值): UInt16 Count + N × Value
                guard cursor + 2 <= data.count else {
                    stopReason = String(format: "e1len#\(idx)@\(cursor) 0x%04X", propCode)
                    return ExtPropParseOutcome(properties: result, declaredCount: totalCount, stopReason: stopReason)
                }
                let count1 = Int(data.readUInt16LE(at: cursor))
                cursor += 2
                supportedList.reserveCapacity(min(count1, 512))
                for _ in 0..<count1 {
                    guard let valBytes = readPTPValueBytes(from: data, dataType: dataType, cursor: &cursor) else {
                        stopReason = String(format: "e1val#\(idx)@\(cursor) 0x%04X c1=\(count1)", propCode)
                        return ExtPropParseOutcome(properties: result, declaredCount: totalCount, stopReason: stopReason)
                    }
                    supportedList.append(valBytes)
                }

                // 关键：严格按 libgphoto2 (ptp-pack.c:932-966) 窥视下 2 字节判断是否紧跟第二张枚举表
                // 标准与 Sony 扩展属性码均在 0x5xxx / 0xDxxx 区间，故 < 0x200 必为 List 2 元素个数
                if cursor + 2 <= data.count {
                    let peekWord = data.readUInt16LE(at: cursor)
                    if peekWord < 0x0200 {
                        hasSettableList = true
                        let count2 = Int(peekWord)
                        cursor += 2
                        settableList.reserveCapacity(min(count2, 512))
                        for _ in 0..<count2 {
                            guard let valBytes = readPTPValueBytes(from: data, dataType: dataType, cursor: &cursor) else {
                                stopReason = String(format: "e2val#\(idx)@\(cursor) 0x%04X c2=\(count2)", propCode)
                                return ExtPropParseOutcome(properties: result, declaredCount: totalCount, stopReason: stopReason)
                            }
                            settableList.append(valBytes)
                        }
                    }
                }

            default:
                // 未知 FormFlag 时记录诊断并退出（避免错位污染后续条目）
                let sample = data.subdata(in: entryStart..<min(entryStart + 18, data.count)).hexString
                stopReason = String(format: "ff=0x%02X#\(idx)@\(entryStart) 0x%04X dt=0x%04X [%@]", formFlag, propCode, dataType, sample)
                return ExtPropParseOutcome(properties: result, declaredCount: totalCount, stopReason: stopReason)
            }

            result[propCode] = SonyDevicePropertyDescriptor(
                propertyCode: propCode,
                dataType: dataType,
                getSet: getSet,
                isEnabled: isEnable,
                formFlag: formFlag,
                currentValueBytes: currentBytes,
                defaultValueBytes: defaultBytes,
                rangeMinBytes: rangeMinBytes,
                rangeMaxBytes: rangeMaxBytes,
                rangeStepBytes: rangeStepBytes,
                supportedValuesBytes: supportedList,
                settableValuesBytes: settableList,
                hasSettableList: hasSettableList
            )
            idx += 1
        }

        return ExtPropParseOutcome(properties: result, declaredCount: totalCount, stopReason: stopReason)
    }

    /// 根据 PTP DataType 读取并推进游标，返回原始字节切片
    private static func readPTPValueBytes(from data: Data, dataType: UInt16, cursor: inout Int) -> Data? {
        let start = cursor
        guard skipPTPValue(in: data, dataType: dataType, cursor: &cursor) else { return nil }
        return data.subdata(in: start..<cursor)
    }

    /// 根据 PTP DataType 跳过单个值（定长标量、数组或 PTP Unicode 字符串）
    private static func skipPTPValue(in data: Data, dataType: UInt16, cursor: inout Int) -> Bool {
        // 1. PTP Unicode 字符串 (0xFFFF): 必须最先判断！因为 0xFFFF 的 bit14 也为 1，绝不可被 0x4000 数组分支误截
        //    结构：UInt8 字符数(含末尾 0x0000) + charCount × 2 字节 UTF-16LE
        if dataType == PTPDataType.string.rawValue {
            guard cursor < data.count else { return false }
            let charCount = Int(data[data.startIndex + cursor])
            cursor += 1
            let byteLen = charCount * 2
            guard cursor + byteLen <= data.count else { return false }
            cursor += byteLen
            return true
        }

        // 2. PTP 数组类型 (高 4 位严格为 0x4000，如 0x4001...0x400A): UInt32 元素个数 + N × 标量宽度
        if (dataType & 0xF000) == 0x4000 {
            guard cursor + 4 <= data.count else { return false }
            let elementCount = Int(data.readUInt32LE(at: cursor))
            cursor += 4
            let baseType = dataType & 0x0FFF
            guard let elemSize = scalarByteSize(for: baseType) else { return false }
            let totalBytes = elementCount * elemSize
            guard elementCount >= 0, cursor + totalBytes <= data.count else { return false }
            cursor += totalBytes
            return true
        }

        // 3. 定长标量类型
        guard let size = scalarByteSize(for: dataType), cursor + size <= data.count else {
            return false
        }
        cursor += size
        return true
    }

    private static func scalarByteSize(for dataType: UInt16) -> Int? {
        switch dataType {
        case 0x0001, 0x0002: return 1   // INT8 / UINT8
        case 0x0003, 0x0004: return 2   // INT16 / UINT16
        case 0x0005, 0x0006: return 4   // INT32 / UINT32
        case 0x0007, 0x0008: return 8   // INT64 / UINT64
        case 0x0009, 0x000A: return 16  // INT128 / UINT128
        default: return nil
        }
    }
}

// MARK: - 6. Data Little-Endian 字节读写与十六进制调试扩展

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func appendUInt64LE(_ value: UInt64) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    func readUInt16LE(at offset: Int) -> UInt16 {
        let base = startIndex + offset
        return UInt16(self[base])
            | (UInt16(self[base + 1]) << 8)
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        let base = startIndex + offset
        return UInt32(self[base])
            | (UInt32(self[base + 1]) << 8)
            | (UInt32(self[base + 2]) << 16)
            | (UInt32(self[base + 3]) << 24)
    }

    func readUInt64LE(at offset: Int) -> UInt64 {
        let lo = UInt64(readUInt32LE(at: offset))
        let hi = UInt64(readUInt32LE(at: offset + 4))
        return lo | (hi << 32)
    }

    func decodeNullTerminatedUTF16LE() -> String {
        var units: [UInt16] = []
        units.reserveCapacity(count / 2)
        var offset = 0
        while offset + 2 <= count {
            let unit = readUInt16LE(at: offset)
            if unit == 0x0000 { break }
            units.append(unit)
            offset += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

private extension UUID {
    init?(data: Data) {
        guard data.count == 16 else { return nil }
        let b = [UInt8](data)
        self.init(uuid: (
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
            b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]
        ))
    }
}

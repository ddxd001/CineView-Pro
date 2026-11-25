# CineView Pro

面向 **Sony A6700 (ILCE-6700 / BIONZ XR)** 打造的纯原生 **iOS 17+ / Swift 6** 专业电影监视器 App，零第三方依赖（严格基于 `SwiftUI`、`Network.framework`、`Metal` / `MetalKit`、`AVFoundation`）。

## 核心特性

### 1. Sony PTP/IP 协议栈 (`Sources/Protocol/SonyPTPIPClient.swift`)
- 基于原生 `NWConnection` 实现 TCP 端口 `15740` **双通道（指令通道 + 事件通道）** 握手、GUID 初始化、事件通道 `Probe` 保活及 **Sony SDIO v3 (`0x012C`)** 4 步初始化。
- 内置严格 **FIFO 非重入异步事务锁**，杜绝 Swift Actor 重入导致的 TCP 拆包错乱。
- 实时拉取 LiveView (`0xFFFFC002`)，精确剥离 Sony 私有头部并提取纯 JPEG 帧流（`AsyncStream<Data>`）。
- 完整封装常用相机参数读写与控制：**ISO (`0xD21E`)、快门速度 (`0xD20D`)、光圈 (`0x5007`)、白平衡 (`0x5005`)、触控对焦坐标下发 (`0xD2DC` + S1 `0xD2C1`)、视频录制启停 (`0xD2C8` / `0xD21D`)**。

### 2. 60fps Metal 专业渲染与并行计算管线 (`Sources/Rendering/`)
- **双源统一输入**：同时兼容 **iOS 17+ 外部 UVC HDMI 采集卡**（`AVCaptureDevice.DeviceType.external` -> `CVMetalTextureCache` 零拷贝 BGRA / 8-bit & 10-bit YCbCr）与 **Sony PTP/IP LiveView** 图像。
- **片元着色器专业工具 (`MonitorShaders.metal`)**：
  - **3D LUT 还原**：内置标准 `.cube` 解析器与 `RGBA16Float` 3D 纹理硬件三线性插值（支持 Sony S-Log3 -> Rec.709）。
  - **12 段专业假色 (False Color)**：Rec.709 亮度 0–100 IRE 标准伪色阶与左侧色标尺。
  - **峰值对焦 (Focus Peaking)**：3×3 Sobel 边缘检测算子，支持红/绿/黄配色与灵敏度调节。
  - **动态斑马纹 (Zebra)**：自定义 IRE 阈值过曝动态斜纹。
  - **变形镜头反挤压**：支持 `1.0x / 1.33x / 1.5x / 2.0x` 水平还原。
- **计算着色器并行示波器**：三缓冲零阻塞实时计算 **亮度波形图 (Waveform)** 与 **RGB + Luma 直方图**，支持 `Post-LUT / Log` 采样切换。
- **离线仿真信号源 (`TestPatternGenerator.swift`)**：内置 1280×720 动态 SMPTE 彩条、0–100 IRE 斜坡与旋转西门子星形对焦标板，可在 Mac iOS 模拟器直接验证全套管线。

### 3. Monitor+ 风格横屏全屏界面 (`Sources/UI/ContentView.swift`)
- 强制锁定横屏，自动隐藏系统状态栏与底部 Home 指示条，支持监看防息屏。
- 支持 **UVC 有线 / Wi-Fi / 混合双模（UVC 60fps 画面 + Wi-Fi 遥控）** 切换。
- 支持双指捏合缩放（1.0x–4.0x）、单指拖动巡检、精准反算缩放与反挤压坐标的**单击触控对焦**。
- 顶部悬浮曝光参数胶囊与底部横向快捷滚轮、可拖动示波器浮窗、安全框（`2.39:1 / 16:9 / 9:16`）。

---

## 目录结构

```text
CineView-Pro/
├── CineViewPro.xcodeproj/          # Xcode 工程（默认 Release 运行方案）
├── Sources/
│   ├── App/
│   │   ├── CineViewProApp.swift    # SwiftUI App 入口与横屏锁定适配器
│   │   └── Info.plist              # 相机/本地网络/横屏/.cube 文件类型配置
│   ├── Protocol/
│   │   └── SonyPTPIPClient.swift   # Sony A6700 PTP/IP 双通道协议实现
│   ├── Rendering/
│   │   ├── MonitorRenderer.swift   # MetalKit 60fps 渲染引擎与 .cube LUT 解析
│   │   ├── MonitorShaders.metal    # 片元着色器 + Compute 示波器核函数
│   │   └── TestPatternGenerator.swift # 模拟器动态测试信号与演示 LUT
│   └── UI/
│       └── ContentView.swift       # Monitor+ 风格横屏主界面与手势系统
├── .gitignore
└── README.md
```

---

## 编译与运行

1. 环境要求：**Xcode 16+**、**iOS 17.0+**（真机推荐带 USB-C 接口的 iPhone 15 Pro / 16 Pro / 17 Pro 系列或 iPad）。
2. 打开 `CineViewPro.xcodeproj`，在 `Signing & Capabilities` 中选择你的 Apple Developer Team 并修改 `Bundle Identifier`。
3. 连接真机按 `⌘ + R` 编译安装（或在 iOS 模拟器运行后点击「启动测试信号」体验全套监看功能）。

### Sony A6700 Wi-Fi Direct 5GHz 连接设置
1. `MENU` → `🌐（网络）` → `Wi-Fi` → `Wi-Fi频带` → **`5GHz`**
2. `MENU` → `🌐（网络）` → `网络选项` → `访问身份验证设置` → `访问身份验证` → **`关`**
3. `MENU` → `🌐（网络）` → `连接/电脑遥控` → `电脑遥控功能` → `电脑遥控` → **`开`**
4. 点击 `Wi-Fi Direct信息`，手机连接相机热点后，在 App 中选择 **Wi-Fi** 模式（默认 IP `192.168.122.1`）连接即可。

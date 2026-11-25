//
//  MonitorSettingsDrawer.swift
//  CineView Pro
//
//  右侧滑出式专业设置与监看工具面板（边调边实时监看左侧图传画面）
//

import SwiftUI

public enum SettingsDrawerTab: String, CaseIterable, Sendable, Identifiable {
    case assist  = "监看辅助"
    case frame   = "构图变换"
    case connect = "连接诊断"

    public var id: String { rawValue }
}

struct MonitorSettingsDrawer: View {
    @Bindable var vm: MonitorViewModel
    @Binding var selectedTab: SettingsDrawerTab
    let trailingInset: CGFloat
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 顶部标题栏
            HStack {
                Text("设置与监看")
                    .font(.robotoFlex(size: 14, weight: 700))
                    .foregroundStyle(.white)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            // 3 分类 Tab 切换栏
            HStack(spacing: 6) {
                ForEach(SettingsDrawerTab.allCases) { tab in
                    let isSelected = selectedTab == tab
                    Button {
                        withAnimation(.snappy(duration: 0.18)) {
                            selectedTab = tab
                        }
                    } label: {
                        Text(tab.rawValue)
                            .font(.robotoFlex(size: 11.5, weight: isSelected ? 700 : 500))
                            .foregroundStyle(isSelected ? .black : .white.opacity(0.72))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(
                                isSelected ? MonitorTheme.accentAmber : Color.white.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: MonitorTheme.chipRadius, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            Divider()
                .background(Color.white.opacity(0.10))

            // 内容滚动区
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    switch selectedTab {
                    case .assist:
                        assistToolsContent
                    case .frame:
                        frameAndTransformContent
                    case .connect:
                        connectionAndDiagnosticsContent
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
        .padding(.trailing, trailingInset)
        .background(MonitorTheme.drawerBackground.opacity(0.95))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(width: 0.6)
        }
    }

    // MARK: - Tab 1: 监看辅助 (LUT / 示波器 / 假色 / 峰值 / 斑马纹)

    private var assistToolsContent: some View {
        VStack(spacing: 10) {
            // 1. 3D LUT
            settingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("3D LUT 色彩还原")
                                .font(.robotoFlex(size: 12.5, weight: 650))
                                .foregroundStyle(.white)
                            if let name = vm.loadedLUTName {
                                Text(name)
                                    .font(.robotoFlex(size: 10.5, weight: 450))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Toggle("", isOn: $vm.renderSettings.isLUTEnabled)
                            .labelsHidden()
                            .tint(MonitorTheme.accentAmber)
                    }

                    // 导入 + 本地收藏横向切换
                    HStack(spacing: 6) {
                        Button {
                            vm.isLUTImporterPresented = true
                        } label: {
                            Label("导入 .cube", systemImage: "folder.badge.plus")
                                .font(.robotoFlex(size: 11, weight: 650))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(MonitorTheme.accentAmber, in: Capsule())
                        }
                        .buttonStyle(.plain)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                let demoActive = vm.activeSavedLUTID == nil && vm.renderSettings.isLUTEnabled
                                Button("演示 LUT") {
                                    vm.activeSavedLUTID = nil
                                    vm.loadBuiltInDemoLUT()
                                }
                                .font(.robotoFlex(size: 11, weight: demoActive ? 700 : 500))
                                .foregroundStyle(demoActive ? .black : .white.opacity(0.85))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(demoActive ? MonitorTheme.accentAmber : Color.white.opacity(0.10), in: Capsule())
                                .buttonStyle(.plain)

                                ForEach(vm.savedLUTs) { item in
                                    let isCurrent = vm.activeSavedLUTID == item.id && vm.renderSettings.isLUTEnabled
                                    HStack(spacing: 4) {
                                        Button(item.displayName) {
                                            vm.selectSavedLUT(item)
                                        }
                                        .font(.robotoFlex(size: 11, weight: isCurrent ? 700 : 500))
                                        .foregroundStyle(isCurrent ? .black : .white.opacity(0.85))
                                        .lineLimit(1)
                                        .buttonStyle(.plain)

                                        Button {
                                            vm.deleteSavedLUT(item)
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 8, weight: .bold))
                                                .foregroundStyle(isCurrent ? .black.opacity(0.7) : .white.opacity(0.5))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(isCurrent ? MonitorTheme.accentAmber : Color.white.opacity(0.10), in: Capsule())
                                }
                            }
                        }
                    }

                    // LUT 混合强度
                    HStack(spacing: 8) {
                        Text("强度")
                            .font(.robotoFlex(size: 11, weight: 500))
                            .foregroundStyle(.white.opacity(0.6))
                        Slider(value: $vm.renderSettings.lutIntensity, in: 0...1)
                            .tint(MonitorTheme.accentAmber)
                        Text("\(Int(vm.renderSettings.lutIntensity * 100))%")
                            .font(.robotoFlex(size: 11, weight: 600))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 36, alignment: .trailing)
                    }
                }
            }

            // 2. 实时示波器
            settingsCard {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("专业示波器浮窗")
                            .font(.robotoFlex(size: 12.5, weight: 650))
                            .foregroundStyle(.white)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { vm.isScopesVisible },
                            set: { newValue in
                                withAnimation(.snappy(duration: 0.2)) {
                                    vm.isScopesVisible = newValue
                                    vm.renderSettings.isScopesEnabled = newValue
                                }
                            }
                        ))
                        .labelsHidden()
                        .tint(MonitorTheme.accentAmber)
                    }

                    if vm.isScopesVisible {
                        HStack(spacing: 5) {
                            ForEach(ScopeDisplayMode.allCases, id: \.self) { m in
                                let selected = vm.scopeDisplayMode == m
                                Button(m.rawValue) {
                                    vm.scopeDisplayMode = m
                                }
                                .font(.robotoFlex(size: 10.5, weight: selected ? 700 : 500))
                                .foregroundStyle(selected ? .black : .white.opacity(0.78))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .background(selected ? MonitorTheme.accentAmber : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .buttonStyle(.plain)
                            }
                        }

                        HStack {
                            Text("信号采样源")
                                .font(.robotoFlex(size: 11, weight: 500))
                                .foregroundStyle(.white.opacity(0.6))
                            Spacer()
                            Button(vm.renderSettings.scopesApplyLUT ? "Post-LUT" : "原始 Log") {
                                vm.renderSettings.scopesApplyLUT.toggle()
                            }
                            .font(.robotoFlex(size: 11, weight: 650))
                            .foregroundStyle(MonitorTheme.diagnosticCyan)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(MonitorTheme.diagnosticCyan.opacity(0.15), in: Capsule())
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // 3. 12 段假色
            settingsCard {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("12 段曝光假色")
                            .font(.robotoFlex(size: 12.5, weight: 650))
                            .foregroundStyle(.white)
                        Text("精准核对高光裁切与肤色 IRE 曝光区")
                            .font(.robotoFlex(size: 10, weight: 450))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer()
                    Toggle("", isOn: $vm.renderSettings.isFalseColorEnabled)
                        .labelsHidden()
                        .tint(MonitorTheme.accentAmber)
                }
            }

            // 4. 峰值对焦
            settingsCard {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("峰值对焦 (Peaking)")
                            .font(.robotoFlex(size: 12.5, weight: 650))
                            .foregroundStyle(.white)
                        Spacer()
                        Toggle("", isOn: $vm.renderSettings.isPeakingEnabled)
                            .labelsHidden()
                            .tint(MonitorTheme.accentAmber)
                    }

                    HStack(spacing: 6) {
                        Text("颜色")
                            .font(.robotoFlex(size: 11, weight: 500))
                            .foregroundStyle(.white.opacity(0.6))
                        Spacer()
                        ForEach(FocusPeakingColor.allCases) { color in
                            let selected = vm.renderSettings.peakingColor == color
                            Button(color.displayName) {
                                vm.renderSettings.peakingColor = color
                                vm.renderSettings.isPeakingEnabled = true
                            }
                            .font(.robotoFlex(size: 11, weight: selected ? 700 : 500))
                            .foregroundStyle(selected ? .black : .white.opacity(0.85))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 4)
                            .background(selected ? MonitorTheme.accentAmber : Color.white.opacity(0.09), in: Capsule())
                            .buttonStyle(.plain)
                        }
                    }

                    HStack(spacing: 8) {
                        Text("灵敏度")
                            .font(.robotoFlex(size: 11, weight: 500))
                            .foregroundStyle(.white.opacity(0.6))
                        Slider(value: $vm.renderSettings.peakingSensitivity, in: 0...1)
                            .tint(MonitorTheme.accentAmber)
                        Text("\(Int(vm.renderSettings.peakingSensitivity * 100))%")
                            .font(.robotoFlex(size: 11, weight: 600))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 36, alignment: .trailing)
                    }
                }
            }

            // 5. 动态斑马纹
            settingsCard {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("动态斑马纹 (Zebra)")
                            .font(.robotoFlex(size: 12.5, weight: 650))
                            .foregroundStyle(.white)
                        Spacer()
                        Toggle("", isOn: $vm.renderSettings.isZebraEnabled)
                            .labelsHidden()
                            .tint(MonitorTheme.accentAmber)
                    }

                    HStack(spacing: 5) {
                        ForEach([Float(70), 80, 90, 95, 100], id: \.self) { ire in
                            let selected = vm.renderSettings.zebraThresholdIRE == ire
                            Button("\(Int(ire))") {
                                vm.renderSettings.zebraThresholdIRE = ire
                                vm.renderSettings.isZebraEnabled = true
                            }
                            .font(.robotoFlex(size: 11, weight: selected ? 700 : 500))
                            .monospacedDigit()
                            .foregroundStyle(selected ? .black : .white.opacity(0.8))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(selected ? MonitorTheme.accentAmber : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Tab 2: 构图与画面变换 (三分线 / 安全框 / 翻转 / 反挤压)

    private var frameAndTransformContent: some View {
        VStack(spacing: 10) {
            // 1. 三分九宫格
            settingsCard {
                HStack {
                    Text("三分构图九宫格")
                        .font(.robotoFlex(size: 12.5, weight: 650))
                        .foregroundStyle(.white)
                    Spacer()
                    Toggle("", isOn: $vm.isGridEnabled)
                        .labelsHidden()
                        .tint(MonitorTheme.accentAmber)
                }
            }

            // 2. 安全框比例
            settingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("裁切安全框比例")
                        .font(.robotoFlex(size: 12.5, weight: 650))
                        .foregroundStyle(.white)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                        ForEach(FrameGuideAspect.allCases) { guide in
                            let selected = vm.frameGuide == guide
                            Button(guide.rawValue) {
                                vm.frameGuide = guide
                            }
                            .font(.robotoFlex(size: 11, weight: selected ? 700 : 500))
                            .monospacedDigit()
                            .foregroundStyle(selected ? .black : .white.opacity(0.85))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(selected ? MonitorTheme.accentAmber : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // 3. 画面镜像与翻转
            settingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("画面翻转")
                            .font(.robotoFlex(size: 12.5, weight: 650))
                            .foregroundStyle(.white)
                        Spacer()
                        if vm.renderSettings.flipHorizontal || vm.renderSettings.flipVertical {
                            Button("复位") {
                                vm.renderSettings.flipHorizontal = false
                                vm.renderSettings.flipVertical = false
                            }
                            .font(.robotoFlex(size: 10.5, weight: 600))
                            .foregroundStyle(.white.opacity(0.7))
                            .buttonStyle(.plain)
                        }
                    }

                    HStack(spacing: 8) {
                        Button {
                            vm.renderSettings.flipHorizontal.toggle()
                        } label: {
                            Text("水平镜像 H")
                                .font(.robotoFlex(size: 11.5, weight: vm.renderSettings.flipHorizontal ? 700 : 500))
                                .foregroundStyle(vm.renderSettings.flipHorizontal ? .black : .white.opacity(0.85))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .background(
                                    vm.renderSettings.flipHorizontal ? MonitorTheme.accentAmber : Color.white.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)

                        Button {
                            vm.renderSettings.flipVertical.toggle()
                        } label: {
                            Text("垂直翻转 V")
                                .font(.robotoFlex(size: 11.5, weight: vm.renderSettings.flipVertical ? 700 : 500))
                                .foregroundStyle(vm.renderSettings.flipVertical ? .black : .white.opacity(0.85))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .background(
                                    vm.renderSettings.flipVertical ? MonitorTheme.accentAmber : Color.white.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // 4. 变形宽银幕反挤压
            settingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("变形镜头反挤压")
                        .font(.robotoFlex(size: 12.5, weight: 650))
                        .foregroundStyle(.white)

                    HStack(spacing: 6) {
                        ForEach(AnamorphicDesqueeze.allCases) { factor in
                            let selected = vm.renderSettings.desqueeze == factor
                            Button(factor.displayName) {
                                vm.renderSettings.desqueeze = factor
                            }
                            .font(.robotoFlex(size: 11.5, weight: selected ? 700 : 500))
                            .monospacedDigit()
                            .foregroundStyle(selected ? .black : .white.opacity(0.85))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(selected ? MonitorTheme.accentAmber : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Tab 3: 连接设置与实时链路诊断

    private var connectionAndDiagnosticsContent: some View {
        VStack(spacing: 10) {
            // 1. 实时遥测与链路状态
            settingsCard {
                VStack(spacing: 6) {
                    telemetryRow(
                        label: "连接状态",
                        value: connectionStateText,
                        valueColor: connectionStateColor
                    )
                    telemetryRow(
                        label: "机身档位",
                        value: vm.currentExposureMode?.displayName ?? (vm.isTestPatternActive ? "仿真信号" : "--"),
                        valueColor: .white.opacity(0.9)
                    )
                    telemetryRow(
                        label: "图传分辨率",
                        value: vm.currentResolutionLabel.isEmpty
                            ? "--"
                            : (vm.currentFrameKB > 0 ? "\(vm.currentResolutionLabel) · \(vm.currentFrameKB)KB" : vm.currentResolutionLabel),
                        valueColor: .white.opacity(0.88)
                    )
                    telemetryRow(
                        label: "实时帧率",
                        value: vm.currentFPS > 0 ? "\(vm.currentFPS) fps" : "--",
                        valueColor: MonitorTheme.diagnosticCyan
                    )
                    telemetryRow(
                        label: "链路延迟",
                        value: vm.signalLatencyMs > 0 ? "\(vm.signalLatencyMs) ms" : "--",
                        valueColor: vm.signalLatencyMs > 80 ? .orange : MonitorTheme.statusGreen
                    )

                    if !vm.ptpDiagnosticText.isEmpty {
                        Divider().background(Color.white.opacity(0.08))
                        Text(vm.ptpDiagnosticText)
                            .font(.robotoFlex(size: 10, weight: 450))
                            .foregroundStyle(.white.opacity(0.55))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            // 2. 监看模式选择
            settingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("信号接入模式")
                        .font(.robotoFlex(size: 12.5, weight: 650))
                        .foregroundStyle(.white)

                    HStack(spacing: 6) {
                        ForEach(MonitorConnectionMode.allCases) { mode in
                            let selected = vm.connectionMode == mode
                            Button {
                                vm.connectionMode = mode
                            } label: {
                                Text(mode.rawValue)
                                    .font(.robotoFlex(size: 11, weight: selected ? 700 : 500))
                                    .foregroundStyle(selected ? .black : .white.opacity(0.85))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .background(selected ? MonitorTheme.accentAmber : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Text(vm.connectionMode.subtitle)
                        .font(.robotoFlex(size: 10, weight: 450))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

            // 3. PTP/IP 地址与画质配置
            if vm.connectionMode != .uvcWired {
                settingsCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sony PTP/IP 地址 (TCP 15740)")
                            .font(.robotoFlex(size: 11.5, weight: 600))
                            .foregroundStyle(.white.opacity(0.8))

                        TextField("192.168.122.1", text: $vm.cameraIP)
                            .keyboardType(.decimalPad)
                            .font(.robotoFlex(size: 13, weight: 550))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(Color.white.opacity(0.14), lineWidth: 0.6)
                            )

                        HStack(spacing: 6) {
                            Text("Wi-Fi 画质")
                                .font(.robotoFlex(size: 11, weight: 500))
                                .foregroundStyle(.white.opacity(0.6))
                            Spacer()
                            qualityChip(title: "流畅 Low", quality: .low)
                            qualityChip(title: "清晰 High", quality: .high)
                        }
                    }
                }
            }

            // 4. 操作按钮
            VStack(spacing: 7) {
                Button {
                    Task {
                        await vm.connectCurrentMode()
                        if vm.isCameraConnected || vm.isUVCActive {
                            onClose()
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if vm.isConnecting {
                            ProgressView()
                                .tint(.black)
                                .scaleEffect(0.75)
                        }
                        Text(vm.isCameraConnected || vm.isUVCActive ? "重新连接" : "立即连接")
                            .font(.robotoFlex(size: 12.5, weight: 700))
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(MonitorTheme.accentAmber, in: RoundedRectangle(cornerRadius: MonitorTheme.cardRadius, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    Task {
                        await vm.startTestPattern()
                        onClose()
                    }
                } label: {
                    Text("启用内置动态测试信号")
                        .font(.robotoFlex(size: 12, weight: 600))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: MonitorTheme.cardRadius, style: .continuous))
                }
                .buttonStyle(.plain)

                if vm.isCameraConnected || vm.isUVCActive || vm.isTestPatternActive {
                    Button {
                        Task { await vm.disconnectAll() }
                    } label: {
                        Text("断开当前信号")
                            .font(.robotoFlex(size: 12, weight: 600))
                            .foregroundStyle(MonitorTheme.tallyRed)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(MonitorTheme.tallyRed.opacity(0.14), in: RoundedRectangle(cornerRadius: MonitorTheme.cardRadius, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 辅助组件

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(11)
            .background(MonitorTheme.surface, in: RoundedRectangle(cornerRadius: MonitorTheme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MonitorTheme.cardRadius, style: .continuous)
                    .stroke(MonitorTheme.border, lineWidth: 0.6)
            )
    }

    private func telemetryRow(label: String, value: String, valueColor: Color) -> some View {
        HStack {
            Text(label)
                .font(.robotoFlex(size: 11, weight: 500))
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
            Text(value)
                .font(.robotoFlex(size: 11.5, weight: 650))
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .lineLimit(1)
        }
    }

    private func qualityChip(title: String, quality: SonyLiveViewImageQuality) -> some View {
        let selected = vm.liveViewQuality == quality
        return Button(title) {
            vm.setLiveViewQuality(quality)
        }
        .font(.robotoFlex(size: 10.5, weight: selected ? 700 : 500))
        .foregroundStyle(selected ? .black : .white.opacity(0.8))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(selected ? MonitorTheme.accentAmber : Color.white.opacity(0.09), in: Capsule())
        .buttonStyle(.plain)
    }

    private var connectionStateText: String {
        if vm.isConnecting { return "正在连接…" }
        if vm.isCameraConnected || vm.isUVCActive { return "已连接 · \(vm.connectionMode.rawValue)" }
        if vm.isTestPatternActive { return "内置测试信号" }
        return "未连接"
    }

    private var connectionStateColor: Color {
        if vm.isConnecting { return MonitorTheme.accentAmber }
        if vm.isCameraConnected || vm.isUVCActive { return MonitorTheme.statusGreen }
        if vm.isTestPatternActive { return MonitorTheme.diagnosticCyan }
        return .white.opacity(0.45)
    }
}

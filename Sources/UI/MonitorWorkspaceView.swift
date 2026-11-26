//
//  MonitorWorkspaceView.swift
//  CineView Pro
//
//  极简双侧边栏零遮挡横屏监视器主界面
//  - 上下零条栏，中间图传画布保持 100% 屏幕最大高度，零像素遮挡
//  - 左侧栏：纯色连接状态点 + 放大单字母档位 + 核心 5 项曝光参数 (SS / F / ISO / EV / WB)，点击原地切换竖向拨轮零遮挡调参
//  - 右侧栏：顶部电量与激活工具微标 + 严格上下居中独立 REC 录制键（无 STBY 文字）+ 底部纯白无文字图标按钮（清屏 / 设置）
//  - 全界面统一 Roboto Flex 可变字体 + 电影机暗黑视觉规范
//

import SwiftUI
import UIKit

struct MonitorWorkspaceView: View {
    @Bindable var vm: MonitorViewModel

    // 视频缩放与拖动状态
    @State private var zoomScale: CGFloat = 1.0
    @State private var gestureZoomScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var gesturePanOffset: CGSize = .zero

    // 可拖动示波器浮窗偏移
    @State private var scopesDragOffset: CGSize = .zero
    @State private var scopesGestureOffset: CGSize = .zero

    // 白平衡竖向拨轮：false = 预设，true = 精准色温 K
    @State private var wbPickerUseKelvin: Bool = false

    // 清屏恢复提示短暂显示
    @State private var showCleanFeedHint: Bool = false

    private let leftRailWidth: CGFloat = 82
    private let rightRailWidth: CGFloat = 70

    private var effectiveZoom: CGFloat {
        min(max(zoomScale * gestureZoomScale, 1.0), 4.0)
    }

    private var effectivePan: CGSize {
        CGSize(
            width: panOffset.width + gesturePanOffset.width,
            height: panOffset.height + gesturePanOffset.height
        )
    }

    var body: some View {
        GeometryReader { rootGeo in
            let edgeInsets = resolvedHorizontalEdgeInsets(for: rootGeo)

            ZStack {
                MonitorTheme.canvasBlack.ignoresSafeArea()

                // 主体水平三段布局：左侧黑边栏 | 100% 满高纯净图传画布 | 右侧黑边栏
                HStack(spacing: 0) {
                    if !vm.isHUDHidden {
                        leftControlRail(leadingInset: edgeInsets.leading)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }

                    // 中间 100% 满高无遮挡图传视口
                    centerVideoViewport

                    if !vm.isHUDHidden {
                        rightControlRail(trailingInset: edgeInsets.trailing)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(width: rootGeo.size.width, height: rootGeo.size.height)

                // 右侧滑出式设置面板（边调边看左侧实时画面）
                if vm.isSettingsDrawerPresented && !vm.isHUDHidden {
                    ZStack(alignment: .trailing) {
                        Color.black.opacity(0.28)
                            .ignoresSafeArea()
                            .onTapGesture {
                                vm.closeSettings()
                            }

                        let drawerWidth = min(max(rootGeo.size.width * 0.42, 292), 360)
                        MonitorSettingsDrawer(
                            vm: vm,
                            selectedTab: $vm.settingsDrawerTab,
                            trailingInset: edgeInsets.trailing,
                            onClose: { vm.closeSettings() }
                        )
                        .frame(width: drawerWidth + edgeInsets.trailing)
                        .frame(maxHeight: .infinity)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                    .zIndex(50)
                }

                // 全屏刚拍照片相册预览
                if vm.isGalleryPresented {
                    CapturedPhotoGalleryView(
                        vm: vm,
                        leadingInset: edgeInsets.leading,
                        trailingInset: edgeInsets.trailing,
                        onClose: { vm.closeGallery() }
                    )
                    .transition(.opacity)
                    .zIndex(60)
                }
            }
            .animation(.snappy(duration: 0.22), value: vm.isHUDHidden)
            .animation(.snappy(duration: 0.22), value: vm.isSettingsDrawerPresented)
            .animation(.snappy(duration: 0.22), value: vm.isGalleryPresented)
        }
        .ignoresSafeArea()
        .ignoresSafeArea(.keyboard)
    }

    // MARK: - 1. 左侧黑边控制栏（状态圆点 + 放大单字母档位 + SS/F/ISO/EV/WB + 原地竖向拨轮）

    private func leftControlRail(leadingInset: CGFloat) -> some View {
        ZStack {
            if let activeControl = vm.activeExposureControl {
                leftVerticalPicker(for: activeControl)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                leftExposureStack
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 10)
        .padding(.leading, leadingInset)
        .padding(.trailing, 7)
        .frame(width: leftRailWidth + leadingInset)
        .frame(maxHeight: .infinity)
        .background(MonitorTheme.canvasBlack)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 0.5)
        }
    }

    private var leftExposureStack: some View {
        VStack(spacing: 5) {
            // 顶部：纯色连接状态圆点 + 档位字母（整张卡片可点击打开设置抽屉）
            Button {
                let haptic = UIImpactFeedbackGenerator(style: .light)
                haptic.impactOccurred()
                let isLive = vm.isCameraConnected || vm.isUVCActive || vm.isTestPatternActive
                vm.openSettings(tab: isLive ? .assist : .connect)
            } label: {
                HStack(spacing: 3) {
                    Circle()
                        .fill(connectionStatusColor)
                        .frame(width: 8, height: 8)
                        .shadow(color: connectionStatusColor.opacity(0.85), radius: 4)
                        .frame(width: 14, height: 24)

                    Spacer(minLength: 2)

                    Text(exposureModeLetter)
                        .font(exposureModeFont)
                        .foregroundStyle(vm.currentExposureMode != nil ? MonitorTheme.accentAmber : .white.opacity(0.45))
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                        .allowsTightening(true)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 6)
                .frame(height: 44)
                .frame(maxWidth: .infinity)
                .background(MonitorTheme.surface, in: RoundedRectangle(cornerRadius: MonitorTheme.cardRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: MonitorTheme.cardRadius, style: .continuous)
                        .stroke(MonitorTheme.border, lineWidth: 0.6)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("连接状态与设置")

            // 5 项核心曝光参数均匀排布
            exposureCard(
                label: "SS",
                value: vm.currentShutter.description,
                control: .shutter
            )
            exposureCard(
                label: "F",
                value: vm.currentAperture.description.replacingOccurrences(of: "F", with: ""),
                control: .aperture
            )
            exposureCard(
                label: "ISO",
                value: vm.currentISO.description.replacingOccurrences(of: "ISO ", with: ""),
                control: .iso
            )
            exposureCard(
                label: "EV",
                value: vm.currentExposureBias.description,
                control: .exposureBias
            )
            exposureCard(
                label: "WB",
                value: vm.currentWhiteBalance == .colorTempFilter
                    ? "\(vm.currentColorTemp)K"
                    : vm.currentWhiteBalance.description,
                control: .whiteBalance
            )
        }
    }

    private func exposureCard(label: String, value: String, control: ActiveExposureControl) -> some View {
        let writable = isControlWritable(control)
        return Button {
            guard writable else {
                let msg = lockedReasonMessage(for: control)
                if !msg.isEmpty { vm.showBanner(msg) }
                return
            }
            let haptic = UIImpactFeedbackGenerator(style: .light)
            haptic.impactOccurred()
            if control == .whiteBalance {
                wbPickerUseKelvin = (vm.currentWhiteBalance == .colorTempFilter)
            }
            withAnimation(.snappy(duration: 0.2)) {
                vm.isSettingsDrawerPresented = false
                vm.activeExposureControl = control
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 2) {
                    Text(label)
                        .font(.robotoFlex(size: 9.5, weight: 550, width: 102))
                        .foregroundStyle(.white.opacity(writable ? 0.48 : 0.35))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    if !writable {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }

                Text(value)
                    .font(.robotoFlex(size: 14, weight: 650, width: 95))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(writable ? 0.96 : 0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(
                MonitorTheme.surface.opacity(writable ? 1.0 : 0.65),
                in: RoundedRectangle(cornerRadius: MonitorTheme.cardRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MonitorTheme.cardRadius, style: .continuous)
                    .stroke(writable ? MonitorTheme.border : Color.white.opacity(0.05), lineWidth: 0.6)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 1B. 左侧原地竖向刻度拨轮（调参全程零遮挡图传画面）

    private func leftVerticalPicker(for control: ActiveExposureControl) -> some View {
        let items = pickerItems(for: control)
        let currentIdx = selectedPickerIndex(for: control)
        let accentColor: Color = (control == .whiteBalance && wbPickerUseKelvin)
            ? MonitorTheme.diagnosticCyan
            : MonitorTheme.accentAmber

        return VStack(spacing: 6) {
            // 顶部参数短标题 + 关闭按钮
            HStack(spacing: 4) {
                Text(control.shortTitle)
                    .font(.robotoFlex(size: 12.5, weight: 750))
                    .foregroundStyle(accentColor)
                Spacer(minLength: 0)
                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        vm.activeExposureControl = nil
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 2)

            // 白平衡专属：预设 / 色温 K 快速切换
            if control == .whiteBalance {
                HStack(spacing: 3) {
                    Button("预设") {
                        wbPickerUseKelvin = false
                    }
                    .font(.robotoFlex(size: 10, weight: wbPickerUseKelvin ? 500 : 700))
                    .foregroundStyle(wbPickerUseKelvin ? .white.opacity(0.65) : .black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(wbPickerUseKelvin ? Color.white.opacity(0.08) : MonitorTheme.accentAmber, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .buttonStyle(.plain)

                    Button("K") {
                        wbPickerUseKelvin = true
                    }
                    .font(.robotoFlex(size: 10, weight: wbPickerUseKelvin ? 700 : 500))
                    .foregroundStyle(wbPickerUseKelvin ? .black : .white.opacity(0.65))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(wbPickerUseKelvin ? MonitorTheme.diagnosticCyan : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .buttonStyle(.plain)
                }
            }

            // 向上步进 ▲
            Button {
                stepPicker(for: control, delta: -1)
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)

            // 竖向选项列表（自动居中定位到当前值）
            if items.isEmpty {
                Spacer()
                Text("不可调")
                    .font(.robotoFlex(size: 11, weight: 500))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(items.enumerated()), id: \.offset) { idx, title in
                                let isSelected = (idx == currentIdx)
                                Button {
                                    let haptic = UISelectionFeedbackGenerator()
                                    haptic.selectionChanged()
                                    selectPickerIndex(idx, for: control)
                                } label: {
                                    Text(title)
                                        .font(.robotoFlex(size: 12.5, weight: isSelected ? 750 : 500, width: 94))
                                        .monospacedDigit()
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.72)
                                        .foregroundStyle(isSelected ? .black : .white.opacity(0.85))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                        .padding(.horizontal, 4)
                                        .background(
                                            isSelected ? accentColor : Color.white.opacity(0.07),
                                            in: RoundedRectangle(cornerRadius: MonitorTheme.chipRadius, style: .continuous)
                                        )
                                }
                                .buttonStyle(.plain)
                                .id(idx)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .onAppear {
                        if let idx = currentIdx {
                            DispatchQueue.main.async {
                                proxy.scrollTo(idx, anchor: .center)
                            }
                        }
                    }
                    .onChange(of: currentIdx) { _, newIdx in
                        if let newIdx {
                            withAnimation(.snappy(duration: 0.18)) {
                                proxy.scrollTo(newIdx, anchor: .center)
                            }
                        }
                    }
                    .onChange(of: wbPickerUseKelvin) { _, _ in
                        if let idx = selectedPickerIndex(for: control) {
                            DispatchQueue.main.async {
                                proxy.scrollTo(idx, anchor: .center)
                            }
                        }
                    }
                }
            }

            // 向下步进 ▼
            Button {
                stepPicker(for: control, delta: 1)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 2. 中间 100% 满高纯净图传视口

    private var centerVideoViewport: some View {
        GeometryReader { viewportGeo in
            let containerSize = viewportGeo.size
            let videoRect = computeActiveVideoRect(in: containerSize)

            ZStack {
                // 底层 60fps MTKView + 安全框 + 手势
                videoCanvasLayer(containerSize: containerSize, videoRect: videoRect)

                // 录制中 Tally 红色细边框（精准贴合当前视频有效画幅，不占面积）
                if vm.isRecording && videoRect.width > 10 && videoRect.height > 10 {
                    Rectangle()
                        .stroke(MonitorTheme.tallyRed, lineWidth: 2)
                        .frame(width: videoRect.width, height: videoRect.height)
                        .position(x: videoRect.midX, y: videoRect.midY)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                // 假色 12 段 IRE 色标尺（仅在开启假色时显示）
                if vm.renderSettings.isFalseColorEnabled && !vm.isHUDHidden {
                    HStack {
                        FalseColorLegendBar()
                            .padding(.leading, 8)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }

                // 触控对焦角标框
                if let reticle = vm.focusReticle {
                    FocusReticleView(isLocked: reticle.isLocked)
                        .position(reticle.screenPoint)
                        .allowsHitTesting(false)
                }

                // 可拖动专业示波器浮窗
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
                                onClose: {
                                    withAnimation(.snappy) {
                                        vm.isScopesVisible = false
                                        vm.renderSettings.isScopesEnabled = false
                                    }
                                }
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
                        .padding(.leading, 10)
                        .padding(.bottom, 10)
                    }
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
                }

                // 轻量状态提示吐司
                if let msg = vm.statusBannerMessage {
                    VStack {
                        Text(msg)
                            .font(.robotoFlex(size: 11.5, weight: 550))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.82), in: Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 0.6))
                            .padding(.top, 10)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // 缩放倍率复位徽标
                if effectiveZoom > 1.02 {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Button {
                                resetZoomAndPan()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "viewfinder")
                                        .font(.system(size: 10.5, weight: .semibold))
                                    Text(String(format: "%.1fx 复位", effectiveZoom))
                                        .font(.robotoFlex(size: 11, weight: 700))
                                        .monospacedDigit()
                                }
                                .foregroundStyle(.black)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(MonitorTheme.accentAmber, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 10)
                            .padding(.bottom, 10)
                        }
                    }
                    .transition(.opacity)
                }

                // 无画面待机引导浮层
                if !vm.isCameraConnected && !vm.isUVCActive && !vm.isTestPatternActive && !vm.isHUDHidden {
                    standbyOverlay
                }

                // 清屏模式提示
                if vm.isHUDHidden && showCleanFeedHint {
                    VStack {
                        Spacer()
                        Text("纯净监看 · 轻点画面恢复控制栏")
                            .font(.robotoFlex(size: 10.5, weight: 500))
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Color.black.opacity(0.72), in: Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                            .padding(.bottom, 14)
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .frame(width: containerSize.width, height: containerSize.height)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func videoCanvasLayer(containerSize: CGSize, videoRect: CGRect) -> some View {
        ZStack {
            MonitorMetalView(renderer: vm.renderer)
                .frame(width: containerSize.width, height: containerSize.height)

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
        // 1. 双击 2.0x 放大检焦 / 复位
        .highPriorityGesture(
            TapGesture(count: 2)
                .onEnded {
                    if vm.isHUDHidden {
                        restoreFromCleanFeed()
                        return
                    }
                    if effectiveZoom > 1.02 {
                        resetZoomAndPan()
                    } else {
                        withAnimation(.snappy(duration: 0.25)) {
                            zoomScale = 2.0
                        }
                    }
                }
        )
        // 2. 单击精准触控对焦（或退出清屏 / 收起拨轮 / 收起设置）
        .simultaneousGesture(
            SpatialTapGesture(count: 1)
                .onEnded { value in
                    if vm.isHUDHidden {
                        restoreFromCleanFeed()
                        return
                    }
                    if vm.isSettingsDrawerPresented {
                        vm.closeSettings()
                        return
                    }
                    if vm.activeExposureControl != nil {
                        withAnimation(.snappy(duration: 0.18)) {
                            vm.activeExposureControl = nil
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
        // 4. 放大态单指拖动巡检
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

    // MARK: - 3. 右侧黑边操控栏（顶部电量/工具微标 + 严格上下居中独立 REC 键 + 底部纯白无文字图标）

    private func rightControlRail(trailingInset: CGFloat) -> some View {
        ZStack {
            // 顶部与底部对齐元素
            VStack(spacing: 0) {
                // 顶部：机身电量 + 已激活监看工具微标
                VStack(spacing: 6) {
                    batteryBadge

                    let badges = activeAssistBadges
                    if !badges.isEmpty {
                        Button {
                            vm.openSettings(tab: .assist)
                        } label: {
                            VStack(spacing: 3) {
                                ForEach(badges.prefix(3), id: \.self) { tag in
                                    Text(tag)
                                        .font(.robotoFlex(size: 8.5, weight: 700, width: 96))
                                        .foregroundStyle(MonitorTheme.accentAmber)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(MonitorTheme.accentAmber.opacity(0.16), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                                .stroke(MonitorTheme.accentAmber.opacity(0.45), lineWidth: 0.5)
                                        )
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 12)

                Spacer()

                // 底部：纯白无文字图标按钮（相册预览 + 清屏）
                VStack(spacing: 6) {
                    Button {
                        let haptic = UIImpactFeedbackGenerator(style: .light)
                        haptic.impactOccurred()
                        vm.openGallery()
                    } label: {
                        ZStack {
                            if vm.isFetchingCapturedPhoto {
                                ProgressView()
                                    .tint(.white)
                                    .scaleEffect(0.7)
                            } else {
                                Image(systemName: "photo")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(width: 44, height: 33)
                        .background(MonitorTheme.surface, in: RoundedRectangle(cornerRadius: MonitorTheme.cardRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: MonitorTheme.cardRadius, style: .continuous)
                                .stroke(
                                    vm.hasUnreadCapturedPhoto ? MonitorTheme.accentAmber.opacity(0.7) : MonitorTheme.border,
                                    lineWidth: 0.6
                                )
                        )
                        .overlay(alignment: .topTrailing) {
                            if vm.hasUnreadCapturedPhoto {
                                Circle()
                                    .fill(MonitorTheme.accentAmber)
                                    .frame(width: 6, height: 6)
                                    .offset(x: -5, y: 5)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("相册预览")

                    Button {
                        enterCleanFeed()
                    } label: {
                        Image(systemName: "eye")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 33)
                            .background(MonitorTheme.surface, in: RoundedRectangle(cornerRadius: MonitorTheme.cardRadius, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: MonitorTheme.cardRadius, style: .continuous)
                                    .stroke(MonitorTheme.border, lineWidth: 0.6)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清屏")
                }
                .padding(.bottom, 10)
            }

            // 严格上下居中：独立电影机 REC 录制键（无 STBY 文字，仅录制中在下方叠加红字时间码）
            Button {
                vm.toggleRecording()
            } label: {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.85), lineWidth: 2.2)
                        .frame(width: 52, height: 52)

                    RoundedRectangle(cornerRadius: vm.isRecording ? 6 : 19, style: .continuous)
                        .fill(MonitorTheme.tallyRed)
                        .frame(width: vm.isRecording ? 21 : 38, height: vm.isRecording ? 21 : 38)
                        .shadow(
                            color: MonitorTheme.tallyRed.opacity(vm.isRecording ? 0.78 : 0.42),
                            radius: vm.isRecording ? 10 : 6
                        )
                        .animation(.snappy(duration: 0.2), value: vm.isRecording)
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(vm.isRecording ? "停止录制" : "开始录制")
            .overlay(alignment: .bottom) {
                if vm.isRecording {
                    Text(vm.formattedRecordingTimecode)
                        .font(.robotoFlex(size: 10.5, weight: 700, width: 92))
                        .monospacedDigit()
                        .foregroundStyle(MonitorTheme.tallyRed)
                        .lineLimit(1)
                        .fixedSize()
                        .offset(y: 22)
                        .transition(.opacity)
                }
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, trailingInset)
        .frame(width: rightRailWidth + trailingInset)
        .frame(maxHeight: .infinity)
        .background(MonitorTheme.canvasBlack)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 0.5)
        }
    }

    private var batteryBadge: some View {
        let isLow = vm.batteryPercent <= 15
        let tintColor: Color = isLow ? MonitorTheme.tallyRed : .white.opacity(0.9)
        return HStack(spacing: 3) {
            Image(systemName: batteryIconName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tintColor)
            Text("\(vm.batteryPercent)%")
                .font(.robotoFlex(size: 10.5, weight: 650, width: 94))
                .monospacedDigit()
                .foregroundStyle(tintColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            isLow ? MonitorTheme.tallyRed.opacity(0.16) : MonitorTheme.surface,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isLow ? MonitorTheme.tallyRed.opacity(0.5) : MonitorTheme.border, lineWidth: 0.6)
        )
    }

    // MARK: - 无信号待机浮层

    private var standbyOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.white.opacity(0.45))

            Text("CineView Pro")
                .font(.robotoFlex(size: 15, weight: 700))
                .foregroundStyle(.white.opacity(0.9))

            Text("未检测到视频输入，请连接 UVC 采集卡或 Sony PTP/IP")
                .font(.robotoFlex(size: 11.5, weight: 450))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)

            Button {
                vm.openSettings(tab: .connect)
            } label: {
                Text("连接相机")
                    .font(.robotoFlex(size: 12.5, weight: 700))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 9)
                    .background(MonitorTheme.accentAmber, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .padding(22)
        .background(MonitorTheme.drawerBackground.opacity(0.85), in: RoundedRectangle(cornerRadius: MonitorTheme.drawerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MonitorTheme.drawerRadius, style: .continuous)
                .stroke(MonitorTheme.border, lineWidth: 0.6)
        )
    }

    // MARK: - 数据映射与交互逻辑

    private var connectionStatusColor: Color {
        if vm.isConnecting { return MonitorTheme.accentAmber }
        if vm.isCameraConnected || vm.isUVCActive { return MonitorTheme.statusGreen }
        if vm.isTestPatternActive { return MonitorTheme.diagnosticCyan }
        return Color.white.opacity(0.32)
    }

    /// 档位紧凑标识（例如 A 光圈优先 -> "A"，MOVIE M -> "M"，AUTO -> "AUTO"，记忆调出 1/2/3 -> "1"/"2"/"3"）
    private var exposureModeLetter: String {
        guard let mode = vm.currentExposureMode else {
            return vm.isTestPatternActive ? "M" : "--"
        }
        switch mode.modeCode {
        case 0x0000:                                         return "--"
        case 0x0001, 0x8053, 0x805C, 0x8087, 0x8083, 0x8096: return "M"
        case 0x0002, 0x8050, 0x8059, 0x8084, 0x8080, 0x8093: return "P"
        case 0x0003, 0x8051, 0x805A, 0x8085, 0x8081, 0x8094: return "A"
        case 0x0004, 0x8052, 0x805B, 0x8086, 0x8082, 0x8095: return "S"
        case 0x808A, 0x8090, 0x8091, 0x8092:                 return "F"
        case 0x8000, 0x8054, 0x805D, 0x8097:                 return "AUTO"
        case 0x8001:                                         return "A+"
        case 0x8011...0x801C:                                return "SCN"
        case 0x8020:
            if (1...3).contains(mode.groupCode) { return "\(mode.groupCode)" }
            return "MR"
        case 0x8021:                                         return "1"
        case 0x8022:                                         return "2"
        case 0x8023:                                         return "3"
        case 0x8024:                                         return "M1"
        case 0x8025:                                         return "M2"
        case 0x8026:                                         return "M3"
        case 0x8027:                                         return "M4"
        case 0x8088:                                         return "MOV"
        case 0x8089:                                         return "STL"
        default:                                             return mode.shortBadge
        }
    }

    /// 按档位文字长度自适应 Roboto Flex 字号与字宽，确保 4 字母 `AUTO` 等完整清晰显示不裁切
    private var exposureModeFont: Font {
        switch exposureModeLetter.count {
        case ...1: return .robotoFlex(size: 24, weight: 800, width: 96)
        case 2:    return .robotoFlex(size: 18, weight: 800, width: 88)
        case 3:    return .robotoFlex(size: 15, weight: 800, width: 82)
        default:   return .robotoFlex(size: 13.5, weight: 800, width: 76)
        }
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

    private var activeAssistBadges: [String] {
        var tags: [String] = []
        if vm.renderSettings.isLUTEnabled { tags.append("LUT") }
        if vm.renderSettings.isPeakingEnabled { tags.append("PEAK") }
        if vm.renderSettings.isZebraEnabled { tags.append("ZEB") }
        if vm.renderSettings.isFalseColorEnabled { tags.append("FC") }
        if vm.isScopesVisible { tags.append("SCP") }
        if vm.frameGuide != .off { tags.append(vm.frameGuide.rawValue) }
        return tags
    }

    private func isControlWritable(_ control: ActiveExposureControl) -> Bool {
        switch control {
        case .aperture: return vm.isApertureWritable
        case .shutter:  return vm.isShutterWritable
        case .iso:      return vm.isISOWritable
        case .exposureBias, .whiteBalance: return true
        }
    }

    private func lockedReasonMessage(for control: ActiveExposureControl) -> String {
        let modeText = vm.currentExposureMode?.shortBadge
        switch control {
        case .aperture:
            if vm.currentExposureMode?.allowsManualAperture == false, let modeText {
                return "当前 \(modeText) 档位由机身自动控制光圈"
            }
            return "当前镜头不支持电控光圈，或光圈环未置于 A 档"
        case .shutter:
            if vm.currentExposureMode?.allowsManualShutter == false, let modeText {
                return "当前 \(modeText) 档位由机身自动控制快门"
            }
            return "当前拍摄模式下快门不可手动调节"
        case .iso:
            if let modeText {
                return "当前 \(modeText) 档位下 ISO 不可手动调节"
            }
            return "当前拍摄模式下 ISO 不可手动调节"
        case .exposureBias, .whiteBalance:
            return ""
        }
    }

    private func pickerItems(for control: ActiveExposureControl) -> [String] {
        switch control {
        case .shutter:
            return vm.shutterPresets.map(\.description)
        case .aperture:
            return vm.aperturePresets.map { $0.description.replacingOccurrences(of: "F", with: "") }
        case .iso:
            return vm.isoPresets.map { $0.description.replacingOccurrences(of: "ISO ", with: "") }
        case .exposureBias:
            return vm.exposureBiasPresets.map(\.description)
        case .whiteBalance:
            if wbPickerUseKelvin {
                return vm.colorTempPresets.map { "\($0)K" }
            }
            return vm.whiteBalancePresets.map(\.description)
        }
    }

    private func selectedPickerIndex(for control: ActiveExposureControl) -> Int? {
        switch control {
        case .shutter:
            return vm.shutterPresets.firstIndex(of: vm.currentShutter)
        case .aperture:
            return vm.aperturePresets.firstIndex(of: vm.currentAperture)
        case .iso:
            return vm.isoPresets.firstIndex(of: vm.currentISO)
        case .exposureBias:
            return vm.exposureBiasPresets.firstIndex(of: vm.currentExposureBias)
        case .whiteBalance:
            if wbPickerUseKelvin {
                if let exact = vm.colorTempPresets.firstIndex(of: vm.currentColorTemp) {
                    return exact
                }
                return vm.colorTempPresets.enumerated().min(by: {
                    abs(Int($0.element) - Int(vm.currentColorTemp)) < abs(Int($1.element) - Int(vm.currentColorTemp))
                })?.offset
            }
            return vm.whiteBalancePresets.firstIndex(of: vm.currentWhiteBalance)
        }
    }

    private func selectPickerIndex(_ index: Int, for control: ActiveExposureControl) {
        switch control {
        case .shutter:
            guard vm.shutterPresets.indices.contains(index) else { return }
            vm.setShutter(vm.shutterPresets[index])
        case .aperture:
            guard vm.aperturePresets.indices.contains(index) else { return }
            vm.setAperture(vm.aperturePresets[index])
        case .iso:
            guard vm.isoPresets.indices.contains(index) else { return }
            vm.setISO(vm.isoPresets[index])
        case .exposureBias:
            guard vm.exposureBiasPresets.indices.contains(index) else { return }
            vm.setExposureBias(vm.exposureBiasPresets[index])
        case .whiteBalance:
            if wbPickerUseKelvin {
                guard vm.colorTempPresets.indices.contains(index) else { return }
                vm.setColorTemperature(vm.colorTempPresets[index])
            } else {
                guard vm.whiteBalancePresets.indices.contains(index) else { return }
                vm.setWhiteBalance(vm.whiteBalancePresets[index])
            }
        }
    }

    private func stepPicker(for control: ActiveExposureControl, delta: Int) {
        let count = pickerItems(for: control).count
        guard count > 0 else { return }
        let current = selectedPickerIndex(for: control) ?? 0
        let target = min(max(current + delta, 0), count - 1)
        guard target != current else { return }
        let haptic = UISelectionFeedbackGenerator()
        haptic.selectionChanged()
        selectPickerIndex(target, for: control)
    }

    private func enterCleanFeed() {
        let haptic = UIImpactFeedbackGenerator(style: .light)
        haptic.impactOccurred()
        withAnimation(.snappy(duration: 0.22)) {
            vm.activeExposureControl = nil
            vm.isSettingsDrawerPresented = false
            vm.isHUDHidden = true
            showCleanFeedHint = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            withAnimation(.easeOut(duration: 0.3)) {
                showCleanFeedHint = false
            }
        }
    }

    private func restoreFromCleanFeed() {
        withAnimation(.snappy(duration: 0.22)) {
            vm.isHUDHidden = false
            showCleanFeedHint = false
        }
    }

    // MARK: - 安全区灵动岛智能避让与视频几何映射

    /// 横屏时仅对灵动岛所在侧施加完整硬件安全区避让（不再人为截断为 48pt，彻底避免 iPhone Pro Max 灵动岛遮挡），对侧保持紧凑外距以最大化中间图传面积
    private func resolvedHorizontalEdgeInsets(for geo: GeometryProxy) -> (leading: CGFloat, trailing: CGFloat) {
        let windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let keyWindow = windowScene?.windows.first(where: \.isKeyWindow)
        let rawLeading = max(geo.safeAreaInsets.leading, keyWindow?.safeAreaInsets.left ?? 0)
        let rawTrailing = max(geo.safeAreaInsets.trailing, keyWindow?.safeAreaInsets.right ?? 0)

        let minEdge: CGFloat = 10
        let islandExtraMargin: CGFloat = 4

        guard max(rawLeading, rawTrailing) >= 36 else {
            return (minEdge, minEdge)
        }

        let leadingClearance = max(rawLeading, minEdge) + islandExtraMargin
        let trailingClearance = max(rawTrailing, minEdge) + islandExtraMargin

        switch windowScene?.interfaceOrientation {
        case .landscapeRight:
            // 灵动岛/听筒位于左侧，给左侧栏完整安全区避让
            return (leadingClearance, minEdge)
        case .landscapeLeft:
            // 灵动岛/听筒位于右侧，给右侧栏完整安全区避让
            return (minEdge, trailingClearance)
        default:
            return (leadingClearance, trailingClearance)
        }
    }

    /// 计算与 `MonitorShaders.metal` 完全一致的有效视频矩形 (含变形镜头反挤压倍率)
    private func computeActiveVideoRect(in containerSize: CGSize) -> CGRect {
        let src = vm.renderer?.currentSourceSize ?? CGSize(width: 1920, height: 1080)
        let srcW = max(src.width, 1)
        let srcH = max(src.height, 1)
        let effectiveAspect = (srcW / srcH) * CGFloat(max(vm.renderSettings.desqueeze.rawValue, 1.0))
        let viewportAspect = containerSize.width / max(containerSize.height, 1)

        if viewportAspect > effectiveAspect {
            let videoH = containerSize.height
            let videoW = videoH * effectiveAspect
            return CGRect(
                x: (containerSize.width - videoW) * 0.5,
                y: 0,
                width: videoW,
                height: videoH
            )
        } else {
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

    /// 将视口触摸点反算回 Sony 画面归一化坐标 [0...1, 0...1]
    private func mapTapToNormalizedFocusPoint(
        tapLocation: CGPoint,
        containerSize: CGSize,
        videoRect: CGRect
    ) -> TouchFocusPoint? {
        let cx = containerSize.width * 0.5
        let cy = containerSize.height * 0.5
        let scale = max(effectiveZoom, 1.0)
        let pan = effectivePan

        let unzoomedX = (tapLocation.x - cx - pan.width) / scale + cx
        let unzoomedY = (tapLocation.y - cy - pan.height) / scale + cy
        let unzoomedPt = CGPoint(x: unzoomedX, y: unzoomedY)

        guard videoRect.contains(unzoomedPt), videoRect.width > 0, videoRect.height > 0 else {
            return nil
        }

        var normX = (unzoomedPt.x - videoRect.minX) / videoRect.width
        var normY = (unzoomedPt.y - videoRect.minY) / videoRect.height
        if vm.renderSettings.flipHorizontal { normX = 1.0 - normX }
        if vm.renderSettings.flipVertical { normY = 1.0 - normY }
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
}

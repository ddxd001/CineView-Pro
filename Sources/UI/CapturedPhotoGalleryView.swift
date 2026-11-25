//
//  CapturedPhotoGalleryView.swift
//  CineView Pro
//
//  相机刚拍照片（PTP/IP 0xFFFFC001）全屏相册预览界面
//  - 支持双指捏合缩放 (1x...6x)、单指拖动巡检、双击 2.5x 检焦/复位、左右滑动切换
//  - 支持通过系统 ShareLink 一键保存至 iPhone 相册或隔空投送
//  - 统一 Roboto Flex 字体 + 纯白图标 + 电影机暗黑风格
//

import ImageIO
import SwiftUI
import UIKit

// MARK: - 1. 刚拍照片数据模型与后台高效解码器

public struct CapturedPhotoItem: Identifiable, @unchecked Sendable {
    public let id: UUID
    public let filename: String
    public let formatLabel: String
    public let pixelSizeLabel: String
    public let fileSizeLabel: String
    public let capturedAt: Date
    public let previewImage: UIImage
    public let thumbnailImage: UIImage
    public let fileURL: URL?

    public static func decode(from captured: SonyCapturedPhoto) -> CapturedPhotoItem? {
        let data = captured.imageData
        let preview = makeThumbnailImage(from: data, maxPixel: 2048)
            ?? UIImage(data: data)
            ?? captured.thumbnailData.flatMap { UIImage(data: $0) }
        guard let preview else { return nil }

        let thumb = captured.thumbnailData.flatMap { makeThumbnailImage(from: $0, maxPixel: 300) }
            ?? makeThumbnailImage(from: data, maxPixel: 300)
            ?? preview

        let id = UUID()
        let fileURL = persistTempFile(data: data, id: id, filename: captured.info.filename)

        let w = captured.info.imageWidth > 0 ? Int(captured.info.imageWidth) : Int(preview.size.width * preview.scale)
        let h = captured.info.imageHeight > 0 ? Int(captured.info.imageHeight) : Int(preview.size.height * preview.scale)
        let sizeMB = Double(data.count) / (1024.0 * 1024.0)
        let sizeText = sizeMB >= 1.0
            ? String(format: "%.1f MB", sizeMB)
            : "\(max(1, data.count / 1024)) KB"

        return CapturedPhotoItem(
            id: id,
            filename: captured.info.filename,
            formatLabel: captured.info.formatDisplayName,
            pixelSizeLabel: "\(w)×\(h)",
            fileSizeLabel: sizeText,
            capturedAt: Date(),
            previewImage: preview,
            thumbnailImage: thumb,
            fileURL: fileURL
        )
    }

    /// 使用 ImageIO 高效解码 JPEG / HEIF / Sony ARW RAW，自动纠正 EXIF 旋转方向
    private static func makeThumbnailImage(from data: Data, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private static func persistTempFile(data: Data, id: UUID, filename: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CineViewCaptures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sanitized = filename.replacingOccurrences(of: "/", with: "_")
        let url = dir.appendingPathComponent("\(id.uuidString.prefix(8))_\(sanitized)")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

// MARK: - 2. 全屏相册预览界面

struct CapturedPhotoGalleryView: View {
    @Bindable var vm: MonitorViewModel
    let leadingInset: CGFloat
    let trailingInset: CGFloat
    let onClose: () -> Void

    @State private var selectedPhotoID: UUID?
    @State private var isChromeHidden: Bool = false

    // 当前照片缩放与拖动状态
    @State private var zoomScale: CGFloat = 1.0
    @State private var gestureZoomScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var gesturePanOffset: CGSize = .zero

    private var effectiveZoom: CGFloat {
        min(max(zoomScale * gestureZoomScale, 1.0), 6.0)
    }

    private var effectivePan: CGSize {
        CGSize(
            width: panOffset.width + gesturePanOffset.width,
            height: panOffset.height + gesturePanOffset.height
        )
    }

    private var selectedIndex: Int {
        guard let selectedPhotoID,
              let idx = vm.capturedPhotos.firstIndex(where: { $0.id == selectedPhotoID }) else {
            return 0
        }
        return idx
    }

    private var currentPhoto: CapturedPhotoItem? {
        guard vm.capturedPhotos.indices.contains(selectedIndex) else { return nil }
        return vm.capturedPhotos[selectedIndex]
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                MonitorTheme.canvasBlack.ignoresSafeArea()

                if let photo = currentPhoto {
                    // 主图可缩放浏览区
                    photoCanvas(photo: photo, containerSize: geo.size)

                    // 顶部与底部悬浮控制栏（单击主图可纯屏隐藏/恢复）
                    if !isChromeHidden {
                        VStack(spacing: 0) {
                            topBar(photo: photo)
                            Spacer()
                            if vm.capturedPhotos.count > 1 {
                                bottomFilmstrip
                            }
                        }
                        .transition(.opacity)
                    }
                } else {
                    // 暂无照片空态
                    VStack(spacing: 0) {
                        emptyTopBar
                        Spacer()
                        emptyStateCard
                        Spacer()
                    }
                }
            }
            .animation(.snappy(duration: 0.2), value: isChromeHidden)
        }
        .ignoresSafeArea()
        .onAppear {
            selectedPhotoID = vm.capturedPhotos.first?.id
        }
        .onChange(of: vm.capturedPhotos.first?.id) { _, newFirstID in
            if selectedPhotoID == nil || !vm.capturedPhotos.contains(where: { $0.id == selectedPhotoID }) {
                selectedPhotoID = newFirstID
                resetZoom()
            }
        }
    }

    // MARK: - 主图缩放与滑动切换画布

    private func photoCanvas(photo: CapturedPhotoItem, containerSize: CGSize) -> some View {
        ZStack {
            Image(uiImage: photo.previewImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: containerSize.width, height: containerSize.height)
                .scaleEffect(effectiveZoom, anchor: .center)
                .offset(effectivePan)
                .clipped()
                .contentShape(Rectangle())
                // 双击 2.5x 检焦 / 复位
                .highPriorityGesture(
                    TapGesture(count: 2)
                        .onEnded {
                            if effectiveZoom > 1.05 {
                                resetZoom()
                            } else {
                                withAnimation(.snappy(duration: 0.22)) {
                                    zoomScale = 2.5
                                }
                            }
                        }
                )
                // 单击隐藏/显示顶底操作条
                .simultaneousGesture(
                    TapGesture(count: 1)
                        .onEnded {
                            isChromeHidden.toggle()
                        }
                )
                // 双指捏合缩放 (1x...6x)
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            gestureZoomScale = value.magnification
                        }
                        .onEnded { value in
                            let finalScale = min(max(zoomScale * value.magnification, 1.0), 6.0)
                            zoomScale = finalScale
                            gestureZoomScale = 1.0
                            if finalScale <= 1.02 {
                                resetZoom()
                            } else {
                                panOffset = clampedPan(panOffset, scale: finalScale, containerSize: containerSize)
                            }
                        }
                )
                // 放大态拖动巡检；未放大态左右轻滑切换上一张/下一张
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            guard effectiveZoom > 1.02 else { return }
                            gesturePanOffset = value.translation
                        }
                        .onEnded { value in
                            if effectiveZoom > 1.02 {
                                let proposed = CGSize(
                                    width: panOffset.width + value.translation.width,
                                    height: panOffset.height + value.translation.height
                                )
                                panOffset = clampedPan(proposed, scale: zoomScale, containerSize: containerSize)
                                gesturePanOffset = .zero
                            } else if abs(value.translation.width) > 48,
                                      abs(value.translation.width) > abs(value.translation.height) * 1.3 {
                                if value.translation.width < 0 {
                                    navigate(delta: 1)
                                } else {
                                    navigate(delta: -1)
                                }
                            }
                        }
                )

            // 放大倍率微标
            if effectiveZoom > 1.05 {
                VStack {
                    Spacer()
                    Button {
                        resetZoom()
                    } label: {
                        Text(String(format: "%.1fx 复位", effectiveZoom))
                            .font(.robotoFlex(size: 11, weight: 700))
                            .monospacedDigit()
                            .foregroundStyle(.black)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(MonitorTheme.accentAmber, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, vm.capturedPhotos.count > 1 && !isChromeHidden ? 74 : 18)
                }
                .transition(.opacity)
            }
        }
    }

    // MARK: - 顶部信息与操作栏

    private func topBar(photo: CapturedPhotoItem) -> some View {
        HStack(spacing: 10) {
            // 左侧：序号 + 文件名 + 规格参数
            HStack(spacing: 8) {
                Text("\(selectedIndex + 1) / \(vm.capturedPhotos.count)")
                    .font(.robotoFlex(size: 11.5, weight: 750))
                    .monospacedDigit()
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(MonitorTheme.accentAmber, in: Capsule())

                VStack(alignment: .leading, spacing: 1) {
                    Text(photo.filename)
                        .font(.robotoFlex(size: 12.5, weight: 650))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(photo.formatLabel) · \(photo.pixelSizeLabel) · \(photo.fileSizeLabel)")
                        .font(.robotoFlex(size: 10.5, weight: 500))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            // 右侧：纯白图标操作组（拉取最新 / 分享保存 / 删除缓存 / 关闭）
            HStack(spacing: 8) {
                refreshCameraButton

                if let url = photo.fileURL {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(MonitorTheme.surface.opacity(0.9), in: RoundedRectangle(cornerRadius: MonitorTheme.cardRadius, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: MonitorTheme.cardRadius, style: .continuous)
                                    .stroke(MonitorTheme.border, lineWidth: 0.6)
                            )
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    deleteCurrentPhoto(photo)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(MonitorTheme.surface.opacity(0.9), in: RoundedRectangle(cornerRadius: MonitorTheme.cardRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: MonitorTheme.cardRadius, style: .continuous)
                                .stroke(MonitorTheme.border, lineWidth: 0.6)
                        )
                }
                .buttonStyle(.plain)

                closeButton
            }
        }
        .padding(.leading, max(leadingInset, 14))
        .padding(.trailing, max(trailingInset, 14))
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.84), Color.black.opacity(0.0)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var emptyTopBar: some View {
        HStack {
            Text("刚拍照片预览")
                .font(.robotoFlex(size: 14, weight: 700))
                .foregroundStyle(.white)
            Spacer()
            HStack(spacing: 8) {
                refreshCameraButton
                closeButton
            }
        }
        .padding(.leading, max(leadingInset, 14))
        .padding(.trailing, max(trailingInset, 14))
        .padding(.top, 12)
    }

    private var refreshCameraButton: some View {
        Button {
            Task { await vm.pullCapturedPhotoFromCamera(manual: true) }
        } label: {
            Group {
                if vm.isFetchingCapturedPhoto {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.75)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 34, height: 34)
            .background(MonitorTheme.surface.opacity(0.9), in: RoundedRectangle(cornerRadius: MonitorTheme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MonitorTheme.cardRadius, style: .continuous)
                    .stroke(MonitorTheme.border, lineWidth: 0.6)
            )
        }
        .buttonStyle(.plain)
        .disabled(vm.isFetchingCapturedPhoto)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(MonitorTheme.surface.opacity(0.9), in: RoundedRectangle(cornerRadius: MonitorTheme.cardRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: MonitorTheme.cardRadius, style: .continuous)
                        .stroke(MonitorTheme.borderStrong, lineWidth: 0.6)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 底部胶片缩略图条

    private var bottomFilmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(vm.capturedPhotos) { item in
                        let isSelected = (item.id == currentPhoto?.id)
                        Button {
                            withAnimation(.snappy(duration: 0.18)) {
                                selectedPhotoID = item.id
                                resetZoom()
                            }
                        } label: {
                            Image(uiImage: item.thumbnailImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 58, height: 40)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(
                                            isSelected ? MonitorTheme.accentAmber : Color.white.opacity(0.18),
                                            lineWidth: isSelected ? 2 : 0.6
                                        )
                                )
                                .opacity(isSelected ? 1.0 : 0.62)
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                    }
                }
                .padding(.horizontal, max(leadingInset, trailingInset, 16))
                .padding(.vertical, 8)
            }
            .background(
                LinearGradient(
                    colors: [Color.black.opacity(0.0), Color.black.opacity(0.84)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .onChange(of: selectedPhotoID) { _, newID in
                if let newID {
                    withAnimation(.snappy(duration: 0.18)) {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - 空状态提示卡片

    private var emptyStateCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.white.opacity(0.45))

            Text("暂无刚拍的照片")
                .font(.robotoFlex(size: 15, weight: 700))
                .foregroundStyle(.white.opacity(0.92))

            Text("连接相机后按下快门，会自动拉取刚拍摄的照片到此预览。\n请确保相机「PC 遥控 → 静止影像保存目的地」设为「PC+相机」或「仅PC」。")
                .font(.robotoFlex(size: 11.5, weight: 450))
                .foregroundStyle(.white.opacity(0.56))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 380)

            HStack(spacing: 10) {
                Button {
                    Task { await vm.pullCapturedPhotoFromCamera(manual: true) }
                } label: {
                    HStack(spacing: 6) {
                        if vm.isFetchingCapturedPhoto {
                            ProgressView()
                                .tint(.black)
                                .scaleEffect(0.72)
                        }
                        Text("立即拉取相机照片")
                            .font(.robotoFlex(size: 12, weight: 700))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(MonitorTheme.accentAmber, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(vm.isFetchingCapturedPhoto)

                if vm.isTestPatternActive {
                    Button {
                        vm.captureSimulatedTestPhoto()
                    } label: {
                        Text("抓取仿真测试照片")
                            .font(.robotoFlex(size: 12, weight: 600))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 2)
        }
        .padding(24)
        .background(MonitorTheme.surface, in: RoundedRectangle(cornerRadius: MonitorTheme.drawerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MonitorTheme.drawerRadius, style: .continuous)
                .stroke(MonitorTheme.border, lineWidth: 0.6)
        )
    }

    // MARK: - 辅助逻辑

    private func navigate(delta: Int) {
        let count = vm.capturedPhotos.count
        guard count > 1 else { return }
        let target = min(max(selectedIndex + delta, 0), count - 1)
        guard target != selectedIndex else { return }
        let haptic = UISelectionFeedbackGenerator()
        haptic.selectionChanged()
        withAnimation(.snappy(duration: 0.18)) {
            selectedPhotoID = vm.capturedPhotos[target].id
            resetZoom()
        }
    }

    private func deleteCurrentPhoto(_ photo: CapturedPhotoItem) {
        let currentIdx = selectedIndex
        vm.deleteCapturedPhoto(photo)
        if vm.capturedPhotos.isEmpty {
            selectedPhotoID = nil
        } else {
            let nextIdx = min(currentIdx, vm.capturedPhotos.count - 1)
            selectedPhotoID = vm.capturedPhotos[nextIdx].id
        }
        resetZoom()
    }

    private func clampedPan(_ offset: CGSize, scale: CGFloat, containerSize: CGSize) -> CGSize {
        let maxX = max(0, (containerSize.width * (scale - 1.0)) * 0.5)
        let maxY = max(0, (containerSize.height * (scale - 1.0)) * 0.5)
        return CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
    }

    private func resetZoom() {
        withAnimation(.snappy(duration: 0.22)) {
            zoomScale = 1.0
            gestureZoomScale = 1.0
            panOffset = .zero
            gesturePanOffset = .zero
        }
    }
}

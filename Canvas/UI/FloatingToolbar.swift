// FloatingToolbar.swift
// 右下角悬浮工具栏：收起时 single FAB，点击展开绘画面板。
// 面板分区：工具 / 颜色 / 笔触 / 内容 / 操作 / 画布，工具选中即进入绘画模式。

import PhotosUI
import SwiftUI

struct FloatingToolbar: View {
    @ObservedObject var drawing: DrawingSettings
    var onResetCamera: () -> Void
    var onFitContent: () -> Void
    @Binding var showGrid: Bool
    @Binding var showMinimap: Bool
    @State private var expanded: Bool
    @State private var photoItem: PhotosPickerItem?

    /// DEBUG 启动参数 -CanvasShowTools：展开状态启动（截图验证用）
    static var debugStartExpanded: Bool {
        #if DEBUG
        CommandLine.arguments.contains("-CanvasShowTools")
        #else
        false
        #endif
    }

    init(drawing: DrawingSettings, showGrid: Binding<Bool>, showMinimap: Binding<Bool>, onResetCamera: @escaping () -> Void, onFitContent: @escaping () -> Void, startExpanded: Bool = false) {
        self.drawing = drawing
        self._showGrid = showGrid
        self._showMinimap = showMinimap
        self.onResetCamera = onResetCamera
        self.onFitContent = onFitContent
        self._expanded = State(initialValue: startExpanded)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            if expanded {
                panel
                    .transition(.scale(scale: 0.9, anchor: .bottomTrailing).combined(with: .opacity))
            }
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    expanded.toggle()
                }
            } label: {
                Image(systemName: expanded ? "xmark" : "paintpalette.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Color.accentColor, in: Circle())
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "收起工具" : "展开工具")
            .accessibilityIdentifier("fabToggle")
        }
    }

    // MARK: - 展开面板

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 工具
            sectionLabel("工具")
            HStack(spacing: 10) {
                toolButton(icon: "hand.draw.fill", selected: drawing.mode == .navigate) {
                    drawing.mode = .navigate
                }
                toolButton(icon: "paintbrush.pointed.fill", selected: isPenActive) {
                    drawing.mode = .draw
                    drawing.tool = .pen
                }
                toolButton(icon: "eraser.fill", selected: isEraserActive) {
                    drawing.mode = .draw
                    // 重复点橡皮：在整擦/部擦之间切换
                    if drawing.tool == .eraserWhole {
                        drawing.tool = .eraserPartial
                    } else if drawing.tool == .eraserPartial {
                        drawing.tool = .eraserWhole
                    } else {
                        drawing.tool = .eraserWhole
                    }
                }
                toolButton(icon: "lasso", selected: isLassoActive) {
                    drawing.mode = .draw
                    drawing.tool = .lasso
                }
            }

            // 橡皮细分
            if isEraserActive {
                Picker("橡皮模式", selection: eraserModeBinding) {
                    Text("整笔擦除").tag(false)
                    Text("局部擦除").tag(true)
                }
                .pickerStyle(.segmented)
            }

            // 颜色（仅画笔）
            if drawing.tool == .pen {
                sectionLabel("颜色")
                HStack(spacing: 12) {
                    ForEach(drawing.palette, id: \.self) { rgba in
                        let selected = drawing.color == rgba
                        Button {
                            drawing.color = rgba
                        } label: {
                            Circle()
                                .fill(rgba.swiftUIColor)
                                .frame(width: 26, height: 26)
                                .overlay(
                                    Circle().stroke(
                                        selected ? Color.primary : Color.primary.opacity(0.15),
                                        lineWidth: selected ? 2.5 : 1
                                    )
                                )
                                .scaleEffect(selected ? 1.12 : 1.0)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            // 笔触预览 + 笔宽（套索除外）
            if drawing.tool != .lasso {
                sectionLabel(drawing.tool == .pen ? "笔触" : "橡皮")
                Capsule()
                    .fill(strokePreviewColor)
                    .frame(height: strokePreviewHeight)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 4)
                HStack(spacing: 8) {
                    Slider(value: widthBinding, in: widthRange, step: 1)
                        .tint(.accentColor)
                    Text("\(Int(widthBinding.wrappedValue))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 26)
                        .accessibilityIdentifier("widthValue")
                }
            }

            Divider()

            // 内容（新建节点自动切回导航模式，落在视口中心）
            sectionLabel("内容")
            HStack(spacing: 10) {
                toolButton(icon: "square.fill", selected: false) {
                    drawing.mode = .navigate
                    drawing.addShape(.rectangle)
                }
                toolButton(icon: "circle.fill", selected: false) {
                    drawing.mode = .navigate
                    drawing.addShape(.ellipse)
                }
                toolButton(icon: "textformat", selected: false) {
                    drawing.mode = .navigate
                    drawing.addText()
                }
                toolButton(icon: "note.text", selected: false) {
                    drawing.mode = .navigate
                    drawing.addNote()
                }
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Image(systemName: "photo.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("插入图片")
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                photoItem = nil
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        drawing.mode = .navigate
                        drawing.addImage(data: data)
                    }
                }
            }

            Divider()

            // 操作
            HStack(spacing: 10) {
                actionButton(icon: "arrow.uturn.backward", enabled: drawing.canUndo) { drawing.undo() }
                actionButton(icon: "arrow.uturn.forward", enabled: drawing.canRedo) { drawing.redo() }
                Spacer()
                actionButton(icon: "trash", enabled: drawing.strokeCount > 0 || drawing.nodeCount > 0, role: .destructive) { drawing.clear() }
            }

            Divider()

            // 画布开关
            HStack(spacing: 10) {
                toggleButton(icon: "grid", label: "网格", on: showGrid) { showGrid.toggle() }
                toggleButton(icon: "hand.tap.fill", label: "手绘", on: drawing.allowFingerDrawing) {
                    drawing.allowFingerDrawing.toggle()
                }
                toggleButton(icon: "map", label: "导览", on: showMinimap) { showMinimap.toggle() }
            }
            HStack(spacing: 10) {
                cameraButton(icon: "arrow.up.left.and.arrow.down.right", label: "适合") { onFitContent() }
                cameraButton(icon: "viewfinder.circle.fill", label: "复位") { onResetCamera() }
            }

            // 节点选择行
            if drawing.hasNodeSelection {
                Divider()
                HStack(spacing: 10) {
                    Button("删除节点") { drawing.deleteSelection() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.red)
                    Button("取消选择") { drawing.clearSelection() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Text("拖动节点可移动，再次点按文本可编辑")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            // 选择行
            if drawing.hasSelection {
                Divider()
                HStack(spacing: 10) {
                    Button("删除选中(\(drawing.selectedCount))") { drawing.deleteSelection() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.red)
                    Button("取消选择") { drawing.clearSelection() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Text("拖动框内可移动选中")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(width: 300)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
    }

    // MARK: - 组件

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.bottom, -6)
    }

    private func toolButton(icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(selected ? .white : .primary)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(
                    selected ? Color.accentColor : Color.primary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 14)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(icon)
        .accessibilityIdentifier(icon)
    }

    private func actionButton(icon: String, enabled: Bool, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(enabled ? (role == .destructive ? Color.red : Color.primary) : Color(uiColor: .tertiaryLabel))
                .frame(width: 52, height: 40)
                .background(Color.primary.opacity(enabled ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityIdentifier(icon)
    }

    private func cameraButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.title3)
                Text(label)
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .frame(width: 56, height: 48)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func toggleButton(icon: String, label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.title3)
                Text(label)
                    .font(.caption2)
            }
            .foregroundStyle(on ? Color.accentColor : .secondary)
            .frame(width: 56, height: 48)
            .background(
                on ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 12)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 状态

    private var isPenActive: Bool {
        drawing.mode == .draw && drawing.tool == .pen
    }

    private var isEraserActive: Bool {
        drawing.mode == .draw && (drawing.tool == .eraserWhole || drawing.tool == .eraserPartial)
    }

    private var isLassoActive: Bool {
        drawing.mode == .draw && drawing.tool == .lasso
    }

    private var eraserModeBinding: Binding<Bool> {
        Binding(
            get: { drawing.tool == .eraserPartial },
            set: { drawing.tool = $0 ? .eraserPartial : .eraserWhole }
        )
    }

    private var strokePreviewColor: Color {
        drawing.tool == .pen ? drawing.color.swiftUIColor : Color.gray.opacity(0.7)
    }

    private var strokePreviewHeight: CGFloat {
        let w = widthBinding.wrappedValue
        if drawing.tool == .pen {
            return min(max(w * 0.5, 2), 20)
        } else {
            return min(max(w * 0.3, 2), 24)
        }
    }

    private var widthBinding: Binding<CGFloat> {
        Binding(
            get: {
                switch drawing.tool {
                case .pen, .lasso:
                    return drawing.lineWidth
                case .eraserWhole, .eraserPartial:
                    return drawing.eraserWidth
                }
            },
            set: { v in
                switch drawing.tool {
                case .pen, .lasso:
                    drawing.lineWidth = v
                case .eraserWhole, .eraserPartial:
                    drawing.eraserWidth = v
                }
            }
        )
    }

    private var widthRange: ClosedRange<CGFloat> {
        switch drawing.tool {
        case .pen, .lasso:
            return 2...40
        case .eraserWhole, .eraserPartial:
            return 4...80
        }
    }
}

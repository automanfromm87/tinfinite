// ContentNodeViews.swift
// 内容节点视图：按 ContentNode 构建 UIView（形状/文本/便签/图片）。
// 视图 frame 即世界矩形，挂在 contentView 下随画布变换；选中态画蓝色边框。

import UIKit

/// 节点容器视图（hit 测试/手势过滤凭此类型识别节点区域）
final class ContentNodeView: UIView {
    let nodeID: UUID
    private(set) var kind: ContentNodeKind

    /// 轻点（Controller 赋值：选中/聚焦）
    var onTap: ((ContentNodeView) -> Void)?
    /// 拖拽（Controller 赋值：移动）
    var onPan: ((ContentNodeView, UIPanGestureRecognizer) -> Void)?

    weak var textView: UITextView?
    private var shapeLayer: CAShapeLayer?
    private var shape: ContentShape?
    private weak var imageView: UIImageView?

    /// 选中边框（世界单位线宽，随缩放一起缩放）
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            layer.borderWidth = isSelected ? 2 : 0
            layer.borderColor = isSelected ? UIColor.systemBlue.cgColor : nil
        }
    }

    init(node: ContentNode, image: UIImage? = nil) {
        self.nodeID = node.id
        self.kind = node.kind
        super.init(frame: node.frame)
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityIdentifier = "contentNode"
        accessibilityLabel = switch node.kind {
        case .shape: "形状节点"
        case .text: "文本节点"
        case .note: "便签节点"
        case .image: "图片节点"
        }
        accessibilityValue = node.text.isEmpty ? nil : node.text
        buildContent(node: node, image: image)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        redrawShape()
    }

    /// 模型变更后同步外观（frame 由 Controller 经 moveItem 设置，不在这里改）
    func sync(with node: ContentNode, image: UIImage?) {
        accessibilityValue = node.text.isEmpty ? nil : node.text
        if let tv = textView, tv.text != node.text, !tv.isFirstResponder {
            tv.text = node.text
        }
        if let layer = shapeLayer {
            layer.fillColor = node.fill.uiColor.cgColor
        }
        if node.kind == .note {
            backgroundColor = node.fill.uiColor
        }
        if let iv = imageView {
            iv.image = image
        }
    }

    // MARK: - 内容构建

    private func buildContent(node: ContentNode, image: UIImage?) {
        switch node.kind {
        case .shape(let shape):
            self.shape = shape
            let layer = CAShapeLayer()
            layer.fillColor = node.fill.uiColor.cgColor
            self.shapeLayer = layer
            self.layer.addSublayer(layer)
            redrawShape()
        case .text:
            let tv = makeTextView(fontSize: 17, node: node)
            addPinned(tv)
            textView = tv
        case .note:
            backgroundColor = node.fill.uiColor
            layer.cornerRadius = 10
            let tv = makeTextView(fontSize: 15, node: node)
            tv.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
            addPinned(tv)
            textView = tv
        case .image:
            let iv = UIImageView(image: image)
            iv.contentMode = .scaleAspectFit
            iv.backgroundColor = .secondarySystemBackground
            iv.clipsToBounds = true
            addPinned(iv)
            imageView = iv
        }
    }

    private func makeTextView(fontSize: CGFloat, node: ContentNode) -> UITextView {
        let tv = UITextView()
        tv.text = node.text
        tv.font = .systemFont(ofSize: fontSize)
        tv.textColor = .label
        tv.backgroundColor = .clear
        tv.isEditable = false // 选中后由 Controller 打开
        tv.isScrollEnabled = false
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        return tv
    }

    private func addPinned(_ view: UIView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func redrawShape() {
        guard let shape, let layer = shapeLayer else { return }
        layer.frame = bounds
        let path: UIBezierPath
        switch shape {
        case .rectangle:
            path = UIBezierPath(rect: bounds)
        case .ellipse:
            path = UIBezierPath(ovalIn: bounds)
        }
        layer.path = path.cgPath
    }

    // MARK: - 手势转发

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        onTap?(self)
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        onPan?(self, recognizer)
    }
}

// CanvasSidebar.swift
// 画布管理侧边栏（仿 Notes）：文档列表 + 新建/重命名/删除。

import SwiftUI

struct CanvasSidebar: View {
    @ObservedObject var library: CanvasLibrary
    @Binding var selection: UUID?

    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var query = ""
    @State private var exportRequest: ExportRequest?
    @State private var exporting = false

    /// 导出结果（sheet(item:) 要求 Identifiable；URL 本身不是）
    private struct ExportRequest: Identifiable {
        let id: UUID
        let title: String
        let url: URL
    }

    var body: some View {
        Group {
            if library.documents.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "paintpalette")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("还没有画布")
                        .foregroundStyle(.secondary)
                    Button("新建画布") { createAndSelect() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                // 不用 List(selection:)：SwiftUI 会在 List 自身更新中途回写 selection
                // binding，触发“Publishing changes from within view updates”。手动管理选中。
                List {
                    ForEach(filteredDocuments, id: \.meta.id) { doc in
                        Button {
                            selection = doc.meta.id
                        } label: {
                            HStack(spacing: 10) {
                                AsyncThumbnailView(library: library, doc: doc)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(doc.meta.title)
                                        .font(.headline)
                                        .lineLimit(1)
                                    Text(subtitle(for: doc))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("documentRow")
                        .listRowBackground(selection == doc.meta.id ? Color.accentColor.opacity(0.12) : nil)
                        // 菜单构建器是「急切求值」的：SwiftUI 在每次 row body 求值时就会
                        // 运行这个闭包（非逃逸 @ViewBuilder），所以这里绝不能做任何重活。
                        // 旧版在此直接渲染整幅 PNG，导致每次自动存档（写字期间 ~0.5s 一次）
                        // 都在主线程跑一遍 tessellate + 2048px 位图 + PNG 编码 + 临时文件写。
                        .contextMenu {
                            Button("重命名") { beginRename(doc) }
                            // O(1) 字典查表，无 IO
                            if library.strokeCount(id: doc.meta.id) > 0 || !doc.nodes.isEmpty {
                                Button {
                                    startExport(doc)
                                } label: {
                                    Label("导出 PNG", systemImage: "square.and.arrow.up")
                                }
                            }
                            Button("删除", role: .destructive) { deleteDocument(doc.meta.id) }
                        }
                    }
                    .onDelete(perform: deleteAt)
                }
                .listStyle(.sidebar)
                .searchable(text: $query, prompt: "搜索标题或节点文字")
            }
        }
        .navigationTitle("画布")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: createAndSelect) {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("新建画布")
            }
        }
        .alert("重命名画布", isPresented: renameAlertBinding) {
            TextField("标题", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("确定") {
                if let id = renamingID {
                    library.rename(id: id, title: renameText)
                }
            }
        }
        .sheet(item: $exportRequest) { request in
            ShareLink(item: request.url, preview: SharePreview(request.title, image: request.url)) {
                Label("分享 \(request.title).png", systemImage: "square.and.arrow.up")
                    .padding()
            }
            .presentationDetents([.height(160)])
        }
    }

    // MARK: - 内部

    /// 搜索：标题或任一节点文字命中（大小写不敏感）
    private var filteredDocuments: [CanvasDocument] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return library.documents }
        return library.documents.filter { doc in
            doc.meta.title.lowercased().contains(q)
                || doc.nodes.contains { $0.text.lowercased().contains(q) }
        }
    }

    private func subtitle(for doc: CanvasDocument) -> String {
        "\(doc.meta.updatedAt.formatted(date: .numeric, time: .shortened)) · \(library.strokeCount(id: doc.meta.id)) 笔 · \(doc.nodes.count) 节点"
    }

    /// 导出 PNG：只在用户真正点了菜单项时才做，且渲染/编码/落盘全在后台线程。
    /// 笔画先经 library 的后台读盘 API 预热缓存，避免主线程同步解码整档。
    private func startExport(_ doc: CanvasDocument) {
        guard !exporting else { return }
        exporting = true
        let id = doc.meta.id
        let safeTitle = doc.meta.title.replacingOccurrences(of: "/", with: "-")
        Task { @MainActor in
            defer { exporting = false }
            _ = await library.strokes(for: id)          // 后台读盘 + 填缓存
            guard let full = library.document(id: id) else { return }  // 现在恒为缓存命中
            let dir = library.imagesSourceDirectory
            let url = await Task.detached(priority: .userInitiated) { () -> URL? in
                guard let data = DocumentExporter.pngData(
                    for: full,
                    imageData: { DrawingStore.loadImageData(file: $0, beside: dir) }
                ) else { return nil }
                // 专用子目录：每次导出前清空，临时 PNG 不会无限堆积
                let exportDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("CanvasExport", isDirectory: true)
                try? FileManager.default.removeItem(at: exportDir)
                guard (try? FileManager.default.createDirectory(
                    at: exportDir, withIntermediateDirectories: true
                )) != nil else { return nil }
                let out = exportDir.appendingPathComponent("\(safeTitle).png")
                guard (try? data.write(to: out, options: .atomic)) != nil else { return nil }
                return out
            }.value
            if let url {
                exportRequest = ExportRequest(id: id, title: safeTitle, url: url)
            }
        }
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { renamingID != nil },
            set: { if !$0 { renamingID = nil } }
        )
    }

    private func createAndSelect() {
        let doc = library.createDocument()
        selection = doc.meta.id
    }

    private func beginRename(_ doc: CanvasDocument) {
        renamingID = doc.meta.id
        renameText = doc.meta.title
    }

    private func deleteDocument(_ id: UUID) {
        library.delete(id: id)
        if selection == id { selection = nil }
    }

    private func deleteAt(_ offsets: IndexSet) {
        let ids = offsets.map { filteredDocuments[$0].meta.id }
        for id in ids { deleteDocument(id) }
    }
}

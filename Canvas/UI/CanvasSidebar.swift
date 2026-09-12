// CanvasSidebar.swift
// 画布管理侧边栏（仿 Notes）：文档列表 + 新建/重命名/删除。

import SwiftUI

struct CanvasSidebar: View {
    @ObservedObject var library: CanvasLibrary
    @Binding var selection: UUID?

    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var query = ""

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
                                DocumentThumbnailView(doc: doc)
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
                        .contextMenu {
                            Button("重命名") { beginRename(doc) }
                            if let url = pngExportURL(for: doc) {
                                ShareLink(item: url, preview: SharePreview(doc.meta.title, image: url)) {
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
        "\(doc.meta.updatedAt.formatted(date: .numeric, time: .shortened)) · \(doc.strokes.count) 笔 · \(doc.nodes.count) 节点"
    }

    /// 导出 PNG 到临时文件（菜单打开时才生成一次；空文档返回 nil，不显示入口）
    private func pngExportURL(for doc: CanvasDocument) -> URL? {
        guard let data = DocumentExporter.pngData(for: doc, imageData: { library.imageData(file: $0) })
        else { return nil }
        let safeTitle = doc.meta.title.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeTitle)-\(doc.meta.id.uuidString.prefix(8)).png")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
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

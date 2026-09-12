//
//  ContentView.swift
//  Canvas
//

import SwiftUI

struct ContentView: View {
    @StateObject private var library = CanvasLibrary()
    @State private var selection: UUID?
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            // compact（iPhone）：NavigationStack + 显式 destination。
            // NavigationSplitView 在 compact 下只响应 List(selection:)/NavigationLink
            // 的选中，手写 Button 回写 selection 只高亮不 push，必须走 Stack。
            if sizeClass == .compact {
                NavigationStack {
                    CanvasSidebar(library: library, selection: $selection)
                        .navigationDestination(item: $selection) { id in
                            detailView(for: id)
                        }
                }
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    CanvasSidebar(library: library, selection: $selection)
                } detail: {
                    if let id = selection {
                        detailView(for: id)
                    } else {
                        ContentUnavailableView(
                            "选择一张画布",
                            systemImage: "paintpalette",
                            description: Text("在侧边栏选择或新建一张画布")
                        )
                    }
                }
            }
        }
        .onAppear {
            #if DEBUG
            if CommandLine.arguments.contains("-CanvasOpenFirst") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    if selection == nil, let first = library.documents.first {
                        selection = first.meta.id
                    }
                }
            }
            #endif
        }
    }

    @ViewBuilder
    private func detailView(for id: UUID) -> some View {
        if library.document(id: id) != nil {
            CanvasDetailView(
                library: library,
                documentID: id,
                columnVisibility: $columnVisibility,
                selection: $selection
            )
            .id(id)
        } else {
            ContentUnavailableView(
                "画布已删除",
                systemImage: "trash",
                description: Text("返回列表选择其他画布")
            )
        }
    }
}

#Preview {
    ContentView()
}

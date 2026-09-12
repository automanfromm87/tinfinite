//
//  ContentView.swift
//  Canvas
//

import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var library = CanvasLibrary()
    @State private var selection: UUID?
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase

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
        // 列表页切后台也排干存档队列（重命名等操作是异步落盘的）
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            let lib = library
            Task { @MainActor in
                let taskID = UIApplication.shared.beginBackgroundTask(withName: "canvas-flush") {}
                await lib.flushSaves()
                UIApplication.shared.endBackgroundTask(taskID)
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
        // hasDocument 只看 manifest 壳：body 里绝不触发笔画懒加载（读盘 + 发布）
        if library.hasDocument(id: id) {
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

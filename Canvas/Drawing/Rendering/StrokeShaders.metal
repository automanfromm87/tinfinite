// StrokeShaders.metal
// 笔画渲染 shader：顶点是相机相对坐标（世界 − renderOrigin，CPU 侧 double 相减），
// viewport 变换在 vertex shader 里做，pan/zoom 只需更新 uniform，零 CPU、零重建 mesh。
// 相对坐标 + 相对中心保证 GPU 只接触视口尺度的小数，远离原点 + 深度缩放不抖动。

#include <metal_stdlib>
using namespace metal;

// 与 Swift 侧 StrokeUniforms 布局一致：float2 + float + float2 = 24 字节
struct StrokeUniforms {
    float2 center;    // 相机中心相对 renderOrigin 的偏移（落在视图中心）
    float  scale;     // 世界 -> 屏幕倍数
    float2 viewSize;  // 视图尺寸（屏幕点）
};

struct StrokeVertexIn {
    float2 position [[attribute(0)]];
    float4 color    [[attribute(1)]];
};

struct StrokeVertexOut {
    float4 position [[position]];
    float4 color;
};

vertex StrokeVertexOut stroke_vertex(
    StrokeVertexIn in       [[stage_in]],
    constant StrokeUniforms &u [[buffer(1)]]
) {
    StrokeVertexOut out;
    float2 screen = (in.position - u.center) * u.scale + u.viewSize * 0.5;
    float2 clip = float2(
        u.viewSize.x > 0 ? (screen.x / u.viewSize.x * 2.0 - 1.0) : 0.0,
        // Metal NDC y 朝上，UIKit y 朝下
        u.viewSize.y > 0 ? (1.0 - screen.y / u.viewSize.y * 2.0) : 0.0
    );
    out.position = float4(clip, 0.0, 1.0);
    out.color = in.color;
    return out;
}

fragment float4 stroke_fragment(StrokeVertexOut in [[stage_in]]) {
    return in.color;
}

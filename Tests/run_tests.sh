#!/bin/bash
# 纯逻辑层测试（macOS 系统 swiftc 直接编译运行，无需 Xcode 工程改动）
# 覆盖：Canvas 坐标数学、笔画采样/几何、编辑（橡皮/套索/移动/LOD/Store/持久化）
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Canvas"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

run_suite() {
  local name="$1"; local suite="$2"; shift 2
  # 顶层测试代码必须位于 main.swift：每套件独立目录
  mkdir -p "$TMP/$name"
  cp "$suite" "$TMP/$name/main.swift"
  # -DDEBUG：打开单测专用钩子（如 StrokeStore.gridCountForTest），不影响 App 产物
  if swiftc -DDEBUG -o "$TMP/$name/$name" "$TMP/$name/main.swift" "$@" 2>"$TMP/$name.err"; then
    if "$TMP/$name/$name"; then
      return 0
    else
      echo "[$name] TEST FAILURES (see above)"
      return 1
    fi
  else
    echo "[$name] COMPILE FAILED:"
    head -20 "$TMP/$name.err"
    return 1
  fi
}

FAIL=0
run_suite camera \
  "$ROOT/Tests/Suites/CameraSuite.swift" \
  "$SRC/CanvasCore/Camera.swift" \
  "$SRC/CanvasCore/Viewport.swift" \
  "$SRC/UI/MinimapMath.swift" || FAIL=1

run_suite drawing \
  "$ROOT/Tests/Suites/DrawingSuite.swift" \
  "$SRC/Drawing/Strokes/StrokeModel.swift" \
  "$SRC/Drawing/Strokes/OneEuroFilter.swift" \
  "$SRC/Drawing/Strokes/StrokeSampler.swift" \
  "$SRC/Drawing/Strokes/StrokeGeometry.swift" || FAIL=1

run_suite editing \
  "$ROOT/Tests/Suites/EditingSuite.swift" \
  "$SRC/CanvasCore/Camera.swift" \
  "$SRC/CanvasCore/PaperTheme.swift" \
  "$SRC/Drawing/Strokes/StrokeModel.swift" \
  "$SRC/Drawing/Strokes/OneEuroFilter.swift" \
  "$SRC/Drawing/Strokes/StrokeSampler.swift" \
  "$SRC/Drawing/Strokes/StrokeGeometry.swift" \
  "$SRC/Drawing/Strokes/StrokeEditing.swift" \
  "$SRC/Drawing/Strokes/StrokeSpatialGrid.swift" \
  "$SRC/Drawing/Strokes/StrokeStore.swift" \
  "$SRC/Drawing/Input/PalmRejection.swift" \
  "$SRC/Content/ContentNode.swift" \
  "$SRC/Content/ContentStore.swift" \
  "$SRC/UI/MinimapMath.swift" \
  "$SRC/Export/DocumentExporter.swift" \
  "$SRC/Drawing/DrawingStore.swift" \
  "$SRC/Library/CanvasLibrary.swift" || FAIL=1

if [ "$FAIL" -eq 0 ]; then
  echo "ALL SUITES PASSED"
else
  echo "SOME SUITES FAILED"
fi
exit "$FAIL"

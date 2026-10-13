#!/bin/bash
#  生成 App 图标（icon/icon.icns）
#
#  为什么要用脚本而不是手搓一个 .icns：
#    · .icns 是二进制资源，出问题没法 review，也没法在别的机器上重做
#    · 换图时只要替换 icon/icon-source.png 再跑一次就行
#    · 构建流程会自动调用它，图标丢了也能自己补回来
#
#  流水线：裁成正方形 → 缩放到 1024 → 留出 macOS 圆角安全边距 → 生成 iconset → iconutil
#
#  用法：
#    ./icon/build-icon.sh              # 用默认的 icon/icon-source.png
#    SRC=xxx.png ./icon/build-icon.sh  # 换一张源图
#
#  可用环境变量微调取景（像素，相对源图）：
#    CROP_X CROP_Y CROP_SIZE  正方形裁剪区域，默认按人像取中上部
#    MARGIN_RATIO             图标四周留白比例（系统还会再套圆角遮罩，所以留一点点就够）

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ICON_DIR="$PROJECT_DIR/icon"
SRC="${SRC:-$ICON_DIR/icon-source.png}"
OUT_ICNS="$ICON_DIR/icon.icns"
WORK="$(mktemp -d)"

MARGIN_RATIO="${MARGIN_RATIO:-0.04}"

echo "▶ 图标源文件: $SRC"

if [ ! -f "$SRC" ]; then
  echo "✗ 找不到源图：$SRC"
  exit 1
fi

# ---------- 1. 把源图统一成 PNG（可能是 jpg/webp） ----------
BASE_PNG="$WORK/base.png"
/usr/bin/sips -s format png "$SRC" --out "$BASE_PNG" >/dev/null

# ---------- 2. 确定正方形裁剪区域 ----------
read -r W H < <(/usr/bin/sips -g pixelWidth -g pixelHeight "$BASE_PNG" \
  | /usr/bin/awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w, h}')

CROP_SIZE="${CROP_SIZE:-$(( W * 73 / 100 ))}"
# 默认取景：把人物放在画面中央（原图是竖构图，四周留白很多，需要裁掉）
CROP_X="${CROP_X:-$(( W * 21 / 100 ))}"
CROP_Y="${CROP_Y:-$(( H * 5 / 100 ))}"

# 别让裁剪框跑出画面
if [ "$CROP_X" -lt 0 ]; then CROP_X=0; fi
if [ "$CROP_Y" -lt 0 ]; then CROP_Y=0; fi
if [ $(( CROP_X + CROP_SIZE )) -gt "$W" ]; then CROP_SIZE=$(( W - CROP_X )); fi
if [ $(( CROP_Y + CROP_SIZE )) -gt "$H" ]; then CROP_SIZE=$(( H - CROP_Y )); fi

echo "▶ 源图 ${W}×${H}，裁剪 x=$CROP_X y=$CROP_Y 边长=$CROP_SIZE"

CANVAS=1024
SQUARE="$WORK/square.png"
/usr/bin/sips -c "$CROP_SIZE" "$CROP_SIZE" --cropOffset "$CROP_Y" "$CROP_X" \
  "$BASE_PNG" --out "$SQUARE" >/dev/null

# ---------- 3. 缩放到画布内并留出安全边距 ----------
INNER=$(/usr/bin/python3 -c "print(int($CANVAS * (1 - 2 * $MARGIN_RATIO)))")
RESIZED="$WORK/resized.png"
/usr/bin/sips -z "$INNER" "$INNER" "$SQUARE" --out "$RESIZED" >/dev/null

MASTER="$WORK/master-1024.png"
/usr/bin/python3 - "$RESIZED" "$MASTER" "$CANVAS" "$INNER" <<'PY'
import sys
from PIL import Image
src, dst, canvas, inner = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
art = Image.open(src).convert("RGBA")
# 背景取图案四角的平均色，和原图底色连成一片，不会有生硬的方框
w, h = art.size
corners = [art.getpixel(p) for p in ((2, 2), (w - 3, 2), (2, h - 3), (w - 3, h - 3))]
bg = tuple(sum(c[i] for c in corners) // len(corners) for i in range(3)) + (255,)
out = Image.new("RGBA", (canvas, canvas), bg)
off = (canvas - inner) // 2
out.paste(art, (off, off))
out.save(dst)
print(f"  合成 {canvas}×{canvas}，内容 {inner}×{inner}，边距 {off}px，底色 {bg[:3]}")
PY

# ---------- 4. 生成 iconset ----------
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  /usr/bin/sips -z $(( size * 2 )) $(( size * 2 )) "$MASTER" \
    --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  /usr/bin/sips -z "$size" "$size" "$MASTER" \
    --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
done

# ---------- 5. 打包 .icns ----------
/usr/bin/iconutil -c icns "$ICONSET" -o "$OUT_ICNS"
rm -rf "$WORK"

echo "✓ 图标已生成: $OUT_ICNS ($(du -h "$OUT_ICNS" | cut -f1))"

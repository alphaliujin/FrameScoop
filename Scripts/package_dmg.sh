#!/bin/bash
#
# package_dmg.sh
# 打包 Release 版本为可拖拽安装的 .dmg（含 Applications 快捷方式）。
#
# 用法:
#   bash Scripts/package_dmg.sh                  # 本地出包（等价 PHASE=all）
#   VOLNAME=FrameScoop bash Scripts/package_dmg.sh
#
#   公证发布走 notarize.sh，它会分两段调用本脚本（中间插入 app 的公证与装订）：
#   PHASE=stage  bash Scripts/package_dmg.sh     # 准备 staging + 重签，保留 staging
#   PHASE=finish bash Scripts/package_dmg.sh     # 从 staging 构建 DMG
#
# 产物: build/FrameScoop.dmg
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="FrameScoop"
CONFIG="${CONFIG:-Release}"
DERIVED="$ROOT/build/DerivedData"
APP_PATH="$DERIVED/Build/Products/$CONFIG/$APP_NAME.app"
BUILD_DIR="$ROOT/build"
STAGING="$BUILD_DIR/dmg-staging"
VOLNAME="${VOLNAME:-$APP_NAME}"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"
RW_DMG="$BUILD_DIR/$APP_NAME-rw.dmg"
# 「上次构建完成时间」标记，供 app_is_fresh 当比较基准。
# 不能拿产物文件的 mtime 当基准：xcodebuild 是增量的，无改动时完全不碰产物，
# 于是「输入比产物新」永远成立 → 每次出包都空跑一遍构建（详见 app_is_fresh 注释）。
BUILD_STAMP="$BUILD_DIR/.last-build-$CONFIG"

# 两阶段执行 —— notarize.sh 必须先把 app 单独公证并装订，再构建 DMG：
#   · app 只有被公证过才能装订票据（stapler 找不到票据会直接失败）；
#   · 装订后的 app 必须参与 DMG 的构建，否则用户离线首次启动时 Gatekeeper
#     要联网回查 Apple 才能放行（在线用户无感，离线直接失败）。
#   · 而 app 的装订又不改变 cdhash（票据写在 Contents/CodeResources，在
#     _CodeSignature 封条之外），所以「先装订再打进 DMG」完全合法。
# 于是打包拆成两段，中间那段留给 notarize.sh 做 app 公证：
#   all   （默认）= stage + finish，本地出包 / Apple Development 分发用
#   stage         = 只准备 staging 并完成 Developer ID 重签，**保留** staging 目录
#   finish        = 直接拿已有 staging 构建 DMG（不重新准备、不重签）
PHASE="${PHASE:-all}"
case "$PHASE" in
  all|stage|finish) ;;
  *) echo "✗ PHASE 只能是 all / stage / finish，当前: $PHASE" >&2; exit 1 ;;
esac

# 发布版重签身份：默认自动探测钥匙串中**有效**的 "Apple Development" 证书。
#
# 为什么必须是带 Team ID 的证书：
#   照片库走 Photos.framework，TCC 按签名登记 app。自签名 "FrameScoop Dev" 无 Team ID，
#   requestAuthorization 直接返回 denied、不弹窗、也不出现在「系统设置 › 隐私 › 照片」列表。
#   Apple Development 证书带 Team ID，照片库可正常授权。
#
# 为什么用 SHA-1 而不是证书名：
#   同一个名字在钥匙串里可能对应多条记录（本机实测 "Apple Development" 有 4 条，
#   历史上前一版脚本还遇到过同名两张证书）。按名字签名会歧义报错，SHA-1 唯一。
#
# 为什么可以自动探测、不必再手工维护哈希：
#   `security find-identity -v -p codesigning` 的 -v 只列出**通过有效性校验**的身份。
#   本机实测：不带 -v 输出 12 条（含 4 条 CSSMERR_TP_NOT_TRUSTED 的自签名证书），
#   带 -v 只剩 8 条。证书续期 / 吊销 / 过期都会自动反映到这张列表上，因此
#   「写死一个哈希」的做法（上一版上次更新于 2026-09-02）必然随证书轮换而失效。
#
# 为什么默认挑 Apple Development 而非 Developer ID：
#   本脚本的默认路径 PHASE=all 是**本地出包**（不公证）。若这里挑 Developer ID，
#   IS_DEVID 会变成 1，于是签出「Developer ID 签了名但从未公证」的 DMG ——
#   本机可用、别人机器上被 Gatekeeper 拒绝，且整条流水线不报任何错。
#   对外分发走 notarize.sh，它会显式传入 Developer ID 哈希覆盖此处。
#
# 需要固定某个身份时用环境变量覆盖：RELEASE_SIGN_IDENTITY=<SHA-1>
detect_release_identity() {
  security find-identity -v -p codesigning 2>/dev/null \
    | grep 'Apple Development' \
    | head -1 \
    | grep -oE '[0-9A-F]{40}'
}

if [ -n "${RELEASE_SIGN_IDENTITY:-}" ]; then
  echo "-> 签名身份（显式指定）: $RELEASE_SIGN_IDENTITY"
else
  RELEASE_SIGN_IDENTITY="$(detect_release_identity)"
  if [ -z "$RELEASE_SIGN_IDENTITY" ]; then
    echo "✗ 钥匙串中找不到有效的 Apple Development 证书。" >&2
    echo "  本地出包需要它注入 Team ID，否则照片库 TCC 无法授权。" >&2
    echo "  创建：Xcode → Settings → Accounts → Manage Certificates → + → Apple Development" >&2
    echo "  对外分发请改用: bash Scripts/notarize.sh（Developer ID + 公证）" >&2
    exit 1
  fi
  echo "-> 签名身份（自动探测）: $RELEASE_SIGN_IDENTITY"
fi

ENTITLEMENTS="$ROOT/FrameScoop/FrameScoop.entitlements"

cd "$ROOT"

# ---------------------------------------------------------------------------
# app_is_fresh
# 判断 $APP_PATH 是否足够新，可以直接拿去做 Developer ID 重签 + 公证。
#
# 返回 0 = 产物可信，跳过构建；非 0 = 产物陈旧，必须先重建。
#
# 背景（2026-09-16）：老版本这里只写了 `if [ ! -d "$APP_PATH" ]`，即产物只要
# 「存在」就完全跳过构建。结果 build/DerivedData 里躺着一个 8 月的 Release
# 产物，脚本会把它签上 Developer ID、公证、分发出去 —— 版本号是旧的，而且
# 整条流水线（codesign / notarytool / stapler）全都会成功，不报任何错。
#
# 实现时要想清楚的取舍：
#   1) 比较基准用哪个？
#      · 源码 mtime（find -newer）：实现最简单，但 git checkout / 切分支会把
#        mtime 全部刷新 → 误判为「陈旧」→ 多构建一次（安全，只是慢）。
#      · git 提交时间（git log -1 --format=%ct -- <paths>）：不受 checkout 影响，
#        但**看不见未提交的工作区改动** → 误判为「新」（危险）。
#      两者取「或」（任一更新即视为陈旧）比只取一个稳。
#   2) 监视哪些路径？至少 project.yml + FrameScoop/。要不要连 Scripts/ 一起算，
#      取决于你认为「改了打包脚本」是否也该触发重建（本脚本自己改不影响二进制）。
#   3) 拿什么当产物的时间戳？.app 目录 mtime 随内部文件增删变化，不稳；
#      Contents/MacOS/$APP_NAME（可执行文件）更可靠。
#   4) 留不留逃生舱（如 SKIP_FRESHNESS_CHECK=1）？CI 想强制跳过时有用，但也是
#      绕过防线的口子。
#
# 实现提示：判断「有没有比 STAMP 更新的文件」用
#   find <paths> -newer "$STAMP" -print -quit | grep -q .
# 比逐个文件比较省事得多。
# ---------------------------------------------------------------------------
app_is_fresh() {
  local stamp="$APP_PATH/Contents/MacOS/$APP_NAME"

  # 监视范围：构建配置 + 源码 + 打包脚本。
  #
  # 为什么连 Scripts/ 一起监视（刻意的选择）：
  #   「改了打包脚本」多数时候不影响二进制 —— 但 build.sh 里的 xcodebuild 参数
  #   会影响（换 destination / 加编译 flag / 改 ARCHS 都会改变产物）。两个方向的
  #   代价不对称：多监视一层 = 偶尔白构建一次（十几秒）；少监视一层 = 可能把
  #   不匹配的二进制发出去，且全流程不报错。宁可比需要的宽一点。
  #   想收窄就从 watch_rel 里去掉 Scripts。
  # 不监视 FrameScoop.xcodeproj：它是 project.yml 的生成物，mtime 每次 xcodegen
  #   都会刷新，监视它等于永远判「陈旧」；project.yml 本身已在列表里。
  local watch_rel=(project.yml FrameScoop Scripts)
  local watch=()
  local p
  for p in "${watch_rel[@]}"; do
    watch+=("$ROOT/$p")
  done

  # 逃生舱：CI 或明确知道产物可信时跳过判断。刻意打印警告，不让它被无声用掉。
  if [ "${SKIP_FRESHNESS_CHECK:-0}" = "1" ]; then
    echo "  ⚠️  SKIP_FRESHNESS_CHECK=1 —— 跳过新旧判断，直接复用现有产物"
    return 0
  fi

  if [ ! -f "$stamp" ]; then
    echo "  · 产物不存在"
    return 1
  fi

  # 比较基准：优先用「上次构建完成时间」标记，而不是可执行文件的 mtime。
  #
  # 为什么不能用产物 mtime 当基准（2026-09-16 实测踩到）：
  #   xcodebuild 是增量的 —— 没有实际改动时它**完全不碰**产物文件，可执行文件的
  #   mtime 保持不动。而输入文件（比如改过的打包脚本）却有了更新的 mtime，于是
  #   「输入比产物新」永远成立，每次出包都判陈旧 → 空跑一遍构建。优化完全失效，
  #   且表现得很隐蔽：exit 0、日志干净、产物正确，只是「跳过构建」这条路径
  #   永远不会被执行到。
  #   而一次 no-op 的 xcodebuild 恰恰**证明**了产物与源码一致 —— 所以「上次构建
  #   完成时间」才是语义正确的基准。标记缺失时退回可执行文件 mtime（偏保守：
  #   宁可多构建一次，不可漏构建）。
  local ref="$BUILD_STAMP"
  if [ ! -f "$ref" ]; then
    echo "  · 无构建时间标记，退回以产物 mtime 为基准"
    ref="$stamp"
  fi

  # 监视路径缺失（仓库结构变了 / 不在预期目录）→ 无从判断，按「陈旧」处理
  for p in "${watch[@]}"; do
    if [ ! -e "$p" ]; then
      echo "  · 监视路径缺失: $p"
      return 1
    fi
  done

  # 判据一：源码 mtime。
  #   能看到**未提交**的工作区改动 —— 这正是 git 判据的盲区；
  #   代价是 git checkout / 切分支会刷新 mtime → 误判陈旧 → 多构建一次（安全侧）。
  #   排除 .DS_Store：Finder 浏览一下目录就会刷新它，不该因此触发重建。
  if find "${watch[@]}" -name '.DS_Store' -prune -o -newer "$ref" -print -quit 2>/dev/null \
     | grep -q .; then
    echo "  · 有源码比上次构建新（mtime 判据）"
    return 1
  fi

  # 判据二：最近一次触及这些路径的提交时间。
  #   不受 checkout 影响，但**看不见未提交改动** —— 单靠它会漏判（危险方向），
  #   所以与判据一取「或」：任一认为陈旧即重建。
  local git_epoch ref_epoch
  git_epoch="$(git -C "$ROOT" log -1 --format=%ct -- "${watch_rel[@]}" 2>/dev/null || true)"
  if [ -n "$git_epoch" ]; then
    ref_epoch="$(stat -f %m "$ref" 2>/dev/null || echo 0)"
    if [ "$git_epoch" -gt "$ref_epoch" ]; then
      echo "  · 有比上次构建更新的提交（git 判据）"
      return 1
    fi
  fi

  return 0
}

# ---------------------------------------------------------------------------
# 发布签名身份校验（stage / finish 两段都要用：finish 段靠 IS_DEVID 决定签不签 DMG）
# ---------------------------------------------------------------------------
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$RELEASE_SIGN_IDENTITY"; then
  echo "✗ 找不到发布签名证书（SHA-1: ${RELEASE_SIGN_IDENTITY}）。" >&2
  echo "  运行 security find-identity -v -p codesigning，取证书哈希，" >&2
  echo "  通过 RELEASE_SIGN_IDENTITY 环境变量传入或更新本脚本。" >&2
  exit 1
fi

# 硬运行（--options runtime）按证书类型区分：
#   - Apple Development（本地分发）：勿加 —— Apple Development + HR 组合在 macOS 26
#     上会导致照片库 TCC 静默拒绝（不弹窗、不出现在系统设置列表，2026-09-02 探针实测）。
#   - Developer ID（公证分发，notarize.sh 传入）：必须加，公证硬性要求；--timestamp
#     打 RFC3161 时间戳同为公证必需。
IS_DEVID=0
RUNTIME_FLAGS=""
if security find-identity -v -p codesigning 2>/dev/null \
  | grep "$RELEASE_SIGN_IDENTITY" | grep -q "Developer ID"; then
  IS_DEVID=1
  RUNTIME_FLAGS="--options runtime --timestamp"
fi

# ===========================================================================
# 阶段 A：准备 staging + 用发布证书重签 app
#   跑完本段后 staging 目录里是一个「已签名、但尚未公证」的 app。
#   PHASE=stage 到此为止，把公证 / 装订交给 notarize.sh，再回来跑阶段 B。
# ===========================================================================
if [ "$PHASE" != "finish" ]; then

  # A1. 确保 Release 产物存在且不陈旧
  if [ ! -d "$APP_PATH" ] || ! app_is_fresh; then
    echo "-> Release 产物缺失或陈旧，先构建…"
    CONFIG=Release bash Scripts/build.sh
    # 记下构建完成时间，作为下一次 app_is_fresh 的比较基准。
    # 注意这里**即使 xcodebuild 是 no-op 也要 touch** —— 一次 no-op 同样证明了
    # 产物与源码一致，正是「新鲜」的信号（见 app_is_fresh 内注释）。
    # set -e 保证这行只在 build.sh 成功后才执行。
    touch "$BUILD_STAMP"
  fi
  if [ ! -d "$APP_PATH" ]; then
    echo "✗ 构建产物不存在: $APP_PATH" >&2
    exit 1
  fi

  # A2. 准备临时目录：app + Applications 快捷方式
  #     注意这里**不删** $DMG_PATH：PHASE=stage 结束时还没有替代品，
  #     提前删掉会让「跑到一半失败」变成「连旧的可用 DMG 都没了」。
  #     旧 DMG 的清理推迟到阶段 B 真正要写新文件之前。
  echo "-> 准备 DMG 内容…"
  rm -rf "$STAGING" "$RW_DMG"
  mkdir -p "$STAGING"
  ditto "$APP_PATH" "$STAGING/$APP_NAME.app"          # ditto 保留 bundle 权限/资源
  ln -s /Applications "$STAGING/Applications"
  xattr -cr "$STAGING/$APP_NAME.app" 2>/dev/null || true   # 清除隔离属性

  # A3. 重签为发布证书（注入 Team ID，使照片库 TCC 可授权）
  echo "-> 用发布证书重签（注入 Team ID）…"
  codesign --force --sign "$RELEASE_SIGN_IDENTITY" $RUNTIME_FLAGS \
    --entitlements "$ENTITLEMENTS" "$STAGING/$APP_NAME.app"
  codesign --verify --verbose "$STAGING/$APP_NAME.app" 2>&1 | tail -2
  codesign -dvv "$STAGING/$APP_NAME.app" 2>&1 | grep -E "Authority=Apple Development|Authority=Developer ID|TeamIdentifier"
fi

# ===========================================================================
# 阶段 B：从 staging 构建 DMG（Developer ID 分发时同时对 DMG 本身签名）
# ===========================================================================
if [ "$PHASE" != "stage" ]; then

if [ ! -d "$STAGING/$APP_NAME.app" ]; then
  echo "✗ 找不到 staging 中的 app: $STAGING/$APP_NAME.app" >&2
  echo "  PHASE=finish 需要先跑一次 PHASE=stage（notarize.sh 会按顺序自动调用）。" >&2
  exit 1
fi

# 3. 创建可读写 DMG
echo "-> 创建 DMG…"
hdiutil create -srcfolder "$STAGING" -volname "$VOLNAME" -fs HFS+ -ov "$RW_DMG" >/dev/null

# 4. 设置 Finder 布局（拖拽安装样式；最佳努力，失败不影响出包）
echo "-> 设置拖拽安装布局…"
MOUNT_DIR="$(mktemp -d)"
hdiutil attach "$RW_DMG" -nobrowse -mountpoint "$MOUNT_DIR" >/dev/null || true
osascript <<APPLESCRIPT 2>/dev/null || echo "  (布局脚本跳过：Finder 未就绪，将使用默认布局)"
tell application "Finder"
    set totalWait to 0
    repeat while (not (exists disk "$VOLNAME")) and totalWait < 10
        delay 0.5
        set totalWait to totalWait + 0.5
    end repeat
    if not (exists disk "$VOLNAME") then return
    tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 760, 440}
        set view options to icon view
        set arrangement of view options to not arranged
        set icon size of view options to 96
        set position of item "$APP_NAME" to {140, 160}
        set position of item "Applications" to {480, 160}
        close
    end tell
end tell
APPLESCRIPT
# 等待 .DSStore 落盘
sleep 1
hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || hdiutil detach force "$MOUNT_DIR" >/dev/null 2>&1 || true

# 5. 转换为压缩只读（UDZO）
echo "-> 压缩为只读 DMG…"
rm -f "$DMG_PATH"    # PHASE=finish 时阶段 A 没跑过，不会替你清旧产物
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
rm -f "$RW_DMG"
rm -rf "$STAGING"

# 5.5 对 DMG 本身做代码签名（仅 Developer ID 分发）。
#      不签的话 spctl -a -t open --context context:primary-signature 会判
#      "rejected / source=no usable signature" —— 裸镜像是个未签名的 code object，
#      Gatekeeper 没有签名对象可评估。
#      必须在提交公证**之前**做：公证针对的就是签名后的那串字节。
#      DMG 不是可执行镜像，所以不加 --options runtime（硬运行只对可执行文件有意义）。
if [ "$IS_DEVID" = "1" ]; then
  echo "-> 对 DMG 签名…"
  codesign --force --sign "$RELEASE_SIGN_IDENTITY" --timestamp "$DMG_PATH"
  codesign --verify --verbose=2 "$DMG_PATH" 2>&1 | tail -1
fi

# 6. 校验
echo "-> 校验 DMG…"
hdiutil verify "$DMG_PATH" >/dev/null

echo ""
echo "✅ DMG 生成完成"
echo "   路径: $DMG_PATH"
echo "   大小: $(du -h "$DMG_PATH" | cut -f1)"
echo "   内容: $APP_NAME.app + Applications（拖拽到应用程序文件夹安装）"

fi   # ← 阶段 B 结束

#!/bin/bash
#
# moveapp.sh - 将 macOS 应用从内置硬盘移动到外部硬盘，同时创建符号链接保证正常运行
#
# 用法:
#   moveapp.sh "应用名称" "/Volumes/外部硬盘/Applications"
#
# 示例:
#   moveapp.sh "Visual Studio Code" "/Volumes/SSD/Applications"
#   moveapp.sh "PyCharm" "/Volumes/External/Applications"
#
# 特性:
#   - 自动检测应用在 /Applications 或 ~/Applications
#   - 使用 ditto 完整复制 app bundle（保留元数据、xattr、资源叉）
#   - 移动后在原位置创建符号链接，保持启动路径不变
#   - 自动清理 quarantine 属性 + ad-hoc 重签名
#   - 更新 LaunchServices 注册
#   - 防止移动正在运行的应用
#
# 新增功能:
#   moveapp.sh --list                  # 显示当前可移动应用推荐列表
#   moveapp.sh --refresh "应用名称"     # 仅刷新缓存，无需移动
#   moveapp.sh --refresh "应用名称" --force-repair   # 额外重新签名和清理 xattr
#   moveapp.sh --force "App" /path     # 强制覆盖已存在的目标
#

# 纯文本日志（兼容性更好）
log_info()  { echo "[INFO]  $1"; }
log_warn()  { echo "[WARN]  $1"; }
log_error() { echo "[ERROR] $1" >&2; }
log_dry()   { echo "[DRY]   $1"; }



# 常见应用别名解析（支持用户输入短名称）
resolve_app_name() {
  local input="$1"
  local lower="$(echo "$input" | tr '[:upper:]' '[:lower:]')"   # 转小写（兼容 Bash 3.2）

  case "$lower" in
    "vs code"|"vscode"|"code"|"visual studio code")
      echo "Visual Studio Code"
      ;;
    "edge"|"ms edge"|"microsoft edge")
      echo "Microsoft Edge"
      ;;
    "chrome"|"google chrome")
      echo "Google Chrome"
      ;;
    "wechat"|"微信")
      echo "WeChat"
      ;;
    "qq")
      echo "QQ"
      ;;
    "企业微信"|"wecom"|"we com")
      echo "WeCom"
      ;;
    "飞书"|"lark"|"feishu")
      echo "Lark"
      ;;
    "钉钉"|"dingtalk"|"ding ding")
      echo "DingTalk"
      ;;
    "iina")
      echo "IINA"
      ;;
    "iterm"|"iterm2")
      echo "iTerm"
      ;;
    "karabiner"|"karabiner-elements")
      echo "Karabiner-Elements"
      ;;
    *)
      echo "$input"
      ;;
  esac
}

# ==================== 应用分类列表 ====================
# 安全可移动（纯 GUI、无系统扩展）
SAFE_MOVABLE=(
  "Visual Studio Code" "Android Studio" "DBeaver" "MongoDB Compass"
  "IINA" "LocalSend" "Motrix" "Pearcleaner" "Hidden Bar" "KeyCastr"
  "Blender" "GIMP" "Inkscape" "draw.io" "FreeCAD" "Audacity"
  "Google Chrome" "Microsoft Edge" "Brave Browser" "Tor Browser"
  "WeChat" "QQ" "Telegram" "TencentMeeting" "WeCom"
  "NeteaseMusic" "QQMusic" "剪映专业版" "剪映专业版 2"
  "夸克网盘" "BaiduNetdisk" "cosbrowser" "Motrix"
  "ChatGPT" "X" "Claude Code URL Handler"
  "GPG Keychain" "CrystalFetch" "UURemote" "NovaMLX"
  "FutuNiuniu" "Futu_OpenD" "MAXHUBShare"
)

# 需要测试（可能有轻度集成）
CAUTION_MOVABLE=(
  "Microsoft Word" "Microsoft Excel" "Microsoft PowerPoint"
  "Ollama" "Android File Transfer" "iTerm" "iTermAI"
  "Hammerspoon" "Karabiner-Elements" "Karabiner-EventViewer"
)

# 不推荐移动（有系统扩展、虚拟机、VPN、重度系统服务）
NOT_RECOMMENDED=(
  "Xcode" "Parallels Desktop" "OrbStack" "Tailscale"
  "ExpressVPN" "Clash Verge" "Tencent Lemon" "lghub"
  "Safari" "iMovie" "Developer"
)

list_movable_apps() {
  echo -e "${GREEN}=== 可移动应用推荐列表 ===${NC}"
  echo

  # 收集当前已安装的应用
  local installed=()
  for base in "/Applications" "$HOME/Applications"; do
    [[ -d "$base" ]] || continue
    for app in "$base"/*.app; do
      [[ -d "$app" ]] || continue
      local name
      name="$(basename "$app" .app)"
      installed+=("$name")
    done
  done

  # 分类输出
  echo -e "${GREEN}✅ 推荐移动（安全）${NC}"
  echo "────────────────────────────────────────"
  local count=0
  for app in "${SAFE_MOVABLE[@]}"; do
    for inst in "${installed[@]}"; do
      if [[ "$inst" == "$app" ]]; then
        printf "  • %s\n" "$app"
        ((count++))
        break
      fi
    done
  done
  [[ $count -eq 0 ]] && echo "  （当前未安装推荐应用）"
  echo

  echo -e "${YELLOW}⚠️  谨慎移动（建议测试）${NC}"
  echo "────────────────────────────────────────"
  count=0
  for app in "${CAUTION_MOVABLE[@]}"; do
    for inst in "${installed[@]}"; do
      if [[ "$inst" == "$app" ]]; then
        printf "  • %s\n" "$app"
        ((count++))
        break
      fi
    done
  done
  [[ $count -eq 0 ]] && echo "  （当前未安装）"
  echo

  echo -e "${RED}❌ 不推荐移动${NC}"
  echo "────────────────────────────────────────"
  count=0
  for app in "${NOT_RECOMMENDED[@]}"; do
    for inst in "${installed[@]}"; do
      if [[ "$inst" == "$app" ]]; then
        printf "  • %s\n" "$app"
        ((count++))
        break
      fi
    done
  done
  [[ $count -eq 0 ]] && echo "  （当前未安装）"
  echo

  echo "提示："
  echo "  使用 moveapp.sh "应用名称" "/Volumes/你的硬盘/Applications" 进行移动"
  echo "  移动后使用 moveapp.sh --refresh "应用名称" 刷新缓存"
  echo
}

usage() {
  cat <<EOF
用法: $(basename "$0") "应用名称" "目标 Applications 目录"
   或: $(basename "$0") "目标 Applications 目录" "应用名称"
   或: $(basename "$0") --refresh "应用名称" [--force-repair]

参数:
  应用名称                应用名称（可带或不带 .app 后缀）
  目标目录                 外部硬盘上的 Applications 目录，例如 /Volumes/MySSD/Applications

子命令:
  --list                   显示当前已安装应用的可移动推荐列表
  --refresh "应用名称"     仅刷新 LaunchServices、Dock、Finder 缓存（推荐移动后使用）
  --refresh "应用名称" --force-repair
                           额外重新执行 xattr 清理 + codesign 重签名

选项:
  --force, -f              移动时如果目标已存在则强制覆盖（谨慎使用）

示例:
  $(basename "$0") "Motrix" "/Volumes/WD/Applications"
  $(basename "$0") "/Volumes/WD/Applications" "Motrix"
  $(basename "$0") --list
  $(basename "$0") --refresh "Visual Studio Code"
  $(basename "$0") --refresh "IINA" --force-repair

注意事项:
  - 外部硬盘建议使用 APFS 或 Mac OS Extended (Journaled) 格式
  - 移动后若外部硬盘未挂载，应用将无法从 Launchpad/Spotlight 启动
  - 某些复杂应用（Adobe 全家桶、Xcode 等）可能需要额外配置

故障排除:
  脚本已自动执行 xattr 清理 + codesign 重签名。
  如遇个别顽固应用仍报错或无法启动，可手动再次执行修复命令：

    sudo xattr -cr "/Volumes/你的硬盘名称/Applications/你的App.app"
    sudo codesign --force --deep --sign - "/Volumes/你的硬盘名称/Applications/你的App.app"

  然后尝试重新打开应用。
EOF
  exit 1
}

# ==================== --refresh 模式 ====================
refresh_app() {
  local APP_NAME="$1"
  local FORCE_REPAIR=false

  if [[ "${2:-}" == "--force-repair" ]]; then
    FORCE_REPAIR=true
  fi

  # 解析常见别名
  APP_NAME="$(resolve_app_name "$APP_NAME")"

  # 标准化应用名
  if [[ "$APP_NAME" != *.app ]]; then
    APP_NAME="${APP_NAME}.app"
  fi

  # 尝试在常见位置找到应用（包括符号链接指向的位置）
  local APP_PATH=""
  for base in "/Applications" "$HOME/Applications"; do
    candidate="$base/$APP_NAME"
    if [[ -e "$candidate" ]]; then
      # 如果是符号链接，解析到真实路径
      if [[ -L "$candidate" ]]; then
        APP_PATH="$(readlink "$candidate")"
      else
        APP_PATH="$candidate"
      fi
      break
    fi
  done

  # 也检查是否用户直接传了完整路径
  if [[ -z "$APP_PATH" && -e "$1" ]]; then
    APP_PATH="$1"
    if [[ -L "$APP_PATH" ]]; then
      APP_PATH="$(readlink "$APP_PATH")"
    fi
  fi

  if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
    log_error "未找到应用: $APP_NAME"
    log_error "请确认应用名称正确，或使用完整路径"
    exit 1
  fi

  log_info "正在刷新应用: $APP_NAME"
  log_info "应用真实路径: $APP_PATH"

  # 1. 重新注册 LaunchServices
  log_info "刷新 LaunchServices 数据库..."
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP_PATH" 2>/dev/null || true

  # 2. 可选：强制重新签名和清理 xattr
  if [[ "$FORCE_REPAIR" == true ]]; then
    log_info "执行强制修复 (xattr + codesign)..."
    xattr -cr "$APP_PATH" 2>/dev/null || true
    codesign --force --deep --sign - "$APP_PATH" 2>/dev/null || log_warn "代码签名未完全成功"
  fi

  # 3. 重启 Dock 和 Finder
  log_info "刷新 Dock 和 Finder..."
  killall Dock 2>/dev/null || true
  killall Finder 2>/dev/null || true

  # 4. 强制 Spotlight 重新索引
  log_info "更新 Spotlight 索引..."
  mdimport -r "$APP_PATH" 2>/dev/null || true

  log_info "✅ 刷新完成！请尝试从 Spotlight 或 Dock 打开应用"
  echo
  echo "提示：如仍无法正常使用，可尝试："
  echo "  open "$APP_PATH""
  echo
}

# 全局标志
FORCE_OVERWRITE=false

# 解析全局选项（--force / -f）
while [[ $# -gt 0 && "$1" == --* || "$1" == -* ]]; do
  case "$1" in
    --force|-f)
      FORCE_OVERWRITE=true
      shift
      ;;
    *)
      break
      ;;
  esac
done

# ==================== --list 模式 ====================
if [[ "${1:-}" == "--list" || "${1:-}" == "--list-movable" ]]; then
  list_movable_apps
  exit 0
fi

# 检查是否是 --refresh 模式
if [[ "${1:-}" == "--refresh" ]]; then
  shift
  if [[ $# -lt 1 ]]; then
    log_error "用法: $(basename "$0") --refresh "应用名称" [--force-repair]"
    exit 1
  fi
  refresh_app "$@"
  exit 0
fi

# ==================== 正常移动模式 ====================
# 检查参数
if [[ $# -lt 2 ]]; then
  usage
fi

# 支持两种参数顺序：
#   moveapp.sh "Motrix" /Volumes/WD/Applications
#   moveapp.sh /Volumes/WD/Applications "Motrix"
arg1="$1"
arg2="$2"

if [[ "$arg1" == /* ]]; then
  # 路径在前，应用名在后
  TARGET_APPS_DIR="$arg1"
  APP_NAME="$arg2"
else
  # 应用名在前，路径在后（原默认顺序）
  APP_NAME="$arg1"
  TARGET_APPS_DIR="$arg2"
fi

# 解析常见别名（如 "VS Code" → "Visual Studio Code"）
APP_NAME="$(resolve_app_name "$APP_NAME")"

# 标准化应用名
if [[ "$APP_NAME" != *.app ]]; then
  APP_NAME="${APP_NAME}.app"
fi

# 查找源应用位置
SRC=""
LINK_DIR=""

for base in "/Applications" "$HOME/Applications"; do
  candidate="$base/$APP_NAME"
  if [[ -d "$candidate" ]]; then
    SRC="$candidate"
    LINK_DIR="$base"
    break
  fi
done

if [[ -z "$SRC" ]]; then
  log_error "未找到应用: $APP_NAME"
  log_error "请确认应用已安装在 /Applications 或 ~/Applications 中"
  exit 1
fi

DST="$TARGET_APPS_DIR/$APP_NAME"

# 检查目标是否已存在
if [[ -e "$DST" ]]; then
  if [[ "$FORCE_OVERWRITE" == true ]]; then
    log_warn "目标位置已存在，正在覆盖: $DST"
    rm -rf "$DST"
  else
    log_error "目标位置已存在: $DST"
    log_error "请先手动删除，或使用 --force / -f 参数强制覆盖"
    exit 1
  fi
fi

# 检查应用是否正在运行
if pgrep -f "/$APP_NAME/" >/dev/null 2>&1; then
  log_error "应用正在运行，请先完全退出该应用后再移动"
  exit 1
fi

# 检查目标目录父路径是否存在
if [[ ! -d "$(dirname "$TARGET_APPS_DIR")" ]]; then
  log_error "目标硬盘路径不存在: $(dirname "$TARGET_APPS_DIR")"
  log_error "请确认外部硬盘已正确挂载"
  exit 1
fi

mkdir -p "$TARGET_APPS_DIR"

log_info "准备移动: $SRC"
log_info "目标位置: $DST"
log_info "符号链接将创建在: $LINK_DIR/$APP_NAME"

# 1. 使用 ditto 复制（最佳实践，完整保留 bundle 结构和元数据）
log_info "正在使用 ditto 复制应用（请稍候）..."
if ! ditto "$SRC" "$DST"; then
  log_error "复制失败"
  exit 1
fi

# 2. 删除原应用
log_info "正在删除原位置应用..."
if ! rm -rf "$SRC" 2>/dev/null; then
  log_warn "普通权限删除失败，尝试使用 sudo..."
  if sudo rm -rf "$SRC"; then
    log_info "sudo 删除成功"
  else
    log_error "删除失败。请手动执行: sudo rm -rf "$SRC""
    # 尝试回滚
    rm -rf "$DST" 2>/dev/null || true
    exit 1
  fi
fi

# 3. 创建符号链接
log_info "创建符号链接..."
if ! ln -s "$DST" "$LINK_DIR/$APP_NAME"; then
  log_error "创建符号链接失败"
  exit 1
fi

# 4. 清理 quarantine 属性（防止 "已损坏" 提示）
log_info "清理扩展属性 (xattr) ..."
xattr -cr "$DST" 2>/dev/null || true

# 5. Ad-hoc 重签名（解决 hardened runtime / 库加载问题）
log_info "重新代码签名 (codesign) ..."
if ! codesign --force --deep --sign - "$DST" 2>/dev/null; then
  log_warn "代码签名未完全成功（部分应用可能不需要或已签名）"
fi

# 6. 更新 LaunchServices 数据库（刷新 Spotlight/Launchpad 路径缓存）
log_info "更新 LaunchServices 注册 ..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$DST" 2>/dev/null || true

log_info "✅ 移动完成！"
echo
echo "应用已移动到外部硬盘: $DST"
echo "原位置已创建符号链接: $LINK_DIR/$APP_NAME"
echo
echo "提示:"
echo "  - 外部硬盘拔出后应用将无法启动（正常现象）"
echo "  - 移动后推荐立即执行刷新（无需重启 Mac）："
echo "      $(basename "$0") --refresh "$APP_NAME""
echo "  - 如遇启动问题，可尝试:"
echo "      open "$LINK_DIR/$APP_NAME""
echo "  - 或者手动执行一次签名修复:"
echo "      sudo xattr -cr "$DST""
echo "      sudo codesign --force --deep --sign - "$DST""
echo

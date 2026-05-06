#!/bin/bash
#
# restoreapps.sh - 一键恢复所有已移动到外部硬盘的应用
#
# 用法:
#   restoreapps.sh [--dry-run] [--yes]
#
# 示例:
#   restoreapps.sh                  # 交互式恢复
#   restoreapps.sh --dry-run        # 仅预览，不实际操作
#   restoreapps.sh --yes            # 跳过确认，直接执行
#

set -euo pipefail

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_dry()   { echo -e "${BLUE}[DRY]${NC}   $1"; }

DRY_RUN=false
AUTO_YES=false

# 参数解析
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --yes|-y)
      AUTO_YES=true
      shift
      ;;
    -h|--help)
      cat <<EOF
用法: $(basename "$0") [选项]

选项:
  --dry-run     仅预览将要恢复的应用，不执行实际操作
  --yes, -y     跳过确认提示，直接执行恢复
  -h, --help    显示帮助

说明:
  自动扫描 /Applications 和 ~/Applications 下的符号链接，
  找出指向 /Volumes/ 外部硬盘的应用，并将其移回内置硬盘。
EOF
      exit 0
      ;;
    *)
      log_error "未知参数: $1"
      exit 1
      ;;
  esac
done

echo "正在扫描已移动的应用（符号链接指向外部硬盘）..."
echo

# 收集所有需要恢复的应用
declare -a TO_RESTORE=()
declare -a LINK_PATHS=()
declare -a REAL_PATHS=()

scan_location() {
  local base="$1"
  if [[ ! -d "$base" ]]; then return; fi

  for link in "$base"/*.app; do
    [[ -e "$link" ]] || continue
    if [[ -L "$link" ]]; then
      local target
      target="$(readlink "$link")"
      if [[ "$target" == /Volumes/* ]]; then
        TO_RESTORE+=("$(basename "$link" .app)")
        LINK_PATHS+=("$link")
        REAL_PATHS+=("$target")
      fi
    fi
  done
}

scan_location "/Applications"
scan_location "$HOME/Applications"

if [[ ${#TO_RESTORE[@]} -eq 0 ]]; then
  log_info "未发现任何指向外部硬盘的应用符号链接。"
  log_info "所有应用似乎都在内置硬盘上。"
  exit 0
fi

echo "发现以下应用可以恢复到内置硬盘："
echo "────────────────────────────────────────────────────────"
for i in "${!TO_RESTORE[@]}"; do
  printf "  %2d. %-30s → %s\n" $((i+1)) "${TO_RESTORE[$i]}" "${REAL_PATHS[$i]}"
done
echo "────────────────────────────────────────────────────────"
echo

if [[ "$DRY_RUN" == true ]]; then
  log_dry "这是预览模式，不会实际移动任何文件。"
  exit 0
fi

if [[ "$AUTO_YES" != true ]]; then
  read -rp "确认要将以上 ${#TO_RESTORE[@]} 个应用移回内置硬盘吗？ [y/N] " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    log_info "已取消操作。"
    exit 0
  fi
fi

echo
log_info "开始恢复应用..."
echo

RESTORED=0
FAILED=0

for i in "${!TO_RESTORE[@]}"; do
  local_link="${LINK_PATHS[$i]}"
  real_path="${REAL_PATHS[$i]}"
  app_name="${TO_RESTORE[$i]}"
  dest_dir="$(dirname "$local_link")"
  dest_path="$dest_dir/${app_name}.app"

  echo -n "  正在恢复: $app_name ... "

  if [[ ! -d "$real_path" ]]; then
    echo -e "${RED}失败${NC} (源文件不存在)"
    ((FAILED++))
    continue
  fi

  if [[ -e "$dest_path" && ! -L "$dest_path" ]]; then
    echo -e "${RED}失败${NC} (目标位置已存在同名应用)"
    ((FAILED++))
    continue
  fi

  # 删除符号链接
  rm -f "$local_link"

  # 移动真实应用回来
  if mv "$real_path" "$dest_path" 2>/dev/null; then
    echo -e "${GREEN}成功${NC}"
    ((RESTORED++))
  else
    echo -e "${RED}失败${NC} (可能权限不足，尝试使用 sudo)"
    # 尝试用 sudo 恢复
    if sudo mv "$real_path" "$dest_path" 2>/dev/null; then
      echo -e "    ${GREEN}sudo 恢复成功${NC}"
      ((RESTORED++))
    else
      ((FAILED++))
    fi
  fi
done

echo
echo "────────────────────────────────────────────────────────"
log_info "恢复完成！成功: $RESTORED 个，失败: $FAILED 个"

if [[ $RESTORED -gt 0 ]]; then
  echo
  log_info "正在刷新系统缓存..."
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -kill -r -domain local -domain system -domain user 2>/dev/null || true
  killall Dock 2>/dev/null || true
  killall Finder 2>/dev/null || true
  log_info "✅ 系统缓存已刷新，现在可以正常使用恢复的应用了。"
fi

if [[ $FAILED -gt 0 ]]; then
  echo
  log_warn "部分应用恢复失败，建议手动处理或使用 sudo 运行此脚本。"
fi

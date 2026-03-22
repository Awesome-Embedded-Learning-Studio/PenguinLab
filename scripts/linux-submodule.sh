#!/bin/bash
# ============================================================================
# Linux Kernel Submodule 管理脚本
# ============================================================================
# 功能：
#   - init:   幂等初始化 Linux kernel submodule 到 third_party/linux
#   - reset:  硬复原到远程最新状态（完全清理后重新初始化）
#   - status: 查看当前 submodule 状态
#
# 使用方法：
#   ./scripts/linux-submodule.sh init
#   ./scripts/linux-submodule.sh reset
#   ./scripts/linux-submodule.sh status
# ============================================================================

set -eEuo pipefail

# 颜色输出
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Linux kernel 官方仓库 URLs
readonly LINUX_KERNEL_UPSTREAM="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git"
readonly LINUX_KERNEL_GITEE="https://gitee.com/mirrors/linux_stable.git"

# 默认分支
readonly DEFAULT_BRANCH="linux-6.19.y"

# 第三方目录
THIRD_PARTY_DIR=""
SUBMODULE_PATH=""

# 项目根目录
PROJECT_ROOT=""

# 日志函数（输出到 stderr，避免污染命令替换）
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# 查找项目根目录（包含 .git 的目录）
find_project_root() {
    local current_dir="$PWD"
    while [[ "$current_dir" != "/" ]]; do
        if [[ -d "$current_dir/.git" ]]; then
            echo "$current_dir"
            return 0
        fi
        current_dir="$(dirname "$current_dir")"
    done
    log_error "无法找到 Git 项目根目录"
    exit 1
}

# 初始化路径变量
init_paths() {
    PROJECT_ROOT="$(find_project_root)"
    THIRD_PARTY_DIR="$PROJECT_ROOT/third_party"
    SUBMODULE_PATH="$THIRD_PARTY_DIR/linux"

    log_info "项目根目录: $PROJECT_ROOT"
    log_info "Submodule 路径: $SUBMODULE_PATH (相对于项目根目录: third_party/linux)"
}

# 检查 git 命令是否可用
check_git() {
    if ! command -v git &> /dev/null; then
        log_error "git 命令未找到，请先安装 git"
        exit 1
    fi
}

# 检查网络连接
check_network() {
    local url="$1"
    if curl -I -s --connect-timeout 5 "$url" > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# 选择可用的镜像
select_mirror() {
    log_info "检测网络连接..."
    local mirror=""
    if check_network "https://git.kernel.org"; then
        mirror="$LINUX_KERNEL_UPSTREAM"
        log_success "使用官方镜像: git.kernel.org"
    elif check_network "https://gitee.com"; then
        mirror="$LINUX_KERNEL_GITEE"
        log_warn "官方镜像不可达，使用 Gitee 镜像"
    else
        log_error "无法连接到任何镜像源"
        exit 1
    fi
    printf '%s' "$mirror"
}

# 幂等初始化 submodule
cmd_init() {
    cd "$PROJECT_ROOT"
    local mirror
    mirror="$(select_mirror)"

    log_info "开始初始化 Linux kernel submodule..."

    # 创建 third_party 目录（幂等）
    mkdir -p "$THIRD_PARTY_DIR"

    # 检查 submodule 是否已存在于 .gitmodules 或 git index
    if git config --file .gitmodules --get submodule.third_party/linux &> /dev/null; then
        log_info "Submodule 配置已存在于 .gitmodules"
    elif git ls-files --error-unmatch third_party/linux &> /dev/null; then
        log_info "Submodule 已存在于 git index（但缺少 .gitmodules 配置），补充配置..."
        # 补充 .gitmodules 配置（index 已有记录，不能再用 submodule add）
        git config -f .gitmodules submodule.third_party/linux.path third_party/linux
        git config -f .gitmodules submodule.third_party/linux.url "$mirror"
        git config -f .gitmodules submodule.third_party/linux.branch "$DEFAULT_BRANCH"
        git add .gitmodules
    else
        log_info "添加 submodule 配置..."
        git submodule add -b "$DEFAULT_BRANCH" --name third_party/linux \
            "$mirror" third_party/linux
    fi

    # 检查 submodule 是否已初始化
    if [[ -f "$SUBMODULE_PATH/.git" ]]; then
        log_info "Submodule 已初始化，更新到最新版本..."
        cd "$SUBMODULE_PATH"
        git fetch origin
        git checkout "$DEFAULT_BRANCH"
        git pull origin "$DEFAULT_BRANCH"
        cd "$PROJECT_ROOT"
    else
        log_info "初始化 submodule..."
        git submodule update --init --checkout -- third_party/linux
    fi

    log_success "Linux kernel submodule 初始化完成!"
    log_info "路径: $SUBMODULE_PATH"
    log_info "分支: $DEFAULT_BRANCH"
}

# 硬复原到远程最新状态
cmd_reset() {
    cd "$PROJECT_ROOT"

    log_warn "即将执行硬复原操作，这将删除所有本地修改！"
    read -p "确认继续? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "操作已取消"
        return 0
    fi

    log_info "开始硬复原 Linux kernel submodule..."

    # 1. 从 .git/config 中移除 submodule 配置（如果存在）
    if git config --local --get submodule.third_party/linux.url &> /dev/null; then
        log_info "移除 .git/config 中的 submodule 配置..."
        git config --local --remove-section submodule.third_party/linux 2>/dev/null || true
    fi

    # 2. 从 .gitmodules 中移除配置（如果存在）
    if git config --file .gitmodules --get submodule.third_party/linux.url &> /dev/null; then
        log_info "移除 .gitmodules 中的 submodule 配置..."
        git config --file .gitmodules --remove-section submodule.third_party/linux 2>/dev/null || true
    fi

    # 3. 从 git index 中移除（如果存在）
    if git ls-files --error-unmatch third_party/linux &> /dev/null; then
        log_info "从 git index 中移除..."
        git rm --cached third_party/linux 2>/dev/null || true
    fi

    # 4. 删除物理目录（如果存在）
    if [[ -d "$SUBMODULE_PATH" ]]; then
        log_info "删除物理目录..."
        rm -rf "$SUBMODULE_PATH"
    fi

    # 5. 清理 .git/modules 中的缓存（如果存在）
    if [[ -d "$PROJECT_ROOT/.git/modules/third_party" ]]; then
        log_info "清理 .git/modules 缓存..."
        rm -rf "$PROJECT_ROOT/.git/modules/third_party"
    fi

    log_success "清理完成，重新初始化..."

    # 重新初始化
    cmd_init
}

# 查看状态
cmd_status() {
    cd "$PROJECT_ROOT"

    log_info "=== Submodule 状态 ==="

    # 检查 .gitmodules 是否存在配置
    if git config --file .gitmodules --get submodule.third_party/linux.url &> /dev/null; then
        local url
        url="$(git config --file .gitmodules --get submodule.third_party/linux.url)"
        log_info ".gitmodules 配置: ✓"
        log_info "  URL: $url"
    else
        log_warn ".gitmodules 配置: ✗ (未配置)"
    fi

    # 检查物理目录是否存在
    if [[ -d "$SUBMODULE_PATH" ]]; then
        log_info "物理目录: ✓ ($SUBMODULE_PATH)"

        # 检查是否是有效的 git 仓库
        if [[ -d "$SUBMODULE_PATH/.git" ]]; then
            cd "$SUBMODULE_PATH"
            local branch
            local commit
            local status
            branch="$(git branch --show-current 2>/dev/null || echo "无分支")"
            commit="$(git rev-parse --short HEAD 2>/dev/null || echo "未知")"
            status="$(git status --porcelain 2>/dev/null && echo "有未提交的修改" || echo "干净")"

            log_info "  当前分支: $branch"
            log_info "  当前提交: $commit"
            log_info "  工作区: $status"

            # 检查是否是 submodule
            cd "$PROJECT_ROOT"
            if git submodule status third_party/linux &> /dev/null; then
                log_info "  Git submodule 状态:"
                git submodule status third_party/linux
            fi
        else
            log_warn "  .git 目录不存在"
        fi
    else
        log_warn "物理目录: ✗ (不存在)"
    fi

    # 检查 .git/config 配置
    if git config --local --get submodule.third_party/linux.url &> /dev/null; then
        log_info ".git/config 配置: ✓"
    else
        log_info ".git/config 配置: ✗ (未初始化)"
    fi
}

# 显示帮助信息
cmd_help() {
    cat << EOF
Linux Kernel Submodule 管理脚本

使用方法:
    $0 <command>

命令:
    init    幂等初始化 Linux kernel submodule 到 third_party/linux
            如果已存在则更新到最新版本

    reset   硬复原到远程最新状态
            完全清理 submodule 后重新初始化（会删除本地修改）

    status  查看当前 submodule 状态
            显示配置、分支、提交等信息

    help    显示此帮助信息

示例:
    $0 init
    $0 status
    $0 reset

EOF
}

# 主函数
main() {
    check_git
    init_paths

    local command="${1:-help}"

    case "$command" in
        init)
            cmd_init
            ;;
        reset)
            cmd_reset
            ;;
        status)
            cmd_status
            ;;
        help|--help|-h)
            cmd_help
            ;;
        *)
            log_error "未知命令: $command"
            echo
            cmd_help
            exit 1
            ;;
    esac
}

main "$@"

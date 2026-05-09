#!/bin/bash
#=============================================================================
# Linux Kernel Cross-Compilation Script for ARM32
#=============================================================================
# This script provides a convenient interface for configuring, building,
# and cleaning the Linux kernel for ARM32 architecture.
#
# Usage:
#   ./scripts/linux-action-scripts.sh [command] [command] ...
#
# Commands:
#   config  - Configure kernel with defconfig
#   build   - Build kernel (zImage + modules + dtbs)
#   clean   - Clean build artifacts
#
# Environment Variables (with defaults):
#   LINUX_SRC         - Kernel source path (default: project_root/third_party/linux)
#   ARCH              - Target architecture (default: arm)
#   CROSS_COMPILE     - Cross-compiler prefix (default: arm-none-linux-gnueabihf-)
#   LINUX_DEFCONFIG   - Defconfig name (required for config command)
#   BUILD_OUTPUT_BASE - Build output directory (default: out/build_latest)
#   BUILD_JOBS        - Parallel jobs (default: auto-detect via nproc)
#=============================================================================

set -e  # Exit on error

#-----------------------------------------------------------------------------
# Color output
#-----------------------------------------------------------------------------
readonly COLOR_RESET='\033[0m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[0;33m'
readonly COLOR_BLUE='\033[0;34m'

#-----------------------------------------------------------------------------
# Logging functions
#-----------------------------------------------------------------------------
log_info() {
    echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $*"
}

log_success() {
    echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} $*"
}

log_warn() {
    echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"
}

log_error() {
    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2
}

#-----------------------------------------------------------------------------
# Default values and environment variables
#-----------------------------------------------------------------------------
# Derive project root from script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Set defaults with environment variable overrides
: "${LINUX_SRC:=${PROJECT_ROOT}/third_party/linux}"
: "${ARCH:=arm}"
: "${CROSS_COMPILE:=arm-none-linux-gnueabihf-}"

# Map architecture names (toolchain naming -> kernel naming)
# aarch64 toolchain uses 'arm64' in Linux kernel
case "${ARCH}" in
    aarch64) KERNEL_ARCH=arm64 ;;
    *)       KERNEL_ARCH="${ARCH}" ;;
esac

# Detect if BUILD_OUTPUT_BASE was explicitly set by user
BUILD_OUTPUT_SPECIFIED="false"
if [[ -n "${BUILD_OUTPUT_BASE_ORIG+x}" ]]; then
    BUILD_OUTPUT_SPECIFIED="true"
fi

# Set default output directory with architecture suffix
: "${BUILD_OUTPUT_BASE:=out/build_latest_${KERNEL_ARCH}}"
: "${BUILD_JOBS:=$(nproc 2>/dev/null || echo 4)}"

# Make BUILD_OUTPUT_BASE relative to project root if not absolute
if [[ "${BUILD_OUTPUT_BASE}" != /* ]]; then
    BUILD_OUTPUT_BASE="${PROJECT_ROOT}/${BUILD_OUTPUT_BASE}"
fi

# Export for make
export ARCH="${KERNEL_ARCH}"
export CROSS_COMPILE

#-----------------------------------------------------------------------------
# Helper functions
#-----------------------------------------------------------------------------
show_usage() {
    cat << EOF
Linux Kernel Cross-Compilation Script

Usage:
    $(basename "$0") [command] [command] ...

Commands:
    config           - Configure kernel using LINUX_DEFCONFIG
    build            - Build kernel (zImage + modules + dtbs)
    config_and_build - Configure and build in one step
    clean            - Clean build artifacts
    help             - Show this help message

Environment Variables (with defaults):
    LINUX_SRC         - ${LINUX_SRC}
    ARCH              - ${ARCH} (aarch64 will be mapped to arm64)
    CROSS_COMPILE     - ${CROSS_COMPILE}
    LINUX_DEFCONFIG   - (required for config command)
    BUILD_OUTPUT_BASE - ${BUILD_OUTPUT_BASE}
                        Specify this to use a fixed output directory
    BUILD_JOBS        - ${BUILD_JOBS}

Examples:
    # Configure with vexpress_defconfig
    LINUX_DEFCONFIG=vexpress_defconfig $(basename "$0") config

    # Build kernel
    $(basename "$0") build

    # Configure and build in one command
    LINUX_DEFCONFIG=vexpress_defconfig $(basename "$0") config_and_build

    # Use a fixed output directory (no auto-backup)
    BUILD_OUTPUT_BASE=out/mybuild LINUX_DEFCONFIG=defconfig $(basename "$0") config_and_build

    # Clean build artifacts
    $(basename "$0") clean
EOF
}

validate_env() {
    local errors=0

    if [[ ! -d "${LINUX_SRC}" ]]; then
        log_error "Kernel source directory not found: ${LINUX_SRC}"
        log_error "Please set LINUX_SRC to a valid kernel source tree"
        ((errors++))
    fi

    if [[ ! -f "${LINUX_SRC}/Makefile" ]]; then
        log_error "Makefile not found in kernel source: ${LINUX_SRC}"
        log_error "Please verify LINUX_SRC points to a valid kernel tree"
        ((errors++))
    fi

    # Check if cross-compiler exists (only warn, don't fail)
    if ! command -v "${CROSS_COMPILE}gcc" &> /dev/null; then
        log_warn "Cross-compiler not found: ${CROSS_COMPILE}gcc"
        log_warn "Build may fail. Please install ARM32 cross-compiler toolchain"
    fi

    return $errors
}

backup_existing_build() {
    if [[ -d "${BUILD_OUTPUT_BASE}" ]]; then
        # Skip backup if .config exists (user just configured)
        if [[ -f "${BUILD_OUTPUT_BASE}/.config" ]]; then
            log_info "Found existing .config, reusing build directory"
            return 0
        fi

        local backup_dir
        backup_dir="$(dirname "${BUILD_OUTPUT_BASE}")/build_$(date +%Y%m%d_%H%M%S)"
        log_info "Backing up existing build to: ${backup_dir}"
        mv "${BUILD_OUTPUT_BASE}" "${backup_dir}"
        log_success "Backup completed"
    fi
}

ensure_output_dir() {
    mkdir -p "$(dirname "${BUILD_OUTPUT_BASE}")"
    mkdir -p "${BUILD_OUTPUT_BASE}"
}

#-----------------------------------------------------------------------------
# Command implementations
#-----------------------------------------------------------------------------
cmd_config() {
    log_info "Configuring kernel for ${KERNEL_ARCH} architecture"

    if [[ -z "${LINUX_DEFCONFIG}" ]]; then
        log_error "LINUX_DEFCONFIG is not set"
        log_error "Please specify a defconfig, e.g., LINUX_DEFCONFIG=vexpress_defconfig"
        return 1
    fi

    log_info "Using defconfig: ${LINUX_DEFCONFIG}"
    log_info "Output directory: ${BUILD_OUTPUT_BASE}"

    ensure_output_dir

    cd "${LINUX_SRC}"
    make O="${BUILD_OUTPUT_BASE}" "${LINUX_DEFCONFIG}"

    log_success "Kernel configuration completed"
    log_info "Config file saved to: ${BUILD_OUTPUT_BASE}/.config"
}

cmd_build() {
    log_info "Building kernel for ${KERNEL_ARCH} architecture"
    log_info "Cross-compiler: ${CROSS_COMPILE}"
    log_info "Output directory: ${BUILD_OUTPUT_BASE}"
    log_info "Parallel jobs: ${BUILD_JOBS}"

    # Backup existing build only if user didn't specify output directory
    if [[ "${BUILD_OUTPUT_SPECIFIED}" != "true" ]]; then
        backup_existing_build
    fi

    ensure_output_dir

    # Check if config exists
    if [[ ! -f "${BUILD_OUTPUT_BASE}/.config" ]]; then
        log_error "Kernel config not found: ${BUILD_OUTPUT_BASE}/.config"
        log_error "Please run 'config' command first or use 'config_and_build'"
        return 1
    fi

    cd "${LINUX_SRC}"

    # Determine kernel image target based on architecture
    local kernel_image_target="zImage"
    local kernel_image_path="${KERNEL_ARCH}/boot/zImage"
    case "${KERNEL_ARCH}" in
        arm64)
            kernel_image_target="Image"
            kernel_image_path="${KERNEL_ARCH}/boot/Image"
            ;;
        arm)
            kernel_image_target="zImage"
            kernel_image_path="${KERNEL_ARCH}/boot/zImage"
            ;;
    esac

    # Build targets: kernel image, modules, dtbs
    log_info "Building ${kernel_image_target}..."
    make O="${BUILD_OUTPUT_BASE}" -j"${BUILD_JOBS}" "${kernel_image_target}"

    log_info "Building modules..."
    make O="${BUILD_OUTPUT_BASE}" -j"${BUILD_JOBS}" modules

    log_info "Building device trees..."
    make O="${BUILD_OUTPUT_BASE}" -j"${BUILD_JOBS}" dtbs

    log_success "Kernel build completed"
    log_info "Kernel image: ${BUILD_OUTPUT_BASE}/arch/${kernel_image_path}"
    log_info "Device trees: ${BUILD_OUTPUT_BASE}/arch/${KERNEL_ARCH}/boot/dts/"
}

cmd_config_and_build() {
    log_info "=== Configure and Build in One Step ==="

    # First configure
    if ! cmd_config; then
        log_error "Configuration failed, aborting build"
        return 1
    fi

    # Then build
    if ! cmd_build; then
        log_error "Build failed"
        return 1
    fi

    log_success "=== Configure and Build Completed Successfully ==="
}

cmd_clean() {
    log_info "Cleaning build artifacts"

    if [[ -d "${BUILD_OUTPUT_BASE}" ]]; then
        log_warn "Removing: ${BUILD_OUTPUT_BASE}"
        rm -rf "${BUILD_OUTPUT_BASE}"
        log_success "Build artifacts cleaned"
    else
        log_warn "Build directory not found: ${BUILD_OUTPUT_BASE}"
    fi
}

#-----------------------------------------------------------------------------
# Main
#-----------------------------------------------------------------------------
main() {
    # Show help if no arguments or help requested
    if [[ $# -eq 0 ]] || [[ "$1" == "help" ]] || [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
        show_usage
        exit 0
    fi

    # Validate environment
    if ! validate_env; then
        log_error "Environment validation failed"
        exit 1
    fi

    # Show configuration
    log_info "=== Linux Kernel Build Configuration ==="
    log_info "Kernel source:    ${LINUX_SRC}"
    log_info "Architecture:     ${KERNEL_ARCH} (from ARCH=${ARCH})"
    log_info "Cross-compile:    ${CROSS_COMPILE}"
    log_info "Build output:     ${BUILD_OUTPUT_BASE}"
    log_info "Parallel jobs:    ${BUILD_JOBS}"
    log_info "======================================="

    # Process commands
    local status=0
    for cmd in "$@"; do
        case "${cmd}" in
            config)
                cmd_config || status=$?
                ;;
            build)
                cmd_build || status=$?
                ;;
            config_and_build)
                cmd_config_and_build || status=$?
                ;;
            clean)
                cmd_clean || status=$?
                ;;
            *)
                log_error "Unknown command: ${cmd}"
                log_info "Run '$(basename "$0") help' for usage"
                exit 1
                ;;
        esac
    done

    exit $status
}

# Run main if script is executed (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

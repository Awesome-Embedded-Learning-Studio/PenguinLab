#!/bin/bash
#=============================================================================
# BusyBox Cross-Compilation Script for ARM32/ARM64
#=============================================================================
# This script builds BusyBox for embedded ARM systems (i.MX6ULL, ARM64, etc.)
# and installs it to create a minimal root filesystem.
#
# Usage:
#   ./scripts/rootfs-minimal-maker.sh [TARGET] [OPTIONS]
#
# Targets:
#   defconfig      - Default configuration (default)
#   menuconfig     - Interactive curses-based configurator
#   config         - Text-based configurator
#   allnoconfig    - Disable all symbols
#   allyesconfig   - Enable all symbols
#
# Options:
#   --clean        - Clean build directory before building
#   --static       - Build static binary (default)
#   --dynamic      - Build dynamic binary
#   --build-only   - Build only, using existing .config
#   --install-only - Install only, using existing build
#   --help, -h     - Show this help
#
# Environment Variables:
#   ARCH               - Target architecture (arm or aarch64, default: arm)
#   CROSS_COMPILE      - Toolchain prefix (default: arm-none-linux-gnueabihf-)
#   BUILD_OUTPUT_BASE  - Base output directory (default: out/build_latest_${ARCH})
#   BUILD_JOBS         - Parallel jobs (default: auto-detect)
#   DEBUG              - Enable debug output (set to 1)
#=============================================================================

set -e

#-----------------------------------------------------------------------------
# Color definitions
#-----------------------------------------------------------------------------
readonly COLOR_RESET='\033[0m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_BLUE='\033[0;34m'

#-----------------------------------------------------------------------------
# Logging functions
#-----------------------------------------------------------------------------
log_info() {
    echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $*"
}

log_error() {
    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2
}

log_warn() {
    echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"
}

log_debug() {
    if [[ "${DEBUG:-0}" == "1" ]]; then
        echo -e "${COLOR_BLUE}[DEBUG]${COLOR_RESET} $*"
    fi
}

log_cmd() {
    echo -e "${COLOR_YELLOW}[CMD]${COLOR_RESET} $*"
}

log_success() {
    echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} $*"
}

#-----------------------------------------------------------------------------
# Project paths
#-----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# BusyBox source directory
BUSYBOX_SRC="${PROJECT_ROOT}/third_party/busybox"

# Architecture and toolchain
: "${ARCH:=arm}"
: "${CROSS_COMPILE:=}"

# Map user-facing ARCH to output directory name (match kernel convention)
case "${ARCH}" in
    aarch64) OUTPUT_ARCH=arm64 ;;
    *)       OUTPUT_ARCH="${ARCH}" ;;
esac

# Auto-detect CROSS_COMPILE if not set
if [[ -z "${CROSS_COMPILE}" ]]; then
    case "${ARCH}" in
        aarch64) CROSS_COMPILE="aarch64-linux-gnu-" ;;
        arm)     CROSS_COMPILE="arm-none-linux-gnueabihf-" ;;
        *)       CROSS_COMPILE="" ;;
    esac
fi

# Output directories (with environment variable overrides)
# Follow project convention: out/build_latest_${OUTPUT_ARCH}/
: "${BUILD_OUTPUT_BASE:=${PROJECT_ROOT}/out/build_latest_${OUTPUT_ARCH}}"
BUSYBOX_OUTPUT="${BUILD_OUTPUT_BASE}/busybox"
ROOTFS_INSTALL="${BUILD_OUTPUT_BASE}/rootfs"
ROOTFS_CPIO="${BUILD_OUTPUT_BASE}/rootfs.cpio.gz"

# Build jobs
: "${BUILD_JOBS:=$(nproc 2>/dev/null || echo 4)}"

# Build options
STATIC_BUILD=1
CLEAN_BUILD=0
BUILD_ONLY=0
INSTALL_ONLY=0
PACK_ONLY=0
SHOW_HELP=0

# Default target
TARGET="defconfig"

#-----------------------------------------------------------------------------
# Usage
#-----------------------------------------------------------------------------
show_usage() {
    cat << EOF
BusyBox Cross-Compilation Script for ARM32/ARM64

Usage: $0 [TARGET] [OPTIONS]

Targets:
  defconfig      - Default configuration (default)
  menuconfig     - Interactive curses-based configurator (exits after config)
  config         - Text-based configurator (exits after config)
  allnoconfig    - Disable all symbols (exits after config)
  allyesconfig   - Enable all symbols (exits after config)

Options:
  --clean        - Clean build directory before building
  --static       - Build static binary (default)
  --dynamic      - Build dynamic binary
  --build-only   - Build only, using existing .config
  --install-only - Install only, using existing build
  --pack-only    - Re-pack rootfs into cpio (no build/install)
  --help, -h     - Show this help

Environment Variables:
  ARCH               - Target architecture (arm, aarch64) [default: arm]
  CROSS_COMPILE      - Toolchain prefix [default: auto-detect by ARCH]
  BUILD_OUTPUT_BASE  - Base output directory [default: out/build_latest_${OUTPUT_ARCH}]
  BUILD_JOBS         - Parallel jobs [default: auto-detect]
  DEBUG              - Enable debug output (set to 1)

Examples:
  $0                              # Full build with defconfig (ARM32)
  ARCH=aarch64 $0                 # Full build for ARM64
  $0 menuconfig                    # Interactive configuration only
  $0 --build-only                  # Build using existing .config
  $0 --clean                      # Clean and rebuild
  $0 defconfig --clean --static    # Clean static build
  $0 --pack-only                    # Re-pack rootfs after adding files

EOF
}

#-----------------------------------------------------------------------------
# Check toolchain
#-----------------------------------------------------------------------------
check_toolchain() {
    log_info "Checking toolchain..."

    if ! command -v ${CROSS_COMPILE}gcc &> /dev/null; then
        log_error "Cross compiler '${CROSS_COMPILE}gcc' not found!"
        log_error "Please ensure the toolchain is installed and in your PATH"
        echo ""
        log_info "For Ubuntu/Debian, install with:"
        echo -e "  ${COLOR_YELLOW}sudo apt install gcc-arm-none-linux-gnueabihf${COLOR_RESET} (for ARM32)"
        echo -e "  ${COLOR_YELLOW}sudo apt install gcc-aarch64-linux-gnu${COLOR_RESET} (for ARM64)"
        echo ""
        exit 1
    fi

    GCC_VERSION=$(${CROSS_COMPILE}gcc --version | head -n1)
    log_info "Toolchain: ${GCC_VERSION}"

    # Check for additional tools
    for tool in objcopy objdump strip; do
        if command -v ${CROSS_COMPILE}${tool} &> /dev/null; then
            log_debug "  ✓ ${CROSS_COMPILE}${tool}"
        else
            log_warn "  ! ${CROSS_COMPILE}${tool} not found (may be needed)"
        fi
    done

    log_success "Toolchain verified"
}

#-----------------------------------------------------------------------------
# Check BusyBox source
#-----------------------------------------------------------------------------
check_busybox_source() {
    log_info "Checking BusyBox source..."

    if [ ! -d "${BUSYBOX_SRC}" ]; then
        log_error "BusyBox source directory not found: ${BUSYBOX_SRC}"
        log_error "Please initialize the BusyBox submodule:"
        echo -e "  ${COLOR_YELLOW}git submodule update --init third_party/busybox${COLOR_RESET}"
        echo ""
        exit 1
    fi

    if [ ! -f "${BUSYBOX_SRC}/Makefile" ]; then
        log_error "BusyBox Makefile not found: ${BUSYBOX_SRC}/Makefile"
        log_error "The submodule may not be properly initialized"
        exit 1
    fi

    # Extract version
    if [ -f "${BUSYBOX_SRC}/Makefile" ]; then
        VERSION=$(grep "^VERSION"      "${BUSYBOX_SRC}/Makefile" | head -n1 | sed 's/VERSION = //')
        PATCHLEVEL=$(grep "^PATCHLEVEL" "${BUSYBOX_SRC}/Makefile" | head -n1 | sed 's/PATCHLEVEL = //')
        SUBLEVEL=$(grep "^SUBLEVEL"    "${BUSYBOX_SRC}/Makefile" | head -n1 | sed 's/SUBLEVEL = //')
        EXTRAVERSION=$(grep "^EXTRAVERSION" "${BUSYBOX_SRC}/Makefile" | head -n1 | sed 's/EXTRAVERSION = //')
        log_info "BusyBox version: ${VERSION}.${PATCHLEVEL}.${SUBLEVEL}${EXTRAVERSION}"
    fi

    log_success "BusyBox source verified"
}

#-----------------------------------------------------------------------------
# Clean build directory
#-----------------------------------------------------------------------------
do_distclean() {
    log_info "Cleaning build directory..."
    log_info "  Removing ${BUSYBOX_OUTPUT}"
    rm -rf "${BUSYBOX_OUTPUT}"
    mkdir -p "${BUSYBOX_OUTPUT}"
    mkdir -p "${ROOTFS_INSTALL}"
    log_success "Clean complete"
}

#-----------------------------------------------------------------------------
# Fix ARM-incompatible configs
#-----------------------------------------------------------------------------
fix_arm_config() {
    log_info "Checking ARM-incompatible config items..."
    local cfg="${BUSYBOX_OUTPUT}/.config"
    local patched=0

    if [ ! -f "${cfg}" ]; then
        log_warn "  No .config found, skipping"
        return 0
    fi

    # These configs are x86-specific and cause build errors on ARM
    if grep -q "^CONFIG_SHA1_HWACCEL=y" "${cfg}"; then
        sed -i 's/^CONFIG_SHA1_HWACCEL=y/# CONFIG_SHA1_HWACCEL is not set/' "${cfg}"
        log_warn "  Disabled CONFIG_SHA1_HWACCEL (x86-only)"
        patched=1
    fi

    if grep -q "^CONFIG_SHA256_HWACCEL=y" "${cfg}"; then
        sed -i 's/^CONFIG_SHA256_HWACCEL=y/# CONFIG_SHA256_HWACCEL is not set/' "${cfg}"
        log_warn "  Disabled CONFIG_SHA256_HWACCEL (x86-only)"
        patched=1
    fi

    if grep -q "^CONFIG_SHA1_SMALL=y" "${cfg}"; then
        sed -i 's/^CONFIG_SHA1_SMALL=y/# CONFIG_SHA1_SMALL is not set/' "${cfg}"
        log_warn "  Disabled CONFIG_SHA1_SMALL (may conflict on ARM)"
        patched=1
    fi

    # Disable tc (traffic control) - often has issues on embedded systems
    if grep -q "^CONFIG_TC=y" "${cfg}"; then
        sed -i 's/^CONFIG_TC=y/# CONFIG_TC is not set/' "${cfg}"
        log_warn "  Disabled CONFIG_TC (traffic control)"
        patched=1
    fi

    if [ ${patched} -eq 1 ]; then
        log_info "Running oldconfig to sync patched dependencies..."
        make -C "${BUSYBOX_SRC}" \
            ARCH=${ARCH} \
            CROSS_COMPILE=${CROSS_COMPILE} \
            O="${BUSYBOX_OUTPUT}" \
            oldconfig </dev/null || {
            log_warn "  oldconfig failed, continuing anyway"
        }
    else
        log_debug "  No ARM-incompatible items found"
    fi
}

#-----------------------------------------------------------------------------
# Configure BusyBox
#-----------------------------------------------------------------------------
do_configure() {
    log_info "Configuring BusyBox with ${TARGET}..."

    local cmd="make -C ${BUSYBOX_SRC} ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} O=${BUSYBOX_OUTPUT} ${TARGET}"
    log_cmd "${cmd}"
    eval "${cmd}"

    # menuconfig and other interactive/text-only targets exit after config
    if [[ "${TARGET}" == "menuconfig" ]] || [[ "${TARGET}" == "config" ]] || \
       [[ "${TARGET}" == "allnoconfig" ]] || [[ "${TARGET}" == "allyesconfig" ]]; then
        echo ""
        log_success "========================================"
        log_success "${TARGET} completed."
        log_success "Configuration saved to: ${BUSYBOX_OUTPUT}/.config"
        echo ""
        log_info "To build BusyBox with this config, run:"
        echo -e "  ${COLOR_YELLOW}$0 --build-only${COLOR_RESET}"
        log_success "========================================"
        exit 0
    fi

    # Enable/disable static build
    if [ ${STATIC_BUILD} -eq 1 ]; then
        log_info "Enabling static binary build..."
        sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' "${BUSYBOX_OUTPUT}/.config" || true
        sed -i 's/^CONFIG_STATIC=n/CONFIG_STATIC=y/' "${BUSYBOX_OUTPUT}/.config" || true
    else
        log_info "Building dynamic binary..."
        sed -i 's/^CONFIG_STATIC=y/# CONFIG_STATIC is not set/' "${BUSYBOX_OUTPUT}/.config" || true
    fi

    # Apply ARM-specific config fixes
    fix_arm_config

    log_success "Configuration complete"
}

#-----------------------------------------------------------------------------
# Build BusyBox
#-----------------------------------------------------------------------------
do_build() {
    log_info "Building BusyBox (${BUILD_JOBS} parallel jobs)..."
    local cmd="make -C ${BUSYBOX_SRC} ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} O=${BUSYBOX_OUTPUT} -j${BUILD_JOBS}"
    log_cmd "${cmd}"
    eval "${cmd}"
    log_success "Build complete"
}

#-----------------------------------------------------------------------------
# Install BusyBox
#-----------------------------------------------------------------------------
do_install() {
    log_info "Installing BusyBox to ${ROOTFS_INSTALL}..."
    mkdir -p "${ROOTFS_INSTALL}"
    local cmd="make -C ${BUSYBOX_SRC} ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} O=${BUSYBOX_OUTPUT} install CONFIG_PREFIX=${ROOTFS_INSTALL}"
    log_cmd "${cmd}"
    eval "${cmd}"
    log_success "Installation complete"
}

#-----------------------------------------------------------------------------
# Setup rootfs structure for initramfs
#-----------------------------------------------------------------------------
setup_rootfs() {
    log_info "Setting up rootfs structure..."

    # Create essential directories
    mkdir -p "${ROOTFS_INSTALL}/proc"
    mkdir -p "${ROOTFS_INSTALL}/sys"
    mkdir -p "${ROOTFS_INSTALL}/dev"
    mkdir -p "${ROOTFS_INSTALL}/tmp"
    mkdir -p "${ROOTFS_INSTALL}/etc"
    mkdir -p "${ROOTFS_INSTALL}/mnt"

    # Create init script
    cat > "${ROOTFS_INSTALL}/init" << 'INIT_EOF'
#!/bin/sh
# Minimal init script for initramfs

echo "=== PenguinLab Initramfs ==="

# Mount essential filesystems
mount -t proc none /proc
mount -t sysfs none /sys
mount -t tmpfs none /dev

# Create essential device nodes
mknod -m 622 /dev/console c 5 1
mknod -m 666 /dev/null c 1 3
mknod -m 666 /dev/zero c 1 5
mknod -m 666 /dev/tty c 5 0
mknod -m 666 /dev/random c 1 8
mknod -m 666 /dev/urandom c 1 9
mknod -m 666 /dev/tty0 c 4 0
mknod -m 666 /dev/ttyAMA0 c 204 64

# Print some info
echo "Kernel: $(uname -r)"
echo "Console: /dev/console"
echo ""
echo "Starting shell..."
echo ""

# Start interactive shell (keep it running)
exec /bin/sh -i </dev/console >/dev/console 2>&1
INIT_EOF

    chmod +x "${ROOTFS_INSTALL}/init"
    log_info "  Created /init"

    # Create /etc/inittab for BusyBox init
    cat > "${ROOTFS_INSTALL}/etc/inittab" << 'INITTAB_EOF'
::sysinit:/etc/init.d/rcS
::respawn:/bin/sh
INITTAB_EOF
    log_info "  Created /etc/inittab"

    # Create init script
    mkdir -p "${ROOTFS_INSTALL}/etc/init.d"
    cat > "${ROOTFS_INSTALL}/etc/init.d/rcS" << 'RC_EOF'
#!/bin/sh
mkdir -p /proc
mount -t proc none /proc
mkdir -p /sys
mount -t sysfs none /sys
mkdir -p /dev
mount -t tmpfs none /dev

mknod /dev/console c 5 1
mknod /dev/null c 1 3
mknod /dev/zero c 1 5
mknod /dev/tty c 5 0
mknod /dev/tty0 c 4 0
mknod /dev/ttyAMA0 c 204 64

echo "Initramfs initialized"
RC_EOF
    chmod +x "${ROOTFS_INSTALL}/etc/init.d/rcS"

    # Create fstab
    cat > "${ROOTFS_INSTALL}/etc/fstab" << 'FSTAB_EOF'
proc /proc proc defaults 0 0
sysfs /sys sysfs defaults 0 0
tmpfs /dev tmpfs defaults 0 0
FSTAB_EOF
    log_info "  Created /etc/fstab"

    log_success "Rootfs structure setup complete"
}

#-----------------------------------------------------------------------------
# Pack rootfs into cpio.gz (initramfs image)
#-----------------------------------------------------------------------------
do_pack_cpio() {
    log_info "Packing rootfs into cpio archive..."

    if [ ! -d "${ROOTFS_INSTALL}" ]; then
        log_error "Rootfs directory not found: ${ROOTFS_INSTALL}"
        log_error "Please run with install step first"
        return 1
    fi

    # Check that there's actually something in rootfs
    local file_count
    file_count=$(find "${ROOTFS_INSTALL}" -type f | wc -l)
    if [ "${file_count}" -eq 0 ]; then
        log_error "Rootfs directory is empty: ${ROOTFS_INSTALL}"
        return 1
    fi

    local old_dir
    old_dir=$(pwd)
    cd "${ROOTFS_INSTALL}"

    log_cmd "find . | cpio -o -H newc 2>/dev/null | gzip > ${ROOTFS_CPIO}"
    find . | cpio -o -H newc 2>/dev/null | gzip > "${ROOTFS_CPIO}"

    cd "${old_dir}"

    if [ ! -f "${ROOTFS_CPIO}" ]; then
        log_error "Failed to create cpio archive"
        return 1
    fi

    local cpio_size
    cpio_size=$(stat -c%s "${ROOTFS_CPIO}" 2>/dev/null || stat -f%z "${ROOTFS_CPIO}" 2>/dev/null)
    local cpio_size_mb
    cpio_size_mb=$(echo "scale=2; ${cpio_size} / 1048576" | bc 2>/dev/null || echo "${cpio_size}")

    log_success "Cpio archive created: ${ROOTFS_CPIO} (${cpio_size_mb} MB)"
    log_info "  Use with qemu-run.sh (auto-detected) or: -initrd ${ROOTFS_CPIO}"
}

#-----------------------------------------------------------------------------
# Verify build artifacts
#-----------------------------------------------------------------------------
verify_build_artifacts() {
    log_info "Verifying build artifacts..."

    local has_error=0

    # Check busybox binary
    if [ -f "${BUSYBOX_OUTPUT}/busybox" ]; then
        FILE_INFO=$(file "${BUSYBOX_OUTPUT}/busybox")
        log_info "  ✓ ${BUSYBOX_OUTPUT}/busybox"
        log_debug "    ${FILE_INFO}"

        if [[ ! "${FILE_INFO}" == *"ARM"* ]]; then
            log_warn "    Binary may not be ARM architecture"
        fi

        # Check if static
        if [[ "${FILE_INFO}" == *"statically linked"* ]]; then
            log_debug "    Static linking confirmed"
        fi

        SIZE=$(stat -c%s "${BUSYBOX_OUTPUT}/busybox" 2>/dev/null || stat -f%z "${BUSYBOX_OUTPUT}/busybox" 2>/dev/null)
        log_debug "    Size: ${SIZE} bytes"
    else
        log_error "  ✗ ${BUSYBOX_OUTPUT}/busybox: not found"
        has_error=1
    fi

    # Check config
    if [ -f "${BUSYBOX_OUTPUT}/.config" ]; then
        log_info "  ✓ ${BUSYBOX_OUTPUT}/.config"
    else
        log_error "  ✗ ${BUSYBOX_OUTPUT}/.config: not found"
        has_error=1
    fi

    # Check installation
    if [ -f "${ROOTFS_INSTALL}/bin/busybox" ]; then
        log_info "  ✓ ${ROOTFS_INSTALL}/bin/busybox"
        if [ -d "${ROOTFS_INSTALL}/bin" ]; then
            LINK_COUNT=$(find "${ROOTFS_INSTALL}/bin" -type l | wc -l)
            log_debug "    Symlinks in bin/: ${LINK_COUNT}"
        fi

        # Show some examples of installed applets
        if [ -d "${ROOTFS_INSTALL}/bin" ]; then
            EXAMPLES=$(find "${ROOTFS_INSTALL}/bin" -type l | head -n 5 | xargs basename -a 2>/dev/null | tr '\n' ' ')
            log_debug "    Example applets: ${EXAMPLES}..."
        fi
    else
        log_warn "  ! ${ROOTFS_INSTALL}/bin/busybox: not installed (may be expected if --install-only was not used)"
    fi

    if [ ${has_error} -eq 0 ]; then
        log_success "Build artifacts verified successfully"
        return 0
    else
        log_error "Build artifact verification failed"
        return 1
    fi
}

#-----------------------------------------------------------------------------
# Main
#-----------------------------------------------------------------------------
main() {
    # Handle help first
    if [ ${SHOW_HELP} -eq 1 ]; then
        show_usage
        exit 0
    fi

    log_info "========================================"
    log_info "BusyBox Build for ${ARCH} (output: ${OUTPUT_ARCH})"
    log_info "Target: ${TARGET}"
    log_info "========================================"

    # Check for mutually exclusive options
    if [ ${BUILD_ONLY} -eq 1 ] && [ ${CLEAN_BUILD} -eq 1 ]; then
        log_error "Error: --build-only and --clean are mutually exclusive"
        log_error "Use --build-only to keep existing config, or --clean to start fresh"
        exit 1
    fi

    if [ ${INSTALL_ONLY} -eq 1 ] && [ ${CLEAN_BUILD} -eq 1 ]; then
        log_error "Error: --install-only and --clean are mutually exclusive"
        exit 1
    fi

    if [ ${BUILD_ONLY} -eq 1 ] && [ ${INSTALL_ONLY} -eq 1 ]; then
        log_error "Error: --build-only and --install-only are mutually exclusive"
        exit 1
    fi

    if [ ${PACK_ONLY} -eq 1 ]; then
        if [ ${BUILD_ONLY} -eq 1 ] || [ ${INSTALL_ONLY} -eq 1 ] || [ ${CLEAN_BUILD} -eq 1 ]; then
            log_error "Error: --pack-only cannot be used with --build-only, --install-only, or --clean"
            exit 1
        fi
    fi

    # Show configuration
    log_debug "Configuration:"
    log_debug "  ARCH: ${ARCH}"
    log_debug "  OUTPUT_ARCH: ${OUTPUT_ARCH}"
    log_debug "  CROSS_COMPILE: ${CROSS_COMPILE}"
    log_debug "  BUILD_OUTPUT_BASE: ${BUILD_OUTPUT_BASE}"
    log_debug "  BUSYBOX_OUTPUT: ${BUSYBOX_OUTPUT}"
    log_debug "  ROOTFS_INSTALL: ${ROOTFS_INSTALL}"
    log_debug "  BUILD_JOBS: ${BUILD_JOBS}"
    log_debug "  STATIC_BUILD: ${STATIC_BUILD}"

    # Pre-flight checks (skip for --pack-only)
    log_info "========================================"
    if [ ${PACK_ONLY} -eq 0 ]; then
        check_toolchain
        check_busybox_source
    fi

    log_info "========================================"
    log_success "All checks passed"
    log_info "========================================"

    # Create directories
    if [ ${CLEAN_BUILD} -eq 1 ]; then
        do_distclean
    else
        mkdir -p "${BUSYBOX_OUTPUT}"
        mkdir -p "${ROOTFS_INSTALL}"
    fi

    # === Mode: Config only (interactive/text-only targets) ===
    if [[ "${TARGET}" == "menuconfig" ]] || [[ "${TARGET}" == "config" ]] || \
       [[ "${TARGET}" == "allnoconfig" ]] || [[ "${TARGET}" == "allyesconfig" ]]; then
        do_configure
        exit 0
    fi

    # === Mode: Pack only (skip build/install, just re-pack cpio) ===
    if [ ${PACK_ONLY} -eq 1 ]; then
        do_pack_cpio
        exit 0
    fi

    # === Mode: Install only ===
    if [ ${INSTALL_ONLY} -eq 1 ]; then
        if [ ! -f "${BUSYBOX_OUTPUT}/busybox" ]; then
            log_error "Install-only mode requires existing busybox binary at: ${BUSYBOX_OUTPUT}/busybox"
            log_error "Please build first with '$0' or '$0 --build-only'"
            exit 1
        fi
        log_info "Install-only mode: installing existing build..."
        do_install
        setup_rootfs
        do_pack_cpio
        log_success "========================================"
        log_success "Installation completed successfully!"
        log_info "Install directory: ${ROOTFS_INSTALL}"
        log_success "========================================"
        exit 0
    fi

    # === Mode: Build only ===
    if [ ${BUILD_ONLY} -eq 1 ]; then
        if [ ! -f "${BUSYBOX_OUTPUT}/.config" ]; then
            log_error "Build-only mode requires existing .config at: ${BUSYBOX_OUTPUT}/.config"
            log_error "Please run '$0 defconfig' or '$0 menuconfig' first"
            exit 1
        fi
        log_info "Build-only mode: using existing .config"
        fix_arm_config
        do_build
        log_success "========================================"
        log_success "Build completed successfully (not installed)"
        log_info "Output: ${BUSYBOX_OUTPUT}/busybox"
        log_info "To install, run: $0 --install-only"
        log_success "========================================"
        exit 0
    fi

    # === Mode: Default (configure + build + install + pack) ===
    do_configure
    do_build
    do_install
    setup_rootfs
    do_pack_cpio

    # Verification
    log_info "========================================"
    verify_build_artifacts || exit 1

    log_success "========================================"
    log_success "Build completed successfully!"
    log_success "========================================"
    log_info "Build artifacts:"
    log_info "  Binary: ${BUSYBOX_OUTPUT}/busybox"
    log_info "  Config: ${BUSYBOX_OUTPUT}/.config"
    log_info ""
    log_info "Installation:"
    log_info "  Directory: ${ROOTFS_INSTALL}"
    log_info "  BusyBox: ${ROOTFS_INSTALL}/bin/busybox"
    log_info "  Cpio:    ${ROOTFS_CPIO}"
    log_success "========================================"
}

#-----------------------------------------------------------------------------
# Parse arguments
#-----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            SHOW_HELP=1
            ;;
        --clean)
            CLEAN_BUILD=1
            ;;
        --static)
            STATIC_BUILD=1
            ;;
        --dynamic)
            STATIC_BUILD=0
            ;;
        --build-only)
            BUILD_ONLY=1
            ;;
        --install-only)
            INSTALL_ONLY=1
            ;;
        --pack-only)
            PACK_ONLY=1
            ;;
        defconfig|menuconfig|config|allnoconfig|allyesconfig)
            TARGET="$1"
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
    shift
done

main "$@"

#!/bin/bash
#=============================================================================
# QEMU ARM System Emulation Script
#=============================================================================
# This script provides a convenient interface for running ARM/ARM64 kernels
# in QEMU emulation. It supports both ARM32 (vexpress) and ARM64 (virt)
# machine types.
#
# Usage:
#   ./scripts/qemu-run.sh [command]
#
# Commands:
#   run     - Start QEMU with the configured kernel
#   stop    - Stop running QEMU instances
#   help    - Show this help message
#
# Environment Variables:
#   QEMU_ARCH         - arm/aarch64 (default: aarch64)
#   QEMU_MACHINE      - virt/vexpress-a9 (default: virt)
#   QEMU_CPU          - cortex-a72/cortex-a9 (default: cortex-a72)
#   QEMU_MEMORY       - Memory size (default: 1G)
#   QEMU_SMP          - CPU cores (default: 2)
#   KERNEL_IMAGE      - Kernel image path
#   DTB_FILE          - Device tree file path (ARM32 only)
#   ROOTFS            - Root filesystem image (initrd)
#   QEMU_EXTRA_OPTS   - Extra QEMU options
#=============================================================================

set -e

#-----------------------------------------------------------------------------
# Color output
#-----------------------------------------------------------------------------
readonly COLOR_RESET='\033[0m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[0;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_CYAN='\033[0;36m'

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

log_cmd() {
    echo -e "${COLOR_CYAN}[CMD]${COLOR_RESET} $*"
}

#-----------------------------------------------------------------------------
# Default values and environment variables
#-----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# QEMU configuration defaults
: "${QEMU_ARCH:=aarch64}"
: "${QEMU_MACHINE:=virt}"
: "${QEMU_CPU:=cortex-a72}"
: "${QEMU_MEMORY:=1G}"
: "${QEMU_SMP:=2}"
: "${QEMU_KERNEL_CMDLINE:=console=ttyAMA0,115200 root=/dev/ram0 rdinit=/init}"
: "${BUILD_OUTPUT_BASE:=${PROJECT_ROOT}/out/build_latest_arm64}"

# QEMU binary
QEMU_BIN=""
QEMU_SYSTEM="${QEMU_SYSTEM:-}"

# Kernel and DTB paths
KERNEL_IMAGE="${KERNEL_IMAGE:-}"
DTB_FILE="${DTB_FILE:-}"
ROOTFS="${ROOTFS:-}"
INITRD="${INITRD:-}"

# Serial port and networking
: "${QEMU_SERIAL:=on}"
: "${QEMU_NET:=off}"
: "${QEMU_NET_USER:=on}"
: "${QEMU_NET_TAP:=off}"
: "${QEMU_TAP_IF:=tap0}"
: "${QEMU_MAC:=}"

# Extra options
QEMU_EXTRA_OPTS="${QEMU_EXTRA_OPTS:-}"

# PID file for tracking running instances
PID_DIR="${PROJECT_ROOT}/out/qemu"
PID_FILE="${PID_DIR}/qemu.pid"

#-----------------------------------------------------------------------------
# Helper functions
#-----------------------------------------------------------------------------
show_usage() {
    cat << EOF
QEMU ARM System Emulation Script

Usage:
    $(basename "$0") [command]

Commands:
    run     - Start QEMU with the configured kernel
    stop    - Stop running QEMU instances
    help    - Show this help message

Environment Variables (with defaults):

Architecture & Machine:
    QEMU_ARCH         - ${QEMU_ARCH}          (arm, aarch64)
    QEMU_MACHINE      - ${QEMU_MACHINE}       (virt, vexpress-a9, vexpress-a15)
    QEMU_CPU          - ${QEMU_CPU}           (cortex-a72, cortex-a57, cortex-a15, cortex-a9)
    QEMU_MEMORY       - ${QEMU_MEMORY}        (e.g., 512M, 1G, 2G)
    QEMU_SMP          - ${QEMU_SMP}           (number of CPU cores)

Kernel & Boot:
    KERNEL_IMAGE      - (auto-detected if not set)
    DTB_FILE          - (auto-detected for ARM32)
    ROOTFS            - Root filesystem disk image (ext4/raw, uses -drive)
    INITRD            - Initramfs cpio image (uses -initrd, takes precedence)
    QEMU_KERNEL_CMDLINE - "${QEMU_KERNEL_CMDLINE}"

Devices & Networking:
    QEMU_SERIAL       - ${QEMU_SERIAL}        (on, off)
    QEMU_NET          - ${QEMU_NET}           (on, off)
    QEMU_NET_USER     - ${QEMU_NET_USER}      (user-mode networking)
    QEMU_NET_TAP      - ${QEMU_NET_TAP}       (TAP networking)
    QEMU_TAP_IF       - ${QEMU_TAP_IF}        (TAP interface name)
    QEMU_MAC          - (MAC address for network)

Build:
    BUILD_OUTPUT_BASE - ${BUILD_OUTPUT_BASE}

Other:
    QEMU_EXTRA_OPTS   - Extra QEMU command-line options

Examples:
    # Run ARM64 kernel with default virt machine
    $(basename "$0") run

    # Run ARM32 vexpress with custom kernel
    QEMU_ARCH=arm QEMU_MACHINE=vexpress-a9 KERNEL_IMAGE=zImage $(basename "$0") run

    # Run with more memory and CPUs
    QEMU_MEMORY=2G QEMU_SMP=4 $(basename "$0") run

    # Run with networking enabled
    QEMU_NET=on $(basename "$0") run

    # Stop running QEMU instances
    $(basename "$0") stop

QEMU virt Machine (Recommended for ARM64):
    - PL011 UART (console=ttyAMA0)
    - VirtIO network, block, balloon
    - GPIO controller
    - GIC interrupt controller

QEMU vexpress Machine (For ARM32):
    - PL011 UART (console=ttyAMA0)
    - PL111 CLCD (framebuffer)
    - LAN9118 Ethernet
    - SP804 timers

EOF
}

detect_qemu_binary() {
    if [[ -n "${QEMU_SYSTEM}" ]]; then
        QEMU_BIN="${QEMU_SYSTEM}"
        log_info "Using QEMU binary: ${QEMU_BIN}"
        return 0
    fi

    case "${QEMU_ARCH}" in
        aarch64)
            QEMU_BIN="qemu-system-aarch64"
            ;;
        arm)
            QEMU_BIN="qemu-system-arm"
            ;;
        *)
            log_error "Unsupported architecture: ${QEMU_ARCH}"
            log_info "Supported: arm, aarch64"
            return 1
            ;;
    esac

    # Check if QEMU binary exists
    if ! command -v "${QEMU_BIN}" &> /dev/null; then
        log_error "QEMU binary not found: ${QEMU_BIN}"
        log_error "Please install QEMU system emulation:"
        log_error "  sudo apt install qemu-system-arm qemu-system-arm qemu-user-static"
        return 1
    fi

    log_info "Detected QEMU binary: ${QEMU_BIN}"
    return 0
}

detect_kernel_image() {
    if [[ -n "${KERNEL_IMAGE}" ]]; then
        if [[ ! -f "${KERNEL_IMAGE}" ]]; then
            log_error "Kernel image not found: ${KERNEL_IMAGE}"
            return 1
        fi
        log_info "Using kernel image: ${KERNEL_IMAGE}"
        return 0
    fi

    # Auto-detect kernel image based on architecture
    local kernel_path=""
    local kernel_name=""

    case "${QEMU_ARCH}" in
        aarch64)
            kernel_name="Image"
            # Try build output directory first
            if [[ -f "${BUILD_OUTPUT_BASE}/arch/arm64/boot/${kernel_name}" ]]; then
                kernel_path="${BUILD_OUTPUT_BASE}/arch/arm64/boot/${kernel_name}"
            elif [[ -f "${PROJECT_ROOT}/third_party/linux/arch/arm64/boot/${kernel_name}" ]]; then
                kernel_path="${PROJECT_ROOT}/third_party/linux/arch/arm64/boot/${kernel_name}"
            fi
            ;;
        arm)
            kernel_name="zImage"
            # Try build output directory first
            if [[ -f "${BUILD_OUTPUT_BASE}/arch/arm/boot/${kernel_name}" ]]; then
                kernel_path="${BUILD_OUTPUT_BASE}/arch/arm/boot/${kernel_name}"
            elif [[ -f "${PROJECT_ROOT}/third_party/linux/arch/arm/boot/${kernel_name}" ]]; then
                kernel_path="${PROJECT_ROOT}/third_party/linux/arch/arm/boot/${kernel_name}"
            fi
            ;;
    esac

    if [[ -z "${kernel_path}" ]]; then
        log_error "Kernel image not found in build output"
        log_error "Please set KERNEL_IMAGE environment variable"
        return 1
    fi

    KERNEL_IMAGE="${kernel_path}"
    log_info "Auto-detected kernel: ${KERNEL_IMAGE}"
    return 0
}

detect_dtb_file() {
    # DTB is optional for virt (may be built-in), required for some machines
    if [[ -n "${DTB_FILE}" ]]; then
        if [[ ! -f "${DTB_FILE}" ]]; then
            log_error "DTB file not found: ${DTB_FILE}"
            return 1
        fi
        log_info "Using DTB: ${DTB_FILE}"
        return 0
    fi

    # For virt machine with ARM64, DTB is often not needed (built-in or generated)
    if [[ "${QEMU_MACHINE}" == "virt" && "${QEMU_ARCH}" == "aarch64" ]]; then
        log_info "virt machine: DTB optional, using QEMU generated device tree"
        return 0
    fi

    # Try to auto-detect DTB for ARM32
    if [[ "${QEMU_ARCH}" == "arm" ]]; then
        local dtb_name=""
        local dtb_path=""

        case "${QEMU_MACHINE}" in
            vexpress-a9)
                dtb_name="vexpress-v2p-ca9.dtb"
                ;;
            vexpress-a15)
                dtb_name="vexpress-v2p-ca15-tc1.dtb"
                ;;
            *)
                dtb_name="vexpress-v2p-ca9.dtb"
                ;;
        esac

        if [[ -f "${BUILD_OUTPUT_BASE}/arch/arm/boot/dts/${dtb_name}" ]]; then
            dtb_path="${BUILD_OUTPUT_BASE}/arch/arm/boot/dts/${dtb_name}"
        elif [[ -f "${PROJECT_ROOT}/third_party/linux/arch/arm/boot/dts/${dtb_name}" ]]; then
            dtb_path="${PROJECT_ROOT}/third_party/linux/arch/arm/boot/dts/${dtb_name}"
        fi

        if [[ -n "${dtb_path}" ]]; then
            DTB_FILE="${dtb_path}"
            log_info "Auto-detected DTB: ${DTB_FILE}"
            return 0
        fi
    fi

    log_warn "DTB file not found, may be built-in or using QEMU generated"
    return 0
}

detect_initrd() {
    if [[ -n "${INITRD}" ]]; then
        if [[ ! -f "${INITRD}" ]]; then
            log_error "Initrd file not found: ${INITRD}"
            return 1
        fi
        log_info "Using initrd: ${INITRD}"
        return 0
    fi

    # Auto-detect initrd based on architecture
    local initrd_path=""
    local initrd_name="rootfs.cpio.gz"

    # Determine architecture-specific output directory
    # Note: BUILD_OUTPUT_BASE uses 'arm64' for kernel, but rootfs may use 'aarch64'
    local output_dirs=()

    if [[ "${QEMU_ARCH}" == "aarch64" ]]; then
        output_dirs=(
            "${PROJECT_ROOT}/out/build_latest_aarch64/${initrd_name}"
            "${PROJECT_ROOT}/out/build_latest_arm64/${initrd_name}"
        )
    else
        output_dirs=(
            "${BUILD_OUTPUT_BASE}/${initrd_name}"
        )
    fi

    for dir in "${output_dirs[@]}"; do
        if [[ -f "${dir}" ]]; then
            initrd_path="${dir}"
            break
        fi
    done

    if [[ -z "${initrd_path}" ]]; then
        log_error "Initrd file not found (tried: ${output_dirs[*]})"
        log_error "Please run rootfs-minimal-maker.sh to create it, or set INITRD variable"
        return 1
    fi

    INITRD="${initrd_path}"
    log_info "Auto-detected initrd: ${INITRD}"
    return 0
}

build_qemu_command() {
    local cmd="${QEMU_BIN}"

    # Machine type
    cmd+=" -M ${QEMU_MACHINE}"

    # CPU
    cmd+=" -cpu ${QEMU_CPU}"

    # Memory
    cmd+=" -m ${QEMU_MEMORY}"

    # SMP (CPUs)
    cmd+=" -smp ${QEMU_SMP}"

    # Kernel image
    cmd+=" -kernel ${KERNEL_IMAGE}"

    # DTB (if specified)
    if [[ -n "${DTB_FILE}" ]]; then
        cmd+=" -dtb ${DTB_FILE}"
    fi

    # Kernel command line
    cmd+=" -append \"${QEMU_KERNEL_CMDLINE}\""

    # Serial port
    if [[ "${QEMU_SERIAL}" == "on" ]]; then
        if [[ "${QEMU_ARCH}" == "aarch64" ]]; then
            # virt machine uses ttyAMA0 (PL011)
            cmd+=" -serial mon:stdio"
        else
            # ARM32 machines typically use ttyAMA0
            cmd+=" -serial mon:stdio"
        fi
    fi

    # Networking
    if [[ "${QEMU_NET}" == "on" ]]; then
        if [[ "${QEMU_NET_USER}" == "on" ]]; then
            cmd+=" -netdev user,id=net0,hostfwd=tcp::2222-:22"
            cmd+=" -device virtio-net-pci,netdev=net0"
        fi

        if [[ "${QEMU_NET_TAP}" == "on" ]]; then
            if [[ -n "${QEMU_MAC}" ]]; then
                cmd+=" -netdev tap,id=net0,ifname=${QEMU_TAP_IF},script=no,downscript=no"
                cmd+=" -device virtio-net-pci,netdev=net0,mac=${QEMU_MAC}"
            else
                cmd+=" -netdev tap,id=net0,ifname=${QEMU_TAP_IF},script=no,downscript=no"
                cmd+=" -device virtio-net-pci,netdev=net0"
            fi
        fi
    fi

    # Initrd (initramfs) - takes precedence over block device
    if [[ -n "${INITRD}" ]]; then
        cmd+=" -initrd ${INITRD}"
    # VirtIO block device (if rootfs specified)
    elif [[ -n "${ROOTFS}" ]]; then
        cmd+=" -drive file=${ROOTFS},if=virtio,format=raw"
    fi

    # No graphic (use serial only)
    cmd+=" -nographic"

    # Enable semihosting (useful for bare-metal testing)
    # cmd+=" -semihosting"

    # Extra options
    if [[ -n "${QEMU_EXTRA_OPTS}" ]]; then
        cmd+=" ${QEMU_EXTRA_OPTS}"
    fi

    echo "${cmd}"
}

cmd_run() {
    log_info "=== QEMU ARM System Emulation ==="
    log_info "Architecture:     ${QEMU_ARCH}"
    log_info "Machine:          ${QEMU_MACHINE}"
    log_info "CPU:              ${QEMU_CPU}"
    log_info "Memory:           ${QEMU_MEMORY}"
    log_info "SMP:              ${QEMU_SMP}"
    log_info "=================================="

    # Detect QEMU binary
    if ! detect_qemu_binary; then
        return 1
    fi

    # Detect kernel image
    if ! detect_kernel_image; then
        return 1
    fi

    # Detect DTB file
    if ! detect_dtb_file; then
        return 1
    fi

    # Detect initrd
    if ! detect_initrd; then
        return 1
    fi

    # Build QEMU command
    local qemu_cmd
    qemu_cmd="$(build_qemu_command)"

    # Create PID directory
    mkdir -p "${PID_DIR}"
    mkdir -p "$(dirname "${PID_FILE}")"

    log_info "Starting QEMU..."
    log_info "Press Ctrl+A, X to exit QEMU console"

    # Run QEMU
    eval "${qemu_cmd}"
}

cmd_stop() {
    log_info "Stopping QEMU instances..."

    if [[ -f "${PID_FILE}" ]]; then
        local pid
        pid=$(cat "${PID_FILE}")
        if kill -0 "${pid}" 2>/dev/null; then
            log_info "Killing QEMU process: ${pid}"
            kill "${pid}"
            rm -f "${PID_FILE}"
            log_success "QEMU stopped"
        else
            log_warn "QEMU process ${pid} not running"
            rm -f "${PID_FILE}"
        fi
    else
        # Try to find and kill qemu-system processes
        local qemu_pids
        qemu_pids=$(pgrep -f "qemu-system-(arm|aarch64).*${PROJECT_ROOT}" || true)

        if [[ -n "${qemu_pids}" ]]; then
            log_info "Found QEMU processes: ${qemu_pids}"
            echo "${qemu_pids}" | xargs kill
            log_success "QEMU processes stopped"
        else
            log_warn "No running QEMU instances found"
        fi
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

    local command="$1"
    shift

    case "${command}" in
        run)
            cmd_run "$@"
            ;;
        stop)
            cmd_stop "$@"
            ;;
        *)
            log_error "Unknown command: ${command}"
            log_info "Run '$(basename "$0") help' for usage"
            exit 1
            ;;
    esac
}

# Run main if script is executed (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

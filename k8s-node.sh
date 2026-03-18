#!/bin/bash
set -euo pipefail

#################
### CONSTANTS ###
#################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/nodes.json"

SHUTDOWN_TIMEOUT=120
SHUTDOWN_POLL_INTERVAL=5

NODES=()
VBOX_DIR=""

#################
### FUNCTIONS ###
#################

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "Error: Config file not found: $CONFIG_FILE"
        exit 1
    fi

    if ! command -v jq &>/dev/null; then
        echo "Error: jq is required but not installed"
        exit 1
    fi

    VBOX_DIR=$(jq -r '.["VirtualBox-Directory"]' "$CONFIG_FILE")

    NODES=()
    while IFS= read -r node; do
        NODES+=("$node")
    done < <(jq -r '.nodes[]' "$CONFIG_FILE")

    if [[ ${#NODES[@]} -eq 0 ]]; then
        echo "Error: No nodes defined in $CONFIG_FILE"
        exit 1
    fi
}

is_vm_running() {
    local vm_name="$1"
    VBoxManage list runningvms | grep -q "\"${vm_name}\""
}

wait_for_shutdown() {
    local vm_name="$1"
    local elapsed=0

    while is_vm_running "$vm_name"; do
        if [[ $elapsed -ge $SHUTDOWN_TIMEOUT ]]; then
            echo "Error: $vm_name did not shut down within ${SHUTDOWN_TIMEOUT}s"
            echo "  Try: VBoxManage controlvm ${vm_name} poweroff"
            return 1
        fi
        sleep "$SHUTDOWN_POLL_INTERVAL"
        elapsed=$((elapsed + SHUTDOWN_POLL_INTERVAL))
    done
}

stop_all() {
    echo "Sending ACPI shutdown to all running VMs..."
    local running=()

    for vm in "${NODES[@]}"; do
        if is_vm_running "$vm"; then
            echo "  Stopping $vm..."
            VBoxManage controlvm "$vm" acpipowerbutton
            running+=("$vm")
        else
            echo "  $vm is already powered off"
        fi
    done

    for vm in "${running[@]}"; do
        echo "  Waiting for $vm to shut down..."
        wait_for_shutdown "$vm"
        echo "  $vm is off"
    done

    echo "All VMs stopped"
}

start_all() {
    echo "Starting all VMs headless..."
    for vm in "${NODES[@]}"; do
        if is_vm_running "$vm"; then
            echo "  $vm is already running"
        else
            echo "  Starting $vm..."
            VBoxManage startvm "$vm" --type headless
        fi
    done
    echo "All VMs started"
}

backup_all() {
    local name="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d')
    local snapshot="${name}-${timestamp}"

    echo "Backup: creating snapshot '$snapshot' on all VMs"

    stop_all

    for vm in "${NODES[@]}"; do
        echo "  Snapshotting $vm as '$snapshot'..."
        VBoxManage snapshot "$vm" take "$snapshot"
        echo "  $vm snapshot taken"
    done

    start_all
    echo "Backup complete: $snapshot"
}

restore_all() {
    local snapshot="$1"

    echo "Restore: reverting all VMs to snapshot '$snapshot'"

    stop_all

    for vm in "${NODES[@]}"; do
        echo "  Restoring $vm to '$snapshot'..."
        VBoxManage snapshot "$vm" restore "$snapshot"
        echo "  $vm restored"
    done

    start_all
    echo "Restore complete: $snapshot"
}

list_all() {
    echo "[ Snapshots: $(date) ]"
    echo
    for vm in "${NODES[@]}"; do
        echo "=== $vm ==="
        if ! VBoxManage snapshot "$vm" list 2>/dev/null; then
            echo "  (no snapshots)"
        fi
        echo
    done
}

format_all() {
    local snapshot="$1"

    echo "Deleting snapshot '$snapshot' from all VMs..."
    for vm in "${NODES[@]}"; do
        echo "  Deleting '$snapshot' from $vm..."
        VBoxManage snapshot "$vm" delete "$snapshot"
        echo "  $vm snapshot deleted"
    done
    echo "Format complete: $snapshot"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [argument]

Commands:
  start                    Start all VMs headless
  stop                     Graceful ACPI shutdown of all VMs
  backup <name>            Stop, snapshot as <name>-YYYY-MM-DD, start
  restore <snapshot>       Stop, restore to <snapshot>, start
  list                     List snapshots for all VMs
  format <snapshot>        Delete <snapshot> from all VMs

Examples:
  $(basename "$0") start
  $(basename "$0") backup fresh-install
  $(basename "$0") restore fresh-install-2026-03-18
  $(basename "$0") list
  $(basename "$0") format fresh-install-2026-03-18
EOF
}

#################
### MAIN CODE ###
#################

main() {
    load_config

    local action="${1:-}"

    case "$action" in
        start)
            start_all
            ;;
        stop)
            stop_all
            ;;
        backup)
            if [[ -z "${2:-}" ]]; then
                echo "Error: backup requires a snapshot name"
                echo "  Usage: $(basename "$0") backup <name>"
                exit 1
            fi
            backup_all "$2"
            ;;
        restore)
            if [[ -z "${2:-}" ]]; then
                echo "Error: restore requires a snapshot name"
                echo "  Usage: $(basename "$0") restore <snapshot>"
                exit 1
            fi
            restore_all "$2"
            ;;
        list)
            list_all
            ;;
        format)
            if [[ -z "${2:-}" ]]; then
                echo "Error: format requires a snapshot name"
                echo "  Usage: $(basename "$0") format <snapshot>"
                exit 1
            fi
            format_all "$2"
            ;;
        *)
            usage
            ;;
    esac
}

main "$@"

#!/bin/bash
#
# SPDX-License-Identifier: Apache-2.0
#


GROUP=$1
ACTION=$2
SNAP_NAME=$3

if [ $# -lt 2 ]; then
    echo "Usage: $0 <group_name> <action> [<snap_name>]"
    echo "Available cmds:"
    echo " Instance actions:   pause|resume|poweroff|poweron"
    echo " Snapshot actions:   take|delete|restore"

    echo ""

    echo "###### Available groups: "
    groups=$(vboxmanage list groups)
    for grp in $groups; do
        grp_txt=${grp:2:-1}
        if [ ! -z "$grp_txt" ]; then
            echo "$grp_txt"
        fi
    done

    exit 0
fi


echo "###### Params:"
echo "Group name:    $GROUP"
echo "Action:        $ACTION"
if [ ! -z "$SNAP_NAME" ]; then
        echo "Snapshot name: $SNAP_NAME"
fi

BASIC_INST_ACTIONS="pause poweroff"
SNAP_ACTIONS="take delete restore"

get_vms_by_group () {
    local group=$1
    vms=$(VBoxManage list -l vms |
        awk -v group="/$group" \
        '/^Name:/ { name = $2; } '`
        '/^Groups:/ { groups = $2; } '`
        '/^UUID:/ { uuid = $2; if (groups == group) print name, uuid; }')
    echo "###### VMs in group:" >&2
    echo "$vms" >&2
    echo "$vms"

}

if [[ "$SNAP_ACTIONS" = *"$ACTION"* ]]; then
    if [ $# -lt 3 ]; then
        echo "###### ERROR:"
        echo "Action '$ACTION' requires a snapshot name."
    fi
    vms=$(get_vms_by_group "$GROUP")
    echo "#### Executing action on vms"
    while read -r vm; do
        vm=(${vm})
        echo "Executing '$ACTION' on ${vm[0]}..."
        VBoxManage snapshot ${vm[1]} "${ACTION}" "${SNAP_NAME}"
    done <<< "$vms"
elif [[ "$BASIC_INST_ACTIONS" = *"$ACTION"* ]]; then
    vms=$(get_vms_by_group "$GROUP")
    echo "#### Executing action on vms"
    while read -r vm; do
        vm=(${vm})
        echo "Executing '$ACTION' on '${vm[0]}'..."
        VBoxManage controlvm ${vm[1]} "${ACTION}"
    done <<< "$vms"
    wait
elif [[ "$ACTION" = "resume" ]]; then
    echo "resume"
    vms=$(get_vms_by_group "$GROUP")
    # Getting vm's in saved state
    saved_vms=""
    while read -r vm; do
        vmA=(${vm})
        state=$(vboxmanage showvminfo ${vmA[1]} --machinereadable |
            grep "VMState=")
        if [[ "$state" = *"saved"* ]]; then
            if [ -z "$saved_vms" ]; then
                saved_vms="$vm"
            else
                saved_vms=$(printf '%s\n%s' "$saved_vms" "$vm")
            fi
        fi
    done <<< "$vms"
    echo "#### VMs in saved state:"
    echo "$saved_vms"
    # Powering on each VM
    echo "#### Preparing vms for start"
    if [ ! -z "$saved_vms" ]; then
        while read -r vm; do
            vm=(${vm})
            echo "Powering on VM \"${vm[1]}\"."
            (VBoxHeadless --start-paused --startvm ${vm[1]} \
                --vrde config >/dev/null 2>&1) &
            sleep 1
            while true; do
                state=$(vboxmanage showvminfo ${vm[1]} --machinereadable |
                    grep "VMState=")
                if [[ "$state" = *"paused"* ]]; then
                    break
                fi
            done
        done <<< "$saved_vms"
    fi
elif [[ "$ACTION" = "poweron" ]]; then
    vms=$(get_vms_by_group "$GROUP")
    echo "#### Powering on vms"
    while read -r vm; do
        vm=(${vm})
        (vboxmanage startvm ${vm[1]} --type headless) &
    done <<< "$vms"
    wait
elif [[ "$ACTION" = "poweroff" ]]; then
    echo "poweroff"
else
    echo "###### ERROR:"
    echo "ERROR: Action '$ACTION' not supported"
fi


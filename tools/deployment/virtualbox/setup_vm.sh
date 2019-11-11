#!/usr/bin/env bash

SCRIPTPATH="$( cd "$(dirname "$0")" ; pwd -P )"

CONFFILE="${1:-standard_controller.conf}"
source $SCRIPTPATH/$CONFFILE

VM_PREFIX_NAME="${VM_PREFIX_NAME:-default-}"
CONTROLLER_CPUS="${TIC_CONTROLLER_CPUS:-4}"
CONTROLLER_MEM="${TIC_CONTROLLER_MEM:-8192}"
CONTROLLER_DISK1="${TIC_CONTROLLER_DISK1:-81920}"
CONTROLLER_DISK2="${TIC_CONTROLLER_DISK2:-10240}"
CONTROLLER_DISK3="${TIC_CONTROLLER_DISK3:-4096}"
ISO="${TIC_INSTALL_ISO:-$SCRIPTPATH/bootimage.iso}"

HOSTADD_SCRIPT="$SCRIPTPATH/add_host.sh"

declare -a CREATED_VMS
machine_folder=`VBoxManage list systemproperties | grep "Default machine folder:" | cut -d : -f 2 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'`

# VRDE port for 1st VM
vrdeport="${TIC_VDEPORT_START:-13389}"
function set_vrde {
    vm=$1
    VBoxManage modifyvm "$vm" --vrde on --vrdeaddress 127.0.0.1 --vrdeport $vrdeport
    let vrdeport=vrdeport+1
}

function my_error {
    echo "Error: $1"
    my_trap_clean
    exit 1
}

function my_trap_clean {
    echo "deleting created VMS ${CREATED_VMS[@]}..."
    for vm in ${CREATED_VMS[@]}; do
        VBoxManage unregistervm "$vm" --delete
    done
}

function init_hostonly_net {
    # Create hostonly networks
    VBoxManage list hostonlyifs | grep vboxnet0 && vboxnet="1"
    if [ "x$vboxnet" != "x" ]; then
        VBoxManage list hostonlyifs
        read -r -p "Hostonly network vboxnet0 already existed. Are you sure to reconfigure it? [y/N] " response
        case $response in
            [yY][eE][sS]|[yY])
                echo
                ;;
            *)
                my_error "Please make sure it's safe before you remove hostonly network vboxnet0!"
                ;;
        esac
    else
        VBoxManage hostonlyif create
    fi
    VBoxManage hostonlyif ipconfig vboxnet0 --ip 10.10.10.1 --netmask 255.255.255.0
}

function createvm {
    vm=$1
    cpus=$2
    mem=$3

    echo "creating VM ${vm}..."
    # Find if VM already existing
    VBoxManage showvminfo "$vm" &>/dev/null && my_error "VM $vm already existed. Please delete it first"
    CREATED_VMS+=("$vm")
    # Create VM
    VBoxManage createvm --name "$vm" --register

    # Configure controller VM
    # CPU
    VBoxManage modifyvm "$vm" --ostype Linux_64 --cpus "$cpus" --pae on --longmode on --x2apic on --largepages off
    # Memory
    VBoxManage modifyvm "$vm" --memory "$mem"
    # Network
    VBoxManage modifyvm "$vm" --cableconnected1 on --nic1 hostonly --nictype1 82540EM --hostonlyadapter1 vboxnet0
    VBoxManage modifyvm "$vm" --cableconnected2 on --nic2 intnet --nictype2 82540EM --intnet2 intnet-management-$(whoami) --nicpromisc2 allow-all --nicbootprio2 1
    VBoxManage modifyvm "$vm" --cableconnected3 on --nic3 intnet --nictype3 virtio --intnet3 intnet-data1-$(whoami) --nicpromisc3 allow-all
    VBoxManage modifyvm "$vm" --cableconnected4 on --nic4 intnet --nictype4 virtio --intnet4 intnet-data2-$(whoami) --nicpromisc4 allow-all
    # Storage Medium
    VBoxManage createmedium disk --filename "${machine_folder}/${vm}/${vm}-disk1.vdi" --size $CONTROLLER_DISK1 --format VDI
    VBoxManage createmedium disk --filename "${machine_folder}/${vm}/${vm}-disk2.vdi" --size $CONTROLLER_DISK2 --format VDI
    VBoxManage createmedium disk --filename "${machine_folder}/${vm}/${vm}-disk3.vdi" --size $CONTROLLER_DISK3 --format VDI
    VBoxManage storagectl "$vm" --name SATA --add sata --controller IntelAhci --portcount 4 --hostiocache on --bootable on
    VBoxManage storageattach "$vm" --storagectl SATA --port 0 --device 0 --type hdd --medium "${machine_folder}/${vm}/${vm}-disk1.vdi"
    VBoxManage storageattach "$vm" --storagectl SATA --port 1 --device 0 --type hdd --medium "${machine_folder}/${vm}/${vm}-disk2.vdi"
    VBoxManage storageattach "$vm" --storagectl SATA --port 2 --device 0 --type hdd --medium "${machine_folder}/${vm}/${vm}-disk3.vdi"
    VBoxManage storageattach "$vm" --storagectl SATA --port 3 --device 0 --type dvddrive --medium emptydrive
    # Display
    VBoxManage modifyvm "$vm" --vram 16
    # Audio
    VBoxManage modifyvm "$vm" --audio none
    # Boot Order
    VBoxManage modifyvm "$vm" --boot1 dvd --boot2 disk --boot3 net --boot4 none
    # Other
    VBoxManage modifyvm "$vm" --ioapic on --rtcuseutc on
    # VM sepcific
    # Serial
    VBoxManage modifyvm "$vm" --uart1 0x3F8 4 --uartmode1 server "/tmp/serial_$vm"
    set_vrde "$vm"
}

function clonevm {
    src=$1
    target=$2
    echo "creating VM ${target} from ${src}..."
    # Find if vm already existing
    VBoxManage showvminfo "$target" &>/dev/null && my_error "VM $target already existed. Please delete it first"
    VBoxManage clonevm  "$src" --mode machine --name "$target" --register
    CREATED_VMS+=("$target")
    # Serial
    VBoxManage modifyvm "$target" --uart1 0x3F8 4 --uartmode1 server "/tmp/serial_$target"
    set_vrde "$target"
}

trap my_trap_clean SIGINT SIGTERM

set -e

[[ -f $ISO ]] || my_error "Can not fild install image $ISO"

# Init hostonly network
init_hostonly_net

# Create host_add.sh for Compute and Controller node
rm -f "$HOSTADD_SCRIPT"
cat <<EOF > "$HOSTADD_SCRIPT"
#!/usr/bin/env bash
source /etc/nova/openrc
EOF
chmod +x "$HOSTADD_SCRIPT"

# Create Contoller VM, at least controller0
createvm "${VM_PREFIX_NAME}controller-0" $CONTROLLER_CPUS $CONTROLLER_MEM
COUNTER=1
while [  $COUNTER -lt $TIC_CONTROLLER_NUM  ]; do
    clonevm ${VM_PREFIX_NAME}controller-0 "${VM_PREFIX_NAME}controller-$COUNTER"
    mac=`VBoxManage showvminfo "${VM_PREFIX_NAME}controller-$COUNTER" | grep intnet-management | grep -o "MAC: [0-9a-fA-F]*" | awk '{ print $2 }' | sed 's/../&:/g;s/:$//'`
    echo "system host-add -n ${VM_PREFIX_NAME}controller-$COUNTER -p controller -m $mac" >> "$HOSTADD_SCRIPT"
    let COUNTER=COUNTER+1
done

# Create Compute VM
COUNTER=0
while [  $COUNTER -lt $TIC_COMPUTE_NUM  ]; do
    clonevm ${VM_PREFIX_NAME}controller-0 "${VM_PREFIX_NAME}compute-$COUNTER"
    mac=`VBoxManage showvminfo "${VM_PREFIX_NAME}compute-$COUNTER" | grep intnet-management | grep -o "MAC: [0-9a-fA-F]*" | awk '{ print $2 }' | sed 's/../&:/g;s/:$//'`
    echo "system host-add -n ${VM_PREFIX_NAME}compute-$COUNTER -p compute -m $mac" >> "$HOSTADD_SCRIPT"
    let COUNTER=COUNTER+1
done

# Start Controller-0 with bootiso.img
VBoxManage storageattach ${VM_PREFIX_NAME}controller-0 --storagectl SATA --port 3 --device 0 --type dvddrive --medium "$ISO"
$SCRIPTPATH/start_vm.sh ${VM_PREFIX_NAME}controller-0

#!/usr/bin/env bash

## To be run AFTER "sudo config_controller --config-file TiS_config.ini_vb_simplex"
source /etc/nova/openrc
system license-install license.lic
system host-disk-list controller-0

NODE=controller-0
DEVICE=/dev/sdb
SIZE=$(echo $(system host-disk-list $NODE | grep $DEVICE | awk '{print $12}') | awk -F"." '{print $1}')
DISK=$(system host-disk-list $NODE | grep $DEVICE | awk '{print $2}')
# Create a partition for Cinder
system host-disk-partition-add $NODE $DISK $SIZE -t lvm_phys_vol
# Create the Volume Group
system host-lvg-add $NODE cinder-volumes
# Wait for partition to be created
while true; do
    system host-disk-partition-list $NODE --nowrap | grep $DEVICE | grep Ready;
    if [ $? -eq 0 ]; then
        break;
    fi;
    sleep 1;
    echo "Waiting for Disk Partition for $DEVICE:$NODE"
done

PARTITION=$(system host-disk-partition-list $NODE --disk $DISK --nowrap | grep part1 | awk '{print $2}')
# Create the PV
sleep 1
system host-pv-add $NODE cinder-volumes $PARTITION
sleep 1
#Enable LVM Backend.

system storage-backend-add lvm -s cinder --confirmed

#Wait for backend to be configured:
echo " This can take a few minutes..."
while true; do
    system storage-backend-list | grep lvm | grep configured;
    if [ $? -eq 0 ]; then
        break;
    else sleep 10;
    fi;
    echo "Waiting for backend to be configured"
done
system storage-backend-list

# Add provider networks and assign segmentation ranges
PHYSNET0='providernet-a'
PHYSNET1='providernet-b'
neutron providernet-create ${PHYSNET0} --type vlan
neutron providernet-create ${PHYSNET1} --type vlan
neutron providernet-range-create ${PHYSNET0} --name ${PHYSNET0}-a --range 400-499
neutron providernet-range-create ${PHYSNET0} --name ${PHYSNET0}-b --range 10-10 --shared
neutron providernet-range-create ${PHYSNET1} --name ${PHYSNET1}-a --range 500-599

# Create data interfaces
DATA0IF=eth1000
DATA1IF=eth1001
COMPUTE='controller-0'
system host-list --nowrap &> /dev/null && NOWRAP="--nowrap"
SPL=/tmp/tmp-system-port-list
SPIL=/tmp/tmp-system-host-if-list
system host-port-list ${COMPUTE} $NOWRAP > ${SPL}
system host-if-list -a ${COMPUTE} $NOWRAP > ${SPIL}
DATA0PCIADDR=$(cat $SPL | grep $DATA0IF |awk '{print $8}')
DATA1PCIADDR=$(cat $SPL | grep $DATA1IF |awk '{print $8}')
DATA0PORTUUID=$(cat $SPL | grep ${DATA0PCIADDR} | awk '{print $2}')
DATA1PORTUUID=$(cat $SPL | grep ${DATA1PCIADDR} | awk '{print $2}')
DATA0PORTNAME=$(cat $SPL | grep ${DATA0PCIADDR} | awk '{print $4}')
DATA1PORTNAME=$(cat  $SPL | grep ${DATA1PCIADDR} | awk '{print $4}')
DATA0IFUUID=$(cat $SPIL | awk -v DATA0PORTNAME=$DATA0PORTNAME '($12 ~ DATA0PORTNAME) {print $2}')
DATA1IFUUID=$(cat $SPIL | awk -v DATA1PORTNAME=$DATA1PORTNAME '($12 ~ DATA1PORTNAME) {print $2}')
system host-if-modify -m 1500 -n data0 -p ${PHYSNET0} -nt data ${COMPUTE} ${DATA0IFUUID}
system host-if-modify -m 1500 -n data1 -p ${PHYSNET1} -nt data ${COMPUTE} ${DATA1IFUUID}

# Add nova local backend
system host-lvg-add ${COMPUTE} nova-local
ROOT_DISK=$(system host-show ${COMPUTE} | grep rootfs | awk '{print $4}')
ROOT_DISK_UUID=$(system host-disk-list ${COMPUTE} --nowrap | grep ${ROOT_DISK} | awk '{print $2}')
ROOT_DISK_SIZE=$(system host-disk-list ${COMPUTE} --nowrap   | grep ${ROOT_DISK} | awk '{print $12}')
PARTITION_SIZE=$(echo ${ROOT_SIZE}/2|bc)
CGTS_PARTITION=$(system host-disk-partition-add -t lvm_phys_vol ${COMPUTE} ${ROOT_DISK_UUID} ${PARTITION_SIZE})

while true; do
    system host-disk-partition-list ${COMPUTE} | grep /dev/sda5 | grep Ready
    if [ $? -eq 0 ]; then
        break;
    else sleep 2;
    fi;
    echo "Waiting to add disk partition"
done
system host-disk-partition-list ${COMPUTE}

CGTS_PARTITION_UUID=$(echo ${CGTS_PARTITION} | grep -ow "| uuid | [a-z0-9\-]* |" | awk '{print $4}')
sleep 1
system host-pv-add ${COMPUTE} cgts-vg ${CGTS_PARTITION_UUID}
sleep 1
NOVA_PARTITION=$(system host-disk-partition-add -t lvm_phys_vol ${COMPUTE} ${ROOT_DISK_UUID} ${PARTITION_SIZE})

while true; do
    system host-disk-partition-list ${COMPUTE} | grep /dev/sda6 | grep Ready
    if [ $? -eq 0 ]; then
        break;
    else sleep 2;
    fi;
    echo "Waiting to add disk partition"
done
system host-disk-partition-list ${COMPUTE}

NOVA_PARTITION_UUID=$(echo ${NOVA_PARTITION} | grep -ow "| uuid | [a-z0-9\-]* |" | awk '{print $4}')
system host-pv-add ${COMPUTE} nova-local ${NOVA_PARTITION_UUID}
sleep 1
system host-lvg-modify -b image -s 10240 ${COMPUTE} nova-local
sleep 10

### This will result in a reboot.
system host-unlock controller-0
echo " Watch CONSOLE to see progress. You will see things like "
echo "    Applying manifest 127.168.204.3_patching.pp..."
echo "    [DONE]"
echo " Tailing /var/log/platform.log until reboot..."
tail -f /var/log/platform.log

#!/bin/bash -eu

PLATFORM_CONF=${PLATFORM_CONF:-"/etc/platform/platform.conf"}
STATUS_FILE=${STATUS_FILE:-"${HOME}/.lab_setup.done"}
CONFIG_FILE=${CONFIG_FILE:-"${HOME}/lab_setup.conf"}
GROUP0_FILE=${GROUP0_FILE:-"${HOME}/lab_setup_group0.conf"}
CONFIG_CHAIN_FILE=${CONFIG_CHAIN_FILE:-"${HOME}/.config_chain"}
VERBOSE_LEVEL=0
DEBUG_LEVEL=0
FORCE="no"
CLEAR_CHAIN="no"
SYSTEM_NAME=""
RAM_QUOTA=""

DEFAULT_IF0=eth0
DEFAULT_IF1=eth1
DEFAULT_IF2=eth2

CLI_NOWRAP=--nowrap
DEFAULT_OPENSTACK_PASSWORD="Li69nux*"
# set timeout as 10 mins
HTTPS_TIMEOUT=600
HTTPS_ENABLED=""
TPM_ENABLED=""
CERTIFICATE_FILENAME="server-with-key.pem"
K8S_ENABLED="yes"
K8S_URL="http://keystone.openstack.svc.cluster.local/v3"
CLUSTER_HOST_INTERFACES="ethernet|mgmt0|none|none"

## Pause first-time configuration to allow the user to setup the
## controller/worker nodes.  Unset or set to "no" to allow the script to run
## to completion without any pauses.
##
PAUSE_CONFIG=${PAUSE_CONFIG:-"yes"}

while getopts :f:cvdzF OPT; do
    case $OPT in
        F|+F)
            FORCE="yes"
            ;;
        f|+f)
            CONFIG_FILE="$OPTARG"
            ;;
        c|+c)
            PAUSE_CONFIG="no"
            ;;
        v|+v)
            VERBOSE_LEVEL=$((VERBOSE_LEVEL + 1))
            ;;
        d|+d)
            DEBUG_LEVEL=$((DEBUG_LEVEL + 1))
            ;;
        z|+z)
            CLEAR_CHAIN="yes"
            ;;
        *)
            echo "usage: ${0##*/} [-f config_file] [-c] [-v] [-d] [-z] [--] ARGS..."
            exit 2
    esac
done
shift $(( OPTIND - 1 ))
OPTIND=1

## Run as admin
OPENRC=/etc/platform/openrc
source ${OPENRC}

## Determine board configuration
if [ ! -f ${PLATFORM_CONF} ]; then
    echo "Failed to find ${PLATFORM_CONF}"
    exit 3
fi
source ${PLATFORM_CONF}

# --os-region-name option is required for cinder, glance, nova and neutron commands on
# SystemController in Distributed Cloud configuration
if [[ -n ${distributed_cloud_role+x} && "${distributed_cloud_role}" == "systemcontroller" ]]; then
    REGION_OPTION="--os-region-name SystemController"
else
    REGION_OPTION=""
fi

if [[ "${subfunction}" == *worker* ]]; then
    ## A small (combined) system
    SMALL_SYSTEM="yes"
    NODES=$(system host-list ${CLI_NOWRAP} | awk '{if (($6 == "controller" || $6 == "worker") && ($12 != "offline")) print $4;}')
else
    SMALL_SYSTEM="no"
    NODES=$(system host-list ${CLI_NOWRAP} | awk '{if ($6=="worker" && ($12 != "offline")) print $4;}')
fi

if [[ "${subfunction}" == *lowlatency* ]]; then
    LOW_LATENCY="yes"
else
    LOW_LATENCY="no"
fi

## Get system mode
SYSTEM_MODE=${system_mode:-none}
#Distributed cloud role: controller, subcloud, none
DISTRIBUTED_CLOUD_ROLE="none"

## vswitch type
VSWITCH_TYPE="avs"

## Cinder's backends.
# LVM, Ceph, both or none. If CONFIGURE_STORAGE_LVM is set, then Cinder will be configured by default
# on LVM.
#
# Examples:
#   CINDER_BACKENDS=""         - no backend will be installed for Cinder
#   CINDER_BACKENDS="ceph"     - ceph backend will be added to cinder
#   CINDER_BACKENDS="ceph lvm" - both ceph and lvm will be added
#   CINDER_BACKENDS="external" - external will be added for cinder
CINDER_BACKENDS=""

## Glance backends
# By default 'file' will be configured. Optional is Ceph.
#
# Examples:
#   GLANCE_BACKENDS=""         - file backend will be configured
#   GLANCE_BACKENDS="ceph"     - file & ceph (i.e. rbd) will be configured as backends for Glance
GLANCE_BACKENDS=""

## Configure one or both of the two main storage backends: LVM & Ceph
# Set based on CINDER_BACKENDS or GLANCE_BACKENDS config. If no Cinder nor Glance backends are configured
# these settings can be set by hand to enable storage backends without services.
CONFIGURE_STORAGE_LVM="no"   # Set to "yes" if storage is on controller
CONFIGURE_STORAGE_CEPH="no"  # Set to "yes" if the lab has storage nodes

## Chose when to configure storage backend:
#  - if 'early' then it is configured at the beginning, when only controller-0 is up
#  - if 'late' then it will be configured after controller-1 is available
WHEN_TO_CONFIG_CEPH="early"
WHEN_TO_CONFIG_LVM="early"

STORAGE_CEPH_CAPABILITIES=""

# The default system tier for OSDs
#
# Note: This aligns with a sysinv constant. Do not change unless code is updated.
CEPH_TIER_DEFAULT="storage"

# Additional Ceph Storage Tiers
# Syntax:
#   STORAGE_TIERS_CEPH="<second tier name>|<third tier name>|..."
STORAGE_TIERS_CEPH=""
#STORAGE_TIERS_CEPH="silver|gold"

## Controller nodes
## (controller-0 is configured by config_controller)
CONTROLLER_NODES="controller-1"

## Optional storage nodes
STORAGE_NODES="storage-1 storage-0"
EXTRA_STORAGE_NODES=""

## Optional Journal devices for storage nodes
# One or more SSD device nodes may be designated as journal backing devices.
# Each journal backing device can accommodate multiple journal partitions.
# If the option is not present then journals are collocated with the OSD data
#
# Note: If multiple journal backing devices are specified then, when configuring
# OSDs, the user must specify the location of the journal.
#
# Example:
#   JOURNAL_DEVICES="/dev/sdc"
#   JOURNAL_DEVICES="/dev/sdc /dev/sdd"

## Optional OSD volumes for storage nodes
# The syntax for each OSD is:
#           <device_node>|<storage_tier>|<journal size (MiB)|<journal backing device>
#
# Note: The user MUST specify the journal location if multiple journal backing
#       devices are configured in JOURNAL_DEVICES, otherwise is optional.
#
# Note: A storage tier is required for each OSD. The default
#       "$CEPH_TIER_DEFAULT" should be used for all OSDs defined in a
#       basic one tier configuration
#
# Examples:
#    OSD_DEVICES="/dev/sdb|${CEPH_TIER_DEFAULT} /dev/sdc|${CEPH_TIER_DEFAULT}"             - osd volumes with collocated journals
#    OSD_DEVICES="/dev/sdb|${CEPH_TIER_DEFAULT}|10240 /dev/sdc|${CEPH_TIER_DEFAULT}|10240" - journals of 10GiB on a single journal device
#    OSD_DEVICES="/dev/sdb|${CEPH_TIER_DEFAULT}|10240|/dev/sdg /dev/sdc|${CEPH_TIER_DEFAULT}|10240|/dev/sdi" - journal location is specified
#OSD_DEVICES="/dev/sdb|${CEPH_TIER_DEFAULT}"

## File System storage size
DATABASE_FS_SIZE=0
IMAGE_FS_SIZE=0
BACKUP_FS_SIZE=0
IMG_CONVERSIONS_FS_SIZE=0

FS_RESIZE_TIMEOUT=180
FS_RESIZE_DEGRADE_TIMEOUT=120

# 60 minutes
DRBD_SYNC_TIMEOUT=3600

## Common resource names and prefixes
##
GROUPNO=0

TENANT1=tenant1
TENANT2=tenant2

## The openstack user domain for creation of tenant user.
## The openstack project domain for creation of tenant projects.
## Since these are mapped to the SQL based Identity backend, they
## shall go into the Default domain.
OPENSTACK_USER_DOMAIN="default"
OPENSTACK_PROJECT_DOMAIN="default"

FIRSTWORKERID=""
LASTWORKERID=""
WORKERIDS=""
ADMIN_USER="admin"
MEMBER_ROLE="member"

## Numa node testing.  Set to "node0", "node1", or "float" to set the numa
## node for a specific tenant.  By default the tenant VMs are pinned to cpus
## but not on a specific numa node.
##
TENANT1NODE=""
TENANT2NODE=""

## The maximum number of NUMA nodes of the system
##
NUMA_NODE_COUNT=2

## Time Synchronization service: NTP or PTP
##
TIMESERVICE="NTP"
NTPSERVERS="132.163.4.102,129.6.15.30,198.111.152.100"

## Tenant network configurations.
##
DNSNAMESERVERS="147.11.57.133 128.224.144.130 147.11.57.128"
MGMTIPVERSION=4
MGMTNETS=1
MGMTSUBNETS=("192.168.101.0/27,192.168.101.32/27,192.168.101.64/27", "192.168.201.0/27,192.168.201.32/27,192.168.201.64/27")
MGMTDVR=("no" "no")
MGMTIPV6ADDRMODE="dhcpv6-stateful"
EXTIPVERSION=4
EXTERNALGWIP="192.168.1.1"
EXTERNALCIDR="192.168.1.0/24"
EXTERNALSNAT="no"


## Provider network configurations. Each lab has dedicated VLANs assigned to it.
## An exception to this is that the external network VLAN is shared across all
## of the labs.  The configuration syntax which is describes belows allows to
## define an arbitrary number of provider networks on a per lab basis and then
## to refer to those provider networks by name when defining data interfaces.
## Since in the large lab configuration we need to distinguish provider
## networks from each group/island we prefix their name with "groupX-" where X
## is the group number.  To avoid having to specify the group number in several
## places we leave it off of all variable specifications and the prefix is
## added dynamically where needed.  For example, "ext0" below will become
## "group0-ext0" when actually created; and "data0" will become "group0-data0"
## when created.
##
## Example:
##
## PROVIDERNETS="vxlan|ext0|1500|4-4|shared|239.0.2.1|4789|11 \
## vlan|data0|1500|600-615|tenant1 \
## vlan|data0b|1500|700-731|shared \
## vlan|data1|1500|616-631|tenant2"
##
PROVIDERNETS="vlan|ext0|1500|10-10|shared \
vlan|data0|1500|600-615|tenant1 \
vlan|data0b|1500|700-731|shared \
vlan|data1|1500|616-631|tenant2"

## Enable vlan transparency on all provider networks that have not provided a
## setting for this feature.  For now this is a global attribute.  In the
## future we will add control on a per provider network and tenant network
## basis.
##
VLAN_TRANSPARENT="False"


## Enable vlan transparency on internal networks.  This is an alternative to
## using trunks, and if True, then trunks will not be provisioned.
VLAN_TRANSPARENT_INTERNAL_NETWORKS="True"

## Tenant network provider network manual configurations.  Because our lab
## environment dictates that we use specific VLAN values for specific tenants
## (i.e., to reach NAT box, or to be carried by specific data interface) we
## need to manual set the provider network and segmentation id values.
##
EXTERNALPNET="vlan|ext0|10"
INTERNALPNET="vlan|data0b"


## Interface configurations.  The script supports setting up mgmt, infra, oam,
## data, pci-passthrough and sriov interfaces.  The syntax for all types is
## similar but each type can refine how parameters are specified.  There are
## some attribute that are common to each type.  Each worker node can have a
## custom value for each variable by prepending the node name; otherwise the
## default (unnamed) variable is used.  These are some examples:
##
## NOTE: the provider network names are supplied without the "group0-" prefix.
## It is added as needed when the data is consumed to avoid having to specify
## the groupno in multiple places.
##
## NOTE: the PCI addresses are a composite of the actual PCIADDR and PCIDEV
## values separated with a "+" character.  PCIDEV is assumed to be "0" if not
## specified.  This value is only relevant for Mellanox devices.
##
## NOTE: the device field can be specified as a comma separated list of
## PCIADDR+PCIDEV values or a comma separated list of interface names.
## Interface names are autogenerated based on type and index in the *_INTERFACE
## list variable (i.e., data0, infra1, etc...).  For VLAN interfaces the VLANID
## is used instead of the index (e.g., vlan11).  The devices are created in
## this order so you can only refer to names that have already been created by
## the time the dependent device gets created:  mgmt data infra pthru sriov
##
## Some examples:
##
## DATA_INTERFACES="ethernet|0000:00:09.0+0|1500|data0 ethernet|0000:00:0a.0+0|1500|data1"
## DATA_INTERFACES="ethernet|0000:00:09.0+0|1500|data0 ethernet|0000:00:0a.0+0|1500|data1 vlan|data0|1500|ext0|11"
## DATA_INTERFACES="ae|0000:00:09.0+0,0000:00:0a.0+0|1500|data0,data1"
## WORKER2_DATA_INTERFACES="ae|0000:00:06.0+0,0000:00:07.0+0|1500|data0,data1"
## INFRA_INTERFACES="vlan|data0|1500|none|12"
## PTHRU_INTERFACES="ethernet|0000:84:00.0|1500|data0"
## SRIOV_INTERFACES="ethernet|0000:84:00.0|1500|data0|4"
##
DATA_INTERFACES="ethernet|0000:00:09.0+0|1500|ext0,data0,data0b ethernet|0000:00:0a.0+0|1500|data1"
OAM_INTERFACES="ethernet|${DEFAULT_IF0}|1500|none"

## IP addresses and routes for data interfaces if using VXLAN provider
## networks.  Must be overridden in lab specific config file since each worker
## node must have its own IP addresses.
##
##    IPADDRS must be in the form:  "IP1/PREFIX,IP2/PREFIX,..."
##    IPROUTES must be in the form: "NET1/PREFIX/GWY,NET2/PREFIX/GWY,..."
##
## There must be an entry for each interface that uses VXLAN provider networks
## on each node.  The IPADDRS and IPROUTES variables must be double prefixes;
## once for node name and once for interface name.  Example:
##
##  WORKER0_DATA0_IPADDRS="192.168.57.2/24,fd00:0:0:1::2/64"
##  WORKER0_DATA0_IPROUTES="0.0.0.0/0/192.168.57.1,::/0/fd00:0:0:1::1"
##
## Alternatively, IP addresses on a per worker node can be omitted if an IP
## address pool is defined.  The pools must be constrained to the IP addresses
## that are assigned to the lab being configured.
##
##  DATA0_IPPOOLS="data0v4|192.168.57.0|24|random|192.168.57.2-192.168.57.5 \
##                 data0v6|fd00:0:0:1::|64|random|fd00:0:0:0:1::2-fd00:0:0:1::5"
##  DATA1_IPPOOLS="data1v4|192.168.58.0|24|random|192.168.58.2-192.168.58.5"
##                 data1v6|fd00:0:0:2::|64|random|fd00:0:0:0:2::2-fd00:0:0:2::5"
##

## VXLAN specific attributes.  The GROUP and PORT array can have multiple
## values.  The 0th entry will be used for the tenant1 provider network
## ranges, the Nth entry will be used for the tenant2 provider networ ranges,
## and the internal network ranges will alternate between each value therefore
## allowing for a mixture of addresses and ports in the configuration.  Each
## internal range will have up to VXLAN_INTERNAL_STEP entries
##
VXLAN_GROUPS="239.0.1.1 ff0e::1:1 239.0.1.2 ff0e::1:2"
VXLAN_PORTS="8472 4789"
VXLAN_TTL=1
VXLAN_INTERNAL_STEP=4

## Board Management attributes.  Configures the BMC (e.g., iLO3, iLO4, etc..)
## for boards that support it.
##
##    The BM_USERNAME, BM_PASSWORD, and BM_TYPE variables can be overriden on
##    a per-lab basis or a per-worker basis in the lab configuration file.
##
##    The BM_MACADDR variable must be overridden on a per-worker basis in the
##    lab configuration file.
##
BM_ENABLED="no"
BM_TYPE="ilo4"
BM_USERNAME="Administrator"
BM_PASSWORD="remoteADMIN"
BM_MACADDR=""

## Set the default VIF model of the first NIC on all VM instances to "virtio".
## Do not change this as it may cause unintended side-effects and NIC
## reordering in the VM.
MGMT_VIF_MODEL="virtio"

## Common paths
IMAGE_DIR=${HOME}/images
USERDATA_DIR=${HOME}/userdata

## Networking test mode
## choices={"layer2", "layer3"}
##
NETWORKING_TYPE="layer3"

## Provider Network type
## choices={"vlan", "vxlan", "mixed"}
##
## warning: If setting to "vxlan" there must be a DATA0IPADDR and DATA1IPADDR
## set for each worker node.
PROVIDERNET_TYPE="vlan"

## Special test mode for benchmarking only.  Set to "yes" only if only a
## single VM pair will exist at any given time.  This will cause only a single
## pair of tenant and internal networks to be created.  This is to facilitate
## sequentially booting and taring down VMs of different types to benchmark
## their network performance without having to cleanup the lab and install a
## different configuration.
##
REUSE_NETWORKS="no"

## Special test mode for benchmarking only.  Set to "yes" to force tenant
## networks to be shared so that a single VM can have a link to each tenant's
## tenant network.  This is to force traffic from ixia to be returned directly
## to ixia without first passing through an internal network and another VM.
## In this mode it is expected that only a single tenant's VM will be launched
## at any given time (i.e., it will not work if 2 VMs are both sharing each
## others tenant network).
##
##  resulting in:
##
##      ixia-port0 +---+ tenant1-net0 +------+
##                                           VM (tenant1)
##      ixia-port1 +---+ tenant2-net0 +------+
##
##  instead of:
##
##      ixia-port0 +---+ tenant1-net0 +------+ VM (tenant1) ---+
##                                                             |
##                                                        internal-net0
##                                                             |
##      ixia-port1 +---+ tenant2-net0 +------+ VM (tenant2) ---+
##
SHARED_TENANT_NETWORKS="no"

## Special test mode for benchmarking only.  Set to "yes" to create a separate
## tenant network and router which will sit between Ixia and the regular layer2
## tenant networks.  The purpose is to insert an AVR router in to the Ixia
## traffic path so that its performance can be evaluated by vbenchmark.  This
## requires that SHARED_TENANT_NETWORKS be set to "yes" because the end goal is
## to have a single VM bridge traffic between 2 tenant networks.
##
##  resulting in:
##
##      ixia-port0 +---+ tenant1-ixia-net0 +---+ router +---+ tenant1-net0 +------+
##                                                                                VM (tenant1)
##      ixia-port1 +---+ tenant2-ixia-net0 +---+ router +---+ tenant2-net0 +------+
##
##
##  instead of:
##
##      ixia-port0 +---+ tenant1-net0 +------+
##                                           VM (tenant1)
##      ixia-port1 +---+ tenant2-net0 +------+
##
ROUTED_TENANT_NETWORKS="no"

## Enables/Disables the allocation of floating IP addresses for each VM.  This
## functionality is disabled by default because our NAT box is configured with
## static routes that provide connectivity directly to the tenant networks.
## The NAT box, as its name implies, already does NAT so we do not need this
## for day-to-day lab usage.  It should be enabled when explicitly testing
## this functionality.
FLOATING_IP="no"

## DHCP on secondary networks
##
INTERNALNET_DHCP="yes"
TENANTNET_DHCP="yes"

## to only create the first NIC on each VM.
EXTRA_NICS="yes"

## Enable config-drive instead of relying only on the metadata server
##
CONFIG_DRIVE="no"

## Force DHCP servers to service metadata requests even if there are routers on
## the network that are capable of this functionality.  Useful for SDN testing
## because routers exist but are implemented in openflow rules and are not
## capable of servicing metadata requests.
##
FORCE_METADATA="no"

## Root disk volume type and image size in GB
## choices={"glance", "cinder"}
##
IMAGE_TYPE="cinder"

## Number of vswitch/shared physical CPU on worker nodes on first numa node
## The PCPU assignment can also be specified as a mapping between numa node and count
## with the following format.
##   XXXX_PCPU_MAP="<numa-node>:<count>,<numa-node>:<count>"
VSWITCH_PCPU=2
SHARED_PCPU=0

## Setup custom VCPU model for each VM type if necessary
##
DPDK_VCPUMODEL="SandyBridge"

## Add extra functions to guest userdata
##
#EXTRA_FUNCTIONS="pgbench"
EXTRA_FUNCTIONS=""

## Logical interface default configuration values.  These can be specified
## directly when defining *_INTERFACES variables, or with a ${IFTYPE}_*
## refinement, or left to use the DEFAULT_* value.
##
DEFAULT_AEMODE="balanced"
DEFAULT_AEHASH="layer2"
MGMT_AEMODE="802.3ad"
MGMT_AEHASH="layer3+4"


## Test creating and apply profiles on nodes
##
TEST_PROFILES="yes"

## Maximum number of networks physically possible in this lab
##
MAXNETWORKS=1

## If the Ixia port has less MAX throughput than the NIC under test, we
## use more than 1 Ixia port to achieve the desired line rate. This variable
## specifies port pairs to acheive the desired line rate.
IXIA_PORT_PAIRS=1

## Maximum number of VLANs per internal network
##
MAXVLANS=1
FIRSTVLANID=0

##If Compute nodes a virtual and controller is hardware [yes/no]
VIRTUALNODES="no"

## Controls the number of VM instances that share the tenant data networks that
## go to ixia.  This exists to allow more VM instances in labs without having
## to increase the number of VLAN instances allocated to the lab.  This only
## works for NETWORKING_TYPE=layer3.
##
VMS_PER_NETWORK=1

## Enable/disable VIRTIO multi-queue support
VIRTIO_MULTIQUEUE="false"

## Custom Flavors to create
## type or a string with parameters, e.g.
##   FLAVORS="<name>|id=1000,cores=1|mem=512|disk=2|dedicated|heartbeat|numa_node.0=0|numa_node.1=0|numa_nodes=2|vcpumodel=SandyBridge|sharedcpus"
##    - <name> is required
##    - id - number
##    - cores 1-N
##    - mem in MB,
##    - disk in GB (volume size), use
##    - dedicated - dedicated if in list used, otherwise not
##    - heartbeat - heartbeat if in list, otherwise not
##    - numa_node.0 - Pin guest numa node 0 to a physical numa node.  Default not pinned
##    - numa_node.1 - Pin guest numa node 1 to a physical numa node.  Default not pinned
##    - numa_nodes - Expose guest to specified number of numa cores (spread across zones)
##    - storage - Nova storage host: local_lvm (default), local_image, remote
##    - vcpumodel - default Sandy Bridge
##    - sharedcpus - default disabled
## If multiple flavors, append them with space between:
##    FLAVORS="flavor1|cores=1|mem=512|disk=2 flavor2|cores=2|mem=1024,disk=4"
## Default values
FLAVORS=""

## Number of VMs to create.  This can be simply a number for each interface
## type or a string with parameters, e.g.
##   AVPAVPAPPS="2|flavor=small|disk=2|image=tis-centos-guest|dbench|glance|voldelay|volwait"
##    - Interface type is defined by the name (AVPAPPS, VIRTIOAPPS, DPDKAPPS, SRIOVAPPS, or PCIPTAPPS)
##    - Only the first parameter is (# of VM pairs) required. Absence means use default
##    - First number is number of pairs to create
##    - flavor - base flavor name to use for defaults, default is default flavor for the app type
##    - disk in GB (volume size), use
##    - image is base image file name - Image type raw and filename extension .img is assumed
##    - imageqcow2 is base qcow2 image file name.  Image type qcow2 and filename extension qcow2 is assumed.
##    - cache_raw - do background caching of qcow2 image to raw
##    - glance - use glance (default is IMAGE_TYPE) Note:  use voldelay with this to prevent volume creation
##    - dbench - enable dbench in VM, default is disabled
##    - nopoll - Don't poll in boot line for VM.  Allows faster booting of VMs
##    - voldelay - Delay creating volume until VM boot if present, otherwise create volume initially (N/A if using glance)
##    - volwait - If using voldelay, will wait for volume creation in volume launch, otherwise no wait (N/A if using glance)
## AVPAPPS=2 would remain legal (all defaults)
## If multiple AVP flavors of same type, append them with space between:
##    AVPAPPS="2|flavor=small|disk=2 4|flavor=large|disk=4"
## Default values
DPDKAPPS=0
AVPAPPS=0
VIRTIOAPPS=0
SRIOVAPPS=0
PCIPTAPPS=0
VHOSTAPPS=0

## Default flavors (if you change any of these make sure that
## setup_minimal_flavors creates the required flavors otherwise set
## FLAVOR_TYPES="all"
##
DPDKFLAVOR="medium.dpdk"
AVPFLAVOR="small"
VIRTIOFLAVOR="small"
SRIOVFLAVOR="small"
PCIPTFLAVOR="small"
VHOSTFLAVOR="medium.dpdk"

## Set to "all" if you want additional flavors created; otherwise only the
## ones in DPDKFLAVOR, AVPFLAVOR, VIRTIOFLAVOR, SRIOVFLAVOR, and PCIPTFLAVOR will be created
FLAVOR_TYPES="minimal"

## Network QoS values
EXTERNALQOS="external-qos"
INTERNALQOS="internal-qos"
EXTERNALQOSWEIGHT=16
INTERNALQOSWEIGHT=4
MGMTQOSWEIGHT=8

## Nova Local Storage Settings
##
## LOCAL_STORAGE="setting"
##          Default settings used to control local storage provisioning
##
## Format of default_setting or host_setting is:
##    mode|pvs|lv_calc_mode|lv_fixed size
##
## Parameters:
##    mode           - Determines the instance disk storage source/format of the
##                     node:
##
##       local_lvm   - nova-local volume group is created and physical volumes are
##                     added. The instances logical volume is created and
##                     mounted at /etc/nova/instances. The instances logical
##                     volume uses a subset of the available space within the
##                     volume group. Instance disks are logical volumes created
##                     out of the available space in the nova-local volume group
##       local_image - nova-local volume group is created and physical volumes
##                     are added. The instances logical volume is created and
##                     mounted at /etc/nova/instances. The instances logical is
##                     sized to use 100% of the volume group. Instance disks are
##                     file based CoW images contained within
##                     /etc/nova/instances.
##       remote      - nova-local volume group is created and physical volumes are
##                     added. The instances logical volume is created and
##                     mounted at /etc/nova/instances. The instances logical is
##                     sized to use 100% of the volume group. Instance disks are
##                     RBD based from the ceph ephemeral pool.
##
##
##    pvs           - Disk or partition device node names to add to the nova local
##                    volume group.
##
##                    <string> - comma separated device list: /dev/sdc,/dev/sdd
##
##
##    lv_calc_mode  - Mode for calculating the size of the instance logical
##                    volume
##
##                    fixed - size provided by lv_fixed_size
##
##
##    lv_fixed_size - size in gib (i.e 10GB). Only relevant for
##                     local_lvm mode. Ignored for remote or local_image modes
##
##  All 5 parameters must be specified.
##
##  Examples:
##   nova-local uses disk partition, instances backed by remote storage
##        LOCAL_STORAGE="remote|/dev/disk/by-path/pci-0000:00:0d.0-ata-1.0-part6|fixed|0"
##
##   nova-local on /dev/disk/by-path/pci-0000:00:0d.0-ata-2.0 instances backed by remote storage
##        LOCAL_STORAGE="remote|/dev/disk/by-path/pci-0000:00:0d.0-ata-2.0|fixed|0"
##
##   nova-local uses disk partition, instances backed by local CoW image files
##        LOCAL_STORAGE="local_image|/dev/disk/by-path/pci-0000:00:0d.0-ata-1.0-part6|fixed|0"
##
##   nova-local uses disk partition, instances backed by local LVM disks
##        LOCAL_STORAGE="local_lvm|/dev/disk/by-path/pci-0000:00:0d.0-ata-1.0-part6|fixed|2"
##
##   nova-local uses multiple disks, instances backed by local CoW image files
##        LOCAL_STORAGE="local_image|/dev/disk/by-path/pci-0000:00:0d.0-ata-2.0,/dev/disk/by-path/pci-0000:00:0d.0-ata-3.0|fixed|0"
##
##   nova-local uses disk and partition, instances backed by local LVM disks
##        LOCAL_STORAGE="local_lvm|/dev/disk/by-path/pci-0000:00:0d.0-ata-2.0,/dev/disk/by-path/pci-0000:00:0d.0-ata-3.0-part4|fixed|2"
##
LOCAL_STORAGE="local_image|fixed|10"
#CONTROLLER0_LOCAL_STORAGE="local_lvm|/dev/sdc|fixed|10"

## Neutron MAC address overrides
NEUTRON_BASE_MAC=""
NEUTRON_DVR_BASE_MAC=""
NEUTRON_EXTENSION_DRIVERS=""
NEUTRON_PORT_SECURITY=""

## BGP Default Configuration
BGP_ENABLED="no"
BGP_SERVICE_PLUGINS=

## Software Defined Networking (SDN) Default Configuration
SDN_ENABLED=${sdn_enabled:-no}
SDN_NETWORKING="opendaylight"

## SDN OpenDaylight Specific Configuration
SDN_ODL_MECHANISM_DRIVERS="vswitch,opendaylight_v2,sriovnicswitch,l2population"
SDN_ODL_SERVICE_PLUGINS="odl-router_v2"
SDN_ODL_USERNAME=admin
SDN_ODL_PASSWORD=admin
SDN_ODL_PORT_BINDING_CONTROLLER=legacy-port-binding

## SFC Specific Configurations
## (note: these are on by default in the system configuration but exist here so
## that they can be modified when enabling SDN with SFC)
SFC_ENABLED="no"
SFC_SERVICE_PLUGINS="flow_classifier,sfc"
SFC_SFC_DRIVERS="avs"
SFC_FLOW_CLASSIFIER_DRIVERS="avs"


## Timeout to wait for system service-parameter-apply to complete
SERVICE_APPLY_TIMEOUT=30

## PCI vendor/device IDs
PCI_VENDOR_VIRTIO="0x1af4"
PCI_DEVICE_VIRTIO="0x1000"
PCI_DEVICE_MEMORY="0x1110"
PCI_SUBDEVICE_NET="0x0001"
PCI_SUBDEVICE_AVP="0x1104"


if [ ! -f ${CONFIG_FILE} ]; then
    ## If the main config file does not exist then check to see if the group0
    ## file exists
    if [ -f ${GROUP0_FILE} ]; then
        CONFIG_FILE=${GROUP0_FILE}
    fi
fi

if [ ! -f ${CONFIG_FILE} ]; then
    ## User must provide lab specific details
    echo "Missing config file: ${CONFIG_FILE} or ${GROUP0_FILE}"
    exit 1
fi

trim()
{
    local trimmed="$1"

    # Strip leading space.
    trimmed="${trimmed## }"
    # Strip trailing space.
    trimmed="${trimmed%% }"

    echo "$trimmed"
}

# Reset chain by clearing the chain config file
if  [ "${CLEAR_CHAIN}" == "yes" ]; then
    rm -f ${CONFIG_CHAIN_FILE}
fi

# Chain multiple config files and source them.
# Each time we call the script with a different config file
# that file is added to the chain and will be sourced in the
# same order as they were added.
# Subsequent call to the script don't need to include the
# config file as a parameter as it's already in the chain
if [ ! -f ${CONFIG_CHAIN_FILE} ]; then
    touch ${CONFIG_CHAIN_FILE}
    echo $CONFIG_FILE > ${CONFIG_CHAIN_FILE}
else
    readarray CHAIN_CONF < ${CONFIG_CHAIN_FILE}
    ADDED=0
    for cfg_file in "${CHAIN_CONF[@]}"; do
        trim_conf="$(trim $cfg_file)"
        if [ "${trim_conf}" == "${CONFIG_FILE}" ] ; then
            ADDED=1
            break
        fi
    done

    if [ $ADDED -eq 0 ]; then
        echo $CONFIG_FILE >> $CONFIG_CHAIN_FILE
    fi
fi

## *** WARNING ***
##
## Source the per-lab configuration settings.  Do not place any user
## overrideable variables below this line.
##
## Support for chaining config files:
## The script now supports adding additional settings from extra
## config files and chaining such configurations.
## Example:
## ./lab_setup.sh
## ./lab_setup.sh -f add_lvm.conf
## ./lab_setup.sh -f add_ceph.conf
## ./lab_setup.sh
##
## Behavior:
## - first call will add the default lab_setup.conf file to the chain
##   and source it
## - the second call will add add_lvm.conf to the chain and source
##   lab_setup.conf and add_lvm.conf (in this order)
## - the second call will add add_ceph.conf to the chain and source
##   lab_setup.conf, add_lvm.conf and add_ceph.conf (in this order)
## - the last call will not add anything new to the chain, but will
##   source all other config files anyway in the chain.
##
## Purpose of this change is to allow adding features or config
## options to a setup, no by changing the existing config file,
## but by adding a new config file with just the new features and
## run lab_setup again.
## Thus we can have a setup without any cinder backend, run tests
## on it, then easily add LVM and/or ceph on it and run the same
## (or other tests).
##
## *** WARNING ***

readarray CHAIN_CONF < ${CONFIG_CHAIN_FILE}

for cfg_file in "${CHAIN_CONF[@]}"; do
    trim_conf="$(trim $cfg_file)"
    echo "Sourcing ${trim_conf} from the config chain"
    set +u
    source ${cfg_file}
    set -u
done

rm -f ${STATUS_FILE}

## Set a per-group status file
GROUP_STATUS=${STATUS_FILE}.group${GROUPNO}
LOG_FILE=${LOG_FILE:-"${HOME}/lab_setup.group${GROUPNO}.log"}

## Overwrite storage backend user settings based on Cinder & Glance configured backends
##
if [[ ${CINDER_BACKENDS} =~ "lvm" ]]; then
    CONFIGURE_STORAGE_LVM="yes"
fi

if [[ ${CINDER_BACKENDS} =~ "ceph" ]]; then
    CONFIGURE_STORAGE_CEPH="yes"
fi

if [[ ${GLANCE_BACKENDS} =~ "ceph" ]]; then
    CONFIGURE_STORAGE_CEPH="yes"
fi


## Variables which can be affected by user overrides
##
TENANTNODES=("${TENANT1NODE}" "${TENANT2NODE}")
TENANTS=("${TENANT1}" "${TENANT2}")
PROVIDERNET0="group${GROUPNO}-data0"
PROVIDERNET1="group${GROUPNO}-data1"
EXTERNALNET="external-net${GROUPNO}"
EXTERNALSUBNET="external-subnet${GROUPNO}"
INTERNALNET="internal${GROUPNO}-net"
INTERNALSUBNET="internal${GROUPNO}-subnet"

DEFAULT_BOOTDIR=${HOME}/instances
BOOTDIR=${HOME}/instances_group${GROUPNO}
BOOTCMDS=${BOOTDIR}/launch_instances.sh
HEATSCRIPT=${BOOTDIR}/heat_instances.sh

## All combined application types
ALLAPPS="${DPDKAPPS} ${AVPAPPS} ${VIRTIOAPPS} ${SRIOVAPPS} ${PCIPTAPPS} ${VHOSTAPPS}"

## Total counts after user overrides
##
APPCOUNT=0
APPS=($ALLAPPS)
for INDEX in ${!APPS[@]}; do
    ENTRY=${APPS[${INDEX}]}
    DATA=(${ENTRY//|/ })
    NUMVMS=${DATA[0]}
    APPCOUNT=$((${APPCOUNT} + ${NUMVMS}))
done

NETCOUNT=$((${APPCOUNT} / ${VMS_PER_NETWORK}))
REMAINDER=$((${APPCOUNT} % ${VMS_PER_NETWORK}))
if [ ${REMAINDER} -ne 0 ]; then
    NETCOUNT=$((NETCOUNT+1))
fi

if [ ${NETCOUNT} -gt ${MAXNETWORKS} ]; then
    echo "Insufficient number of networks for all requested apps"
    exit 1
fi

if [ ${VMS_PER_NETWORK} -ne 1 -a ${NETWORKING_TYPE} != "layer3" ]; then
    echo "VMS_PER_NETWORK must be 1 if NETWORKING_TYPE is not \"layer3\""
    exit 1
fi

## Tenant Quotas
##    network: each tenant has a network per VM plus a mgmt network
##    subnet: each tenant has a subnet per network plus additional mgmt subnets
##    port: each tenant has 3 ports per VM, 2 ports per network (DHCP/L3),
##          1 floating-ip per VM, 1 gateway per router, plus additional manual ports
##    volume/snapshot - 2x instances to allow volume for launch script volume and heat volume
##
NETWORK_QUOTA=${NETWORK_QUOTA:-$((NETCOUNT + (2 * ${MGMTNETS})))}
SUBNET_QUOTA=${SUBNET_QUOTA:-$((NETWORK_QUOTA + 10))}
PORT_QUOTA=${PORT_QUOTA:-$(((APPCOUNT * 3) + (${NETCOUNT} * 2) + ${APPCOUNT} + 1 + 32))}
INSTANCE_QUOTA=${INSTANCE_QUOTA:-${APPCOUNT}}
CORE_QUOTA=${CORE_QUOTA:-$((INSTANCE_QUOTA * 3))}
FLOATING_IP_QUOTA=${FLOATING_IP_QUOTA:-${APPCOUNT}}
VOLUME_QUOTA=${VOLUME_QUOTA:-$((APPCOUNT * 2))}
SNAPSHOT_QUOTA=${SNAPSHOT_QUOTA:-$((APPCOUNT * 2))}

## Admin Quotas
##     network:  the admin has 1 external network, and all shared internal networks
##     subnet: the admin has 1 for the external network, and 1 subnet per pair of VM
##     port: the admin has 1 port on the external network for DHCP (if needed)
##
SHARED_NETCOUNT=${NETCOUNT}
ADMIN_NETWORK_QUOTA=${ADMIN_NETWORK_QUOTA:-$((SHARED_NETCOUNT + 2))}
ADMIN_SUBNET_QUOTA=${ADMIN_SUBNET_QUOTA:-$((NETCOUNT + 2))}
ADMIN_PORT_QUOTA=${ADMIN_PORT_QUOTA:-"10"}

## Two VMs per application pairs
VMCOUNT=$((APPCOUNT * 2))

## Prune the list of controller nodes down to the ones that are locked-online
TMP_CONTROLLER_NODES=${CONTROLLER_NODES}
CONTROLLER_NODES=""
if [ ${GROUPNO} -eq 0 ]; then
    for NODE in ${TMP_CONTROLLER_NODES}; do
        HOSTNAME=$(system host-list ${CLI_NOWRAP} | grep ${NODE} | awk '{if (($8 == "locked") && ($12 == "online")) {print $4;}}')
        if [ -n "${HOSTNAME}" ]; then
            CONTROLLER_NODES="${HOSTNAME} ${CONTROLLER_NODES}"
        fi
    done
fi

AVAIL_CONTROLLER_NODES=""
if [ ${GROUPNO} -eq 0 ]; then
    for NODE in ${TMP_CONTROLLER_NODES}; do
        HOSTNAME=$(system host-list ${CLI_NOWRAP} | grep ${NODE} | awk '{if (($8 == "unlocked") && ($12 == "available")) {print $4;}}')
        if [ -n "${HOSTNAME}" ]; then
            AVAIL_CONTROLLER_NODES="${HOSTNAME} ${AVAIL_CONTROLLER_NODES}"
        fi
    done
fi

## Prune the list of storage nodes down to the ones that are locked-online
TMP_STORAGE_NODES="${STORAGE_NODES} ${EXTRA_STORAGE_NODES}"
STORAGE_NODES=""
if [ ${GROUPNO} -eq 0 -o -n "${EXTRA_STORAGE_NODES}" ]; then
    for NODE in ${TMP_STORAGE_NODES}; do
        HOSTNAME=$(system host-list ${CLI_NOWRAP} | grep ${NODE} | awk '{if (($8 == "locked") && ($12 == "online")) {print $4;}}')
        if [ -n "${HOSTNAME}" ]; then
            STORAGE_NODES="${HOSTNAME} ${STORAGE_NODES}"
        fi
    done
fi

## Global data to help facilitate constants that vary by VM type.  These must
## all map one-to-one with the values in APPTYPES
##
APPTYPES=("PCIPT" "SRIOV" "DPDK" "AVP" "VIRTIO" "VHOST")
VMTYPES=("pcipt" "sriov" "vswitch" "avp" "virtio" "vhost")
NETTYPES=("kernel" "kernel" "vswitch" "kernel" "kernel" "vswitch")
NIC1_VIF_MODELS=("avp" "avp" "avp" "avp" "virtio" "virtio")
NIC2_VIF_MODELS=("pci-passthrough" "pci-sriov" "avp" "avp" "virtio" "virtio")


function get_node_list {
    ## Build the list of required node numbers using both the old and new way
    ## of specifying the worker id list for backwards compatibility
    REQUIRED=""
    if [ ! -z "${FIRSTWORKERID}" -a ! -z "${LASTWORKERID}" ]; then
        REQUIRED=$(seq ${FIRSTWORKERID} ${LASTWORKERID})
    fi
    REQUIRED="${REQUIRED} ${WORKERIDS//,/ }"

    ## Get the list of actual node names
    HOSTS=$(system host-list ${CLI_NOWRAP} | awk '{if ($6 == "worker") print $4}')

    ## Build the list of required node names that are present
    RESULT=""
    for ID in ${REQUIRED}; do
        if [[ "${HOSTS} " == *worker-${ID}[^0-9]* ]]; then
            RESULT="worker-${ID} ${RESULT}"
        fi
    done

    echo $RESULT
}

## Requery the worker node names if the config file specified first and last worker id
if [ ! -z "${FIRSTWORKERID}" -a ! -z "${LASTWORKERID}" -o ! -z "${WORKERIDS}" ]; then
    NODES=$(get_node_list)
fi

DATE_FORMAT="%Y-%m-%d %T"

## Executes a command and logs the output
function log_command {
    local CMD=$1
    local MSG="[${OS_USERNAME}@${OS_PROJECT_NAME}]> RUNNING: ${CMD}"

    set +e
    if [ ${VERBOSE_LEVEL} -gt 0 ]; then
        echo ${MSG}
    fi
    echo $(date +"${DATE_FORMAT}") ${MSG} >> ${LOG_FILE}

    if [ ${VERBOSE_LEVEL} -gt 1 ]; then
        eval ${CMD} 2>&1 | tee -a ${LOG_FILE}
        RET=${PIPESTATUS[0]}
    else
        eval ${CMD} &>> ${LOG_FILE}
        RET=$?
    fi

    if [ ${RET} -ne 0 ]; then
        info "COMMAND FAILED (rc=${RET}): ${CMD}"
        info "==========================="
        info "Check \"${LOG_FILE}\" for more details, and re-run the failed"
        info "command manually before contacting the domain owner for assistance."
        exit 1
    fi
    set -e

    return ${RET}
}

## Log a message to screen if verbose enabled
function log {
    local MSG="$1"

    if [ ${VERBOSE_LEVEL} -gt 1 ]; then
        echo ${MSG}
    fi
    echo $(date +"${DATE_FORMAT}") ${MSG} >> ${LOG_FILE}
}

## Log a message to screen if debug enabled
function debug {
    local MSG="$1"

    if [ ${DEBUG_LEVEL} -ge 1 ]; then
        echo ${MSG}
    fi
    echo $(date +"${DATE_FORMAT}") ${MSG} >> ${LOG_FILE}
}

## Log a message to screen and file
function info {
    local MSG="$1"

    echo ${MSG}
    echo $(date +"${DATE_FORMAT}") ${MSG} >> ${LOG_FILE}
}

## Log a message to file and stdout
function log_warning {
    local MSG="WARNING: $1"

    echo ${MSG}
    echo $(date +"${DATE_FORMAT}") ${MSG} >> ${LOG_FILE}
}


function wait_for_service_parameters {
    info "Waiting for controller-0 configuration apply"

    DELAY=0
    sleep 10
    while [ $DELAY -lt ${SERVICE_APPLY_TIMEOUT} ]; do
        STATUS=$(get_host_config_status "controller-0")
        if [ "${STATUS}" == "None" ]; then
            # Wait an additional amount to allow the neutron-server to restart
            # and be able to accept API requests.
            sleep 45
            break
        fi
        DELAY=$((DELAY + 5))
        sleep 5
    done
}

## Retrieve the status for a host configuration
function get_host_config_status {
    local NAME=$1
    echo $(system host-show ${NAME} 2>/dev/null | awk 'BEGIN { FS="|" } { if ($2 ~ /config_status/) {print $3} }'|xargs echo)
}


## Retrieve the interface profile uuid for a profile name
function get_ifprofile_id {
    local NAME=$1
    echo $(system ifprofile-list ${CLI_NOWRAP} | grep -E "[0-9a-z]{8}-" | grep -E "${NAME}[^-_0-9a-zA-Z]" | awk '{print $2}')
}

## Retrieve the CPU profile uuid for a profile name
function get_cpuprofile_id {
    local NAME=$1
    echo $(system cpuprofile-list ${CLI_NOWRAP} | grep -E "[0-9a-z]{8}-" | grep -E "${NAME}[^-_0-9a-zA-Z]" | awk '{print $2}')
}

## Retrieve the storage profile uuid for a profile name
function get_storprofile_id {
    local NAME=$1
    echo $(system storprofile-list ${CLI_NOWRAP} | grep -E "[0-9a-z]{8}-" | grep -E "${NAME}[^-_0-9a-zA-Z]" | awk '{print $2}')
}

## Retrieve the address pool uuid for a pool name
function get_addrpool_id {
    local NAME=$1
    echo $(system addrpool-list ${CLI_NOWRAP} | grep -E -- "${NAME}" | awk '{print $2}')
}

## Retrieve the image id for a volume name
function get_cinder_id {
    local NAME=$1
    echo $(cinder ${REGION_OPTION} show ${NAME} 2>/dev/null | awk '{ if ($2 == "id") {print $4} }')
}

## Retrieve the status for a volume name
function get_cinder_status {
    local NAME=$1
    echo $(cinder ${REGION_OPTION} show ${NAME} 2>/dev/null | awk '{ if ($2 == "status") {print $4} }')
}

## Retrieve the router id for a router name
function get_router_id {
    local NAME=$1
    echo $(openstack ${REGION_OPTION} router show ${NAME} -c id -f value 2>/dev/null)
}

## Retrieve the tenant id for a tenant name
function get_tenant_id {
    local NAME=$1
    echo $(openstack project show ${NAME} -c id 2>/dev/null | grep id | awk '{print $4}')
}

## Retrieve the user id for a user name
function get_user_id {
    local NAME=$1
    echo $(openstack user show ${NAME} -c id 2>/dev/null | grep id | awk '{print $4}')
}

## Retrieve the user roles for a tenant and user
function get_user_roles {
    local TENANT=$1
    local USERNAME=$2
    echo $(openstack role list --project ${TENANT} --user ${USERNAME} 2>/dev/null | grep ${USERNAME} | awk '{print $4}')
}

## Build the network name for a given network instance.  For backwards
## compatibility with existing testcases the first network instance has no
## number in its' name.
function get_mgmt_network_name {
    local PREFIX=$1
    local NUMBER=$2

    local NAME=${PREFIX}
    if [ ${NUMBER} -ne 0 ]; then
        NAME=${NAME}${NUMBER}
    fi

    echo ${NAME}
    return 0
}

## Retrieve the network id for a network name
function get_network_id {
    local NAME=$1
    echo $(openstack ${REGION_OPTION} network show ${NAME} -c id -f value 2>/dev/null)
}

## Retrieve the network MTU for a network id
function get_network_mtu {
    local ID=$1
    echo $(openstack ${REGION_OPTION} network show ${ID} -c mtu -f value 2>/dev/null)
}

## Get the fixed ip on the tenant network
function get_network_ip_address {
    local NETNUMBER=$1
    local HOSTNUMBER=$2
    local TENANTNUM=$3
    ## tenant1 gets VM addresses:   172.16.*.1, 172.16.*.3, 172.16.*.5
    ## tenant1 gets Ixia addresses: 172.16.*.2, 172.16.*.4, 172.16.*.6
    ## tenant2 gets VM addresses:   172.18.*.1, 172.18.*.3, 172.18.*.5
    ## tenant2 gets Ixia addresses: 172.18.*.2, 172.18.*.4, 172.18.*.6
    echo "172.$((16 + ${TENANTNUM} * 2)).${NETNUMBER}.$((1 + (${HOSTNUMBER} * 2)))"
}

## construct the nova boot arg for a fixed ip on the tenant network
function get_network_ip {
    if [ "x${ROUTED_TENANT_NETWORKS}" == "xyes" ]; then
        ## Doesn't matter since the VM will be bridging traffic and not routing
        echo ""
    else
        echo ",v4-fixed-ip=$(get_network_ip_address $1 $2 $3)"
    fi
}

## Retrieve the subnet id for a subnet name
function get_subnet_id {
    local NAME=$1
    echo $(openstack ${REGION_OPTION} subnet show ${NAME} -c id -f value 2>/dev/null)
}

## Retrieve the providernet id for a providernet name
function get_provider_network_id {
    local NAME=$1
    echo $(openstack ${REGION_OPTION} providernet show ${NAME} -c id -f value 2>/dev/null)
}

## Retrieve the datanetwork uuid for a datanetwork name
function get_data_network_uuid {
    local NAME=$1
    echo $(system datanetwork-list | grep "${NAME}" | awk '{print $2}')
}

## Retrieve the providernet id for a providernet name
function get_provider_network_range_id {
    local NAME=$1
    echo $(openstack ${REGION_OPTION} providernet range show ${NAME} -c id -f value 2>/dev/null)
}

## Retrieve the qos id for a qos name
function get_qos_id {
    local NAME=$1
    echo $(openstack ${REGION_OPTION} qos show ${NAME} -c id -f value 2>/dev/null)
}

## Retrieve the flavor id for a flavor name
function get_flavor_id {
    local NAME=$1
    echo $(nova ${REGION_OPTION} flavor-show ${NAME} 2>/dev/null | grep "| id" | awk '{print $4}')
}

## Retrieve a specific neutron quota value for a tenant
function get_neutron_quota {
    local TENANTID=$1
    local QUOTA=$2

    echo $(openstack ${REGION_OPTION} quota show ${TENANTID} -c ${QUOTA} -f value 2>/dev/null)
}

## Retrieve the hosts ip address of managment network
function get_mgmt_ip {
    local ID=$1
    echo $(system host-show ${ID} 2>/dev/null | grep "mgmt_ip" | awk '{print $4}')
}

## Retrieve the numa node flavor modifier for a given tenant
function get_flavor_modifier {
    local TENANTNUM=$1
    local VMCOUNTER=$2

    if [ "${TENANTNUM}" -gt ${#TENANTNODES[@]} ]; then
        echo ""
    elif [ "${TENANTNODES[${TENANTNUM}]}" == "split" ]; then
        local NODE=$(($((VMCOUNTER-1)) % ${NUMA_NODE_COUNT}))
        echo "node${NODE}"
    elif [ ! -z "${TENANTNODES[${TENANTNUM}]}" ]; then
        echo "${TENANTNODES[${TENANTNUM}]}"
    else
        echo ""
    fi

    return 0
}

## Retrieve the network id of the network to be used between two tenant VM
## instances.  If SHARED_TENANT_NETWORKS is set to "yes" then it is assumed
## that only a single VM is running and instead of using one of the actual
## internal networks the VM should use the other VM's tenant network to return
## traffic to ixia.
#
function get_internal_network_id {
    local TENANTNUM=$1
    local NETNUMBER=$2
    local OTHER_TENANTNET="${TENANTS[$((1 - ${TENANTNUM}))]}-net"
    local NET=0

    if [ "x${SHARED_TENANT_NETWORKS}" == "xyes" ]; then
        INTERNALNETID=$(get_network_id ${OTHER_TENANTNET}${NETNUMBER})
    else
        if [ "x${REUSE_NETWORKS}" != "xyes" ]; then
            NET=$((NETNUMBER / ${MAXVLANS}))
        fi
        INTERNALNETID=$(get_network_id ${INTERNALNET}${NET})
    fi

    echo ${INTERNALNETID}
    return 0
}

function get_internal_network_name {
    local TENANTNUM=$1
    local NETNUMBER=$2
    local OTHER_TENANTNET="${TENANTS[$((1 - ${TENANTNUM}))]}-net"
    local NET=0

    if [ "x${SHARED_TENANT_NETWORKS}" == "xyes" ]; then
        echo ${OTHER_TENANTNET}${NETNUMBER}
    else
        if [ "x${REUSE_NETWORKS}" != "xyes" ]; then
            NET=$((NETNUMBER / ${MAXVLANS}))
        fi
        echo ${INTERNALNET}${NET}
    fi

    return 0
}

## Retrieve the speaker id for a speaker name
function get_bgp_speaker_id {
    local NAME=$1
    echo $(neutron bgp-speaker-show ${NAME} -F id 2>/dev/null | grep id | awk '{print $4}')
}

## Retrieve the peer id for a peer name
function get_bgp_peer_id {
    local NAME=$1
    echo $(neutron bgp-peer-show ${NAME} -F id 2>/dev/null | grep id | awk '{print $4}')
}

## Retrieve the bgpvpn id for a bgpvpn name
function get_bgp_vpn_id {
    local NAME=$1
    echo $(neutron bgpvpn-show ${NAME} -F id 2>/dev/null | grep id | awk '{print $4}')
}

## Retrieve the value of a prefixed variable name.  If a variable named
## ${PREFIX}_${NAME} does not exist then a variable with DEFAULT_${NAME} is
## used.
##
function get_variable {
    local PREFIX=$1
    local NAME=$2

    ## No specific AEMODE for this interface, try the type-specific value
    local VARNAME=${PREFIX^^}_${NAME^^}
    if [ -z ${!VARNAME+x} ]; then
        ## No type-specific value, use the global default
        VARNAME=DEFAULT_${NAME^^}
        if [ -z ${!VARNAME+x} ]; then
            echo "Missing variable ${VARNAME}"
            exit 2
        fi
        VALUE=${!VARNAME}
    else
        VALUE=${!VARNAME}
    fi

    echo $VALUE
}


## Retrieve the value of a worker node overridden variable.  First the
## variable ${WORKER0_VARNAME} is checked and if no variable exists then
## ${VARNAME} is returned.  If ${VARNAME} also does not exist then an empty
## value is returned.
##
function get_node_variable {
    local NODE=${1/-/}
    local VARNAME=${NODE^^}_$2

    if [ -z "${!VARNAME+x}" ]; then
        # There is no node specific variable available use the default
        VARNAME=$2
    fi

    if [ -z "${!VARNAME+x}" ]; then
        # There is no variable with the requested name so return an empty
        # string
        echo ""
    else
        # Dereference the variable name and echo its' contents
        echo ${!VARNAME}
    fi

    return 0
}

## Generates the neutron provider args for an internal network
function get_internal_provider_network {
    DATA=(${INTERNALPNET//|/ })
    local PNET_TYPE=${DATA[0]}
    local PNET_NAME=group${GROUPNO}-${DATA[1]}
    if [ ${PNET_TYPE} == 'vxlan' ]; then
        echo "--provider-network-type=${PNET_TYPE}"
    else
        echo "--provider-network-type=${PNET_TYPE} --provider-physical-network=${PNET_NAME}"
    fi
}

## Generates the neutron provider args for the external network
function get_external_provider_network {
    DATA=(${EXTERNALPNET//|/ })
    local PNET_TYPE=${DATA[0]}
    local PNET_NAME=group${GROUPNO}-${DATA[1]}
    local SEGMENT_ID=${DATA[2]}
    local PNET_ARGS="--provider-network-type=${PNET_TYPE} --provider-physical-network=${PNET_NAME}"

    if [ ${PNET_TYPE} == 'vxlan' ]; then
        PNET_ARGS="--provider-network-type=${PNET_TYPE}"
    fi
    if [ ${SEGMENT_ID} != 'none' ]; then
        PNET_ARGS="${PNET_ARGS} --provider-segment=${SEGMENT_ID}"
    fi

    echo ${PNET_ARGS}
}


## Generates the list of provider networks for data interface
function get_provider_networks {
    local NODE=$1
    local IFACE=$2

    if [ ${PROVIDERNET_TYPE} != "mixed" ]; then
        if [ ${IFACE} == "data0" ]; then
            echo ${PROVIDERNET0}
        elif [ ${IFACE} == "data1" ]; then
            echo ${PROVIDERNET1}
        else
            echo "error"
        fi
    else
        if [ ${IFACE} == "data0" ]; then
            echo "${PROVIDERNET0},${PROVIDERNET0}-vxlan"
        elif [ ${IFACE} == "data1" ]; then
            echo ${PROVIDERNET1}
        else
            echo "error"
        fi
    fi
}


## Rudimentary check to determine if an address is IPv4
##
function is_ipv4 {
    local VALUE=$1

    [[ ${VALUE} =~ ^[0-9]{1,3}.[0-9]{1,3}.[0-9]{1,3}.[0-9]{1,3}$ ]]
    if [ $? -eq 0 ]; then
        return 1
    else
        return 0
    fi
}

## Query the "ipv4-mode" attribute of an interface
##
function get_interface_ipv4_mode {
    local NODE=$1
    local IFACE=$2
    local MODE=""

    echo $(system host-if-show ${NODE} ${IFNAME} | grep "ipv4_mode" | awk '{ print $4 }')
    return 0
}

## Query the "ipv6-mode" attribute of an interface
##
function get_interface_ipv6_mode {
    local NODE=$1
    local IFACE=$2
    local MODE=""

    echo $(system host-if-show ${NODE} ${IFNAME} | grep "ipv6_mode" | awk '{ print $4 }')
    return 0
}

# Retrieve the port name by PCI address and device
function get_port_name {
    local NODE=$1
    local PCIADDR=$2
    local PCIDEV=$3

    PCIMATCH="${PCIADDR} | ${PCIDEV}"
    echo $(system host-port-list ${NODE} ${CLI_NOWRAP} | grep "${PCIMATCH}" | awk '{print $4}')
}

## Retrieve the interface uuid that is associated to the port specified by the
## PCI address and device provided.
##
function get_interface_uuid {
    local NODE=$1
    local PCIADDR=$2
    local PCIDEV=$3

    PCIMATCH="${PCIADDR} | ${PCIDEV}"
    DATA=$(system host-port-list ${NODE} ${CLI_NOWRAP} | grep "${PCIMATCH}" | awk '{printf "%s %s", $2, $4}')
    DATA=(${DATA//=/ })
    NAME=${DATA[1]}
    UUID=${DATA[0]}

    ID=`system host-if-list -a ${NODE} ${CLI_NOWRAP} | awk -v PORT=[u\'${NAME}\'] '($12 == PORT) {print $2}'`
    echo ${ID}
}

## Derive the guest NIC device type based on the VM type
function get_guest_nic_device {
    local VMTYPE=$1

    if [ "$VMTYPE" == "vswitch" ]; then
        NIC_DEVICE="${PCI_VENDOR_VIRTIO}:${PCI_DEVICE_MEMORY}:${PCI_SUBDEVICE_AVP}"
    elif [ "$VMTYPE" == "vhost" ]; then
        NIC_DEVICE="${PCI_VENDOR_VIRTIO}:${PCI_DEVICE_VIRTIO}:${PCI_SUBDEVICE_NET}"
    else
        NIC_DEVICE=""
    fi

    echo "${NIC_DEVICE}"
    return 0;
}

## Determine whether one of the setup stages has already completed
function is_stage_complete {
    local STAGE=$1
    local NODE=${2:-""}
    local FILE=""

    if [ "${FORCE}" == "no" ]; then
        if [ -z "${NODE}" ]; then
            FILE=${GROUP_STATUS}.${STAGE}
        else
            FILE=${GROUP_STATUS}.${NODE}.${STAGE}
        fi
        if [ -f ${FILE} ]; then
            return 0
        fi
    fi

    return 1
}

## Mark a stage as complete
function stage_complete {
    local STAGE=$1
    local NODE=${2:-""}
    local FILE=""

    if [ -z "${NODE}" ]; then
        FILE=${GROUP_STATUS}.${STAGE}
    else
        FILE=${GROUP_STATUS}.${NODE}.${STAGE}
    fi

    touch ${FILE}
    log "Stage complete: ${STAGE}"

    return 0
}


## Set the system name and description
##
function set_system_name {
    local NAME=$1
    local DESCRIPTION="${NAME}: setup by lab_setup.sh"

    info "Setting system name"
    source ${OPENRC}
    log_command "system modify --name=${NAME} --description=\"${DESCRIPTION}\""
    RET=$?
    return ${RET}
}


## Set the system vswitch type
##
function set_vswitch_type {
    local TYPE=$1

    if is_stage_complete "vswitch_type"; then
        info "Skipping vswitch type configuration; already done"
        return 0
    fi

    info "Setting vswitch type"
    source ${OPENRC}

    CURRENT=$(system show|grep vswitch_type|awk '{print $4}')
    if [ $VSWITCH_TYPE != $CURRENT ]; then
        log_command "system modify --vswitch_type ${TYPE}"
        RET=$?
    fi
    stage_complete "vswitch_type"
    return ${RET}
}

## Set the DNS configuration
##
function set_dns {
    if is_stage_complete "dns"; then
        info "Skipping DNS configuration; already done"
        return 0
    fi
    info "Setting DNS configuration"
    source ${OPENRC}
    log_command "system dns-modify nameservers=${NAMESERVERS} action=apply"
    RET=$?
    stage_complete "dns"
    return ${RET}
}

## Set the NTP/PTP configuration
##
function set_time_service {
    RET=0
    if is_stage_complete "time"; then
        info "Skipping ${TIMESERVICE} configuration; already done"
        return ${RET}
    fi
    info "Setting ${TIMESERVICE} configuration"
    source ${OPENRC}
    if [ "x${TIMESERVICE}" == "xNTP" ]; then
        log_command "system ntp-modify ntpservers=${NTPSERVERS}"
        RET=$?
        stage_complete "time"
    elif [ "x${TIMESERVICE}" == "xPTP" ]; then
        log_command "system ntp-modify --enabled=false"
        log_command "system ptp-modify --enabled=true"
        RET=$?
        stage_complete "time"
    else
        info "Unsupported time service type: ${TIMESERVICE}"
        RET=1
    fi
    return ${RET}
}

## Check for prerequisite files
##
function check_required_files {
    mkdir -p ${USERDATA_DIR}
    mkdir -p ${BOOTDIR}

    if [ ! -f ${OPENRC} ]; then
        echo "Nova credential file is missing: ${OPENRC}"
        return 1
    fi

    if [ ${GROUPNO} -eq 0 ]; then
        if [ ! -L ${DEFAULT_BOOTDIR} ]; then
            ln -s ${BOOTDIR} ${DEFAULT_BOOTDIR}
        fi
    fi

    return 0
}

## Increment an IP address by an arbitrary amount.  There is no elegant way of
## doing this in bash, that handles both ipv4 and ipv6, without installing
## other packages so python is used.
function ip_incr {
    local IPADDRESS=$1
    local VALUE=$2

    python -c "import netaddr;print netaddr.IPAddress('${IPADDRESS}')+${VALUE}"
}

## Add tenants and users
function add_tenants {
    local TENANTID=0

    if is_stage_complete "tenants"; then
        info "Skipping tenant configuration; already done"
        return 0
    fi

    info "Adding tenants"

    for TENANT in ${TENANTS[@]}; do
        ## Create the project if it does not exist
        TENANTID=$(get_tenant_id ${TENANT})
        if [ -z "${TENANTID}" ]; then
            log_command "openstack project create \
--domain ${OPENSTACK_PROJECT_DOMAIN} --description ${TENANT} ${TENANT}"
        fi

        ## Create the user if it does not exist
        USERID=$(get_user_id ${TENANT})
        if [ -z "${USERID}" ]; then
            log_command "openstack user create \
--password ${DEFAULT_OPENSTACK_PASSWORD} --domain ${OPENSTACK_USER_DOMAIN} --project ${TENANT} \
--project-domain ${OPENSTACK_PROJECT_DOMAIN} \
--email ${TENANT}@noreply.com ${TENANT}"
        fi

        ## Ensure tenant user is a member of the project
        ROLES=$(get_user_roles ${TENANT} ${TENANT})
        if [[ ! $ROLES =~ ${MEMBER_ROLE} ]]; then
            log_command "openstack role add --project ${TENANT} \
--project-domain ${OPENSTACK_PROJECT_DOMAIN} --user ${TENANT} \
--user-domain ${OPENSTACK_USER_DOMAIN} ${MEMBER_ROLE}"
        fi

        ## Add the admin user to each group/project so that all projects can be
        ## accessed from Horizon without needing to logout/login again.
        ROLES=$(get_user_roles ${TENANT} ${ADMIN_USER})
        if [[ ! $ROLES =~ ${MEMBER_ROLE} ]]; then
            log_command "openstack role add --project ${TENANT} \
--project-domain ${OPENSTACK_PROJECT_DOMAIN} --user ${ADMIN_USER} \
--user-domain ${OPENSTACK_USER_DOMAIN} ${MEMBER_ROLE}"
        fi
    done

    stage_complete "tenants"

    return 0
}

## Create credential files for tenants
##
function create_credentials {
    local TENANT=""
    local ADMIN_URL="35357"
    local PUBLIC_URL="5000"
    local K8S_URL="http://keystone.openstack.svc.cluster.local/v3"

    if is_stage_complete "credentials"; then
        info "Skipping credential configuration; already done"
        return 0
    fi

    info "Adding tenant credentials"

    for TENANT in ${TENANTS[@]}; do
        cp ${OPENRC} ${HOME}/openrc.${TENANT}
        sed -i -e "s#admin#${TENANT}#g" ${HOME}/openrc.${TENANT}
        sed -i -e "s#\(OS_PASSWORD\)=.*#\1=${DEFAULT_OPENSTACK_PASSWORD}#g" ${HOME}/openrc.${TENANT}
        sed -i -e "s#${ADMIN_URL}#${PUBLIC_URL}#g" ${HOME}/openrc.${TENANT}
        if [ "$K8S_ENABLED" == "yes" ]; then
            sed -i -e "s#\(OS_AUTH_URL\)=.*#\1=${K8S_URL}#g" ${HOME}/openrc.${TENANT}
        fi
    done

    if [ "$K8S_ENABLED" == "yes" ]; then
        cp ${OPENRC} ${HOME}/openrc.admin
        sed -i -e "s#\(OS_AUTH_URL\)=.*#\1=${K8S_URL}#g" ${HOME}/openrc.admin
    fi

    stage_complete "credentials"

    return 0
}


function set_cinder_quotas {
    if is_stage_complete "quotas_cinder"; then
        info "Skipping cinder quota configuration; already done"
        return 0
    fi

    info "Adding cinder quotas"
    unset OS_AUTH_URL
    export OS_AUTH_URL=${K8S_URL}
    for TENANT in ${TENANTS[@]}; do
        TENANTID=$(get_tenant_id ${TENANT})
        log_command "openstack ${REGION_OPTION} quota set ${TENANTID} \
--volumes ${VOLUME_QUOTA} \
--snapshots ${SNAPSHOT_QUOTA}"
    done

    stage_complete "quotas_cinder"
}

## Adjust quotas
##
function set_quotas {
    local SQUOTA=0
    local NQUOTA=0
    local PQUOTA=0
    local RAMPARAM=""

    if is_stage_complete "quotas"; then
        info "Skipping quota configuration; already done"
        return 0
    fi

    info "Adding quotas"

    ## Set the Admin quotas.
    NQUOTA=$(get_neutron_quota ${ADMINID} "network")
    if [ "x${NQUOTA}" != "x${ADMIN_NETWORK_QUOTA}" -a ${GROUPNO} -eq 0 ]; then
        log_command "openstack ${REGION_OPTION} quota set ${ADMINID} --networks ${ADMIN_NETWORK_QUOTA}"
    fi
    SQUOTA=$(get_neutron_quota ${ADMINID} "subnet")
    if [ "x${SQUOTA}" != "x${ADMIN_SUBNET_QUOTA}" -a ${GROUPNO} -eq 0 ]; then
        log_command "openstack ${REGION_OPTION} quota set ${ADMINID} --subnets ${ADMIN_SUBNET_QUOTA}"
    fi
    PQUOTA=$(get_neutron_quota ${ADMINID} "port")
    if [ "x${PQUOTA}" != "x${ADMIN_PORT_QUOTA}" -a ${GROUPNO} -eq 0 ]; then
        log_command "openstack ${REGION_OPTION} quota set ${ADMINID} --ports ${ADMIN_PORT_QUOTA}"
    fi

    # Only set RAM quota if value is specified
    if [ ! -z "${RAM_QUOTA}" ]; then
        RAMPARAM="--ram ${RAM_QUOTA}"
    fi

    for TENANT in ${TENANTS[@]}; do
        TENANTID=$(get_tenant_id ${TENANT})
        NQUOTA=$(get_neutron_quota ${TENANTID} "network")
        SQUOTA=$(get_neutron_quota ${TENANTID} "subnet")
        PQUOTA=$(get_neutron_quota ${TENANTID} "port")
        ## Setup neutron quota (if necessary)
        if [ "x${NQUOTA}" != "x${NETWORK_QUOTA}" -o "x${SQUOTA}" != "x${SUBNET_QUOTA}" -o "x${PQUOTA}" != "x${PORT_QUOTA}" ]; then
            log_command "openstack ${REGION_OPTION} quota set ${TENANTID} \
--subnets ${SUBNET_QUOTA} \
--networks ${NETWORK_QUOTA} \
--ports ${PORT_QUOTA} \
--floating-ips ${FLOATING_IP_QUOTA}"
        fi

        ## Setup nova quotas
        log_command "nova ${REGION_OPTION} quota-update ${TENANTID} \
--instances ${INSTANCE_QUOTA} \
--cores ${CORE_QUOTA} \
${RAMPARAM}"

    done

    ## Prevent the admin from launching VMs
    log_command "nova ${REGION_OPTION} quota-update ${ADMINID} --instances 0 --cores 0"
    log_command "openstack ${REGION_OPTION} quota set ${ADMINID} --floating-ips 0"

    stage_complete "quotas"
}

## Sets up a single flat data network with no ranges
##
function setup_flat_data_network {
    local INDEX=$1
    local NAME=group${GROUPNO}-$2
    local MTU=$3

    local TRANSPARENT_ARGS="--vlan-transparent ${VLAN_TRANSPARENT}"
    if [ "${VLAN_TRANSPARENT_INTERNAL_NETWORKS}" == "True" ]; then
        TRANSPARENT_ARGS="--vlan-transparent=True"
    fi

    log_command "system ${REGION_OPTION} datanetwork-add ${NAME} flat -m ${MTU}"

    return 0
}

## Sets up a single VLAN data network with range details
##
function setup_vlan_data_network {
    local INDEX=$1
    local NAME=group${GROUPNO}-$2
    local MTU=$3
    local RANGES=$4
    local OWNER=$5

    local TRANSPARENT_ARGS="--vlan-transparent ${VLAN_TRANSPARENT}"
    if [ "${VLAN_TRANSPARENT_INTERNAL_NETWORKS}" == "True" ]; then
        TRANSPARENT_ARGS="--vlan-transparent=True"
    fi


    DNETUUID=$(get_data_network_uuid ${NAME})
    if [ -z "${DNETUUID}" ]; then
        log_command "system ${REGION_OPTION} datanetwork-add ${NAME} vlan -m ${MTU}"
    fi

    return 0
}

## Adds a set of internal segments ranges alternating between VXLAN_GROUP and
## VXLAN_PORT values according with VXLAN_INTERNAL_STEP segments in each
## range.  This is to facilitate having different group addresses and
## potentially each group could be either IPv4 or IPv6
##
function setup_vxlan_provider_network_ranges {
    local INDEX=$1
    local NAME=$2
    local OWNER_ARGS="$3"
    local RANGES=(${4//,/ })
    local GROUPS_VARNAME=$5
    local PORTS_VARNAME=$6
    local VXLAN_ARGS=""
    local GROUP_IDX=0
    local PORT_IDX=0

    local MCAST_GROUPS=(${!GROUPS_VARNAME})
    local UDP_PORTS=(${!PORTS_VARNAME})

    VALUES=${MCAST_GROUPS[@]}
    debug "vxlan provider ranges with ${#MCAST_GROUPS[@]} group attributes: ${VALUES}"
    VALUES=${UDP_PORTS[@]}
    debug "vxlan provider ranges with ${#UDP_PORTS[@]} attributes: ${VALUES}"

    local COUNT=0
    for I in ${!RANGES[@]}; do
        local RANGE=${RANGES[${I}]}
        RANGE=(${RANGE/-/ })

        ## Start at the beginning for each new range
        GROUP_IDX=0
        PORT_IDX=0

        for J in $(seq ${RANGE[0]} ${VXLAN_INTERNAL_STEP} ${RANGE[1]}); do
            local RANGE_NAME=${NAME}-r${INDEX}-${COUNT}

            RANGEID=$(get_provider_network_range_id ${RANGE_NAME})
            if [ ! -z "${RANGEID}" ]; then
                ## already exists
                continue
            fi

            VXLAN_ARGS="--port ${UDP_PORTS[${PORT_IDX}]} --ttl ${VXLAN_TTL}"
            GROUP_ARG="${MCAST_GROUPS[${GROUP_IDX}]}"
            if [[ "${GROUP_ARG}" == @(static|evpn) ]]; then
                VXLAN_ARGS="${VXLAN_ARGS} --mode ${GROUP_ARG}"
            else
                VXLAN_ARGS="${VXLAN_ARGS} --group ${GROUP_ARG}"
            fi

            END=$((J+${VXLAN_INTERNAL_STEP}-1))
            END=$((${END} < ${RANGE[1]} ? ${END} : ${RANGE[1]}))
            log_command "openstack ${REGION_OPTION} providernet range create ${NAME} --name ${RANGE_NAME} ${OWNER_ARGS} --range ${J}-${END} ${VXLAN_ARGS}"

            GROUP_IDX=$(((GROUP_IDX + 1) % ${#MCAST_GROUPS[@]}))
            PORT_IDX=$(((PORT_IDX + 1) % ${#UDP_PORTS[@]}))

            COUNT=$((COUNT+1))
        done
    done

    return 0
}

## Sets up a single VXLAN provider network with range details and VXLAN
## attributes.  The GROUPS and PORTS arguments are optional and if not
## specified will be taken from the global variable VXLAN_GROUPS or
## VXLAN_PORTS.
##
function setup_vxlan_provider_network {
    local INDEX=$1
    local NAME=group${GROUPNO}-$2
    local MTU=$3
    local RANGES=$4
    local OWNER=$5
    set +u
    local MCAST_GROUPS=(${6//,/ })
    local UDP_PORTS=(${7//,/ })
    local TTL=$8
    set -u

    local TRANSPARENT_ARGS="--vlan-transparent ${VLAN_TRANSPARENT}"
    if [ "${VLAN_TRANSPARENT_INTERNAL_NETWORKS}" == "True" ]; then
        TRANSPARENT_ARGS="--vlan-transparent=True"
    fi

    PNETID=$(get_provider_network_id ${NAME})
    if [ -z "${PNETID}" ]; then
        log_command "openstack ${REGION_OPTION} providernet create ${NAME} --type vxlan --mtu ${MTU} ${TRANSPARENT_ARGS}"
    fi

    OWNER_ARGS="--shared"
    if [ "${OWNER}" != "shared" ]; then
        OWNER_ARGS="--project $(get_tenant_id ${OWNER})"
    fi

    if [ -z "${MCAST_GROUPS+x}" ]; then
        ## Use global defaults
        MCAST_GROUPS=(${VXLAN_GROUPS})
    fi

    if [ -z "${UDP_PORTS+x}" ]; then
        ## Use global defaults
        UDP_PORTS=(${VXLAN_PORTS})
    fi

    if [ -z "${TTL}" ]; then
        ## Use global default
        TTL=${VXLAN_TTL}
    fi

    if [ ${#MCAST_GROUPS[@]} -gt 1 -o ${#UDP_PORTS[@]} -gt 1 ]; then
        ## Setup smaller ranges with varying groups and ports
        setup_vxlan_provider_network_ranges ${INDEX} ${NAME} "${OWNER_ARGS}" ${RANGES} MCAST_GROUPS[@] UDP_PORTS[@]
    else
        ## Setup just a single set of ranges each with the same VXLAN attributes
        VALUES=${MCAST_GROUPS[@]}
        debug "vxlan provider ranges with group attributes: ${VALUES}"
        VALUES=${UDP_PORTS[@]}
        debug "vxlan provider ranges with attributes: ${VALUES}"

        RANGES=(${RANGES//,/ })
        for I in ${!RANGES[@]}; do
            local RANGE=${RANGES[${I}]}
            local RANGE_NAME=${NAME}-r${INDEX}-${I}

            RANGEID=$(get_provider_network_range_id ${RANGE_NAME})
            if [ ! -z "${RANGEID}" ]; then
                ## already exists
                return 0
            fi

            VXLAN_ARGS="--ttl ${TTL} --port ${UDP_PORTS[0]}"
            GROUP_ARG="${MCAST_GROUPS[0]}"
            if [[ "${GROUP_ARG}" == @(static|evpn) ]]; then
                VXLAN_ARGS="${VXLAN_ARGS} --mode ${GROUP_ARG}"
            else
                VXLAN_ARGS="${VXLAN_ARGS} --group ${GROUP_ARG}"
            fi
            log_command "openstack ${REGION_OPTION} providernet range create ${NAME} --name ${RANGE_NAME} --range ${RANGE} ${OWNER_ARGS} ${VXLAN_ARGS}"
        done
    fi

    return 0
}

## Sets up a single VXLAN provider network with range details and VXLAN
## attributes.  The GROUPS and PORTS arguments are optional and if not
## specified will be taken from the global variable VXLAN_GROUPS or
## VXLAN_PORTS.
##
function setup_vxlan_data_network {
    local INDEX=$1
    local NAME=group${GROUPNO}-$2
    local MTU=$3
    local RANGES=$4
    local OWNER=$5
    set +u
    local MCAST_GROUPS=(${6//,/ })
    local UDP_PORTS=(${7//,/ })
    local TTL=$8
    set -u

    local TRANSPARENT_ARGS="--vlan-transparent ${VLAN_TRANSPARENT}"
    if [ "${VLAN_TRANSPARENT_INTERNAL_NETWORKS}" == "True" ]; then
        TRANSPARENT_ARGS="--vlan-transparent=True"
    fi


    OWNER_ARGS="--shared"
    if [ "${OWNER}" != "shared" ]; then
        OWNER_ARGS="--project $(get_tenant_id ${OWNER})"
    fi

    if [ -z "${MCAST_GROUPS+x}" ]; then
        ## Use global defaults
        MCAST_GROUPS=(${VXLAN_GROUPS})
    fi

    if [ -z "${UDP_PORTS+x}" ]; then
        ## Use global defaults
        UDP_PORTS=(${VXLAN_PORTS})
    fi

    if [ -z "${TTL}" ]; then
        ## Use global default
        TTL=${VXLAN_TTL}
    fi

    DNETUUID=$(get_data_network_uuid ${NAME})
    if [ -z "${DNETUUID}" ]; then
        DNVXLAN_ARGS="-p ${UDP_PORTS[0]} -g ${MCAST_GROUPS[0]} -t ${TTL}"
        DNMODE_ARG="${MCAST_GROUPS[0]}"
        if [[ "${DNMODE_ARG}" == "static" ]]; then
            DNVXLAN_ARGS="-p ${UDP_PORTS[0]} -t ${TTL} -M static"
        fi
        log_command "system ${REGION_OPTION} datanetwork-add ${NAME} vxlan -m ${MTU} ${DNVXLAN_ARGS}"
    fi

    return 0
}
## Loops over all PROVIDERNETS entries and creates each provider network
## according to its attributes.
##
function add_provider_networks {
    local PNETS=(${PROVIDERNETS})

    source ${OPENRC}

    if is_stage_complete "datanetworks"; then
        info "Skipping provider networks; already done"
        return 0
    fi

    info "Adding data networks"

    for IFINDEX in ${!PNETS[@]}; do
        ENTRY=${PNETS[${IFINDEX}]}
        DATA=(${ENTRY//|/ })
        TYPE=${DATA[0]}

        debug "setting up providernet(${IFINDEX}): ${ENTRY}"

        ## Remove the type from the array
        unset DATA[0]
        DATA=(${DATA[@]})

        if [ "${TYPE}" == "vxlan" ]; then
            setup_vxlan_data_network ${IFINDEX} "${DATA[@]}"

        elif [ "${TYPE}" == "vlan" ]; then
            setup_vlan_data_network ${IFINDEX} "${DATA[@]}"

        elif [ "${TYPE}" == "flat" ]; then
            setup_flat_data_network ${IFINDEX} "${DATA[@]}"

        else
            echo "unsupported data network type: ${TYPE}"
            return 1
        fi

        RET=$?
        if [ ${RET} -ne 0 ]; then
            echo "Failed to setup data network(${IFINDEX}): ${ENTRY}"
            return ${RET}
        fi
    done

    stage_complete "datanetworks"

    return 0
}

## Retrieve the network segment range id for a segment range name
function get_network_segment_range_id {
    local RANGE_NAME=$1
    echo $(openstack ${REGION_OPTION} network segment range show ${RANGE_NAME} -c id -f value 2>/dev/null)
}

## Adds a set of internal segments ranges alternating between VXLAN_GROUP and
## VXLAN_PORT values according with VXLAN_INTERNAL_STEP segments in each
## range.  This is to facilitate having different group addresses and
## potentially each group could be either IPv4 or IPv6
##
function setup_vxlan_network_segment_ranges_varied {
    local INDEX=$1
    local NAME=$2
    local OWNER_ARGS="$3"
    local RANGES=(${4//,/ })
    local GROUPS_VARNAME=$5
    local PORTS_VARNAME=$6
    local GROUP_IDX=0
    local PORT_IDX=0

    local MCAST_GROUPS=(${!GROUPS_VARNAME})
    local UDP_PORTS=(${!PORTS_VARNAME})

    VALUES=${MCAST_GROUPS[@]}
    debug "vxlan provider ranges with ${#MCAST_GROUPS[@]} group attributes: ${VALUES}"
    VALUES=${UDP_PORTS[@]}
    debug "vxlan provider ranges with ${#UDP_PORTS[@]} attributes: ${VALUES}"

    local COUNT=0
    for I in ${!RANGES[@]}; do
        local RANGE=${RANGES[${I}]}
        RANGE=(${RANGE/-/ })

        ## Start at the beginning for each new range
        GROUP_IDX=0
        PORT_IDX=0

        for J in $(seq ${RANGE[0]} ${VXLAN_INTERNAL_STEP} ${RANGE[1]}); do
            local RANGE_NAME=${NAME}-r${INDEX}-${COUNT}

            RANGEID=$(get_network_segment_range_id ${RANGE_NAME})
            if [ ! -z "${RANGEID}" ]; then
                ## already exists
                continue
            fi

            END=$((J+${VXLAN_INTERNAL_STEP}-1))
            END=$((${END} < ${RANGE[1]} ? ${END} : ${RANGE[1]}))

            log_command "openstack ${REGION_OPTION} network segment range create ${RANGE_NAME} --network-type vxlan --minimum ${J} --maximum ${END} ${OWNER_ARGS}"

            # log_command "openstack ${REGION_OPTION} providernet range create ${NAME} --name ${RANGE_NAME} ${OWNER_ARGS} --range ${J}-${END} ${VXLAN_ARGS}"

            GROUP_IDX=$(((GROUP_IDX + 1) % ${#MCAST_GROUPS[@]}))
            PORT_IDX=$(((PORT_IDX + 1) % ${#UDP_PORTS[@]}))

            COUNT=$((COUNT+1))
        done
    done

    return 0
}

## Sets up a single VXLAN provider network with range details and VXLAN
## attributes.  The GROUPS and PORTS arguments are optional and if not
## specified will be taken from the global variable VXLAN_GROUPS or
## VXLAN_PORTS.
##
function setup_vxlan_network_segment_ranges {
    local INDEX=$1
    local NAME=group${GROUPNO}-$2
    local MTU=$3
    local RANGES=$4
    local OWNER=$5
    set +u
    local MCAST_GROUPS=(${6//,/ })
    local UDP_PORTS=(${7//,/ })
    local TTL=$8
    set -u

    OWNER_ARGS="--shared"
    if [ "${OWNER}" != "shared" ]; then
        OWNER_ARGS="--private --project $(get_tenant_id ${OWNER})"
    fi

    if [ -z "${MCAST_GROUPS+x}" ]; then
        ## Use global defaults
        MCAST_GROUPS=(${VXLAN_GROUPS})
    fi

    if [ -z "${UDP_PORTS+x}" ]; then
        ## Use global defaults
        UDP_PORTS=(${VXLAN_PORTS})
    fi

    if [ -z "${TTL}" ]; then
        ## Use global default
        TTL=${VXLAN_TTL}
    fi

    if [ ${#MCAST_GROUPS[@]} -gt 1 -o ${#UDP_PORTS[@]} -gt 1 ]; then
        ## Setup smaller ranges with varying groups and ports
        setup_vxlan_network_segment_ranges_varied ${INDEX} ${NAME} "${OWNER_ARGS}" ${RANGES} MCAST_GROUPS[@] UDP_PORTS[@]
    else
        ## Setup just a single set of ranges each with the same VXLAN attributes
        VALUES=${MCAST_GROUPS[@]}
        debug "vxlan provider ranges with group attributes: ${VALUES}"
        VALUES=${UDP_PORTS[@]}
        debug "vxlan provider ranges with attributes: ${VALUES}"

        RANGES=(${RANGES//,/ })
        for I in ${!RANGES[@]}; do
            local RANGE=${RANGES[${I}]}
            local RANGE_MIN=$(echo "${RANGE}" | cut -f1 -d-)
            local RANGE_MAX=$(echo "${RANGE}" | cut -f2 -d-)
            local RANGE_NAME=${NAME}-r${INDEX}-${I}

            RANGEID=$(get_network_segment_range_id ${RANGE_NAME})
            if [ ! -z "${RANGEID}" ]; then
                ## already exists
                return 0
            fi

            log_command "openstack ${REGION_OPTION} network segment range create ${RANGE_NAME} --network-type vxlan --minimum ${RANGE_MIN} --maximum ${RANGE_MAX} ${OWNER_ARGS}"

        done
    fi

    return 0
}

## Sets up a single VLAN data network with range details
##
function setup_vlan_network_segment_ranges {
    local INDEX=$1
    local NAME=group${GROUPNO}-$2
    local MTU=$3
    local RANGES=$4
    local OWNER=$5

    OWNER_ARGS="--shared"
    if [ "${OWNER}" != "shared" ]; then
        OWNER_ARGS="--private --project $(get_tenant_id ${OWNER})"
    fi

    RANGES=(${RANGES//,/ })
    for I in ${!RANGES[@]}; do
        local RANGE=${RANGES[${I}]}
        local RANGE_NAME=${NAME}-r${INDEX}-${I}
        local RANGE_MIN=$(echo "${RANGE}" | cut -f1 -d-)
        local RANGE_MAX=$(echo "${RANGE}" | cut -f2 -d-)

        RANGEID=$(get_network_segment_range_id ${RANGE_NAME})
        if [ ! -z "${RANGEID}" ]; then
            ## already exists
            return 0
        fi

        log_command "openstack ${REGION_OPTION} network segment range create ${RANGE_NAME} --network-type vlan --physical-network ${NAME} --minimum ${RANGE_MIN} --maximum ${RANGE_MAX} ${OWNER_ARGS}"

    done

    return 0
}

## Loops over all PROVIDERNETS entries and creates each
## network segment range according to its attributes.
##
function add_network_segment_ranges {
    local PNETS=(${PROVIDERNETS})

    source ${OPENRC}
    unset OS_AUTH_URL
    export OS_AUTH_URL=${K8S_URL}


    if is_stage_complete "network_segment_ranges"; then
        info "Skipping network segment ranges; already done"
        return 0
    fi

    info "Adding network segment ranges"

    for IFINDEX in ${!PNETS[@]}; do
        ENTRY=${PNETS[${IFINDEX}]}
        DATA=(${ENTRY//|/ })
        TYPE=${DATA[0]}

        debug "setting up network segment ranges (${IFINDEX}): ${ENTRY}"

        ## Remove the type from the array
        unset DATA[0]
        DATA=(${DATA[@]})

        if [ "${TYPE}" == "vxlan" ]; then
            setup_vxlan_network_segment_ranges ${IFINDEX} "${DATA[@]}"

        elif [ "${TYPE}" == "vlan" ]; then
            setup_vlan_network_segment_ranges ${IFINDEX} "${DATA[@]}"

        elif [ "${TYPE}" == "flat" ]; then
            continue

        else
            echo "unsupported data network type: ${TYPE}"
            return 1
        fi

        RET=$?
        if [ ${RET} -ne 0 ]; then
            echo "Failed to setup network segment range (${IFINDEX}): ${ENTRY}"
            return ${RET}
        fi
    done

    stage_complete "network_segment_ranges"

    return 0
}

## Setup network qos policies
##
function add_qos_policies {
    local TENANTID=""
    local MGMTQOS=""
    local ID=""

    source ${OPENRC}
    if [ "$K8S_ENABLED" == "yes" ]; then
        unset OS_AUTH_URL
        export OS_AUTH_URL=${K8S_URL}
    fi

    if is_stage_complete "qos"; then
        info "Skipping QoS configuration; already done"
        return 0
    fi

    info "Adding network qos policies"

    ID=$(get_qos_id ${EXTERNALQOS})
    if [ -z "${ID}" ]; then
        log_command "openstack ${REGION_OPTION} qos create --name ${EXTERNALQOS} --description \"External Network Policy\" --scheduler weight=${EXTERNALQOSWEIGHT}"
    fi

    ID=$(get_qos_id ${INTERNALQOS})
    if [ -z "${ID}" ]; then
        log_command "openstack ${REGION_OPTION} qos create --name ${INTERNALQOS} --description \"Internal Network Policy\" --scheduler weight=${INTERNALQOSWEIGHT}"
    fi

    for TENANT in ${TENANTS[@]}; do
        TENANTID=$(get_tenant_id ${TENANT})
        MGMTQOS="${TENANT}-mgmt-qos"
        ID=$(get_qos_id ${MGMTQOS})
        if [ -z "${ID}" ]; then
            log_command "openstack ${REGION_OPTION} qos create --name ${MGMTQOS} --description \"${TENANT} Management Network Policy\" --project ${TENANTID} --scheduler weight=${MGMTQOSWEIGHT}"
        fi
    done

    stage_complete "qos"

    return 0
}

## provider network names are specified without their group prefix so add the
## prefix before passing any provider network lists to system commands.
##
function resolve_provider_networks {
    local PNETS=(${1//,/ })
    local NAMES=(${PNETS[@]/#/group${GROUPNO}-})
    NAMES=$(printf ",%s" "${NAMES[@]}")
    PNETS=${NAMES:1}
    echo ${PNETS}
}

function get_class_from_type {
    local TYPE=$1
    local CLASS=""
    if [[ "${TYPE}" == @(pxeboot|mgmt|infra|oam|cluster-host) ]]; then
        CLASS="platform"
    elif [ "${TYPE}" == "data" ]; then
        CLASS="data"
    elif [ "${TYPE}" == "pthru" ]; then
        ## Use sysinv type value
        CLASS="pci-passthrough"
    elif [ "${TYPE}" == "sriov" ]; then
        ## Use sysinv type value
        CLASS="pci-sriov"
    elif [ "${TYPE}" == "none" ]; then
        CLASS="none"
    fi
    echo ${CLASS}
}

## Sets up a single VLAN interface over a lower interface.
##
function setup_vlan_interface {
    local NODE=$1
    local IFINDEX=$2
    local TYPE=$3
    local DEVICES=$4
    local MTU=$5
    local PNETS=$6
    local VLANID=$7
    local LOWER_IFNAME=""
    local IFNAME="vlan${VLANID}"

    ## Check for a matching name
    local DATA=($(system host-if-show ${NODE} ${IFNAME} 2> /dev/null | awk '($2 == "uuid" || $2 == "iftype") {print $4}'))
    if [ ! -z "${DATA+x}" ]; then
        if [ "${DATA[0]}" == "vlan" ]; then
            ## Already exists
            return 0
        fi
    fi

    if [ -z "${VLANID}" ]; then
        echo "VLANID not specified for interface(${IFINDEX}) ${DEVICES}"
        return 1
    fi

    CLASS=$(get_class_from_type ${TYPE})
    ## Check for a matching type + vlanid since on small systems the infra vlan may already exist
    IFACEID=$(system host-if-list ${NODE} ${CLI_NOWRAP} | awk -v CLASS=${CLASS} -v VLANID=${VLANID} '{if ($6 == CLASS && $10 == VLANID) print $2}')
    if [ ! -z "${IFACEID}" ]; then
        ## Already exists
        return 0
    fi

    local PNET_ARGS=""
    if [[ "${TYPE}" == data && "${PNETS}" != "none" ]]; then
        PNETS=$(resolve_provider_networks ${PNETS})
        PNET_ARGS="${PNETS}"
    fi

    local MTU_ARGS=""
    if [[ "${TYPE}" == data && -n "${MTU}" ]]; then
        MTU_ARGS="-m ${MTU}"
    fi

    if [[ "${DEVICES}" != "0000:"* ]]; then
        ## Specified as a lower interface name; nothing to do
        LOWER_IFNAME=${DEVICES}

    else
        ## Specified as PCIADDR.  Find the port name and interface name
        local PCIINFO=(${DEVICES//+/ })
        local PCIADDR=${PCIINFO[0]}
        local PCIDEV=${PCIINFO[1]:-"0"}

        PORTNAME=$(get_port_name ${NODE} ${PCIADDR} ${PCIDEV})
        if [ -z "${PORTNAME}" ]; then
            echo "Failed to find port name for ${PCIADDR} ${PCIDEV} on ${NODE}"
            return 1
        fi

        LOWER_IFNAME=$(system host-if-list -a ${NODE} ${CLI_NOWRAP} | awk -v PORTNAME=[u\'$PORTNAME\'] '($12 == PORTNAME) {print $4}')
        if [ -z "${LOWER_IFNAME}" ]; then
            echo "Failed to find interface name for port ${PORTNAME}"
            return 1
        fi
    fi

    local LOWER_MTU=$(system host-if-show ${NODE} ${LOWER_IFNAME} | awk '($2 == "imtu") {print $4}')
    if [ -z "${LOWER_MTU}" ]; then
        echo "Interface ${LOWER_IFNAME} not found\n"
        return 1
    fi
    if [ ${LOWER_MTU} -lt ${MTU} ]; then
        log_command "system host-if-modify ${NODE} ${LOWER_IFNAME} -m ${MTU}"
    fi

    if [ ${CLASS} == "platform" ]; then
        NET_ID=`system network-list |grep ${TYPE} | awk '{print $4}'`
        log_command "system host-if-add ${MTU_ARGS} -V ${VLANID} -c ${CLASS} --networks ${NET_ID} ${NODE} ${IFNAME} vlan ${PNET_ARGS} ${LOWER_IFNAME}"
    else
        log_command "system host-if-add ${MTU_ARGS} -V ${VLANID} -c ${CLASS} ${NODE} ${IFNAME} vlan ${PNET_ARGS} ${LOWER_IFNAME}"
    fi

    return 0
}


## Sets up a single ethernet interface as a data or infra type interface
##
function setup_ethernet_interface {
    local NODE=$1
    local IFINDEX=$2
    local TYPE=$3
    local DEVICES=$4
    local MTU=$5
    local PNETS=$6

    shift 6
    ARGS=($@)

    local PORTNAME=""
    local IFNAME="${TYPE:0:7}${IFINDEX}"
    #IFNAME=($(echo ${IFNAME:0:10}))

    local DATA=($(system host-if-show ${NODE} ${IFNAME} 2> /dev/null | awk '($2 == "uuid" || $2 == "iftype") {print $4}'))
    if [ ! -z "${DATA+x}" ]; then
        if [ "${DATA[0]}" == "ethernet" ]; then
            ## Already exists
            return 0
        fi
    fi

    if [[ "${TYPE}" == @(pxeboot|mgmt) ]]; then
        echo "Creating mgmt or pxeboot ethernet interfaces is not supported"
        return 1
    fi

    local PNET_ARGS=""
    if [[ "${TYPE}" == @(data|pthru|sriov) ]]; then
        if [ "${PNETS}" != "none" ]; then
            PNETS=$(resolve_provider_networks ${PNETS})
            PNET_ARGS="-p ${PNETS}"
        fi
    fi

    local VF_ARGS=""
    if [ "${TYPE}" == "sriov" ]; then
        VF_ARGS="-N ${ARGS[0]}"
    fi

    local MTU_ARGS=""
    if [[ "${TYPE}" == @(data|pthru|sriov) ]]; then
        if [ ! -z "${MTU}" ]; then
            MTU_ARGS="-m ${MTU}"
        fi
    fi

    if [[ "${DEVICES}" == "eth"* ]]; then
        ## Specified as a port name; nothing to do
        PORTNAME=${DEVICES}

    elif [[ "${DEVICES}" == "0000:"* ]]; then
        ## Specified as a PCIADDR; convert to a port name
        local PCIINFO=(${DEVICES//+/ })
        local PCIADDR=${PCIINFO[0]}
        local PCIDEV=${PCIINFO[1]:-"0"}

        PORTNAME=$(get_port_name ${NODE} ${PCIADDR} ${PCIDEV})
        if [ -z "${PORTNAME}" ]; then
            echo "Failed to find port name for ${PCIADDR} ${PCIDEV} on ${NODE}"
            return 1
        fi
    else
        ## Specified as an interface name (e.g., mgmt0, pxeboot0, etc...)
        IFNAME=${DEVICES}
    fi

    ## Get the interface ID and class
    if [ ! -z "${PORTNAME}" ]; then
        ## ... by port name
        local DATA=($(system host-if-list -a ${NODE} ${CLI_NOWRAP} | awk -v PORTNAME=[u\'${PORTNAME}\'] '($12 == PORTNAME) {printf "%s %s\n", $2, $6}'))
    else
        ## ... by interface name
        local DATA=($(system host-if-list -a ${NODE} ${CLI_NOWRAP} | awk -v IFNAME=${IFNAME} '($4 == IFNAME) {printf "%s %s\n", $2, $6}'))
    fi

    local IFACEID=${DATA[0]}
    local CLASS=${DATA[1]}
    if [ -z "${IFACEID}" -o -z "${CLASS}" ]; then
        echo "Failed to get interface id (${IFACEID}) or class (${CLASS}) for ${DEVICES}"
        return 1
    fi

    CLASS=$(get_class_from_type ${TYPE})
    if [ ${CLASS} == "platform" ]; then
        NET_ID=`system network-list |grep ${TYPE} | awk '{print $4}'`
        log_command "system host-if-modify ${MTU_ARGS} -n ${IFNAME} ${VF_ARGS} ${PNET_ARGS} -c ${CLASS} --networks ${NET_ID} ${NODE} ${IFACEID}"
    else
        log_command "system host-if-modify ${MTU_ARGS} -n ${IFNAME} ${VF_ARGS} ${PNET_ARGS} -c ${CLASS} ${NODE} ${IFACEID}"
    fi

    return 0
}


## Sets up a single AE ethernet interface as a data, infra, or mgmt type interface
##
function setup_ae_interface {
    local NODE=$1
    local IFINDEX=$2
    local TYPE=$3
    local DEVICES=(${4//,/ })
    local MTU=$5
    local PNETS=$6
    set +u
    local AEMODE=$7
    local AEHASH=$8
    set -u
    #local IFNAME="${TYPE}${IFINDEX}"
    local IFNAME="${TYPE:0:7}${IFINDEX}"

    local DATA=($(system host-if-show ${NODE} ${IFNAME} 2> /dev/null | awk '($2 == "uuid" || $2 == "iftype") {print $4}'))
    if [ ! -z "${DATA+x}" ]; then
        if [ "${DATA[0]}" == "ae" ]; then
            ## Already exists
            return 0
        elif [ "${TYPE}" == "pxeboot" -a "${DATA[0]}" == "ethernet" ]; then
            ## Already exists as the default ethernet pxeboot interface; remove
            ## the upper mgmt VLAN interface before continuing (lab_cleanup.sh
            ## is capable of restoring this if this was not intentional)
            log_warning "Removing existing mgmt0 VLAN interfaces"
            log_command "system host-if-delete ${NODE} mgmt0"
        fi
    fi

    if [ -z "${AEMODE}" ]; then
        ## Get global default value
        AEMODE=$(get_variable ${TYPE} AEMODE)
    fi

    if [ -z "${AEHASH}" ]; then
        ## Get global default value
        AEHASH=$(get_variable ${TYPE} AEHASH)
    fi

    local PNET_ARGS="none"
    if [ "${TYPE}" == "data" ]; then
        PNETS=$(resolve_provider_networks ${PNETS})
        PNET_ARGS="${PNETS}"
    elif [ "${TYPE}" == "bond" ]; then
        ## Special case to be able to create an AE strictly for later placing
        ## VLAN interfaces on top of it.
        TYPE="none"
        PNET_ARGS="none"
    fi

    local MTU_ARGS=""
    if [[ "${TYPE}" == @(pxeboot|data) ]]; then
        if [ ! -z "${MTU}" ]; then
            MTU_ARGS="-m ${MTU}"
        fi
    fi

    if [[ "${DEVICES[0]}" != "0000:"* ]]; then
        ## Specified as port names; nothing to do
        PORT0NAME=${DEVICES[0]}
        PORT1NAME=${DEVICES[1]:-""}

    else
        ## Convert to port names
        PCIINFO=(${DEVICES[0]//+/ })
        PCI0ADDR=${PCIINFO[0]}
        PCI0DEV=${PCIINFO[1]:-"0"}

        PORT0NAME=$(get_port_name ${NODE} ${PCI0ADDR} ${PCI0DEV})
        if [ -z "${PORT0NAME}" ]; then
            echo "Failed to find port name for ${PCI0ADDR} ${PCI0DEV} on ${NODE}"
            return 1
        fi

        PORT1NAME=""
        if [ ! -z "${DEVICES[1]+x}" ]; then
            PCIINFO=(${DEVICES[1]//+/ })
            PCI1ADDR=${PCIINFO[0]}
            PCI1DEV=${PCIINFO[1]:-"0"}

            PORT1NAME=$(get_port_name ${NODE} ${PCI1ADDR} ${PCI1DEV})
            if [ -z "${PORT1NAME}" ]; then
                echo "Failed to find port name for ${PCI1ADDR} ${PCI1DEV} on ${NODE}"
                return 1
            fi
        fi
    fi

    ## Convert to interface names and make sure their network type is None
    local DATA0IFNAME=$(system host-if-list -a ${NODE} ${CLI_NOWRAP} | awk -v PORT0NAME=[u\'$PORT0NAME\'] '($12 == PORT0NAME) {print $4}')
    log_command "system host-if-modify ${NODE} ${DATA0IFNAME} -n ${PORT0NAME} -c none"
    DATA0IFNAME=${PORT0NAME}

    local DATA1IFNAME=""
    if [ ! -z "${PORT1NAME}" ]; then
        DATA1IFNAME=$(system host-if-list -a ${NODE} ${CLI_NOWRAP} | awk -v PORT1NAME=[u\'$PORT1NAME\'] '($12 == PORT1NAME) {print $4}')
        log_command "system host-if-modify ${NODE} ${DATA1IFNAME} -n ${PORT1NAME} -c none"
        DATA1IFNAME=${PORT1NAME}
    fi

    ## Create the AE interface
    local AE_ARGS="-a ${AEMODE}"
    if [ "${AEMODE}" != "active_standby" ]; then
        AE_ARGS="${AE_ARGS} -x ${AEHASH}"
    fi
    CLASS=$(get_class_from_type ${TYPE})
    if [ ${CLASS} == "platform" ]; then
        NET_ID=`system network-list |grep ${TYPE} | awk '{print $4}'`
        log_command "system host-if-add ${MTU_ARGS} ${AE_ARGS} -c ${CLASS} --networks ${NET_ID} ${NODE} ${IFNAME} ae ${PNET_ARGS} ${DATA0IFNAME} ${DATA1IFNAME}"
    else
        log_command "system host-if-add ${MTU_ARGS} ${AE_ARGS} -c ${CLASS} ${NODE} ${IFNAME} ae ${PNET_ARGS} ${DATA0IFNAME} ${DATA1IFNAME}"

    fi
    return 0
}


## Setup data interfaces on a single node
##
function setup_interfaces {
    local NODE=$1
    local TYPE=$2
    local NETTYPE=${TYPE//-/_}
    local INTERFACES=($(get_node_variable ${NODE} ${NETTYPE^^}_INTERFACES))
    local IFINDEX_SHIFT=0

    if [ -z "${INTERFACES+x}" ]; then
        return 0
    fi

    debug "  Adding ${TYPE} interfaces for ${NODE}"

    if [ "${TYPE}" == "bond" ]; then
        ## Get bond AE interfaces number and use it as IFINDEX shift
        IFINDEX_SHIFT=$(system host-if-list ${NODE} | awk '($6 != "None" && $8 == "ae" && $4 ~ /^bond/) {print}'| wc -l)
    fi

    for IFINDEX in ${!INTERFACES[@]}; do
        local ENTRY=${INTERFACES[${IFINDEX}]}
        local DATA=(${ENTRY//|/ })
        local IFTYPE=${DATA[0]}

        debug "setting up ${TYPE} interface(${IFINDEX}) on ${NODE}: ${ENTRY}"

        ## Remove the IFTYPE from the array
        unset DATA[0]
        DATA=(${DATA[@]})

        if [ "${IFTYPE}" == "vlan" ]; then
            setup_vlan_interface ${NODE} ${IFINDEX} ${TYPE} "${DATA[@]}"

        elif [ "${IFTYPE}" == "ae" ]; then
            setup_ae_interface ${NODE} $((IFINDEX+IFINDEX_SHIFT)) ${TYPE} "${DATA[@]}"

        elif [ "${IFTYPE}" == "ethernet" ]; then
            setup_ethernet_interface ${NODE} ${IFINDEX} ${TYPE} "${DATA[@]}"

        else
            echo "unsupported ${TYPE} interface type: ${IFTYPE}"
            return 1
        fi

        RET=$?
        if [ ${RET} -ne 0 ]; then
            echo "Failed to ${TYPE} data interface ${IFINDEX}, ${IFTYPE} ${DEVICES}"
            return ${RET}
        fi
    done

    return 0
}

#change memory settings on a virtual worker node
function set_reserved_memory {
    local TYPES=""
    local NODE=""

    for NODE in ${NODES}; do
        if is_stage_complete "memory" ${NODE}; then
            info "Skipping memory configuration for ${NODE}; already done"
            continue
        fi

        info "Configuring memory on ${NODE}"
                log_command "system host-memory-modify -m 1200 -2M 256   ${NODE} 0"
                RET=$?
        if [ ${RET} -ne 0 ]; then
            echo "Failed to set addressing mode to static on ${NODE}:${IFNAME}"
            return ${RET}
        fi

                log_command "system host-memory-modify -m 1000 -2M 256   ${NODE} 1"
                RET=$?
        if [ ${RET} -ne 0 ]; then
            echo "Failed to set addressing mode to static on ${NODE}:${IFNAME}"
            return ${RET}
        fi

        stage_complete "memory" ${NODE}
    done

    return 0
}

#create flag file for virtual worker nodes
function write_flag_file {
    local TYPES=""
    local NODE=""
        local VIRTDIR="/etc/sysinv/.virtual_worker_nodes"
        sudo test -d ${VIRTDIR} || sudo mkdir ${VIRTDIR}
    for NODE in ${NODES}; do
        if is_stage_complete "virtual_flags" ${NODE}; then
            info "Skipping Flag creation for ${NODE}; already done"
            continue
        fi
        info "Writing flag for ${NODE}"
                local IP=$(get_mgmt_ip ${NODE})
                echo ${IP}
                sudo touch ${VIRTDIR}/${IP}
        stage_complete "virtual_flags" ${NODE}
    done

    return 0
}

## Setup data interfaces on all worker nodes
##
function add_interfaces {
    local TYPES=""
    local NODE=""

    for NODE in ${NODES} ${CONTROLLER_NODES} ${STORAGE_NODES}; do
        if is_stage_complete "interfaces" ${NODE}; then
            info "Skipping interface configuration for ${NODE}; already done"
            continue
        fi

        info "Adding interfaces on ${NODE}"

        if [[ "${NODE}" == *"storage"* ]]; then
            TYPES="bond pxeboot mgmt infra cluster-host"
        elif [[ "${NODE}" == *"controller"* ]]; then
            if [ "${SMALL_SYSTEM}" == "yes" ]; then
                TYPES="bond pxeboot mgmt data infra pthru sriov oam cluster-host"
            else
                TYPES="bond pxeboot mgmt infra oam cluster-host"
            fi
        else
            TYPES="bond pxeboot mgmt data infra pthru sriov cluster-host"
        fi

        for TYPE in ${TYPES}; do
            if [[ "${SMALL_SYSTEM}" == "yes" && "${NODE}" == "controller-0" ]]; then
                if [[ "${TYPE}" == @(mgmt|infra|cluster-host) ]]; then
                    ## config_controller should have done these
                    continue
                fi
            fi

            setup_interfaces ${NODE} ${TYPE}
            RET=$?
            if [ ${RET} -ne 0 ]; then
                echo "Failed to setup ${TYPE} interfaces for ${NODE}"
                return ${RET}
            fi
        done

        stage_complete "interfaces" ${NODE}
    done

    return 0
}


## Before adding an IP address to a data interface the addressing mode must be
## set to 'static' for the correct address family.
##
function setup_data_static_address_modes {
    local NODE=$1
    local IFNAME=$2
    local IPLIST=$3
    local IPV4_MODE=""
    local IPV6_MODE=""

    IPARRAY=(${IPLIST//,/ })
    for IPADDR in ${IPARRAY[@]}; do
        IPFIELDS=(${IPADDR//\// })

        if [ ${IPFIELDS[0]} == "na" ]; then
            continue
        fi

        RET=0
        set +e
        is_ipv4 ${IPFIELDS[0]}
        IS_IPV4=$?
        set -e
        if [ ${IS_IPV4} -eq 1 ]; then
            IPV4_MODE=$(get_interface_ipv4_mode ${NODE} ${IFNAME})
            if [ "${IPV4_MODE}" != "static" ]; then
                log_command "system host-if-modify ${NODE} ${IFNAME} --ipv4-mode=static"
                RET=$?
            fi
        else
            IPV6_MODE=$(get_interface_ipv6_mode ${NODE} ${IFNAME})
            if [ "${IPV6_MODE}" != "static" ]; then
                log_command "system host-if-modify ${NODE} ${IFNAME} --ipv6-mode=static"
                RET=$?
            fi
        fi

        if [ ${RET} -ne 0 ]; then
            echo "Failed to set addressing mode to static on ${NODE}:${IFNAME}"
            return ${RET}
        fi

    done

    return 0
}

## Setup IP addresses by taking a comma seperated list of route descriptors
## for a node + interface.
##
function setup_data_addresses {
    local NODE=$1
    local IFNAME=$2
    local IPLIST=$3

    debug "Setting up data addresses for ${IFNAME} on ${NODE}: ${IPLIST}"

    setup_data_static_address_modes ${NODE} ${IFNAME} ${IPLIST}
    RET=$?
    if [ ${RET} -ne 0 ]; then
        return ${RET}
    fi

    IPARRAY=(${IPLIST//,/ })
    for IPADDR in ${IPARRAY[@]}; do
        IPFIELDS=(${IPADDR//\// })

        if [ ${IPFIELDS[0]} == "na" ]; then
            continue
        fi

        IPFIELDS=(${IPADDR//\// })
        ID=`system host-addr-list ${NODE} ${CLI_NOWRAP} | grep -E "${IFNAME}[^0-9].* ${IPFIELDS[0]}[^0-9]" | awk '{print $2}'`
        if [ -z "${ID}" ]; then
            log_command "system host-addr-add ${NODE} ${IFNAME} ${IPFIELDS[0]} ${IPFIELDS[1]}"
            RET=$?
            if [ ${RET} -ne 0 ]; then
                echo "Failed to add ${IPFIELDS[0]}/${IPFIELDS[1]} to ${IFNAME} on ${NODE}"
                return ${RET}
            fi
        fi
    done

    return 0
}

## Setup IP routes by taking a comma seperated list of route descriptors for a
## node + interface.
##
function setup_data_routes {
    local NODE=$1
    local IFNAME=$2
    local ROUTELIST=$3
    local METRIC=1

    debug "Setting up data addresses for ${IFNAME} on ${NODE}: ${ROUTELIST}"

    ROUTEARRAY=(${ROUTELIST//,/ })
    for IPROUTE in ${ROUTEARRAY[@]}; do
        IPFIELDS=(${IPROUTE//\// })

        if [ ${IPFIELDS[0]} == "na" ]; then
            continue
        fi

        ID=`system host-route-list ${NODE} ${CLI_NOWRAP}| grep -E "${IFNAME}[^0-9].* ${IPFIELDS[0]}[^0-9].* ${IPFIELDS[2]}[^0-9]" | awk '{print $2}'`
        if [ -z "${ID}" ]; then
            log_command "system host-route-add ${NODE} ${IFNAME} ${IPFIELDS[0]} ${IPFIELDS[1]} ${IPFIELDS[2]} ${METRIC}"
            RET=$?
            if [ ${RET} -ne 0 ]; then
                echo "Failed to add ${IPFIELDS[0]}/${IPFIELDS[1]} via ${IPFIELDS[2]} to ${IFNAME} on ${NODE}"
                return ${RET}
            fi
        fi
    done

    return 0
}


## Setup data pools to later be associated to data interfaces
##
function setup_data_address_pools {
    local POOLS=$1

    for POOL in ${POOLS}; do
        local FIELDS=(${POOL//|/ })
        local NAME="group${GROUPNO}-${FIELDS[0]}"
        local NETWORK=${FIELDS[1]}
        local PREFIX=${FIELDS[2]}
        local ORDER=${FIELDS[3]}
        local RANGES=${FIELDS[4]}

        local ID=$(get_addrpool_id ${NAME})
        if [ -z "${ID}" ]; then
            log_command "system addrpool-add ${NAME} ${NETWORK} ${PREFIX} --order ${ORDER} --ranges ${RANGES}"
        fi

    done

    return 0
}


## Associate data address pools to data interfaces
function setup_data_address_pools_on_interface {
    local NODE=$1
    local IFNAME=$2
    local POOLS=$3
    local IPV4_MODE=""
    local IPV6_MODE=""

    for POOL in ${POOLS}; do
        local FIELDS=(${POOL//|/ })
        local NAME="group${GROUPNO}-${FIELDS[0]}"
        local NETWORK=${FIELDS[1]}

        RET=0
        set +e
        is_ipv4 ${NETWORK}
        IS_IPV4=$?
        set -e

        if [ ${IS_IPV4} -eq 1 ]; then
            IPV4_MODE=$(get_interface_ipv4_mode ${NODE} ${IFNAME})
            if [ "${IPV4_MODE}" != "pool" ]; then
                log_command "system host-if-modify ${NODE} ${IFNAME} --ipv4-mode=pool --ipv4-pool=${NAME}"
                RET=$?
            fi
        else
            IPV6_MODE=$(get_interface_ipv6_mode ${NODE} ${IFNAME})
            if [ "${IPV6_MODE}" != "static" ]; then
                log_command "system host-if-modify ${NODE} ${IFNAME} --ipv6-mode=pool --ipv6-pool=${NAME}"
                RET=$?
            fi
        fi

        if [ ${RET} -ne 0 ]; then
            echo "Failed to set addressing mode to pool on ${NODE}:${IFNAME}"
            return ${RET}
        fi

    done

    return 0
}


## Setup data interface IP addresses and routes on all worker nodes
##
function add_data_addresses_and_routes {
    local NODE=""
    local ID=""

    VXLAN_PNETS=$(system ${REGION_OPTION} datanetwork-list | grep group${GROUPNO} | grep vxlan | awk '{print $4}')
    if [ -z "${VXLAN_PNETS}" ]; then
        ## No VXLAN provider networks exist; nothing to do
        return 0
    fi

    debug "found VXLAN provider networks: ${VXLAN_PNETS}"

    for NODE in ${NODES}; do
        ## Process all worker nodes

        if is_stage_complete "addresses" ${NODE}; then
            info "Skipping interface address configuration for ${NODE}; already done"
            continue
        fi

        info "Adding IP addresses and routes to data interfaces on ${NODE}"

        IFACES=$(system host-if-list ${NODE} ${CLI_NOWRAP} | grep -E "[a-z0-9]{8}-" | sed -e 's/[ \t]*//g' | awk -F\| '{printf "%s|%s\n", $3, $11}')

        info "Adding addresses: interfaces ${IFACES}"

        for ENTRY in ${IFACES}; do
            ## Look at all interfaces that have provider networks
            DATA=(${ENTRY//|/ })
            IFNAME=${DATA[0]}
            PNETS=${DATA[1]}

            if [ "${PNETS}" == "None" ]; then
                info "Adding PNETS  None: PNETS ${PNETS}"
                continue
            fi

            ## Lookup the pool(s) associated to this interface
            set +u
            VARNAME=${IFNAME^^}_IPPOOLS
            IPPOOLS=${!VARNAME}
            set -u
            if [ ! -z "${IPPOOLS}" ]; then
                setup_data_address_pools "${IPPOOLS}"
                RET=$?
                if [ ${RET} -ne 0 ]; then
                    return ${RET}
                fi
            fi

            ## This one has provider networks but exclude it if it doesn't have
            ## any VXLAN provider networks.
            for PNET in ${VXLAN_PNETS}; do
                if [[ "${PNETS}" != *"${PNET}"* ]]; then
                    ## This interface has no VXLAN provider networks
                    continue
                fi

                IPADDRS=$(get_node_variable ${NODE} ${IFNAME^^}_IPADDRS)
                if [ -z "${IPADDRS}" -a -z "${IPPOOLS}" ]; then
                    echo "No IP addresses defined for ${IFNAME} on ${NODE}"
                    return 1
                fi

                if [ ! -z "${IPADDRS}" ]; then
                    setup_data_addresses ${NODE} ${IFNAME} ${IPADDRS}
                    RET=$?
                    if [ ${RET} -ne 0 ]; then
                        return ${RET}
                    fi
                elif [ ! -z "${IPPOOLS}" ]; then
                    setup_data_address_pools_on_interface ${NODE} ${IFNAME} "${IPPOOLS}"
                    RET=$?
                    if [ ${RET} -ne 0 ]; then
                        return ${RET}
                    fi
                fi

                IPROUTES=$(get_node_variable ${NODE} ${IFNAME^^}_IPROUTES)
                if [ -z "${IPROUTES}" ]; then
                    ## routes are optional
                    continue
                fi

                setup_data_routes ${NODE} ${IFNAME} ${IPROUTES}
                RET=$?
                if [ ${RET} -ne 0 ]; then
                    return ${RET}
                fi

                ## Do not repeat if there are multiple VXLAN datanetworks on
                ## this interface.
                break
            done
        done

        stage_complete "addresses" ${NODE}

    done

    return 0
}

## Setup custom firewall rules
##
function setup_custom_firewall_rules {
    source ${OPENRC}

    if is_stage_complete "firewall_rules"; then
        info "Skipping custom firewall rules; already done"
        return 0
    fi

    info "Adding custom firewall rules"
    log_command "system firewall-rules-install ${FIREWALL_RULES_FILE}"
    RET=$?
    if [ ${RET} -ne 0 ]; then
        echo "Failed to install custom firewall rules ret=${RET}"
        return ${RET}
    fi

    stage_complete "firewall_rules"
    return 0
}

## Setup board management configuration for all nodes
##
function add_board_management {
    if [ "x${BM_ENABLED}" != "xyes" ]; then
        return 0
    fi

    if is_stage_complete "bmc"; then
        info "Skipping board management configuration; already done"
        return 0
    fi

    info "Adding board management config on all nodes"

    ALL_NODES=$(system host-list ${CLI_NOWRAP} | awk '{if ($6=="worker" || $6=="controller") print $4;}')
    for NODE in ${ALL_NODES} ${STORAGE_NODES}; do
        STATE=$(system host-show ${NODE} | grep administrative | awk '{print $4}')
        if [ "x${STATE}" != "xlocked" ]; then
            log_warning "Node ${NODE} not locked; cannot set board management configuration"
            continue
        fi

        MACADDR=$(get_node_variable ${NODE} BM_MACADDR)
        if [ -z "${MACADDR}" ]; then
            ## not configured on this node
            continue
        fi

        USERNAME=$(get_node_variable ${NODE} BM_USERNAME)
        PASSWORD=$(get_node_variable ${NODE} BM_PASSWORD)
        if [ -z "${USERNAME}" -o -z "${PASSWORD}" ]; then
            log "Configuration for ${NODE} missing BM username and/or password"
            continue
        fi

        TYPE=$(get_node_variable ${NODE} BM_TYPE)
        if [ -z "${TYPE}" ]; then
            log "Configuration for ${NODE} missing BM type"
            continue
        fi

        log_command "system host-update ${NODE} bm_mac=${MACADDR} bm_type=${TYPE} bm_username=${USERNAME} bm_password=${PASSWORD}"
        RET=$?
        if [ ${RET} -ne 0 ]; then
            echo "Failed to set BM MAC, Type, Username, Password on ${NODE}, ret=${RET}"
            return ${RET}
        fi

    done

    stage_complete "bmc"

    return 0
}


## Setup vswitch CPUs on worker nodes
##
function setup_vswitch_cpus {
    for NODE in ${NODES}; do
        if is_stage_complete "vswitch_cpus" ${NODE}; then
            info "Skipping vswitch CPU configuration for ${NODE}; already done"
            continue
        fi

        info "Adding vswitch CPU config on ${NODE}"

        DATA=($(system host-show ${NODE} | grep -E "personality|administrative" | awk '{print $4}'))
        STATE=${DATA[0]}
        PERSONALITY=${DATA[1]}
        if [ "x${PERSONALITY}" == "xworker" -a "x${STATE}" != "xlocked" ]; then
            log_warning "Node ${NODE} not locked; cannot set vswitch CPU configuration"
            continue
        fi

        # Use the supplied PCPU mapping, otherwise configure against the default numa node
        PCPU_MAP=$(get_node_variable ${NODE} VSWITCH_PCPU_MAP)
        if [ -z "${PCPU_MAP}" ]; then
            PCPU_MAP="0:$(get_node_variable ${NODE} VSWITCH_PCPU)"
        fi

        PCPU_ARRAY=(${PCPU_MAP//,/ })
        for PCPU in ${PCPU_ARRAY[@]}; do
            ARRAY=(${PCPU//:/ })
            NUMA=${ARRAY[0]}
            REQUIRED=${ARRAY[1]}

            CURRENT=$(system host-cpu-list ${NODE} |grep vSwitch | awk -v numa="$NUMA" '$6==numa { ++count } BEGIN { count=0 } END { print count }')

            if [ ${CURRENT} -ne ${REQUIRED} ]; then
                log_command "system host-cpu-modify ${NODE} -f vswitch -p${NUMA} ${REQUIRED}"
            fi
        done

        stage_complete "vswitch_cpus" ${NODE}
    done

    return 0
}

function wait_for_drbd_resize {
    DELAY=0

    while [ $DELAY -lt ${FS_RESIZE_TIMEOUT} ]; do
        log_command "system controllerfs-list"
        FS=$(system controllerfs-list ${CLI_NOWRAP} | grep drbd_fs_resizing_in_progress | awk '{print $4}')
        if [ -n "${FS}" ]; then
            log "Waiting for resizing to be done for filesystem $FS"
            sleep 5
            DELAY=$((DELAY + 5))
        else
            # Only three possible states: drbd_fs_resizing_in_progress, available, None
            # When state is "available" or "None", it means resizing is done.
            log "Done resizing controller filesystems"
            return 0
        fi
    done

    info "Timed out waiting for drbd resizing"
    echo -e "system controllerfs-list\n $(system controllerfs-list)"
    echo -e "drbd-overview\n $(drbd-overview)"
    return 1
}

function wait_for_drbd_sync {
    DELAY=0

    while [ $DELAY -lt ${DRBD_SYNC_TIMEOUT} ]; do
        log_command "drbd-overview"
        STATE=$(drbd-overview |  grep sync\'ed  |  awk '{print $1}')
        # When drbd is syncing the standby node becomes degraded
        if [ "${STATE}" ]; then
            log "Waiting for drbd syncing to be done"
            sleep 5
            DELAY=$((DELAY + 5))
        else
            log "Done drbd sync"
            return 0
        fi
    done

    info "Timed out waiting for drbd sync"
    echo -e "system controllerfs-list\n $(system controllerfs-list)"
    echo -e "drbd-overview\n $(drbd-overview)"
    return 1
}

function wait_for_controller_degrade_to_clear {
    DELAY=0

    while [ $DELAY -lt ${FS_RESIZE_DEGRADE_TIMEOUT} ]; do
        log_command "system host-list"
        STATE=$(system host-list ${CLI_NOWRAP} | grep controller | grep degraded | awk '{print $2}')
        if [ "${STATE}" ]; then
            log "Waiting for degrade to clear on controllers"
            sleep 5
            DELAY=$((DELAY + 5))
        else
            log "Controllers degraded state cleared"
            return 0
        fi
    done

    info "Timed out waiting for degrade to clear on controllers"
    return 1
}

## Resize following file systems from default to desired size:
## database, image, backup, img-conversions
##
function resize_controller_filesystem {
    info "Resizing controller filesystems ..."

    if is_stage_complete "resize_fs"; then
        info "Skipping controller file systems resize; already done"
        return 0
    fi

    ## For AIO-DX and standard lab, wait until 2nd controller is unlocked/available
    ## to do the resizing; otherwise controllerfs-modify will fail
    if [ -z "${AVAIL_CONTROLLER_NODES}" -a "${SYSTEM_MODE}" != "simplex" ]; then
        info "WARNING:"
        info "Following controller file systems, database, image, backup, img-conversions "
        info "have default settings.  Rerun this command after both controllers are in "
        info "unlocked/available state if their original sizes are required."
        return 0
    fi

    source ${OPENRC}
    local -i DEFAULT_DATABASE_FS_SIZE=$(system controllerfs-show database | grep size | awk '{print $4}')
    local -i DEFAULT_IMAGE_FS_SIZE=$(system controllerfs-show glance | grep size | awk '{print $4}')
    local -i DEFAULT_BACKUP_FS_SIZE=$(system controllerfs-show backup | grep size | awk '{print $4}')
    local -i DEFAULT_IMG_CONVERSIONS_FS_SIZE=$(system controllerfs-show img-conversions | grep size | awk '{print $4}')

    local cmd="system controllerfs-modify "
    local args=""

    if [ "${DEFAULT_BACKUP_FS_SIZE}" -ne 0 -a "${DEFAULT_BACKUP_FS_SIZE}" -lt "${BACKUP_FS_SIZE}" ]; then
        args+="backup=${BACKUP_FS_SIZE} "
    fi

    if [ -n "${DEFAULT_IMG_CONVERSIONS_FS_SIZE}" -a "${DEFAULT_IMG_CONVERSIONS_FS_SIZE}" -lt "${IMG_CONVERSIONS_FS_SIZE}" ]; then
        args+="img-conversions=${IMG_CONVERSIONS_FS_SIZE} "
    fi

    DRBD=0
    # Resize the drbd file systems if needed
    if [ "${DEFAULT_DATABASE_FS_SIZE}" -ne 0 -a "${DEFAULT_DATABASE_FS_SIZE}" -lt "${DATABASE_FS_SIZE}" ]; then
        args+="database=${DATABASE_FS_SIZE} "
        DRBD=$((DRBD + 1))
    fi

    # Resize the drbd file systems if needed
    if [ "${CONFIGURE_STORAGE_LVM}" == "yes" ]; then
        if [ "${DEFAULT_IMAGE_FS_SIZE}" -ne 0 -a "${DEFAULT_IMAGE_FS_SIZE}" -lt "${IMAGE_FS_SIZE}" ]; then
            args+="glance=${IMAGE_FS_SIZE} "
            DRBD=$((DRBD + 1))
        fi
    fi

    # No need to resize
    if [ -z "${args}" ]; then
        log "No need to resize file systems"
        stage_complete "resize_fs"
        return 0
    fi

    log_command "${cmd} ${args}"

    info "Resizing controller filesystems ..."

    if [ "${DRBD}" -ne 0 ]; then
        # Wait till the drdb resizing is done before proceeding
        wait_for_drbd_resize
        RET=$?
        if [ ${RET} -ne 0 ]; then
            info "Failed drbd resize for the database filesystem"
            log_command "system controllerfs-list"
            log_command "drbd-overview"
            return 1
        fi

        # Wait till the drdb sync is done before proceeding
        wait_for_drbd_sync
        RET=$?
        if [ ${RET} -ne 0 ]; then
            info "Timed-out drbd sync for the database filesystem"
            log_command "system controllerfs-list"
            log_command "drbd-overview"
            return 1
        fi

        # Wait till the controllers are available before proceeding with the next resize
        wait_for_controller_degrade_to_clear
        RET=$?
        if [ ${RET} -ne 0 ]; then
            info "Timed-out clearing degraded state for controllers"
            log_command "system controllerfs-list"
            log_command "drbd-overview"
            return 1
        fi
    fi

    info "Done resizing controller filesystems"
    log_command "system controllerfs-list"
    log_command "drbd-overview"

    stage_complete "resize_fs"
    return 0
}

## Setup Additional Ceph Storage Tiers
##
function setup_ceph_storage_tiers {
    if is_stage_complete "ceph_storage_tiers"; then
        info "Skipping creation of ceph storage tiers; already done"
        continue
    fi

    if [ -z "${STORAGE_TIERS_CEPH}" ]; then
        stage_complete "ceph_storage_tiers"
        return 0
    fi

    info "Adding additional ceph storage tiers"

    local TIER_ARRAY=(${STORAGE_TIERS_CEPH//|/ })
    for TINDEX in ${!TIER_ARRAY[@]}; do
        local TIER_UUID=$(system storage-tier-list ceph_cluster ${CLI_NOWRAP} | grep ${TIER_ARRAY[${TINDEX}]} | awk '{print $2}')
        if [ "${TIER_UUID}" == "" ]; then
            # Add the storage tier
            log_command "system storage-tier-add ceph_cluster ${TIER_ARRAY[${TINDEX}]}"
        else
            info "Skipping adding storage tier ${TIER_ARRAY[${TINDEX}]}; already exists"
        fi
    done

    stage_complete "ceph_storage_tiers"

    return 0
}

## Setup Additional Ceph Backends
##
function setup_ceph_storage_tier_backends {
    if is_stage_complete "ceph_storage_tier_backends"; then
        info "Skipping creation of additional ceph storage backends; already done"
        continue
    fi

    if [ -z "${STORAGE_TIERS_CEPH}" ]; then
        stage_complete "ceph_storage_tier_backends"
        return 0
    fi

    info "Adding additional ceph storage tier backends"

    local TIER_ARRAY=(${STORAGE_TIERS_CEPH//|/ })
    for TINDEX in ${!TIER_ARRAY[@]}; do
        local TIER_UUID=$(system storage-tier-list ceph_cluster ${CLI_NOWRAP} | grep ${TIER_ARRAY[${TINDEX}]} | awk '{print $2}')
        if [ "${TIER_UUID}" == "" ]; then
            echo "Error adding storage backend for ${TIER_ARRAY[${TINDEX}]}; tier is missing"
            return 1
        else
            local BACKEND_UUID=$(system storage-backend-list ${CLI_NOWRAP} | grep "${TIER_ARRAY[${TINDEX}]}-store" | awk '{print $2}')
            if [ "${BACKEND_UUID}" == "" ]; then
                log_command "system storage-backend-add --services cinder --name ${TIER_ARRAY[${TINDEX}]}-store -t $TIER_UUID ceph"

                # Wait for the backend to be applied
                wait_for_backend_configuration ceph "${TIER_ARRAY[${TINDEX}]}-store"
                RET=$?
                if [ ${RET} -ne 0 ]; then
                    exit ${RET}
                fi
            else
                info "Skipping adding storage backend for ${TIER_ARRAY[${TINDEX}]}; already exists"
            fi
        fi
    done

    stage_complete "ceph_storage_tier_backends"

    return 0
}

## Setup Journal devices for storage nodes
##
function setup_journal_storage {
    for NODE in ${STORAGE_NODES}; do
        if is_stage_complete "journals" ${NODE}; then
            info "Skipping creation of journal stors for ${NODE}; already done"
            continue
        fi

        local JOURNAL_DEVICES=$(get_node_variable ${NODE} JOURNAL_DEVICES)
        if [ -z "${JOURNAL_DEVICES}" ]; then
            stage_complete "journals" ${NODE}
            continue
        fi

        info "Adding journal stors on ${NODE}"

        DISKS=$(system host-disk-list ${NODE} ${CLI_NOWRAP})
        STORS=$(system host-stor-list ${NODE} ${CLI_NOWRAP})

        for DEVNAME in ${JOURNAL_DEVICES}; do
            DISKID=$(echo "$DISKS" | grep ${DEVNAME} | awk '{print $2}')
            if [ -z "${DISKID}" ]; then
                echo "No device named ${DEVNAME} on ${NODE}"
                return 1
            fi

            STORID=$(echo "${STORS}" | grep ${DISKID} | awk '{print $2}')
            if [ -z "${STORID}" ]; then
                log_command "system host-stor-add ${NODE} journal ${DISKID}"
            fi
        done

        stage_complete "journals" ${NODE}
    done

    return 0
}

## Setup OSD storage for storage nodes
##
function setup_osd_storage {
    ##OSD can be only added to storage nodes when controller-1 is available
    if [ -z "${AVAIL_CONTROLLER_NODES}" ]; then
        local ALL_NODES=$(system host-list ${CLI_NOWRAP} | awk '{if ($6=="controller" && ($12 != "offline")) print $4;}')
    else
            local ALL_NODES=$(system host-list ${CLI_NOWRAP} | awk '{if (($6=="controller" || $6=="storage") && ($12 != "offline")) print $4;}')
    fi

    for NODE in ${ALL_NODES}; do
        if is_stage_complete "osd" ${NODE}; then
            info "Skipping addition of OSDs on ${NODE}"
            continue
        fi

        if [[ "${SMALL_SYSTEM}" != "yes" && $NODE == *"controller"* ]]; then
            continue
        fi

        local OSD_DEVICES=$(get_node_variable ${NODE} OSD_DEVICES)
        if [ -z "${OSD_DEVICES}" ]; then
            stage_complete "osd" ${NODE}
            continue
        fi

        info "Adding OSD volumes on ${NODE}"

        # Validate config
        for DEV_CFG_STR in ${OSD_DEVICES}; do
            local DEV_CFG_ARRAY=(${DEV_CFG_STR//|/ })
            if [ ${#DEV_CFG_ARRAY[@]} -gt 4 ]; then
                echo "Journal settings for host ${NODE} has an invalid format: Incorrect number of fields"
                echo "     ${DEV_CFG_STR}"
                return 2
            fi
        done

        TIERS=$(system storage-tier-list ceph_cluster ${CLI_NOWRAP})
        DISKS=$(system host-disk-list ${NODE} ${CLI_NOWRAP})
        STORS=$(system host-stor-list ${NODE} ${CLI_NOWRAP})

        for DEV_CFG_STR in ${OSD_DEVICES}; do
            local DEV_CFG_ARRAY=(${DEV_CFG_STR//|/ })

            DISKID=$(echo "${DISKS}" | grep ${DEV_CFG_ARRAY[0]} | awk '{print $2}')
            if [ -z "${DISKID}" ]; then
                echo "No device named ${DEV_CFG_ARRAY[0]} on ${NODE}"
                return 1
            fi

            TIERID=$(echo "${TIERS}" | grep ${DEV_CFG_ARRAY[1]} | awk '{print $2}')
            if [ -z "${TIERID}" ]; then
                echo "No storage tier named ${DEV_CFG_ARRAY[1]} present in the cluster"
                return 1
            fi

            STORID=$(echo "${STORS}" | grep ${DISKID} | awk '{print $2}')
            if [ -z "${STORID}" ]; then
                CMD="system host-stor-add ${NODE} osd ${DISKID} --tier-uuid ${TIERID}"
                if [ ${#DEV_CFG_ARRAY[@]} -gt 2 ]; then
                    CMD="$CMD --journal-size ${DEV_CFG_ARRAY[1]}"
                fi
                if [ ${#DEV_CFG_ARRAY[@]} -gt 3 ]; then
                    JOURNAL_DISK=$(echo "${DISKS}" | grep ${DEV_CFG_ARRAY[2]} | awk '{print $2}')
                    JOURNAL_STOR=$(echo "${STORS}" | grep ${JOURNAL_DISK} | awk '{print $2}')
                    CMD="${CMD} --journal-location ${JOURNAL_STOR}"
                fi
                log_command "${CMD}"
            fi
        done

        stage_complete "osd" ${NODE}
    done

    return 0
}


## Setup profiles band apply them.  This steps exists purely to test
## this functionality to make sure that it is tested as frequently as
## possible.  Applying a profile to the same node that was used to generate it
## should produce the exact same configuration.
##
function add_system_profiles {
    for NODE in ${NODES} ${STORAGE_NODES}; do

        if is_stage_complete "profiles" ${NODE}; then
            info "Skipping system profile creation for ${NODE}; already done"
            continue
        fi

        info "Adding and applying system profiles for ${NODE}"

        PROFILE="ifprofile-${NODE}"
        ID=$(get_ifprofile_id ${PROFILE})
        if [ -z "${ID}" ]; then
            log_command "system ifprofile-add ${PROFILE} ${NODE}"
            log_command "system host-apply-ifprofile ${NODE} ${PROFILE}"
        fi

        if [[ "${NODE}" == *"worker"* ]]; then
            PROFILE="cpuprofile-${NODE}"
            ID=$(get_cpuprofile_id ${PROFILE})
            if [ -z "${ID}" ]; then
                log_command "system cpuprofile-add ${PROFILE} ${NODE}"
                log_command "system host-apply-cpuprofile ${NODE} ${PROFILE}"
            fi

        elif [[ "${NODE}" == *"storage"* ]]; then
            PROFILE="storprofile-${NODE}"
            ID=$(get_storprofile_id ${PROFILE})
            if [ -z "${ID}" ]; then
                log_command "system storprofile-add ${PROFILE} ${NODE}"
                ## We only support applying profiles to a newly installed board
                ##log_command "system host-apply-storprofile ${NODE} ${PROFILE}"
            fi
        fi

        stage_complete "profiles" ${NODE}
    done

    return 0
}


## Setup common shared networking resources
##
function setup_internal_networks {
    local TRANSPARENT_ARGS=""
    local TRANSPARENT_INTERNAL_ARGS=""
    local DHCPARGS=""
    local VLANARGS=""
    local PORT_SECURITY_ARGS=""
    local QOS_ARGS=""
    local VLANID=0
    local LIMIT=0
    local COUNT=0
    local NET=0
    local ID=""

    if is_stage_complete "internal_networks"; then
        info "Skipping shared internal networks configuration; already done"
        return 0
    fi

    if [ "$K8S_ENABLED" == "yes" ]; then
        unset OS_AUTH_URL
        export OS_AUTH_URL=${K8S_URL}
    fi

    info "Adding shared internal networks"

    if [ "x${INTERNALNET_DHCP}" != "xyes" ]; then
        DHCPARGS="--no-dhcp"
    fi

    if [ "${NEUTRON_PORT_SECURITY}" == "True" ]; then
            PORT_SECURITY_ARGS="--enable-port-security"
    fi

    if [ "${NEUTRON_PORT_SECURITY}" == "False" ]; then
            PORT_SECURITY_ARGS="--disable-port-security"
    fi

    if [ "${VSWITCH_TYPE}" == "avs" ]; then
        QOS_ARGS="--wrs-tm:qos $(get_qos_id ${EXTERNALQOS})"
    fi

    ## Setup the shared external network
    EXTERNAL_PROVIDER=$(get_external_provider_network)
    ID=$(get_network_id ${EXTERNALNET})
    if [ -z "${ID}" ]; then
        log_command "openstack ${REGION_OPTION} network create --project ${ADMINID} ${EXTERNAL_PROVIDER} --share --external ${EXTERNALNET} ${QOS_ARGS} ${PORT_SECURITY_ARGS}"
    fi

    ID=$(get_subnet_id ${EXTERNALSUBNET})
    if [ -z "${ID}" ]; then
        log_command "openstack ${REGION_OPTION} subnet create --project ${ADMINID} ${EXTERNALSUBNET} --gateway ${EXTERNALGWIP} --no-dhcp --network ${EXTERNALNET} --subnet-range ${EXTERNALCIDR} --ip-version ${EXTIPVERSION}"
    fi

    if [ "${SHARED_TENANT_NETWORKS}" == "yes" -o "${EXTRA_NICS}" != "yes" ]; then
        ## Internal networks are not required since VM instances will be
        ## directly connected to tenant data networks see comment describing
        ## the use of this variable.
        stage_complete "internal_networks"
        return 0
    fi

    LIMIT=$((NETCOUNT - 1))
    if [ "x${REUSE_NETWORKS}" == "xyes" ]; then
        ## Only create a single internal network
        LIMIT=1
    fi

    if [ "${FIRSTVLANID}" -ne "0" ]; then
        INTERNALNETNAME=${INTERNALNET}${NET}
        INTERNALSUBNETNAME=${INTERNALSUBNET}${NET}
            INTERNALSUBNETNAME=${INTERNALSUBNET}${NET}-${VLANID}

        INTERNALNETID=$(get_network_id ${INTERNALNETNAME})
        if [ -z "${INTERNALNETID}" ]; then
            INTERNAL_PROVIDER=$(get_internal_provider_network 0)
            log_command "openstack ${REGION_OPTION} network create --project ${ADMINID} ${INTERNAL_PROVIDER} --share ${INTERNALNETNAME} ${QOS_ARGS} ${TRANSPARENT_INTERNAL_ARGS}"
        fi
    fi

    ## Setup the shared internal network(s)
    local QOS_ARGS=""
    if [ "${VSWITCH_TYPE}" == "avs" ]; then
        QOS_ARGS="--wrs-tm:qos $(get_qos_id ${INTERNALQOS})"
    fi
    for I in $(seq 0 ${LIMIT}); do
        NET=$((I / ${MAXVLANS}))
        VLANID=$(((I % ${MAXVLANS}) + ${FIRSTVLANID}))

        INTERNALNETNAME=${INTERNALNET}${NET}
        INTERNALSUBNETNAME=${INTERNALSUBNET}${NET}
        if [ ${VLANID} -ne 0 ]; then
            INTERNALNETNAME=${INTERNALNET}${NET}-${VLANID}
            INTERNALSUBNETNAME=${INTERNALSUBNET}${NET}-${VLANID}
        fi

        INTERNALNETID=$(get_network_id ${INTERNALNETNAME})
        if [ -z "${INTERNALNETID}" ]; then
            INTERNAL_PROVIDER=$(get_internal_provider_network ${I})
            log_command "openstack ${REGION_OPTION} network create --project ${ADMINID} ${INTERNAL_PROVIDER} --share ${INTERNALNETNAME} ${QOS_ARGS} ${TRANSPARENT_INTERNAL_ARGS}"
        fi

        SUBNET=10.${I}.${VLANID}
        SUBNETCIDR=${SUBNET}.0/24

        # The VM user data is setup to statically assign addresses to each VM
        # instance so we need to make sure that any dynamic addresses (i.e.,
        # DHCP port addresses, Router addresses) are not in conflict with any
        # addresses that are chosen by this script.  WARNING: the IP addresses
        # set in the user data will not correspond to the IP addresses selected
        # by neutron.  This used to be the case but in Newton we can no longer
        # set the fixed_ip when booting on the internal network because it is
        # shared and owned by the admin.  We would need to create the port
        # ahead of time, let the system pick an address, and then set the user
        # data accordingly.  That's too complicated to do for what we need.
        POOLARGS="--allocation-pool start=${SUBNET}.128,end=${SUBNET}.254"

        ID=$(get_subnet_id ${INTERNALSUBNETNAME})
        if [ -z "${ID}" ]; then
            log_command "openstack ${REGION_OPTION} subnet create --project ${ADMINID} ${INTERNALSUBNETNAME} ${DHCPARGS} ${POOLARGS} --gateway none --network ${INTERNALNETNAME} --subnet-range ${SUBNETCIDR}"
        fi
        COUNT=$((COUNT + 1))
    done

    stage_complete "internal_networks"

    return 0
}


## Setup a management router
##
function setup_management_router {
    local TENANT=$1
    local NAME=$2
    local EXTERNAL_NETWORK=$3
    local DVR_ENABLED=$4
    local EXTERNAL_SNAT=$5
    local TENANTNUM=$6

    ID=$(get_router_id ${NAME})
    if [ -z "${ID}" ]; then
        log_command "openstack ${REGION_OPTION} router create ${NAME}"
    fi

    if [ "x${DVR_ENABLED}" == "xyes" ]; then
        ## Switch to admin context and update the router to be distributed
        source ${OPENRC}
        if [ "$K8S_ENABLED" == "yes" ]; then
            unset OS_AUTH_URL
            export OS_AUTH_URL=${K8S_URL}
        fi

        log_command "openstack ${REGION_OPTION} router set ${NAME} --disable"
        log_command "openstack ${REGION_OPTION} router set ${NAME} --distributed"
    fi

    source ${OPENRC}
    if [ "$K8S_ENABLED" == "yes" ]; then
        unset OS_AUTH_URL
        export OS_AUTH_URL=${K8S_URL}
    fi
    # Neutron will allocate ip addresses non-sequentially so in
    # order for us to get predictable ip addresses for our router gateway
    # interfaces we must set them ourselves. We set it separately because
    # the CLI does not support setting a fixed ip when updating the
    # external_gateway_info dict.
    log_command "openstack ${REGION_OPTION} router set ${NAME} --external-gateway ${EXTERNAL_NETWORK} --fixed-ip ip-address=$(ip_incr ${EXTERNALGWIP} $((TENANTNUM+1)))"

    if [ "x${EXTERNAL_SNAT}" == "xno" ]; then
        ## Switch to admin context and update the router to disable SNAT
        log_command "openstack ${REGION_OPTION} router set ${NAME} --external-gateway ${EXTERNAL_NETWORK} --disable-snat"
    fi

    ## Switch back to tenant context
    source ${HOME}/openrc.${TENANT}

    return 0
}

## Setup a single management subnet
##
function setup_management_subnet {
    local TENANT=$1
    local NETWORK=$2
    local CIDR=$3
    local NAME=$4
    local ROUTER=$5
    local POOL=$6
    local PROVIDERARGS=""
    local DNSARGS=""
    local POOLARGS=""
    local IPARGS=""
    local OWNERARGS=""
    local ELEVATE_CREDENTIALS=""
    local RESTORE_CREDENTIALS=""

    ID=$(get_subnet_id ${NAME})
    if [ ! -z "${ID}" ]; then
        ## already exists
        return 0
    fi

    for NAMESERVER in ${DNSNAMESERVERS}; do
        DNSARGS="${DNSARGS} --dns-nameserver ${NAMESERVER}"
    done

    if [ ! -z "${POOL}" -a "${POOL}" != "none" ]; then
        POOLARRAY=(${POOL//-/ })
        POOLARGS="--allocation-pool start=${POOLARRAY[0]},end=${POOLARRAY[1]}"
    fi

    IPFIELDS=(${CIDR//\// })
    set +e
    is_ipv4 ${IPFIELDS[0]}
    IS_IPV4=$?
    set -e
    if [ ${IS_IPV4} -eq 1 ]; then
        IPARGS="--ip-version=4"
    else
        IPARGS="--ip-version=6 --ipv6-address-mode=${MGMTIPV6ADDRMODE} --ipv6-ra-mode=${MGMTIPV6ADDRMODE}"
    fi

    ${ELEVATE_CREDENTIALS}

    if [ "${OS_USERNAME}" == "admin" ]; then
        OWNERARGS="--project=$(get_tenant_id ${TENANT})"
    fi

    log_command "openstack ${REGION_OPTION} subnet create --network ${NETWORK} --subnet-range ${CIDR} ${NAME} ${OWNERARGS} ${DNSARGS} ${POOLARGS} ${IPARGS}"

    ${RESTORE_CREDENTIALS}

    log_command "openstack ${REGION_OPTION} router add subnet ${ROUTER} ${NAME}"

    return 0
}

## Setup management networks
##
function setup_management_networks {
    local TENANTNUM=0
    local TENANT=""
    local QOS_ARGS=""
    local ID=""

    if is_stage_complete "management_networks"; then
        info "Skipping management networks configuration; already done"
        return 0
    fi

    info "Adding tenant management networks"

    for TENANT in ${TENANTS[@]}; do
        local MGMTQOS="${TENANT}-mgmt-qos"
        local MGMTROUTER="${TENANT}-router"
        source ${HOME}/openrc.${TENANT}

        local EXTERNALNETID=$(get_network_id ${EXTERNALNET})
        if [ -z "${EXTERNALNETID}" ]; then
            echo "Unable to get external network ${EXTERNALNET} for tenant ${TENANT}"
            return 1
        fi

        if [ "${VSWITCH_TYPE}" == "avs" ]; then
            local QOSID=$(get_qos_id ${MGMTQOS})
            if [ -z "${QOSID}" ]; then
                echo "Unable to find QoS resource for ${MGMTQOS} for tenant ${TENANT}"
                return 1
            else
                QOS_ARGS="--wrs-tm:qos ${QOSID}"
            fi
        fi

        for I in $(seq 0 $((MGMTNETS-1))); do
            local MGMTNET=$(get_mgmt_network_name ${TENANT}-mgmt-net ${I})
            local ID=$(get_network_id ${MGMTNET})
            if [ -z "${ID}" ]; then
                log_command "openstack ${REGION_OPTION} network create ${MGMTNET} ${QOS_ARGS}"
            fi
        done

        setup_management_router ${TENANT} ${MGMTROUTER} ${EXTERNALNETID} ${MGMTDVR[${TENANTNUM}]} ${EXTERNALSNAT} ${TENANTNUM}
        RET=$?
        if [ ${RET} -ne 0 ]; then
            echo "Unable to setup mgmt router ${MGMTROUTER} for ${TENANT}"
            return ${RET}
        fi

        SUBNETS=${MGMTSUBNETS[${TENANTNUM}]}
        if [ -z "${SUBNETS}" ]; then
            echo "Unable to find any defined subnets for ${TENANT}"
            return 1
        fi

        TMPSUBNETS=(${SUBNETS//,/ })
        SUBNETS_PER_NETWORK=$((${#TMPSUBNETS[@]} / ${MGMTNETS}))
        REMAINDER=$((${#TMPSUBNETS[@]} % ${MGMTNETS}))
        if [ ${REMAINDER} -ne 0 ]; then
            echo "Number of subnets in SUBNETS must be a multiple of MGMTNETS=${MGMTNETS}"
            return 1
        fi

        COUNT=0
        DATA=(${SUBNETS//,/ })
        for SUBNET in ${DATA[@]}; do
            ARRAY=(${SUBNET//|/ })
            CIDR=${ARRAY[0]}
            set +u
            POOL=${ARRAY[1]}
            set -u

            ## Distribute the subnets evenly across the number of mgmt networks
            NETWORK=$(((COUNT / ${SUBNETS_PER_NETWORK}) % ${MGMTNETS}))
            local MGMTNET=$(get_mgmt_network_name ${TENANT}-mgmt-net ${NETWORK})
            local MGMTSUBNET="${TENANT}-mgmt${NETWORK}-subnet${COUNT}"
            setup_management_subnet ${TENANT} ${MGMTNET} ${CIDR} ${MGMTSUBNET} ${MGMTROUTER} "${POOL}"
            RET=$?
            if [ ${RET} -ne 0 ]; then
                echo "Unable to setup mgmt subnet ${MGMTNET} ${SUBNET} for tenant ${TENANT}"
                return ${RET}
            fi

            COUNT=$((COUNT+1))
        done

        TENANTNUM=$((TENANTNUM + 1))
    done

    stage_complete "management_networks"

    return 0
}


DEDICATED_CPUS="hw:cpu_policy=dedicated"
SHARED_CPUS="hw:cpu_policy=shared"
DPDK_CPU="hw:cpu_model=${DPDK_VCPUMODEL}"

if [ ${SHARED_PCPU} -ne 0 ]; then
    SHARED_VCPU="hw:wrs:shared_vcpu=0"
else
    SHARED_VCPU=""
fi

if [ ${LOW_LATENCY} == "yes" ]; then
    CPU_REALTIME="hw:cpu_realtime=yes"
    CPU_REALTIME_MASK="hw:cpu_realtime_mask=^0"
else
    CPU_REALTIME=""
    CPU_REALTIME_MASK=""
fi

## FIXME:  these are not ported yet
##HEARTBEAT_ENABLED="guest-heartbeat=true"
HEARTBEAT_ENABLED=""

function flavor_create {
    local NAME=$1
    local ID=$2
    local MEM=$3
    local DISK=$4
    local CPU=$5

    shift 5
    local USER_ARGS=$*
    local DEFAULT_ARGS="hw:mem_page_size=2048"

    local X=$(get_flavor_id ${NAME})

    if [ "$K8S_ENABLED" == "yes" ]; then
        unset OS_AUTH_URL
        export OS_AUTH_URL=${K8S_URL}
    fi

    if [ -z "${X}" ]; then
        log_command "nova ${REGION_OPTION} flavor-create ${NAME} ${ID} ${MEM} ${DISK} ${CPU}"
        RET=$?
        if [ ${RET} -ne 0 ]; then
            echo "Failed to create flavor: ${NAME}"
            exit ${RET}
        fi

        log_command "nova ${REGION_OPTION} flavor-key ${NAME} set ${USER_ARGS} ${DEFAULT_ARGS}"
        RET=$?
        if [ ${RET} -ne 0 ]; then
            echo "Failed to set ${NAME} extra specs: ${USER_ARGS} ${DEFAULT_ARGS}"
            exit ${RET}
        fi
    fi

    return 0
}

## Setup flavors
##
function setup_all_flavors {
    local FLAVORS=""
    local FLAVOR=""
    local HB_FLAVOR_SUFFIX=".hb"
    local HB_FLAVOR_ARGS="${DEDICATED_CPUS} ${HEARTBEAT_ENABLED}"
    local DPDK_FLAVOR_SUFFIX=".dpdk"
    local DPDK_FLAVOR_ARGS="${DEDICATED_CPUS} ${SHARED_VCPU} ${DPDK_CPU}"

    local ID=""

    ## Create custom flavors (pinned on any numa node)
    FLAVOR="small"
    flavor_create ${FLAVOR} auto 512 ${IMAGE_SIZE} 1 ${DEDICATED_CPUS}
    flavor_create ${FLAVOR}${HB_FLAVOR_SUFFIX} auto 512 ${IMAGE_SIZE} 1 ${HB_FLAVOR_ARGS}

    FLAVOR="medium"
    flavor_create ${FLAVOR} auto 1024 ${IMAGE_SIZE} 2 ${DEDICATED_CPUS}
    flavor_create ${FLAVOR}${HB_FLAVOR_SUFFIX} auto 1024 ${IMAGE_SIZE} 2 ${HB_FLAVOR_ARGS}
    flavor_create ${FLAVOR}${DPDK_FLAVOR_SUFFIX} auto 1024 ${IMAGE_SIZE} 2 ${DPDK_FLAVOR_ARGS}

    FLAVOR="large"
    flavor_create ${FLAVOR} auto 2048 ${IMAGE_SIZE} 3 ${DEDICATED_CPUS}
    flavor_create ${FLAVOR}${HB_FLAVOR_SUFFIX} auto 2048 ${IMAGE_SIZE} 3 ${HB_FLAVOR_ARGS}
    flavor_create ${FLAVOR}${DPDK_FLAVOR_SUFFIX} auto 2048 ${IMAGE_SIZE} 3 ${DPDK_FLAVOR_ARGS}

    FLAVOR="xlarge"
    flavor_create ${FLAVOR} auto 4096 ${IMAGE_SIZE} 3 ${DEDICATED_CPUS}
    flavor_create ${FLAVOR}${HB_FLAVOR_SUFFIX} auto 4096 ${IMAGE_SIZE} 3 ${HB_FLAVOR_ARGS}
    flavor_create ${FLAVOR}${DPDK_FLAVOR_SUFFIX} auto 4096 ${IMAGE_SIZE} 3 ${DPDK_FLAVOR_ARGS}

    ## Create custom flavors (not pinned to any cpu)
    FLAVOR="small.float"
    flavor_create ${FLAVOR} auto 512 ${IMAGE_SIZE} 1 ${SHARED_CPUS}
    flavor_create ${FLAVOR}${HB_FLAVOR_SUFFIX} auto 512 ${IMAGE_SIZE} 1 ${SHARED_CPUS} ${HEARTBEAT_ENABLED}

    FLAVOR="medium.float"
    flavor_create ${FLAVOR} auto 1024 ${IMAGE_SIZE} 2 ${SHARED_CPUS}
    flavor_create ${FLAVOR}${HB_FLAVOR_SUFFIX} auto 1024 ${IMAGE_SIZE} 2 ${SHARED_CPUS} ${HEARTBEAT_ENABLED}

    FLAVOR="large.float"
    flavor_create ${FLAVOR} auto 2048 ${IMAGE_SIZE} 3 ${SHARED_CPUS}
    flavor_create ${FLAVOR}${HB_FLAVOR_SUFFIX} auto 2048 ${IMAGE_SIZE} 3 ${SHARED_CPUS} ${HEARTBEAT_ENABLED}

    FLAVOR="xlarge.float"
    flavor_create ${FLAVOR} auto 4096 ${IMAGE_SIZE} 3 ${SHARED_CPUS}
    flavor_create ${FLAVOR}${HB_FLAVOR_SUFFIX} auto 4096 ${IMAGE_SIZE} 3 ${SHARED_CPUS} ${HEARTBEAT_ENABLED}

    for NODE in $(seq 0 $((NUMA_NODE_COUNT-1))); do
        ## Create custom flavors (pinned on numa node)
        if [ ${NODE} -eq 0 ]; then
            DPDK_FLAVOR_ARGS="${DEDICATED_CPUS} ${SHARED_VCPU} ${DPDK_CPU}"
        else
            # A VM cannot span Numa nodes so disable the shared vcpu
            DPDK_FLAVOR_ARGS="${DEDICATED_CPUS} ${DPDK_CPU}"
        fi
        PROCESSOR_ARGS="hw:numa_nodes=1 hw:numa_node.0=${NODE}"

        flavor_create "small.node${NODE}" auto 512 ${IMAGE_SIZE} 1 ${DEDICATED_CPUS} ${PROCESSOR_ARGS}
        flavor_create "medium.node${NODE}" auto 1024 ${IMAGE_SIZE} 2 ${DEDICATED_CPUS} ${PROCESSOR_ARGS}
        flavor_create "large.node${NODE}" auto 2048 ${IMAGE_SIZE} 3 ${DEDICATED_CPUS} ${PROCESSOR_ARGS}
        flavor_create "xlarge.node${NODE}" auto 4096 ${IMAGE_SIZE} 3 ${DEDICATED_CPUS} ${PROCESSOR_ARGS}
        flavor_create "medium.dpdk.node${NODE}" auto 1024 ${IMAGE_SIZE} 2 ${DPDK_FLAVOR_ARGS} ${PROCESSOR_ARGS}
        flavor_create "large.dpdk.node${NODE}" auto 2048 ${IMAGE_SIZE} 3 ${DPDK_FLAVOR_ARGS} ${PROCESSOR_ARGS}
        flavor_create "xlarge.dpdk.node${NODE}" auto 4096 ${IMAGE_SIZE} 3 ${DPDK_FLAVOR_ARGS} ${PROCESSOR_ARGS}
    done

    return 0
}


function setup_minimal_flavors {
    local DPDK_FLAVOR_ARGS="${DEDICATED_CPUS} ${SHARED_VCPU} ${DPDK_CPU}"

    flavor_create "small" auto 512 ${IMAGE_SIZE} 1 ${DEDICATED_CPUS}
    flavor_create "medium.dpdk" auto 1024 ${IMAGE_SIZE} 2 ${DPDK_FLAVOR_ARGS}
    flavor_create "small.float" auto 512 ${IMAGE_SIZE} 1 ${SHARED_CPUS}

    return 0
}

function create_custom_flavors {
    local FLAVORLIST=(${FLAVORS})
    local CUSTOM_NAME=""
    local CUSTOM_ID="auto"
    local CUSTOM_CORES=0
    local CUSTOM_MEM=0
    local CUSTOM_DISK=0
    local CUSTOM_DEDICATED=""
    local CUSTOM_HEARTBEAT=""
    local CUSTOM_NUMA0=""
    local CUSTOM_NUMA1=""
    local CUSTOM_NUMA_NODES=""
    local CUSTOM_VCPUMODEL=""
    local CUSTOM_SHARED_CPUS=""
    local CUSTOM_NOVA_STORAGE=""

    if is_stage_complete "custom_flavors"; then
        info "Skipping custom flavors; already done"
        return 0
    fi

    info "Adding custom flavors"

    for INDEX in ${!FLAVORLIST[@]}; do
        ENTRY=${FLAVORLIST[${INDEX}]}
        DATA=(${ENTRY//|/ })
        CUSTOM_NAME=${DATA[0]}
        log "  Adding flavor ${ENTRY}"

        ## Remove the flavor name from the array
        unset DATA[0]
        DATA=(${DATA[@]})

        FLAVOR_NAME=""
        CUSTOM_CORES=1
        CUSTOM_ID="auto"
        CUSTOM_MEM=1024
        CUSTOM_DISK=${IMAGE_SIZE}
        CUSTOM_DEDICATED=""
        CUSTOM_HEARTBEAT=""
        CUSTOM_NUMA0=""
        CUSTOM_NUMA1=""
        CUSTOM_NUMA_NODES=""
        CUSTOM_VCPUMODEL=""
        CUSTOM_SHARED_CPUS=""
        CUSTOM_NOVA_STORAGE=""

        for KEYVALUE in ${DATA[@]}; do
            KEYVAL=(${KEYVALUE//=/ })
            if [ "x${KEYVAL[0]}" == "xdisk" ]; then
                CUSTOM_DISK=${KEYVAL[1]}
            elif [ "x${KEYVAL[0]}" == "xcores" ]; then
                CUSTOM_CORES=${KEYVAL[1]}
            elif [ "x${KEYVAL[0]}" == "xmem" ]; then
                CUSTOM_MEM=${KEYVAL[1]}
            elif [ "x${KEYVAL[0]}" == "xdedicated" ]; then
                CUSTOM_DEDICATED="hw:cpu_policy=dedicated"
            elif [ "x${KEYVAL[0]}" == "xheartbeat" ]; then
                CUSTOM_HEARTBEAT="sw:wrs:guest:heartbeat=True"
            elif [ "x${KEYVAL[0]}" == "xnuma_node.0" ]; then
                CUSTOM_NUMA0="hw:numa_node.0=${KEYVAL[1]}"
            elif [ "x${KEYVAL[0]}" == "xnuma_node.1" ]; then
                CUSTOM_NUMA1="hw:numa_node.0=${KEYVAL[1]}"
            elif [ "x${KEYVAL[0]}" == "xnuma_nodes" ]; then
                CUSTOM_NUMA_NODES="hw:numa_nodes=${KEYVAL[1]}"
            elif [ "x${KEYVAL[0]}" == "xvcpumodel" ]; then
                CUSTOM_VCPUMODEL="hw:cpu_model=${KEYVAL[1]}"
            elif [ "x${KEYVAL[0]}" == "xsharedcpus" ]; then
                CUSTOM_SHARED_CPUS="hw:cpu_policy=shared"
            elif [ "x${KEYVAL[0]}" == "xstorage" ]; then
                CUSTOM_NOVA_STORAGE="aggregate_instance_extra_specs:storage=${KEYVAL[1]}"
            fi
        done

        flavor_create ${CUSTOM_NAME} ${CUSTOM_ID} ${CUSTOM_MEM} ${CUSTOM_DISK} ${CUSTOM_CORES} ${CUSTOM_HEARTBEAT} ${CUSTOM_DEDICATED} ${CUSTOM_VCPUMODEL} ${CUSTOM_SHARED_CPUS} ${CUSTOM_NUMA0} ${CUSTOM_NUMA1} ${CUSTOM_NUMA_NODES} ${CUSTOM_NOVA_STORAGE}
    done

    stage_complete "custom_flavors"

    return 0
}


## Setup flavors
##
function setup_flavors {
    if is_stage_complete "flavors"; then
        info "Skipping flavor configuration; already done"
        return 0
    fi

    info "Adding ${FLAVOR_TYPES} VM flavors"

    if [ "x${FLAVOR_TYPES}" == "xall" ]; then
        setup_all_flavors
        RET=$?
    elif [ "x${FLAVOR_TYPES}" == "xavs" ]; then
        setup_avs_flavors
    else
        setup_minimal_flavors
        RET=$?
    fi

    stage_complete "flavors"

    return ${RET}
}

## Setup keys
##
function setup_keys {
    local PRIVKEY="${HOME}/.ssh/id_rsa"
    local PUBKEY="${PRIVKEY}.pub"
    local KEYNAME=""
    local TENANT=""
    local ID=""

    if is_stage_complete "public_keys"; then
        info "Skipping public key configuration; already done"
        return 0
    fi

    info "Adding VM public keys"

    if [ -f ${HOME}/id_rsa.pub ]; then
        ## Use a user defined public key instead of the local user public key
        ## if one is found in the home directory
        PUBKEY="${HOME}/id_rsa.pub"
    elif [ ! -f ${PRIVKEY} ]; then
        log "Generating new SSH key pair for ${USER}"
        ssh-keygen -q -N "" -f ${PRIVKEY}
        RET=$?
        if [ ${RET} -ne 0 ]; then
                echo "Failed to generate SSH key pair"
            return ${RET}
        fi
    fi

    for TENANT in ${TENANTS[@]}; do
        source ${HOME}/openrc.${TENANT}
        KEYNAME="keypair-${TENANT}"
        ID=`nova ${REGION_OPTION} keypair-list | grep -E ${KEYNAME}[^0-9] | awk '{print $2}'`
        if [ -z "${ID}" ]; then
            log_command "nova ${REGION_OPTION} keypair-add --pub-key ${PUBKEY} ${KEYNAME}"
        fi
    done

    stage_complete "public_keys"

    return 0
}

## Setup floating IP addresses for each tenant
##
function setup_floating_ips {
    local TENANT=""
    local COUNT=0

    if [ "${FLOATING_IP}" != "yes" ]; then
        return 0
    fi

    if is_stage_complete "floating_ips"; then
        info "Skipping floating IP address configuration; already done"
        return 0
    fi

    info "Adding floating IP addresses"

    for TENANT in ${TENANTS[@]}; do
        source ${HOME}/openrc.${TENANT}
        COUNT=$(openstack ${REGION_OPTION} floating ip list | grep -E "[a-zA-Z0-9]{8}-" | wc -l)
        if [ ${COUNT} -ge ${APPCOUNT} ]; then
            continue
        fi
        for I in $(seq 1 $((APPCOUNT - ${COUNT}))); do
            log_command "openstack ${REGION_OPTION} floating ip create ${EXTERNALNET}"
        done
    done

    stage_complete "floating_ips"

    return 0
}

## Create networks for Ixia
##
function setup_ixia_networks {
    local TRANSPARENT_ARGS=""
    local TENANTNUM=0
    local DHCPARGS="--no-dhcp"
    local POOLARGS=""

    if is_stage_complete "ixia_networks"; then
        info "Skipping tenant networks configuration; already done"
        return 0
    fi

    if [ "${ROUTED_TENANT_NETWORKS}" == "no" ]; then
        ## Not required.
        return 0
    fi

    if [ "${SHARED_TENANT_NETWORKS}" == "no" ]; then
        ## Not compatible
        echo "SHARED_TENANT_NETWORKS must be set to \"yes\" for ROUTED_TENANT_NETWORKS"
        return 1
    fi

    info "Adding Ixia networks"

    for TENANT in ${TENANTS[@]}; do
        source ${HOME}/openrc.${TENANT}
        local IXIANET="${TENANT}-ixia-net0"
        local IXIASUBNET="${TENANT}-ixia-subnet0"
        local IXIAROUTER="${TENANT}-ixia0"
        local SUBNET=172.$((16 + ${TENANTNUM} * 2)).0
        local SUBNETCIDR=${SUBNET}.0/24
        local IXIAGWY=${SUBNET}.31

        if [ "${VLAN_TRANSPARENT}" == "True" ]; then
            TRANSPARENT_ARGS="--transparent-vlan"
        fi

        ID=$(get_network_id ${IXIANET})
        if [ -z "${ID}" ]; then
            log_command "openstack ${REGION_OPTION} network create ${IXIANET}"
        fi

        ID=$(get_subnet_id ${IXIASUBNET})
        if [ -z "${ID}" ]; then
            log_command "openstack ${REGION_OPTION} subnet create ${IXIASUBNET} ${DHCPARGS} ${POOLARGS} --network ${IXIANET} --subnet-range ${SUBNETCIDR}"
        fi

        ID=$(get_router_id ${IXIAROUTER})
        if [ -z "${ID}" ]; then
            log_command "openstack ${REGION_OPTION} router create ${IXIAROUTER}"
            log_command "openstack ${REGION_OPTION} router add subnet ${IXIAROUTER} ${IXIASUBNET}"
        fi

        TENANTNUM=$((TENANTNUM + 1))
    done

    stage_complete "ixia_networks"

    return 0
}

## Create networks for tenants
##
function setup_tenant_networks {
    local TRANSPARENT_ARGS=""
    local OWNERSHIP=""
    local PROVIDERARGS=""
    local SHAREDARGS=""
    local DHCPARGS=""
    local PORT_SECURITY_ARGS=""
    local TENANT=""
    local LIMIT=0
    local ID=0
    local TENANTNUM=0

    if is_stage_complete "tenant_networks"; then
        info "Skipping tenant networks configuration; already done"
        return 0
    fi

    info "Adding tenant networks"

    if [ "${EXTRA_NICS}" != "yes" ]; then
        stage_complete "tenant_networks"
        return 0
    fi

    if [ "x${TENANTNET_DHCP}" != "xyes" ]; then
        DHCPARGS="--no-dhcp"
    fi

    if [ "${NEUTRON_PORT_SECURITY}" == "True" ]; then
        PORT_SECURITY_ARGS="--enable-port-security"
    fi

    if [ "${NEUTRON_PORT_SECURITY}" == "False" ]; then
        PORT_SECURITY_ARGS="--disable-port-security"
    fi

    for TENANT in ${TENANTS[@]}; do
        source ${HOME}/openrc.${TENANT}
        local TENANTNET="${TENANT}-net"
        local TENANTSUBNET="${TENANT}-subnet"

        if [ "x${SHARED_TENANT_NETWORKS}" == "xyes" ]; then
            source ${OPENRC}
            OWNERSHIP="--project $(get_tenant_id ${TENANT})"
            SHAREDARGS="--share"
        fi

        LIMIT=$((NETCOUNT - 1))
        if [ "x${REUSE_NETWORKS}" == "xyes" ]; then
            ## Create only a single network
            LIMIT=0
        fi

        for I in $(seq 0 ${LIMIT}); do
            GATEWAYARGS="--gateway none"
            if [ "${ROUTED_TENANT_NETWORKS}" == "yes" ]; then
                SUBNET=172.31.${I}
                SUBNETCIDR=${SUBNET}.0/24
                PEERGWY=${SUBNET}.$((1 + (1 - ${TENANTNUM})))
            else
                SUBNET=172.$((16 + ${TENANTNUM} * 2)).${I}
                SUBNETCIDR=${SUBNET}.0/24
            fi

            # The nova boot commands are setup to statically assign
            # addresses to each VM instance so we need to make sure that
            # any dynamic addresses (i.e., DHCP port addresses) are not in
            # conflict with any addresses that are chosen by this script.
            POOLARGS="--allocation-pool start=${SUBNET}.128,end=${SUBNET}.254"

            TENANTNETID=$(get_network_id ${TENANTNET}${I})
            if [ -z "${TENANTNETID}" ]; then
                log_command "openstack ${REGION_OPTION} network create ${OWNERSHIP} ${SHAREDARGS} ${TENANTNET}${I} ${PORT_SECURITY_ARGS}"
                TENANTNETID=$(get_network_id ${TENANTNET}${I})
            fi

            ID=$(get_subnet_id ${TENANTSUBNET}${I})
            if [ -z "${ID}" ]; then
                log_command "openstack ${REGION_OPTION} subnet create ${OWNERSHIP} ${TENANTSUBNET}${I} ${DHCPARGS} ${POOLARGS} ${GATEWAYARGS} --network ${TENANTNET}${I} --subnet-range ${SUBNETCIDR}"

                if [ "${ROUTED_TENANT_NETWORKS}" == "yes" ]; then
                    log_command "openstack ${REGION_OPTION} router add subnet ${TENANT}-ixia0 ${TENANTSUBNET}${I}"
                    for J in $(seq 1 ${IXIA_PORT_PAIRS}); do
                        ROUTES=""
                        PORT_OFFSET=$(((${J} - 1)*10))
                        IXIAGWY=172.$((16 + ${TENANTNUM} * 2)).0.$((31 + ${PORT_OFFSET}))

                        BASE=$(((100 * (${TENANTNUM} + 1)) + ${PORT_OFFSET}))
                        ROUTES="${ROUTES} --route destination=10.$((BASE + ${I})).0.0/24,gateway=${IXIAGWY}"
                        BASE=$(((100 * ((1 - ${TENANTNUM}) + 1)) + ${PORT_OFFSET}))
                        ROUTES="${ROUTES} --route destination=10.$((BASE + ${I})).0.0/24,gateway=${PEERGWY}"
                        log_command "openstack ${REGION_OPTION} router set ${TENANT}-ixia0 ${ROUTES}"
                    done
                fi
            fi
        done

        TENANTNUM=$((TENANTNUM + 1))
    done

    stage_complete "tenant_networks"

    return 0
}

## Create a per-VM userdata file to setup the layer2 bridge test.  The VM
## will be setup to bridge traffic between its 2nd and 3rd NIC
##
function create_layer2_userdata {
    local VMNAME=$1
    local VMTYPE=$2
    local NETTYPE=$3
    local TENANTNUM=$4
    local NETNUMBER=$5
    local HOSTNUMBER=$6
    local VLANID=$7
    local TENANTMTU=$8
    local INTERNALMTU=$9

    local USERDATA=${USERDATA_DIR}/${VMNAME}_userdata.txt

    BRIDGE_MTU=$(($TENANTMTU < $INTERNALMTU ? $TENANTMTU : $INTERNALMTU))

    if [ "${NETTYPE}" == "kernel" ]; then
        cat << EOF > ${USERDATA}
#wrs-config

FUNCTIONS="bridge,${EXTRA_FUNCTIONS}"
LOW_LATENCY="${LOW_LATENCY}"
BRIDGE_PORTS="${DEFAULT_IF1},${DEFAULT_IF2}.${VLANID}"
BRIDGE_MTU="${BRIDGE_MTU}"
EOF
        sed -i -e "s#\(BRIDGE_PORTS\)=.*#\1=\"${DEFAULT_IF1},${DEFAULT_IF2}.${VLANID}\"#g" ${USERDATA}
        sed -i -e "s#\(FUNCTIONS\)=.*#\1=\"bridge\"#g" ${USERDATA}
    else
        NIC_DEVICE=$(get_guest_nic_device $VMTYPE)

        cat << EOF > ${USERDATA}
#wrs-config

FUNCTIONS="hugepages,vswitch,${EXTRA_FUNCTIONS}"
LOW_LATENCY="${LOW_LATENCY}"
BRIDGE_PORTS="${DEFAULT_IF0},${DEFAULT_IF1}.${VLANID}"
BRIDGE_MTU="${BRIDGE_MTU}"
NIC_DEVICE="${NIC_DEVICE}"
EOF
        if [ ! -z "${VSWITCH_ENGINE_IDLE_DELAY+x}" ]; then
            echo "VSWITCH_ENGINE_IDLE_DELAY=${VSWITCH_ENGINE_IDLE_DELAY}" >> ${USERDATA}
        fi
        if [ ! -z "${VSWITCH_MEM_SIZES+x}" ]; then
            echo "VSWITCH_MEM_SIZES=${VSWITCH_MEM_SIZES}" >> ${USERDATA}
        fi
        if [ ! -z "${VSWITCH_MBUF_POOL_SIZE+x}" ]; then
            echo "VSWITCH_MBUF_POOL_SIZE=${VSWITCH_MBUF_POOL_SIZE}" >> ${USERDATA}
        fi
        if [ ! -z "${VSWITCH_ENGINE_PRIORITY+x}" ]; then
            echo "VSWITCH_ENGINE_PRIORITY=${VSWITCH_ENGINE_PRIORITY}" >> ${USERDATA}
        fi
    fi

    echo ${USERDATA}
    return 0
}

## Create a per-VM userdata file to setup the layer3 routing test.  The VM
## will be setup to route traffic between its 2nd and 3rd NIC according to the
## IP addresses and routes supplied in the ADDRESSES and ROUTES variables.
##
##
function create_layer3_userdata {
    local VMNAME=$1
    local VMTYPE=$2
    local NETTYPE=$3
    local TENANTNUM=$4
    local NETNUMBER=$5
    local HOSTNUMBER=$6
    local VLANID=$7
    local TENANTMTU=$8
    local INTERNALMTU=$9
    local IFNAME1="${DEFAULT_IF1}"
    local IFNAME2="${DEFAULT_IF2}"

    local USERDATA=${USERDATA_DIR}/${VMNAME}_userdata.txt

    if [ "${NETTYPE}" == "kernel" ]; then
        local FUNCTIONS="routing,${EXTRA_FUNCTIONS}"
    elif [ "${NETTYPE}" == "vswitch" ]; then
        local FUNCTIONS="hugepages,avr,${EXTRA_FUNCTIONS}"
        IFNAME1="${DEFAULT_IF0}"
        IFNAME2="${DEFAULT_IF1}"
    else
        echo "layer3 user data for type=${NETTYPE} is not supported"
        exit 1
    fi

    NIC_DEVICE=$(get_guest_nic_device $VMTYPE)

    if [ "0${VLANID}" -ne 0 ]; then
        IFNAME2="${IFNAME2}.${VLANID}"
    fi

    ## Setup static routes between IXIA -> VM0 -> VM1 -> IXIA for 4 Ixia static
    ## subnets and 4 connected interface subnets.
    ##
    ## Static traffic will look like the following where the leading prefix (10)
    ## will increment by 10 based on the HOSTNUMBER variable to allow different
    ## ranges for each VM instance on the network:
    ##    10.160.*.* -> 10.180.*.*
    ##    10.170.*.* -> 10.190.*.*
    ##
    ## Connected interface traffic will look like this:
    ##    172.16.*.* -> 172.18.*.*
    ##    172.19.*.* -> 172.17.*.*
    ##
    ## The gateway addresses will look like this:
    ##    172.16.*.{2,4,6...} -> 172.16.*.{1,3,5...} -> 10.1.*.{1,3,5...} -> +
    ##                                                                       |
    ##    172.18.*.{2,4,6...} <- 172.18.*.{1,3,5...} <- 10.1.*.{2,4,6...} <- +
    ##
    ##
    ##
    PREFIX=$((10 * (1 + ${HOSTNUMBER})))
    MY_HOSTBYTE=$((1 + (${HOSTNUMBER} * 2)))
    IXIA_HOSTBYTE=$((2 + (${HOSTNUMBER} * 2)))

    if [ "${SHARED_TENANT_NETWORKS}" == "yes" ]; then
        # directly connected to both networks, therefore setup local addresses
        # only and no routes for the internal network.
        cat << EOF > ${USERDATA}
#wrs-config

FUNCTIONS=${FUNCTIONS}
LOW_LATENCY="${LOW_LATENCY}"
NIC_DEVICE=${NIC_DEVICE}
ADDRESSES=(
    "172.16.${NETNUMBER}.${MY_HOSTBYTE},255.255.255.0,${IFNAME1},${TENANTMTU}"
    "172.18.${NETNUMBER}.${MY_HOSTBYTE},255.255.255.0,${IFNAME2},${TENANTMTU}"
    )
ROUTES=()
EOF
    elif [ ${TENANTNUM} -eq 0 ]; then
        MY_P2PBYTE=$((1 + (${HOSTNUMBER} * 2)))
        PEER_P2PBYTE=$((2 + (${HOSTNUMBER} * 2)))

        cat << EOF > ${USERDATA}
#wrs-config

FUNCTIONS=${FUNCTIONS}
LOW_LATENCY="${LOW_LATENCY}"
NIC_DEVICE=${NIC_DEVICE}
ADDRESSES=(
    "172.16.${NETNUMBER}.${MY_HOSTBYTE},255.255.255.0,${IFNAME1},${TENANTMTU}"
    "10.1.${NETNUMBER}.${MY_P2PBYTE},255.255.255.0,${IFNAME2},${INTERNALMTU}"
    )
ROUTES=(
    "${PREFIX}.160.${NETNUMBER}.0/24,172.16.${NETNUMBER}.${IXIA_HOSTBYTE},${IFNAME1}"
    "${PREFIX}.170.${NETNUMBER}.0/24,172.16.${NETNUMBER}.${IXIA_HOSTBYTE},${IFNAME1}"
    "${PREFIX}.180.${NETNUMBER}.0/24,10.1.${NETNUMBER}.${PEER_P2PBYTE},${IFNAME2}"
    "${PREFIX}.190.${NETNUMBER}.0/24,10.1.${NETNUMBER}.${PEER_P2PBYTE},${IFNAME2}"
    "172.18.${NETNUMBER}.0/24,10.1.${NETNUMBER}.${PEER_P2PBYTE},${IFNAME2}"
    "172.19.${NETNUMBER}.0/24,10.1.${NETNUMBER}.${PEER_P2PBYTE},${IFNAME2}"
    )
EOF

    else
        MY_P2PBYTE=$((2 + (${HOSTNUMBER} * 2)))
        PEER_P2PBYTE=$((1 + (${HOSTNUMBER} * 2)))

        cat << EOF > ${USERDATA}
#wrs-config

FUNCTIONS=${FUNCTIONS}
LOW_LATENCY="${LOW_LATENCY}"
NIC_DEVICE=${NIC_DEVICE}
ADDRESSES=(
    "172.18.${NETNUMBER}.${MY_HOSTBYTE},255.255.255.0,${IFNAME1},${TENANTMTU}"
    "10.1.${NETNUMBER}.${MY_P2PBYTE},255.255.255.0,${IFNAME2},${INTERNALMTU}"
    )
ROUTES=(
    "${PREFIX}.180.${NETNUMBER}.0/24,172.18.${NETNUMBER}.${IXIA_HOSTBYTE},${IFNAME1}"
    "${PREFIX}.190.${NETNUMBER}.0/24,172.18.${NETNUMBER}.${IXIA_HOSTBYTE},${IFNAME1}"
    "${PREFIX}.160.${NETNUMBER}.0/24,10.1.${NETNUMBER}.${PEER_P2PBYTE},${IFNAME2}"
    "${PREFIX}.170.${NETNUMBER}.0/24,10.1.${NETNUMBER}.${PEER_P2PBYTE},${IFNAME2}"
    "172.16.${NETNUMBER}.0/24,10.1.${NETNUMBER}.${PEER_P2PBYTE},${IFNAME2}"
    "172.17.${NETNUMBER}.0/24,10.1.${NETNUMBER}.${PEER_P2PBYTE},${IFNAME2}"
    )
EOF

    fi

    if [ ! -z "${VSWITCH_ENGINE_IDLE_DELAY+x}" ]; then
        echo "VSWITCH_ENGINE_IDLE_DELAY=${VSWITCH_ENGINE_IDLE_DELAY}" >> ${USERDATA}
    fi
    if [ ! -z "${VSWITCH_MEM_SIZES+x}" ]; then
        echo "VSWITCH_MEM_SIZES=${VSWITCH_MEM_SIZES}" >> ${USERDATA}
    fi
    if [ ! -z "${VSWITCH_MBUF_POOL_SIZE+x}" ]; then
        echo "VSWITCH_MBUF_POOL_SIZE=${VSWITCH_MBUF_POOL_SIZE}" >> ${USERDATA}
    fi
    if [ ! -z "${VSWITCH_ENGINE_PRIORITY+x}" ]; then
        echo "VSWITCH_ENGINE_PRIORITY=${VSWITCH_ENGINE_PRIORITY}" >> ${USERDATA}
    fi

    echo ${USERDATA}
    return 0
}


## Create a per-VM userdata file to setup the layer2 bridge test.  The VM
## will be setup to bridge traffic between its 2nd and 3rd NIC
##
function create_layer2_centos_userdata {
    local VMNAME=$1
    local NETTYPE=$2
    local TENANTNUM=$3
    local NETNUMBER=$4
    local HOSTNUMBER=$5
    local VLANID=$6
    local TENANTMTU=$7
    local INTERNALMTU=$8

    local USERDATA=${USERDATA_DIR}/${VMNAME}_userdata.txt

    # Initially, just worry about enabling login
    # TODO:  Add networking at a later date

    cat << EOF > ${USERDATA}
#cloud-config
chpasswd:
 list: |
   root:root
   centos:centos
 expire: False
ssh_pwauth: True
EOF

    echo ${USERDATA}
    return 0
}

## Create a per-VM userdata file to setup the layer3 routing test.  The VM
## will be setup to route traffic between its 2nd and 3rd NIC according to the
## IP addresses and routes supplied in the ADDRESSES and ROUTES variables.
##
##
function create_layer3_centos_userdata {
    local VMNAME=$1
    local NETTYPE=$2
    local TENANTNUM=$3
    local NETNUMBER=$4
    local HOSTNUMBER=$5
    local VLANID=$6
    local TENANTMTU=$7
    local INTERNALMTU=$8
    local IFNAME1="${DEFAULT_IF1}"
    local IFNAME2="${DEFAULT_IF2}"

    local USERDATA=${USERDATA_DIR}/${VMNAME}_userdata.txt

    # Initially, just worry about enabling login
    # TODO:  Add networking at a later data

    cat << EOF > ${USERDATA}
#cloud-config
chpasswd:
 list: |
   root:root
   centos:centos
 expire: False
ssh_pwauth: True
EOF

    echo ${USERDATA}
    return 0
}

## Create a per-VM userdata file to setup the networking in the guest
## according to the NETWORKING_TYPE variable.
##
function create_userdata {
    local VMNAME=$1
    local VMTYPE=$2
    local NETTYPE=$3
    local TENANTNUM=$4
    local NETNUMBER=$5
    local HOSTNUMBER=$6
    local VLANID=$7
    local TENANTMTU=$8
    local INTERNALMTU=$9
    local IMAGE=$10


    if [ "x${IMAGE}" == "xcentos" -o "x${IMAGE}" == "xcentos_raw" ]; then
        if [ "x${NETWORKING_TYPE}" == "xlayer3" ]; then
            create_layer3_centos_userdata ${VMNAME} ${NETTYPE} ${TENANTNUM} ${NETNUMBER} ${HOSTNUMBER} ${VLANID} ${TENANTMTU} ${INTERNALMTU}
        else
            create_layer2_centos_userdata ${VMNAME} ${NETTYPE} ${TENANTNUM} ${NETNUMBER} ${HOSTNUMBER} ${VLANID} ${TENANTMTU} ${INTERNALMTU}
        fi
    else
        if [ "x${NETWORKING_TYPE}" == "xlayer3" ]; then
            create_layer3_userdata ${VMNAME} ${VMTYPE} ${NETTYPE} ${TENANTNUM} ${NETNUMBER} ${HOSTNUMBER} ${VLANID} ${TENANTMTU} ${INTERNALMTU}
        else
            create_layer2_userdata ${VMNAME} ${VMTYPE} ${NETTYPE} ${TENANTNUM} ${NETNUMBER} ${HOSTNUMBER} ${VLANID} ${TENANTMTU} ${INTERNALMTU}
        fi
    fi

    return $?
}

## Create a per-VM userdata file to setup the layer2 bridge test.  The VM
## will be setup to bridge traffic between its 2nd and 3rd NIC
##
function append_layer2_heat_userdata {
    local VMNAME=$1
    local VMTYPE=$2
    local NETTYPE=$3
    local TENANTNUM=$4
    local NETNUMBER=$5
    local HOSTNUMBER=$6
    local VLANID=$7
    local TENANTMTU=$8
    local INTERNALMTU=$9
    local FILE=$10

    BRIDGE_MTU=$(($TENANTMTU < $INTERNALMTU ? $TENANTMTU : $INTERNALMTU))

    if [ "${NETTYPE}" == "kernel" ]; then
        cat << EOF >> ${FILE}
        user_data_format: 'RAW'
        user_data:
          Fn::Base64:
            Fn::Replace:
            - 'OS::stack_name': {Ref: 'OS::stack_name'}
            - |
              #wrs-config

              FUNCTIONS="bridge,${EXTRA_FUNCTIONS}"
              LOW_LATENCY="${LOW_LATENCY}"
              BRIDGE_PORTS="${DEFAULT_IF1},${DEFAULT_IF2}.${VLANID}"
              BRIDGE_MTU="${BRIDGE_MTU}"
EOF
        sed -i -e "s#\(BRIDGE_PORTS\)=.*#\1=\"${DEFAULT_IF1},${DEFAULT_IF2}.${VLANID}\"#g" ${FILE}
        sed -i -e "s#\(FUNCTIONS\)=.*#\1=\"bridge\"#g" ${FILE}
    else
        NIC_DEVICE=$(get_guest_nic_device $VMTYPE)

        cat << EOF >> ${FILE}
        user_data_format: 'RAW'
        user_data:
          Fn::Base64:
            Fn::Replace:
            - 'OS::stack_name': {Ref: 'OS::stack_name'}
            - |
              #wrs-config

              FUNCTIONS="hugepages,vswitch,${EXTRA_FUNCTIONS}"
              LOW_LATENCY="${LOW_LATENCY}"
              BRIDGE_PORTS="${DEFAULT_IF0},${DEFAULT_IF1}.${VLANID}"
              BRIDGE_MTU="${BRIDGE_MTU}"
              NIC_DEVICE="${NIC_DEVICE}"
EOF
        if [ ! -z "${VSWITCH_ENGINE_IDLE_DELAY+x}" ]; then
            echo "              VSWITCH_ENGINE_IDLE_DELAY=${VSWITCH_ENGINE_IDLE_DELAY}" >> ${FILE}
        fi
        if [ ! -z "${VSWITCH_MEM_SIZES+x}" ]; then
            echo "              VSWITCH_MEM_SIZES=${VSWITCH_MEM_SIZES}" >> ${FILE}
        fi
        if [ ! -z "${VSWITCH_MBUF_POOL_SIZE+x}" ]; then
            echo "              VSWITCH_MBUF_POOL_SIZE=${VSWITCH_MBUF_POOL_SIZE}" >> ${FILE}
        fi
        if [ ! -z "${VSWITCH_ENGINE_PRIORITY+x}" ]; then
            echo "              VSWITCH_ENGINE_PRIORITY=${VSWITCH_ENGINE_PRIORITY}" >> ${FILE}
        fi
    fi

    return 0
}

## Create a per-VM userdata file to setup the layer3 routing test.  The VM
## will be setup to route traffic between its 2nd and 3rd NIC according to the
## IP addresses and routes supplied in the ADDRESSES and ROUTES variables.
##
##
function append_layer3_heat_userdata {
    local VMNAME=$1
    local VMTYPE=$2
    local NETTYPE=$3
    local TENANTNUM=$4
    local NETNUMBER=$5
    local HOSTNUMBER=$6
    local VLANID=$7
    local TENANTMTU=$8
    local INTERNALMTU=$9
    local FILE=$10
    local IFNAME1="${DEFAULT_IF1}"
    local IFNAME2="${DEFAULT_IF2}"

    if [ "${NETTYPE}" == "kernel" ]; then
        local FUNCTIONS="routing,${EXTRA_FUNCTIONS}"
    elif [ "${NETTYPE}" == "vswitch" ]; then
        local FUNCTIONS="hugepages,avr,${EXTRA_FUNCTIONS}"
        IFNAME1="${DEFAULT_IF0}"
        IFNAME2="${DEFAULT_IF1}"
    else
        echo "layer3 user data for type=${NETTYPE} is not supported"
        exit 1
    fi

    NIC_DEVICE=$(get_guest_nic_device $VMTYPE)

    if [ "0${VLANID}" -ne 0 ]; then
        IFNAME2="${IFNAME2}.${VLANID}"
    fi

    ## Setup static routes between IXIA -> VM0 -> VM1 -> IXIA for 4 Ixia static
    ## subnets and 4 connected interface subnets.
    ##
    ## See comment above for detailed explanation
    ##
    PREFIX=$((10 * (1 + ${HOSTNUMBER})))
    MY_HOSTBYTE=$((1 + (${HOSTNUMBER} * 2)))
    IXIA_HOSTBYTE=$((2 + (${HOSTNUMBER} * 2)))

    if [ ${TENANTNUM} -eq 0 ]; then
        MY_P2PBYTE=$((1 + (${HOSTNUMBER} * 2)))
        PEER_P2PBYTE=$((2 + (${HOSTNUMBER} * 2)))

        cat << EOF >> ${FILE}
        user_data_format: 'RAW'
        user_data:
          Fn::Base64:
            Fn::Replace:
            - 'OS::stack_name': {Ref: 'OS::stack_name'}
            - |
              #wrs-config

              FUNCTIONS=${FUNCTIONS}
              LOW_LATENCY="${LOW_LATENCY}"
              NIC_DEVICE=${NIC_DEVICE}
              ADDRESSES=(
                  "172.16.${NETNUMBER}.$((1 + (${HOSTNUMBER} * 2))),255.255.255.0,${IFNAME1},${TENANTMTU}"
                  "10.1.${NETNUMBER}.$((1 + (${HOSTNUMBER} * 2))),255.255.255.0,${IFNAME2},${INTERNALMTU}"
                  )
              ROUTES=(
                  "${PREFIX}.160.${NETNUMBER}.0/24,172.16.${NETNUMBER}.${IXIA_HOSTBYTE},${IFNAME1}"
                  "${PREFIX}.170.${NETNUMBER}.0/24,172.16.${NETNUMBER}.${IXIA_HOSTBYTE},${IFNAME1}"
                  "${PREFIX}.180.${NETNUMBER}.0/24,10.1.${NETNUMBER}.${PEER_P2PBYTE},${IFNAME2}"
                  "${PREFIX}.190.${NETNUMBER}.0/24,10.1.${NETNUMBER}.${PEER_P2PBYTE},${IFNAME2}"
                  "172.18.${NETNUMBER}.0/24,10.1.${NETNUMBER}.${PEER_P2PBYTE},${IFNAME2}"
                  "172.19.${NETNUMBER}.0/24,10.1.${NETNUMBER}.${PEER_P2PBYTE},${IFNAME2}"
                  )
EOF
    else
        MY_P2PBYTE=$((2 + (${HOSTNUMBER} * 2)))
        PEER_P2PBYTE=$((1 + (${HOSTNUMBER} * 2)))

        cat << EOF >> ${FILE}
        user_data_format: 'RAW'
        user_data:
          Fn::Base64:
            Fn::Replace:
            - 'OS::stack_name': {Ref: 'OS::stack_name'}
            - |
              #wrs-config

              FUNCTIONS=${FUNCTIONS}
              LOW_LATENCY="${LOW_LATENCY}"
              NIC_DEVICE=${NIC_DEVICE}
              ADDRESSES=(
                  "172.18.${NETNUMBER}.$((1 + (${HOSTNUMBER} * 2))),255.255.255.0,${IFNAME1},${TENANTMTU}"
                  "10.1.${NETNUMBER}.$((2 + (${HOSTNUMBER} * 2))),255.255.255.0,${IFNAME2},${INTERNALMTU}"
                  )
              ROUTES=(
                  "${PREFIX}.180.${NETNUMBER}.0/24,172.18.${NETNUMBER}.${IXIA_HOSTBYTE},${IFNAME1}"
                  "${PREFIX}.190.${NETNUMBER}.0/24,172.18.${NETNUMBER}.${IXIA_HOSTBYTE},${IFNAME1}"
                  "${PREFIX}.160.${NETNUMBER}.0/24,10.1.${NETNUMBER}.${PEER_P2PBYTE},${IFNAME2}"
                  "${PREFIX}.170.${NETNUMBER}.0/24,10.1.${NETNUMBER}.${PEER_P2PBYTE},${IFNAME2}"
                  "172.16.${NETNUMBER}.0/24,10.1.${NETNUMBER}.${PEER_P2PBYTE},${IFNAME2}"
                  "172.17.${NETNUMBER}.0/24,10.1.${NETNUMBER}.${PEER_P2PBYTE},${IFNAME2}"
                  )
EOF
    fi

    return 0
}


## Create a per-VM userdata file to setup the layer2 bridge test.  The VM
## will be setup to bridge traffic between its 2nd and 3rd NIC
##
function append_layer2_heat_centos_userdata {
    local VMNAME=$1
    local NETTYPE=$2
    local TENANTNUM=$3
    local NETNUMBER=$4
    local HOSTNUMBER=$5
    local VLANID=$6
    local TENANTMTU=$7
    local INTERNALMTU=$8
    local FILE=$9

    # Initially, just worry about enabling login
    # TODO:  Add networking at a later data

    cat << EOF >> ${FILE}
        user_data_format: 'RAW'
        user_data:
          Fn::Base64:
            Fn::Replace:
            - 'OS::stack_name': {Ref: 'OS::stack_name'}
            - |
              #cloud-config
              chpasswd:
               list: |
                 root:root
                 centos:centos
               expire: False
              ssh_pwauth: True
EOF

    return 0
}

## Create a per-VM userdata file to setup the layer3 routing test.  The VM
## will be setup to route traffic between its 2nd and 3rd NIC according to the
## IP addresses and routes supplied in the ADDRESSES and ROUTES variables.
##
##
function append_layer3_heat_centos_userdata {
    local VMNAME=$1
    local NETTYPE=$2
    local TENANTNUM=$3
    local NETNUMBER=$4
    local HOSTNUMBER=$5
    local VLANID=$6
    local TENANTMTU=$7
    local INTERNALMTU=$8
    local FILE=$9
    local IFNAME1="${DEFAULT_IF1}"
    local IFNAME2="${DEFAULT_IF2}"

    # Initially, just worry about enabling login
    # TODO:  Add networking at a later data

    cat << EOF >> ${FILE}
        user_data_format: 'RAW'
        user_data:
          Fn::Base64:
            Fn::Replace:
            - 'OS::stack_name': {Ref: 'OS::stack_name'}
            - |
              #cloud-config
              chpasswd:
               list: |
                 root:root
                 centos:centos
               expire: False
              ssh_pwauth: True
EOF

    return 0
}

## Create a per-VM userdata file to setup the networking in the guest
## according to the NETWORKING_TYPE variable.
##
function append_heat_userdata {
    local VMNAME=$1
    local VMTYPE=$2
    local NETTYPE=$3
    local TENANTNUM=$4
    local NETNUMBER=$5
    local HOSTNUMBER=$6
    local VLANID=$7
    local TENANTMTU=$8
    local INTERNALMTU=$9
    local FILE=$10
    local IMAGE=$11

    if [ "x${IMAGE}" == "xcentos" -o "x${IMAGE}" == "xcentos_raw" ]; then
        if [ "x${NETWORKING_TYPE}" == "xlayer3" ]; then
            append_layer3_heat_centos_userdata ${VMNAME} ${NETTYPE} ${TENANTNUM} ${NETNUMBER} ${HOSTNUMBER} ${VLANID} ${TENANTMTU} ${INTERNALMTU} ${FILE}
        else
            append_layer2_heat_centos_userdata ${VMNAME} ${NETTYPE} ${TENANTNUM} ${NETNUMBER} ${HOSTNUMBER} ${VLANID} ${TENANTMTU} ${INTERNALMTU} ${FILE}
        fi
    else
        if [ "x${NETWORKING_TYPE}" == "xlayer3" ]; then
            append_layer3_heat_userdata ${VMNAME} ${VMTYPE} ${NETTYPE} ${TENANTNUM} ${NETNUMBER} ${HOSTNUMBER} ${VLANID} ${TENANTMTU} ${INTERNALMTU} ${FILE}
        else
            append_layer2_heat_userdata ${VMNAME} ${VMTYPE} ${NETTYPE} ${TENANTNUM} ${NETNUMBER} ${HOSTNUMBER} ${VLANID} ${TENANTMTU} ${INTERNALMTU} ${FILE}
        fi
    fi

    return 0
}

## Setup the image arguments for the nova boot command according to whether
## the user wants to use cinder volumes or glance images.
##
function create_image_args {
    local VMNAME=$1
    local IMAGE=$2
    local BOOT_SOURCE=$3

    if [ "x${BOOT_SOURCE}" == "xglance" ]; then
        echo "--image=${IMAGE}"
    else
        # Added cinder id to launch file so now just use \$CINDER_ID
        echo "--block-device-mapping vda=\${CINDER_ID}:::0"
    fi
    return 0
}

## Create a file to later add boot commands
##
function create_boot_command_file {
    local TENANT=$1
    local VMNAME=$2
    local RESULT=$3
    local FILE=${BOOTDIR}/launch_${VMNAME}.sh

    cat << EOF > ${FILE}
#!/bin/bash
#
source ${HOME}/openrc.${TENANT}
EOF
    chmod 755 ${FILE}

    eval "$RESULT=${FILE}"
    return 0
}

## Create a file to later add yaml statements
##
function create_heat_yaml_file {
    local TENANT=$1
    local VMNAME=$2
    local RESULT=$3
    local FILE=${BOOTDIR}/heat_${VMNAME}.yaml

    cat << EOF > ${FILE}
heat_template_version: 2013-05-23

description: >
    Creates specified VMs from lab_setup.sh

parameters:

resources:

EOF
    chmod 755 ${FILE}

    eval "$RESULT=${FILE}"
    return 0
}

## Add Heat Parameters to a file
##
#function write_heat_parameter_commands
## Add Heat resources to a file
##
function write_heat_resource_commands {
    local VMNAME=${1}
    local VOLNAME=${2}
    local IMAGE=${3}
    local BOOT_SOURCE=${4}
    local SIZE=${5}
    local FLAVOR=${6}
    local FLAVOR_MODIFIER=${7}
    local IP=${8}
    local MGMTNETID=${9}
    local MGMTVIF=${10}
    local TENANTNETID=${11}
    local TENANTVIF=${12}
    local TENANTIP=${13}
    local INTERNALNETID=${14}
    local INTERNALVIF=${15}
    local FILE=${16}

    VMNAME_UNDERSCORES=$(echo "${VMNAME}" | sed -e 's/-/_/g')

    local GLANCE_ID=$(get_glance_id ${IMAGE})
    if [ -z "${GLANCE_ID}" ]; then
        echo "No glance image with name: ${IMAGE}"
        return 1
    fi

    if [ "x${BOOT_SOURCE}" == "xglance" ]; then

        cat << EOF > ${FILE}

   ${VMNAME_UNDERSCORES}:
      type: OS::Nova::Server
      properties:
        name: ${VMNAME}
        flavor: ${FLAVOR}
        image: ${IMAGE}
        networks:
        - {uuid: ${MGMTNETID}, vif-model: ${MGMTVIF} }
        - {uuid: ${TENANTNETID}, fixed_ip: ${TENANTIP}, vif-model: ${TENANTVIF} }
        - {uuid: ${INTERNALNETID}, vif-model: ${INTERNALVIF} }
EOF

    else
        VOLNAME_UNDERSCORES=$(echo "${VOLNAME}" | sed -e 's/-/_/g')

        cat << EOF > ${FILE}

   ${VOLNAME_UNDERSCORES}:
      type: OS::Cinder::Volume
      properties:
        name: heat_vol_${VOLNAME}
        image: ${IMAGE}
        size: ${SIZE}

   ${VMNAME_UNDERSCORES}:
      type: OS::Nova::Server
      properties:
        name: ${VMNAME}
        flavor: ${FLAVOR}
        block_device_mapping:
        - {device_name: vda, volume_id: { get_resource: ${VOLNAME_UNDERSCORES} } }
        networks:
        - {uuid: ${MGMTNETID}, vif-model: ${MGMTVIF} }
        - {uuid: ${TENANTNETID}, fixed_ip: ${TENANTIP}, vif-model: ${TENANTVIF} }
        - {uuid: ${INTERNALNETID}, vif-model: ${INTERNALVIF} }
EOF
    fi

    return 0
}


## Add volume creation to launch file
##
function write_cinder_command {
    local NAME=$1
    local IMAGE=$2
    local SIZE=$3
    local BOOT_SOURCE=$4
    local FILE=$5

    # Don't do anything if using glance instead of cinder
    if [ "x${BOOT_SOURCE}" == "xglance" ]; then
        return 0
    fi

    local GLANCE_ID=$(get_glance_id ${IMAGE})
    if [ -z "${GLANCE_ID}" ]; then
        echo "No glance image with name: ${IMAGE}"
        return 1
    fi

    cat << EOF >> ${FILE}
# Allow disk size override for testing
SIZE=\${3:-${SIZE}}

CINDER_ID=\$(cinder ${REGION_OPTION} list | grep "vol-${NAME} " | awk '{print \$2}')
if [ -z "\${CINDER_ID}" ]; then
    cinder ${REGION_OPTION} create --image-id ${GLANCE_ID} --display-name=vol-${NAME} \${SIZE}
    RET=\$?
    if [ \${RET} -ne 0 ]; then
        echo "Failed to create cinder volume 'vol-${NAME}'"
        exit
    fi

    # Wait up to one minute for the volume to be created
    echo "Creating volume 'vol-${NAME}'"
    DELAY=0
    while [ \$DELAY -lt ${CINDER_TIMEOUT} ]; do
        STATUS=\$(cinder ${REGION_OPTION} show vol-${NAME} 2>/dev/null | awk '{ if (\$2 == "status") {print \$4} }')
        if [ \${STATUS} == "downloading" -o \${STATUS} == "creating" ]; then
            DELAY=\$((DELAY + 5))
            sleep 5
        elif [ \${STATUS} == "available" ]; then
            break
        else
            echo "Volume Create Failed"
            exit
        fi
    done

    if [ \${STATUS} == "available" ]; then
        echo "Volume Created"
    else
        echo "Timed out waiting for volume creation"
    fi
fi
CINDER_ID=\$(cinder ${REGION_OPTION} show vol-${NAME} 2>/dev/null | awk '{ if (\$2 == "id") {print \$4} }')

EOF
    return 0
}

## Append commands to create vlan trunks to boot scripts
##
function write_trunk_commands {
    local FILE=$1
    local INSTANCE=$2
    local INSTANCE_VLANID=$3

        cat << EOF >> ${FILE}
VMNAME=$INSTANCE
NIC_INDEX=0
nova ${REGION_OPTION} show \$VMNAME|grep nic| while read -r NIC; do
    PARENTPORT=\`echo \$NIC|egrep -o '"port_id": "[[:alnum:]-]*"'|egrep -o "[[:alnum:]-]*"|tail -n 1\`
    PARENTMAC=\`echo \$NIC|egrep -o '"mac_address": "[[:alnum:]:]*"'|egrep -o "[[:alnum:]:]*"|tail -n 1\`
    PARENTNETWORK=\`echo \$NIC|egrep -o '"network": "[[:alnum:]-]*"'|egrep -o "[[:alnum:]-]*"|tail -n 1\`

    SUBPORT_INDEX=0
    for VLAN_NETWORK in \`openstack ${REGION_OPTION} network list -c Name|grep "\${PARENTNETWORK}-"\`; do
        VLAN_NETWORK_NAME=\`echo \$VLAN_NETWORK |egrep -o "[[:alnum:]-]*net[[:alnum:]]*-[[:alnum:]]*"\`
        if [ "x\$VLAN_NETWORK_NAME" == "x" ]; then
            continue
        fi
        VLANID=\`echo \$VLAN_NETWORK|egrep -o "\-[0-9]"|tail -n 1|egrep -o "[0-9]"\`
        if [ "\$VLANID" -ne "$INSTANCE_VLANID" ]; then
            continue
        fi
        if [ "\$SUBPORT_INDEX" -eq "0" ]; then
            openstack ${REGION_OPTION} network trunk create \$VMNAME-trunk\$NIC_INDEX --parent-port \$PARENTPORT
        fi
        openstack ${REGION_OPTION} port create --network \$VLAN_NETWORK_NAME \$VMNAME-trunk\$NIC_INDEX-port\$SUBPORT_INDEX
        echo "source /etc/platform/openrc; openstack ${REGION_OPTION} port set \$VMNAME-trunk\$NIC_INDEX-port\$SUBPORT_INDEX --mac-address \$PARENTMAC"|bash
        openstack ${REGION_OPTION} network trunk set \$VMNAME-trunk\$NIC_INDEX --subport port=\$VMNAME-trunk\$NIC_INDEX-port\$SUBPORT_INDEX,segmentation-type=vlan,segmentation-id=\$VLANID
        SUBPORT_INDEX=\$((SUBPORT_INDEX+1))
    done
    NIC_INDEX=\$((NIC_INDEX+1))
done
EOF
}

## Write the bash commands to launch a VM and assign a floating IP
##
function write_boot_command {
    local CMD=$1
    local VMNAME=$2
    local FLAVOR=$3
    local FLAVOR_MODIFIER=$4
    local FIPID=$5
    local FILE=$6
    local VLANID=$7

    cat << EOF >> ${FILE}
FLAVOR=\${1:-${FLAVOR}}
FLAVOR_MODIFIER=\${2:-${FLAVOR_MODIFIER}}

if [ ! -z \${FLAVOR_MODIFIER} ]; then
    FLAVOR_MODIFIER=".\${FLAVOR_MODIFIER}"
fi

INFO=\$(nova ${REGION_OPTION} show ${VMNAME} &>> /dev/null)
RET=\$?
if [ \${RET} -ne 0 ]; then
   ${CMD}
   RET=\$?
EOF
    if [ "${VLAN_TRANSPARENT_INTERNAL_NETWORKS}" == "False" ]; then
        write_trunk_commands ${FILE} ${VMNAME} ${VLANID}
    fi

    cat << EOF >> ${FILE}
fi
EOF
    if [ "x${FLOATING_IP}" == "xyes" ]; then
        cat << EOF >> ${FILE}
if [ \${RET} -eq 0 ]; then
   FIXED_ADDRESS=
   PORT_ID=
   RETRY=30
   while [ -z "\${FIXED_ADDRESS}" -a \${RETRY} -ne 0 ]; do
       FIXED_ADDRESS=\$(echo \${INFO} | sed -e 's#^.*192.168#192.168#' -e 's#[, ].*##g')
       PORT_ID=\$(echo "\${INFO}" | grep "nic.*mgmt-net" | grep -Eo "[0-9a-zA-Z]{8}-[0-9a-zA-Z]{4}-[0-9a-zA-Z]{4}-[0-9a-zA-Z]{4}-[0-9a-zA-Z]{12}")
       if [ -z \${FIXED_ADDRESS} ]; then
           sleep 2
           INFO=\$(nova ${REGION_OPTION} show ${VMNAME})
       fi
       RETRY=\$((RETRY-1))
   done
   if [ -z \${FIXED_ADDRESS} ]; then
       echo "Could not determine fixed address of ${VMNAME}"
       exit 1
   fi
   openstack ${REGION_OPTION} floating ip set ${FIPID} --port \${PORT_ID} --fixed-ip-address \${FIXED_ADDRESS}
   RET=\$?

fi

exit \${RET}
EOF

    else
        cat << EOF >> ${FILE}
exit \${RET}
EOF

    fi

    return 0
}

## Output all wrapper scripts that do not have variable content.
function create_heat_script_files {
    info "Writing Heat Scripts to: ${HEATSCRIPT}"

    ## The global file runs each individual tenant file
    GLOBAL_FILENAME=${HEATSCRIPT}
    echo "#!/bin/bash -e" > ${GLOBAL_FILENAME}

    for TENANT in ${TENANTS[@]}; do
        ## The tenant file runs each VMTYPE file for the tenant
        TENANT_FILENAME=${BOOTDIR}/heat_${TENANT}.sh
        TENANT_HEAT_NAME=heat_${TENANT}-instances
        echo "#!/bin/bash -e" > ${TENANT_FILENAME}
        echo "source ${HOME}/openrc.${TENANT}" >> ${TENANT_FILENAME}
        echo "heat stack-create -f ${BOOTDIR}/${TENANT_HEAT_NAME}.yaml ${TENANT_HEAT_NAME}" >> ${TENANT_FILENAME}
        echo "exit 0" >> ${TENANT_FILENAME}
        chmod 755 ${TENANT_FILENAME}

        for INDEX in ${!APPTYPES[@]}; do
            APPTYPE=${APPTYPES[${INDEX}]}
            VMTYPE=${VMTYPES[${INDEX}]}
            ## The tenant APPTYPE file runs one VMTYPE for the tenant
            APPTYPE_FILENAME=${BOOTDIR}/heat_${TENANT}-${VMTYPE}-instances.sh
            APPTYPE_HEAT_NAME=heat_${TENANT}-${VMTYPE}-instances
            echo "#!/bin/bash -e" > ${APPTYPE_FILENAME}
            echo "source ${HOME}/openrc.${TENANT}" >> ${APPTYPE_FILENAME}
            echo "heat stack-create -f ${BOOTDIR}/${APPTYPE_HEAT_NAME}.yaml ${APPTYPE_HEAT_NAME}" >> ${APPTYPE_FILENAME}
            echo "exit 0" >> ${APPTYPE_FILENAME}
            chmod 755 ${APPTYPE_FILENAME}
        done

        echo "${TENANT_FILENAME}" >> ${GLOBAL_FILENAME}
    done

    echo "exit 0" >> ${GLOBAL_FILENAME}
    chmod 755 ${GLOBAL_FILENAME}

    for INDEX in ${!APPTYPES[@]}; do
        APPTYPE=${APPTYPES[${INDEX}]}
        VMTYPE=${VMTYPES[${INDEX}]}
        ## Then APPTYPE file runs all APPTYPE files for all tenants
        APPTYPE_FILENAME=${BOOTDIR}/heat_${VMTYPE}_instances.sh
        echo "#!/bin/bash -e" > ${APPTYPE_FILENAME}

        for TENANT in ${TENANTS[@]}; do
            APPTYPE_HEAT_NAME=heat_${TENANT}-${VMTYPE}-instances
            echo "${BOOTDIR}/${APPTYPE_HEAT_NAME}.sh" >> ${APPTYPE_FILENAME}
        done

        echo "exit 0" >> ${APPTYPE_FILENAME}
        chmod 755 ${APPTYPE_FILENAME}
    done

    return 0
}


## Setup local storage on a single node
##
function setup_local_storage {
    local NODE=$1
    local MODE=$2
    local PVS=$3
    local LV_CALC_MODE=$4
    local LV_SIZE=$5

    if is_stage_complete "local_storage" ${NODE}; then
        info "Skipping local storage configuration for ${NODE}; already done"
        return 0
    fi

    # Special Case: Small system controller-0 (after running lab_cleanup)
    if [[ "${SMALL_SYSTEM}" == "yes" && "${NODE}" == "controller-0" ]]; then
        local NOVA_VG=$(system host-lvg-list ${NODE} ${CLI_NOWRAP} | awk '{if ($4 == "nova-local" && $6 == "provisioned") print $4}')
        if [ "${NOVA_VG}" == "nova-local" ]; then
            info "Skipping local storage configuration for ${NODE}; already done"
            return 0
        fi
    fi

    # Validate parameters: mode
    if [[ ${MODE} == local* || "${MODE}" == "remote" ]]; then
        info "Adding nova storage; Instance disks backed by ${MODE} storage for ${NODE}."
    else
        echo "ERROR: mode storage setting for ${NODE} is uknown: ${MODE}"
        return 3
    fi

    # Validate parameters: make sure that at least one physical volume will be added
    if [[ "${PVS}" == "none" ]]; then
        echo "ERROR: No physical volumes are specified for ${NODE}"
        return 3
    fi


    # Validate parameters: lv_calc_mode and lv_fixed_size
    if [ "${LV_CALC_MODE}" == "fixed" ]; then
        if [[ "${MODE}" == "local_lvm" && "${LV_SIZE}" == "0" ]]; then
            echo "ERROR: lv_fixed_size storage setting for ${NODE} is invalid: ${LV_SIZE}"
            return 3
        fi
    else
        echo "ERROR: lv_calc_mode storage setting for ${NODE} is uknown: ${LV_CALC_MODE}"
        return 3
    fi

    # Volume Group: Create the the nova-local volume group
    local NOVA_VG=$(system host-lvg-list ${NODE} ${CLI_NOWRAP} | awk '{if ($4 == "nova-local" && ($6 == "provisioned" || $6 ~ /adding/)) print $4}')
    if [ -z "${NOVA_VG}" ]; then
    log_command "system host-lvg-add ${NODE} nova-local"
    fi

    # Physical Volumes: Process the devices (disks and/or partitions)
    if [ "${PVS}" != "none" ]; then
        local DEVICE_ARRAY=(${PVS//,/ })
        for DINDEX in ${!DEVICE_ARRAY[@]}; do
            local DEVICE_UUID=$(system host-disk-list ${NODE} ${CLI_NOWRAP} | grep ${DEVICE_ARRAY[${DINDEX}]} | awk '{print $2}')

            if [ "${DEVICE_UUID}" == "" ]; then
                log "PV is not a disk, looking for a partition"
                local DEVICE_UUID=$(system host-disk-partition-list ${NODE} ${CLI_NOWRAP} | grep ${DEVICE_ARRAY[${DINDEX}]} | awk '{print $2}')
                if [ "${DEVICE_UUID}" == "" ]; then
                    echo "ERROR: could not find the device (${DEVICE_ARRAY[${DINDEX}]}) UUID for ${NODE}"
                    return 4
                fi
            fi

            # Add the addition physical volume
            local NOVA_PV=$(system host-pv-list ${NODE} ${CLI_NOWRAP} | grep nova-local | grep ${DEVICE_UUID} | awk '{if ($12 == "provisioned" || $12 == "adding") print $4}')
            if [ -z ${NOVA_PV} ];then
                log_command "system host-pv-add ${NODE} nova-local ${DEVICE_UUID}"
            fi
        done
    fi

    # Set instances LV parameter
    if [ "${MODE}" == "local_lvm" ]; then
        log_command "system host-lvg-modify ${NODE} nova-local -b lvm -s ${LV_SIZE}"
    elif [ "${MODE}" == "local_image" ]; then
        log_command "system host-lvg-modify ${NODE} nova-local -b image"
    elif [ "${MODE}" == "remote" ]; then
        log_command "system host-lvg-modify ${NODE} nova-local -b remote"
    fi

    stage_complete "local_storage" ${NODE}

    return 0
}


## Setup local storage on nodes
##
function add_local_storage {
    local NODE=""

    for NODE in ${NODES}; do
        if [[ "${SMALL_SYSTEM}" != "yes" && $NODE == *"controller"* ]]; then
            continue
        fi
        local SETTINGS_STRING=$(get_node_variable ${NODE} LOCAL_STORAGE)
        local FIELD_SEPARATORS="${SETTINGS_STRING//[^|]}"
        if [ ${#FIELD_SEPARATORS} -ne 3 ]; then
            echo "Local storage settings for host ${NODE} has an invalid format: Incorrect number of fields"
            echo "     ${SETTINGS_STRING}"
            return 2
        fi

        local SETTINGS_ARRAY=(${SETTINGS_STRING//|/ })
        if [ ${#SETTINGS_ARRAY[@]} == 4 ]; then
            setup_local_storage ${NODE} ${SETTINGS_ARRAY[@]}
            RET=$?
            if [ ${RET} -ne 0 ]; then
                echo "Failed to setup local storage for ${NODE}"
                return ${RET}
            fi
        else
            echo "Local storage settings for host ${NODE} has an invalid format: One or more fields are empty"
            echo "     ${SETTINGS_STRING}"
            return 2
        fi
    done

    return 0
}


## Setup cinder device on controller
##
function setup_cinder_device {
    local NODE=$1
    local CINDER_SETTINGS=$2

    if is_stage_complete "cinder_device" ${NODE}; then
        info "Skipping cinder device creation for ${NODE}; already done"
        return 0
    fi

    # Special case: after lab_cleanup we may already have cinder provisioned.
    local CINDER_VG=$(system host-lvg-list ${NODE} ${CLI_NOWRAP} | awk '{if ($4 == "cinder-volumes") print $4}')
    if [[ "${CINDER_VG}" == *"cinder-volumes"* ]]; then
        info "Skipping cinder device creation for ${NODE}; already done"
        return 0
    fi

    info "Adding cinder device for ${NODE}"

    # Validate config
    for DEV_CFG_STR in ${CINDER_SETTINGS}; do
        local DEV_CFG_ARRAY=(${DEV_CFG_STR//|/ })
        if [ ${#DEV_CFG_ARRAY[@]} -ne 1 ]; then
            echo "Cinder device settings for host ${NODE} has an invalid format: Incorrect number of fields"
            echo "     ${DEV_CFG_STR}"
            return 1
        fi
    done

    for DEV_CFG_STR in ${CINDER_SETTINGS}; do
        local DEV_CFG_ARRAY=(${DEV_CFG_STR//|/ })
        PARTITION=${DEV_CFG_ARRAY[0]}

        PARTITIONS=$(system host-disk-partition-list ${NODE} ${CLI_NOWRAP})
        PARTITION_UUID=$(echo "${PARTITIONS}" | grep ${PARTITION} | awk '{print $2}')
        if [ -z "${PARTITION_UUID}" ]; then
            echo "No device named ${PARTITION} on ${NODE}"
            return 2
        fi

        local CINDER_VG=$(system host-lvg-list ${NODE} ${CLI_NOWRAP} | awk '{if ($4 == "cinder-volumes" && ($6 == "provisioned" || $6 ~ /adding/)) print $4}')
        if [ -z "${CINDER_VG}" ]; then
            log_command "system host-lvg-add ${NODE} cinder-volumes"
        fi

        CMD="system host-pv-add ${NODE} cinder-volumes ${PARTITION_UUID}"
        log_command "${CMD}"
    done

    stage_complete "cinder_device" ${NODE}

    return 0
}

## Partition Settings.
##
## <HOSTNAME>_PARTITIONS="<disk_device_path1>,[partition1_size_gib, partition2_size_gib]|<disk_device_path2>,[partition1_size_gib]"
##
## Examples:
##  - create three partitions on controller-0:
##     -> two 144 GiB partitions on /dev/disk/by-path/pci-0000:00:17.0-ata-3.0
##     -> one 128 GiB partition on /dev/disk/by-path/pci-0000:00:17.0-ata-2.0
##          CONTROLLER0_PARTITIONS="/dev/disk/by-path/pci-0000:00:17.0-ata-3.0,[144,144]|/dev/disk/by-path/pci-0000:00:17.0-ata-2.0,[128]"
##
## - create one partition on worker-1:
##     -> one 419 GiB partition on /dev/disk/by-path/pci-0000:00:1f.2-ata-2.0
##          WORKER1_PARTITIONS="/dev/disk/by-path/pci-0000:00:1f.2-ata-2.0,[419]"
function setup_partitions {
    NODE=$1
    DISK_DEVICE_PATH=$2
    # this is how you get a paramater that is passed as an array
    declare -a partitionArgArray=("${!3}")

    # 180 but longer in vbox. That's because there is another set of manifests already applying.
    # The partition goes to "Ready" eventually but lab_setup timeout.
    local PARTITION_CREATE_TIMEOUT=360

    local DISK_UUID=""

    # Disk search up to 10 times with 10 seconds between retries
    for ((loop=0;loop<10;loop++)); do
        # Get the disk UUID for the provided disk device path.
        DISK_UUID=$(system host-disk-list ${NODE} ${CLI_NOWRAP} | grep ${DISK_DEVICE_PATH} | awk '{print $2}')

        # If we couldn't obtain the disk UUID then retry.
        if [ "${DISK_UUID}" != "" ]; then
            break
        else
            sleep 10
        fi
    done

    # If we couldn't obtain the disk UUID, return with Error.
    if [ "${DISK_UUID}" == "" ]; then
        echo "ERROR: could not find the disk (${DISK_DEVICE_PATH}) for ${NODE}"
        return 4
    fi

    # Get the sizes of partitions existing on the current disk.
    local present_partition_sizes=$(system host-disk-partition-list ${NODE} --disk ${DISK_UUID} ${CLI_NOWRAP} | grep "ba5eba11" | awk -F'|' '{print $7}' | tr '\r\n' ' ')
    PARTITION_SIZES=$(echo ${partitionArgArray[@]})


    # Remove present partition sizes from the requested partition sizes (in case this is after lab_cleanup).
    if [[ -n "${present_partition_sizes}" ]]; then
        PARTITION_SIZES_COPY=",${PARTITION_SIZES// /,},"
        log "We have other partitions present, determine which we still need to create."
        for present_size in ${present_partition_sizes}; do
            # lab_setup script uses int values for partition sizes,
            # while sysinv reports them as float values, so in order
            # to properly compare them, we turn the sysinv ones into
            # integer values.
            int_present_size=${present_size%.*}
            PARTITION_SIZES_COPY=${PARTITION_SIZES_COPY/,$int_present_size,/,}
        done

        PARTITION_SIZES=${PARTITION_SIZES_COPY//,/ }
    fi

    if [[ -z "${PARTITION_SIZES-}" ]]; then
        log "No new partitions to add, return.."
        return 0
    fi

    invprovision=$(system host-show ${NODE} | grep "invprovision" | awk '{print $4;}')

    # Create all the requested partitions.
    for PARTITION_SIZE in ${PARTITION_SIZES}; do
        log "Create part of size $PARTITION_SIZE on node $NODE, disk $DISK_DEVICE_PATH"
        local new_partition=$(system host-disk-partition-add -t lvm_phys_vol ${NODE} ${DISK_UUID} ${PARTITION_SIZE})
        local new_partition_uuid=$(echo $new_partition | grep -ow "| uuid | [a-z0-9\-]* |" | awk '{print $4}')

        if [ "${new_partition_uuid}" == "" ]; then
            echo "ERROR: Could not create partition of ${PARTITION_SIZE} GiB on disk ${DISK_UUID} for ${NODE}"
            return 1
        fi

        # If this is controller-0 or the host has already been provisioned, create the partition in-service, so wait for it to become Ready.
        if [[ $NODE == *"controller-0"* || $invprovision == "provisioned"* ]]; then
            local PARTITION_DELAY=0
            while [[ $PARTITION_DELAY -lt $PARTITION_CREATE_TIMEOUT ]]; do
                partition_status=$(system host-disk-partition-list ${NODE} ${CLI_NOWRAP} | grep ${new_partition_uuid} | awk '{print $(NF-1)}')
                if [[ ${partition_status} != *"Ready"* ]]; then
                    log "Waiting for partition ${new_partition_uuid} to become Ready. Status: ${partition_status}"
                    sleep 5
                    PARTITION_DELAY=$((PARTITION_DELAY + 5))
                else
                    log "Partition ${new_partition_uuid} is Ready"
                    break
                fi
            done

            if [[ $PARTITION_DELAY -eq $PARTITION_CREATE_TIMEOUT ]]; then
                echo "ERROR: Timed out waiting for partition ${new_partition_uuid} to become Ready"
                return 1
            fi
        fi
    done

    return 0
}

## Extend cgts-vg - AIO only.
##
## Use the mentioned devices (disks/partitions) for Physical Volumes to extend cgts-vg:
##     <HOSTNAME>_CGTS_STORAGE="device_path_1|device_path_2|device_path_3"
##
## Examples:
##  - extend controller-0's cgts-vg with one disk based PV and one partition based PV:
##    CONTROLLER0_CGTS_STORAGE="/dev/disk/by-path/pci-0000:00:0d.0-ata-3.0|/dev/disk/by-path/pci-0000:00:0d.0-ata-1.0-part6"
##
##  - extend controller-1's cgts-vg with one partition based PV:
##    CONTROLLER1_CGTS_STORAGE="/dev/disk/by-path/pci-0000:00:0d.0-ata-1.0-part5"
function setup_cgts_extend {
    NODE=$1
    DEVICES=$2

    info "Extending cgts-vg for host $NODE"

    local PROVISION_PV_TIMEOUT=180

    for DEVICE in "${DEVICES[@]}"; do
       # Check if this PV is already in cgts-vg.
       # Special case: after lab_cleanup we may already have this PV in cgts-vg.
        local CGTS_VG=$(system host-pv-list $NODE ${CLI_NOWRAP} | grep $DEVICE | awk -F'|' '{print $9}')
        if [[ "${CGTS_VG}" == *"cgts-vg"* ]]; then
            log "Skipping adding device $DEVICE to cgts-vg for ${NODE}; already done"
            continue
        fi

        if [[ $NODE == *"worker"*  ]]; then
            log_command "system host-lvg-add $NODE cgts-vg"
        fi

        log_command "system host-pv-add $NODE cgts-vg $DEVICE"

        if [[ $NODE != *"controller-0"*  ]]; then
            log "$NODE is not controller-0, don't wait for extending cgts-vg"
            continue
        fi

        local PROVISION_PV_DELAY=0
        while [[ $PROVISION_PV_DELAY -lt $PROVISION_PV_TIMEOUT ]]; do
            pv_state=$(system host-pv-list $NODE ${CLI_NOWRAP} | grep $DEVICE | awk '{print $12;}')
            if [[ ${pv_state} != *"provisioned"* ]]; then
                log "Waiting for PV ${DEVICE} to become Ready. Status: ${pv_state}"
                sleep 5
                PROVISION_PV_DELAY=$((PROVISION_PV_DELAY + 5))
            else
                log "PV ${DEVICE} is provisioned"
                break
            fi

            if [[ $PROVISION_PV_DELAY -eq $PROVISION_PV_TIMEOUT ]]; then
                echo "ERROR: Timed out waiting for PV ${DEVICE} to be provisioned"
                return 1
            fi
        done
    done

    return 0
}

function add_partitions {
    local NODE=""
    local PART_NODES=$(system host-list ${CLI_NOWRAP} | awk '{if (($6=="controller" || $6=="worker") && ($12 != "offline")) print $4;}')

    for NODE in ${PART_NODES}; do
        # We should never skip this as we may want to add
        # additional partitions at a later date.
        # Useful for chaining config files.
        info "Setting partitions for host $NODE"

        local SETTINGS_STRING=$(get_node_variable ${NODE} PARTITIONS)
        local FIELD_SEPARATORS="${SETTINGS_STRING//[^|]}"
        local SETTINGS_ARRAY=(${SETTINGS_STRING//|/ })
        unset MERGE_PARTITION_INFO
        declare -A MERGE_PARTITION_INFO

        # When chaining multiple config files, the same node may contain
        # partition info that is not all in one place. Example:
        # {NODE}_PARTITIONS="{disk1},[1,2,3]|{disk2},[3,4,5]|{disk1},[1,5,6]"
        # This will merge then into:
        # {NODE}_PARTITIONS="{disk1},[1,2,3,1,5,6]|{disk2},[3,4,5]"
        if [ ${#SETTINGS_ARRAY[@]} -ne 0 ]; then
            for DISK_PART_SETTING in "${SETTINGS_ARRAY[@]}"; do
                local DISK_PART_SETTING_ARRAY=(${DISK_PART_SETTING//[\]\[,]/ })
                local PARTITION_SIZES=("${DISK_PART_SETTING_ARRAY[@]:1}")
                local DISK_DEVICE_PATH=${DISK_PART_SETTING_ARRAY[0]}

                set +u
                if [ -z "${MERGE_PARTITION_INFO[${DISK_DEVICE_PATH}]}" ]; then
                    MERGE_PARTITION_INFO[$DISK_DEVICE_PATH]="${PARTITION_SIZES[@]}"
                else
                    MERGE_PARTITION_INFO["${DISK_DEVICE_PATH}"]="${MERGE_PARTITION_INFO["${DISK_DEVICE_PATH}"]} ${PARTITION_SIZES[@]}"
                fi
                set -u
            done
        fi

        for disk_key in "${!MERGE_PARTITION_INFO[@]}"; do
            P_SIZES=(${MERGE_PARTITION_INFO[$disk_key]})
            setup_partitions ${NODE} ${disk_key} P_SIZES[@]
            RET=$?
            if [[ ${RET} -ne 0 ]]; then
                echo "ERROR: Could not create all the partitions for host ${NODE}"
                return ${RET}
            fi
        done

    done

    return 0
}


function extend_cgts_vg {
    if [[ "${SMALL_SYSTEM}" != "yes" && "${K8S_ENABLED}" != "yes" ]]; then
        log "This is not an AIO setup, we don't extend cgts-vg, so return."
        return
    fi

    local NODE=""
    local ALL_NODES=$(system host-list ${CLI_NOWRAP} | awk '{if (($6=="controller" || $6=="worker") && ($12 != "offline")) print $4;}')

    for NODE in ${ALL_NODES}; do
        if is_stage_complete "extend_cgts_vg" ${NODE}; then
            info "Skipping cgts-vg extend for ${NODE}; already done"
            continue
        fi

        local SETTINGS_STRING=$(get_node_variable ${NODE} CGTS_STORAGE)
        local FIELD_SEPARATORS="${SETTINGS_STRING//[^|]}"

        local SETTINGS_ARRAY=(${SETTINGS_STRING//|/ })
        if [ ${#SETTINGS_ARRAY[@]} -ne 0 ]; then
            local DEVICES=("${SETTINGS_ARRAY[@]:0}")
            setup_cgts_extend ${NODE} ${DEVICES}
        else
            info "No cgts-vg extension for ${NODE}"
        fi

        stage_complete "extend_cgts_vg" ${NODE}
    done

    return 0
}

function wait_for_backend_configuration {
    local BACKEND_TYPE=$1
    local BACKEND_NAME=$2
    local CINDER_CONFIGURED_TIMEOUT=600
    local CINDER_CONFIGURED_DELAY=0
    while [[ $CINDER_CONFIGURED_DELAY -lt $CINDER_CONFIGURED_TIMEOUT ]]; do
        backend_info=$(system storage-backend-list ${CLI_NOWRAP} | grep ${BACKEND_NAME})
        backend_status=$(echo ${backend_info}| awk '{print $8}')
        backend_task=$(echo ${backend_info}| awk '{print $10}')

        if [[ ${backend_status} == "configuration-failed" ]]; then
            log "${BACKEND_NAME} backend (${BACKEND_NAME}): configuration failed"
            return 1
        fi

        if [[ ${backend_status} != *"configured"* && ${backend_task} != *"reconfig-controller"* ]]; then
            log "Waiting for ${BACKEND_TYPE} backend ${BACKEND_NAME} to become configured info: ${backend_info}"
            sleep 10
            CINDER_CONFIGURED_DELAY=$((CINDER_CONFIGURED_DELAY + 10))
        else
            log "${BACKEND_NAME} backend (${BACKEND_NAME}): configuration complete"
            break
        fi
    done

    if [[ CINDER_CONFIGURED_DELAY -eq CINDER_CONFIGURED_TIMEOUT ]]; then
        echo "ERROR: timed out waiting for ${BACKEND_NAME} backend (${BACKEND_NAME}) to become configured"
        return 1
    fi
}

function storage_backend_enable {
    BACKEND_TYPE=$1
    if is_stage_complete "storage_backend_enable" ${BACKEND_TYPE}; then
        info "Skipping storage backend ${BACKEND_TYPE} enabling; already done"
        return 0
    else
        info "Enabling ${BACKEND_TYPE} storage backend"
    fi

    if [[ ${BACKEND_TYPE} == *"ceph"* ]]; then
        if [ "$K8S_ENABLED" != "yes" ]; then
            #TODO: Refactor services based on cinder & glance's backends
            #TODO: Add nova as a service to use ceph ephemeral pool for
            # remote instance-backing
            STORAGE_SERVICES="cinder,glance,nova"
        else
            STORAGE_SERVICES=""
        fi
        BACKEND_NAME="ceph-store"
    fi

    if [[ ${BACKEND_TYPE} == *"lvm"* ]]; then
        STORAGE_SERVICES="cinder"
        BACKEND_NAME="lvm-store"
    fi

    if [[ ${BACKEND_TYPE} == *"external"* ]]; then
        STORAGE_SERVICES="cinder"
        BACKEND_NAME="shared_services"
    fi

    # TODO: Support storage backend modifications on successive lab_setup executions
    # (if backend is new use storage-backend-add otherwise use storage-backend-modify)
    NAME="${BACKEND_TYPE}-store"
    ID=$(system storage-backend-list ${CLI_NOWRAP} | awk -v NAME=${BACKEND_NAME} '{if ($4 == NAME) { print $2 }}')
    if [ -z "${ID}" ]; then
        if [[ ${STORAGE_SERVICES} == "" ]]; then
            log_command "system storage-backend-add ${BACKEND_TYPE} ${STORAGE_CEPH_CAPABILITIES} --confirmed"
        else
            log_command "system storage-backend-add ${BACKEND_TYPE} ${STORAGE_CEPH_CAPABILITIES} -s ${STORAGE_SERVICES} --confirmed"
        fi
    else
        if [[ ${BACKEND_TYPE} == *"external"* ]]; then
            log_command "system storage-backend-modify ${BACKEND_NAME} -s cinder,glance"
            NAME=${BACKEND_NAME}
        fi
    fi

    wait_for_backend_configuration $BACKEND_TYPE $NAME
    RET=$?
    if [ ${RET} -ne 0 ]; then
        exit ${RET}
    fi

    stage_complete "storage_backend_enable" ${BACKEND_TYPE}

    return 0
}


function setup_neutron_service_parameters {
    if is_stage_complete "neutron_service_param"; then
        info "Skipping Neutron service parameter configuration; already done"
        return 0
    fi

    info "Adding Neutron service parameter configuration"

    if [ ! -z "${NEUTRON_BASE_MAC}" ]; then
        log_command "system service-parameter-add network default base_mac=${NEUTRON_BASE_MAC}"
    fi

    if [ ! -z "${NEUTRON_DVR_BASE_MAC}" ]; then
        log_command "system service-parameter-add network default dvr_base_mac=${NEUTRON_DVR_BASE_MAC}"
    fi

    if [ ! -z "${NEUTRON_EXTENSION_DRIVERS}" ]; then
        log_command "system service-parameter-add network ml2 extension_drivers=${NEUTRON_EXTENSION_DRIVERS}"
    fi

    log_command "system service-parameter-apply network"

    # Wait for neutron-server to finish restarting
    wait_for_service_parameters

    stage_complete "neutron_service_param"
    return 0
}

function setup_odl_service_parameters {
    if [ -z "${SDN_ODL_URL}" ]; then
        echo "ERROR: SDN_ODL_URL configuration parameter must be defined"
        return 1
    fi

    log_command "system service-parameter-add network ml2 mechanism_drivers=${SDN_ODL_MECHANISM_DRIVERS}"
    log_command "system service-parameter-add network ml2_odl url=${SDN_ODL_URL}"
    log_command "system service-parameter-add network ml2_odl username=${SDN_ODL_USERNAME}"
    log_command "system service-parameter-add network ml2_odl password=${SDN_ODL_PASSWORD}"
    log_command "system service-parameter-add network ml2_odl port_binding_controller=${SDN_ODL_PORT_BINDING_CONTROLLER}"

    if [ ! -z "${SDN_ODL_SERVICE_PLUGINS}" ]; then
        log_command "system service-parameter-add network default service_plugins=${SDN_ODL_SERVICE_PLUGINS}"
    fi

    if [ "${FORCE_METADATA}" == "yes" ]; then
        log_command "system service-parameter-add network dhcp force_metadata=true"
    fi

    log_command "system service-parameter-apply network"

    # Wait for neutron-server to finish restarting
    wait_for_service_parameters

    return 0
}


## Setup SDN service parameters
##
function setup_sdn_service_parameters {
    if is_stage_complete "sdn_service_param"; then
        info "Skipping SDN service parameter configuration; already done"
        return 0
    fi

    info "Adding SDN service parameter configuration"

    if [ "${SDN_NETWORKING}" == "opendaylight" ]; then
        setup_odl_service_parameters
        RET=$?
        if [ ${RET} -ne 0 ]; then
            echo "Failed to setup opendaylight service parameters"
            return ${RET}
        fi
    else
        echo "ERROR: unsupported SDN_NETWORKING type of \"${SDN_NETWORKING}\""
        return 4
    fi

    stage_complete "sdn_service_param"

    return 0
}


## Setup SFC service parameters
##
function setup_sfc_service_parameters {
    if is_stage_complete "sfc_service_param"; then
        info "Skipping SFC service parameter configuration; already done"
        return 0
    fi

    info "Adding SFC service parameter configuration"

    log_command "system service-parameter-add network sfc sfc_drivers=${SFC_SFC_DRIVERS}"
    log_command "system service-parameter-add network sfc flowclassifier_drivers=${SFC_FLOW_CLASSIFIER_DRIVERS}"


    log_command "system service-parameter-apply network"

    stage_complete "sfc_service_param"

    return 0
}


## Setup SDN controllers
##
function setup_sdn_controllers {
    if [ -z "${SDN_CONTROLLERS}" ]; then
        echo "ERROR: SDN_CONTROLLERS configuration parameter must be defined"
        return 1
    fi

    if is_stage_complete "sdn_controllers"; then
        info "Skipping SDN controllers configuration; already done"
        return 0
    fi

    info "Adding SDN controllers"

    for CONTROLLER in ${SDN_CONTROLLERS}; do
        local DATA=(${CONTROLLER//:/ })
        local TRANSPORT=${DATA[0]^^}
        local HOST=${DATA[1]}
        local PORT=${DATA[2]}
        log_command "system sdn-controller-add -a ${HOST} -p ${PORT} -t ${TRANSPORT}"
    done

    stage_complete "sdn_controllers"

    return 0
}

## Enable SDN
##
function enable_sdn {
    if is_stage_complete "enable_sdn"; then
        info "Skipping SDN enabling; already done"
        return 0
    fi

    info "Enabling SDN"
    log_command "system modify --sdn_enabled=true"

    stage_complete "enable_sdn"
    return 0
}

## Setup Software Defined Networking (SDN)
##
function setup_sdn {
    if [ "${SDN_ENABLED}" != "yes" ]; then
        # SDN is not enabled
        return 0
    fi

    source ${OPENRC}

    enable_sdn
    RET=$?
    if [ ${RET} -ne 0 ]; then
        echo "Failed to enable SDN"
        return ${RET}
    fi

    setup_sdn_service_parameters
    RET=$?
    if [ ${RET} -ne 0 ]; then
        echo "Failed to setup SDN service parameters"
        return ${RET}
    fi

    setup_sdn_controllers
    RET=$?
    if [ ${RET} -ne 0 ]; then
        echo "Failed to setup SDN controllers"
        return ${RET}
    fi

    return 0
}

## Setup Service Function Chaining (SFC)
##
function setup_sfc {
    if [ "${SFC_ENABLED}" != "yes" ]; then
        # SFC is not enabled
        return 0
    fi

    source ${OPENRC}

    setup_sfc_service_parameters
    RET=$?
    if [ ${RET} -ne 0 ]; then
        echo "Failed to setup SDN service parameters"
        return ${RET}
    fi

    return 0
}

# Https Changes
function is_https_security_configuration {
    if [ ! -z "${HTTPS_ENABLED}"  ]  ; then
        # A value is set for https , could be true or false -
        SYSTEM_HTTPS_ENABLED=$(system show  | awk '{ if ($2 == "https_enabled") print $4;}');

        if [ "${SYSTEM_HTTPS_ENABLED}" != "${HTTPS_ENABLED}" ]; then
            return 0
        else
                      # configuration value in .conf file matches with system show value .
                      # no changes needed.
            return 1
        fi
    else
        # Lab is not https enabled  .conf file has value for HTTPS_ENABLED?
        return 1
    fi

}

function setup_https_security_configuration {
    set +e
    is_https_security_configuration
    RET=$?
    if [ ${RET} -eq 0 ]; then
        info "Changing HTTPS security configuration .."
        source ${OPENRC}

        if [ "$HTTPS_ENABLED" == "True" ]; then
            log_command "system modify --https_enabled=true"
        elif [ "$HTTPS_ENABLED" == "False" ]; then
            log_command "system modify --https_enabled=false"
        fi

        RET=$?
        if [ ${RET} -ne 0 ]; then
            echo "Error changing HTTPS confuguration $RET"
            exit 0
        fi

        # Wait for puppet operations to be over
        DELAY=0
        while [ $DELAY -lt ${HTTPS_TIMEOUT} ]; do

            CONFIG_APPLIED=$(system host-show controller-0  | awk '{ if ($2 == "config_applied") print $4;}');
            CONFIG_TARGET=$(system host-show controller-0  | awk '{ if ($2 == "config_target") print $4;}');

                    ICONFIG_APPLIED=${CONFIG_APPLIED:(-35)}
                    ICONFIG_TARGET=${CONFIG_TARGET:(-35)}
            if [ "${ICONFIG_APPLIED}" != ${ICONFIG_TARGET} ]; then
                DELAY=$((DELAY + 5))
                sleep 5
            else
                echo "HTTPS security configuration change is successful."
                # Now check for a CA certificate entry in conf file . if it exists and
                # if we are converting the lab from http to https , copy the CA certificate
                # No need to copy certificate if the conversion is from https to http

                if [ ! -z "${CERTIFICATE_FILENAME}" ]  && [ "${HTTPS_ENABLED}" == "True" ]  ; then
                    # check if the file exists
                    if [  -f "${CERTIFICATE_FILENAME}" ]; then
                        if [ "$TPM_ENABLED" == "True" ]; then
                            # This is the initial certificate setup. For TPM configurations, we will need
                            # to do it again once the second controller node is up
                            # Otherwise, the TPM configuration will be missing on the second controller
                            # So we need to make a copy, since the install operation will delete the input file provided
                            cp ${CERTIFICATE_FILENAME} copy_of_${CERTIFICATE_FILENAME}
                            log_command "system certificate-install -m tpm_mode copy_of_${CERTIFICATE_FILENAME}"
                        else
                            log_command "system certificate-install ${CERTIFICATE_FILENAME}"
                        fi
                        RET=$?
                        return ${RET}
                    else
                        echo "CA certificate (${CERTIFICATE_FILENAME}) does not exist. \
                             Please install the CA certificate manually\
                             using system certificate-install "
                    fi
                fi

                return 0
            fi
        done
    else
        echo "HTTPS security confguration change is not required."
        local CONTROLLER_NODES=$(system host-list ${CLI_NOWRAP} | awk '{if ($6=="controller" && ($12 != "offline")) print $4;}')
        local COUNT=$(echo ${CONTROLLER_NODES} | wc -w)
        if [ ${COUNT} -gt 1 ]; then
            # now that the second controller is up, we need to install the CA certificate for https again if using TPM
            if [ ! -z "${CERTIFICATE_FILENAME}" ] && [ "${HTTPS_ENABLED}" == "True" ] && [ "$TPM_ENABLED" == "True" ]; then
                # check if the file exists
                if [  -f "${CERTIFICATE_FILENAME}" ]; then
                    log_command "system certificate-install -m tpm_mode ${CERTIFICATE_FILENAME}"
                fi
            fi

        fi
    fi

    return 0
}

function setup_providernet_tenants_quota_crentials {
    if [ "x${DISTRIBUTED_CLOUD_ROLE}" != "xsubcloud" ]; then
        add_tenants
        RET=$?
        if [ ${RET} -ne 0 ]; then
            echo "Failed to add tenants, ret=${RET}"
            exit ${RET}
        fi
    fi

    ## Cache the tenantid values
    ADMINID=$(get_tenant_id admin)
    TENANT1ID=$(get_tenant_id ${TENANT1})
    TENANT2ID=$(get_tenant_id ${TENANT2})

    create_credentials
    RET=$?
    if [ ${RET} -ne 0 ]; then
        echo "Failed to create credentials, ret=${RET}"
        exit ${RET}
    fi

    if [ "x${DISTRIBUTED_CLOUD_ROLE}" != "xsubcloud" ]; then
        set_quotas
        RET=$?
        if [ ${RET} -ne 0 ]; then
            echo "Failed to set quotas, ret=${RET}"
            exit ${RET}
        fi
    fi

    if [ "x${DISTRIBUTED_CLOUD_ROLE}" != "xsubcloud" ]; then
        if [ ${GROUPNO} -eq 0 ]; then
            setup_flavors
            RET=$?
            if [ ${RET} -ne 0 ]; then
                echo "Failed to setup flavors, ret=${RET}"
                exit ${RET}
            fi
        fi

        create_custom_flavors
        RET=$?
        if [ ${RET} -ne 0 ]; then
            echo "Failed to create custom flavors, ret=${RET}"
            exit ${RET}
        fi
    fi

    if [ "x${DISTRIBUTED_CLOUD_ROLE}" != "xsubcloud" ]; then
        setup_keys
        RET=$?
        if [ ${RET} -ne 0 ]; then
            echo "Failed to setup keys, ret=${RET}"
            exit ${RET}
        fi
    fi

    return 0

}

##Wait for applicatin apply to complete
function wait_for_application_apply {
    local APPLICATION_CONFIGURED_TIMEOUT=3600
    local APPLICATION_CONFIGURED_DELAY=0
    while [[ $APPLICATION_CONFIGURED_DELAY -lt $APPLICATION_CONFIGURED_TIMEOUT ]]; do
        app_info=$(system application-list ${CLI_NOWRAP} | grep stx-openstack)
        app_status=$(echo ${app_info}| awk '{print $8}')
        #app_task=$(echo ${app_info}| awk '{print $10}')

        if [[ ${app_status} == "apply-failed" ]]; then
            echo "Application  stx-openstack : apply failed"
            return 1
        fi

        if [[ ${app_status} == *"applying"* ]]; then
            log "Waiting for application to become applied info: stx-openstack"
            sleep 10
            APPLICATION_CONFIGURED_DELAY=$((APPLICATION_CONFIGURED_DELAY + 10))
        else
            log "stx-openstack application: apply complete"
            break
        fi
    done

    if [[ APPLICATION_CONFIGURED_DELAY -eq APPLICATION_CONFIGURED_TIMEOUT ]]; then
        echo "ERROR: timed out waiting for stx-openstack to become applied"
        return 1
    fi
    return 0
}

#Wait for application upload to complete
function wait_for_application_upload {
    local APPLICATION_CONFIGURED_TIMEOUT=600
    local APPLICATION_CONFIGURED_DELAY=0
    while [[ $APPLICATION_CONFIGURED_DELAY -lt $APPLICATION_CONFIGURED_TIMEOUT ]]; do
        app_info=$(system application-list ${CLI_NOWRAP} | grep stx-openstack)
        app_status=$(echo ${app_info}| awk '{print $8}')

        if [[ ${app_status} == "upload-failed" ]]; then
            log "$Application  stx-openstack : upload failed"
            return 1
        fi

        if [[ ${app_status} == *"uploading"* ]]; then
            log "Waiting for application to become uploaded info: stx-openstack"
            sleep 10
            APPLICATION_CONFIGURED_DELAY=$((APPLICATION_CONFIGURED_DELAY + 10))
        else
            log "stx-openstack application: upload complete"
            break
        fi
    done

    if [[ APPLICATION_CONFIGURED_DELAY -eq APPLICATION_CONFIGURED_TIMEOUT ]]; then
        echo "ERROR: timed out waiting for stx-openstack to become uploaded"
        return 1
    fi
    return 0
}

#upload application (helm-charts) and apply application
function setup_kube_pods {
    if [[ "$K8S_ENABLED" != "yes" ]]; then
        return 0
    fi

    if is_stage_complete "openstack_deployment"; then
        info "Skipping Openstack app deployment configuration; already done"
        return 0
    fi

    # Add DNS Cluster, might need to remove later
    # DNS_EP=$(kubectl describe svc -n kube-system kube-dns | awk /IP:/'{print $2}')
    # log_command "system dns-modify nameservers="$DNS_EP,8.8.8.8""
    # RET=$?
    #log_command "ceph osd pool ls | xargs -i ceph osd pool set {} size 1"

    app_info=$(system application-list ${CLI_NOWRAP} | grep stx-openstack)
    app_status=$(echo ${app_info}| awk '{print $8}')
    echo "app status is: ${app_status}"
    if [[ ${app_status} == "upload-failed" || ${app_status} == "apply-failed" ]]; then
        log "Application upload/apply: configuration failed"
        return 1
    fi

    if [[ ${app_status} == *"applied"* ]]; then
        log "Application Already applied"
        stage_complete "openstack_deployment"
        return 0
    fi

    if [[ ${app_status} == *"applying"* ]]; then
        wait_for_application_apply
        RET=$?
        if [ ${RET} -ne 0 ]; then
            exit ${RET}
        else
            echo "Openstack App is applied"
            return 0
        fi
    elif [[ ${app_status} == *"uploaded"* ]]; then
        info "Applying stx-openstack application"
        log_command "system application-apply stx-openstack"
        wait_for_application_apply
        RET=$?
        if [ ${RET} -ne 0 ]; then
            exit ${RET}
        fi
    else
        info "Uploading stx-openstack application"
        log_command "system application-upload stx-openstack helm-charts-manifest-no-tests.tgz"
        wait_for_application_upload
        RET=$?
        if [ ${RET} -ne 0 ]; then
            exit ${RET}
        fi
        info "Applying stx-openstack application"
        log_command "system application-apply stx-openstack"
        wait_for_application_apply
        RET=$?
        if [ ${RET} -ne 0 ]; then
            exit ${RET}
        fi
    fi

    #log_command "ceph osd pool ls | xargs -i ceph osd pool set {} size 1"
    stage_complete "openstack_deployment"
    return 0
}

#wait for ceph monitor to be ready
function wait_for_ceph_mon {
    local CEPH_MON_CONFIGURED_TIMEOUT=600
    local CEPH_MON_CONFIGURED_DELAY=0
    local NODE=$1
    while [[ $CEPH_MON_CONFIGURED_DELAY -lt $CEPH_MON_CONFIGURED_TIMEOUT ]]; do
        ceph_info=$(system ceph-mon-list ${CLI_NOWRAP} | grep ${NODE})
        ceph_status=$(echo ${ceph_info}| awk '{print $8}')

        if [[ ${ceph_status} == *"configuring"* ]]; then
            log "Waiting for ceph mon to become configured on ${NODE}"
            sleep 10
            CEPH_MON_CONFIGURED_DELAY=$((CEPH_MON_CONFIGURED_DELAY + 10))
        else
            log "ceph mon configured on ${NODE}"
            break
        fi
    done

    if [[ CEPH_MON_CONFIGURED_DELAY -eq CEPH_MON_CONFIGURED_TIMEOUT ]]; then
        echo "ERROR: timed out waiting for ceph mon to become configured"
        return 1
    fi
    return 0
}

#add ceph monitor for standard system
function add_ceph_mon {
    local STORAGE_NODES=$(system host-list ${CLI_NOWRAP} | awk '{if ($6 == "storage") print $4}')
    if [ ! -z "${STORAGE_NODES}" ]; then
        return 0
    fi
    if is_stage_complete "ceph-mon"; then
        info "Skipping k8s cert configuration; already done"
        return 0
    fi
    local HOSTS=$(system host-list ${CLI_NOWRAP} | awk '{if ($6 == "worker") print $4}')
    if [ ! -z "${HOSTS}" ]; then
        log_command "system ceph-mon-add "${HOSTS[0]}""
        wait_for_ceph_mon ${HOSTS[0]}
        echo "After unlocking worker nodes, lock controller-1"
        echo "Add osd to controller-1, unlock"
        echo "swact to controller-1, lock controller-0"
        echo "Add osd to controller-0, unlock"
        echo "swact back to controller-0, and run lab_setup.sh"
        stage_complete "ceph-mon"
    fi

    return 0
}

#install cert
function install_k8s_cert {
    if [ "$K8S_ENABLED" != "yes" ]; then
        return 0
    fi
    if is_stage_complete "k8scert"; then
        info "Skipping k8s cert configuration; already done"
        return 0
    fi

    log_command "git archive --remote=git://147.11.178.22/users/rchurch/k8s/tools.git stx-containers2 ca-cert.pem | tar -x"
    log_command "echo ${DEFAULT_OPENSTACK_PASSWORD} sudo -S cp ca-cert.pem /etc/pki/ca-trust/source/anchors/"
    log_command "echo ${DEFAULT_OPENSTACK_PASSWORD} sudo -S update-ca-trust"

    stage_complete "k8scert"
    return 0
}

#Add labels
function add_k8s_label {
    local ALL_NODES=$(system host-list ${CLI_NOWRAP} | awk '{if (($6=="controller" || $6=="worker") && ($12 != "offline")) print $4;}')
    for NODE in ${ALL_NODES}; do
        if is_stage_complete "k8s_label" ${NODE}; then
            info "Skipping k8s label configuration for ${NODE}; already done"
            continue
        fi
        if [[ "${NODE}" == "controller"* ]]; then
            info "Adding K8S label for ${NODE}"
            log_command "system host-label-assign ${NODE} openstack-control-plane=enabled"
            if [[ "${SMALL_SYSTEM}" == "yes" ]]; then
                log_command "system host-label-assign ${NODE} openstack-worker-node=enabled"
                log_command "system host-label-assign ${NODE} openvswitch=enabled"
                log_command "system host-label-assign ${NODE} sriov=enabled"
            fi
        elif [[ "${NODE}" == "worker"* ]]; then
            info "Adding K8S label for ${NODE}"
            log_command "system host-label-assign ${NODE} openstack-worker-node=enabled"
            log_command "system host-label-assign ${NODE} openvswitch=enabled"
            log_command "system host-label-assign ${NODE} sriov=enabled"
        fi
        stage_complete "k8s_label" ${NODE}
    done
    return 0
}

#
# Https Changes


if [ -f "${STATUS_FILE}" ]; then
    rm -f ${STATUS_FILE}
fi


log "============================================================================"
log "Starting lab setup (${CONFIG_FILE}): $(date)"
declare -p >> ${LOG_FILE}
log "============================================================================"

echo "Checking for required files"
check_required_files
RET=$?
if [ ${RET} -ne 0 ]; then
    echo "Failed to check required files, ret=${RET}"
    exit ${RET}
fi

if [ ! -z "${SYSTEM_NAME}" ]; then
    set_system_name ${SYSTEM_NAME}
    RET=$?
    if [ ${RET} -ne 0 ]; then
        echo "Failed to set system name, ret=${RET}"
        exit ${RET}
    fi
fi

set_vswitch_type ${VSWITCH_TYPE}
RET=$?
if [ ${RET} -ne 0 ]; then
    echo "Failed to set vswitch type, ret=${RET}"
    exit ${RET}
fi

#  Check HTTPS configuration.
# 1. if the config file has HTTPS_ENABLED=true/false and the system
# https configuration is different than the config file value ,
# we will modify the sytem https value to match with config file value.
# This will happen at the first stages of lab setup as the endpoints
# will be converted to https , and other service use these endpoints
# 2. If the config file has CERTIFICATE_FILENAME ,
# parameter , we will copy the certificate using
# "system certificate-install" . This will be done as one
# of the last steps in lab_setup
setup_https_security_configuration
RET=$?
if [ ${RET} -ne 0 ]; then
    echo "Failed to set HTTPS Security configuration , ret=${RET}"
    exit ${RET}
fi

setup_neutron_service_parameters
RET=$?
if [ ${RET} -ne 0 ]; then
    echo "Failed to setup BGP service parameters"
    return ${RET}
fi

setup_sdn
RET=$?
if [ ${RET} -ne 0 ]; then
    echo "Failed to setup SDN, ret=${RET}"
    exit ${RET}
fi

setup_sfc
RET=$?
if [ ${RET} -ne 0 ]; then
    echo "Failed to setup SFC, ret=${RET}"
    exit ${RET}
fi

if [ "x${DISTRIBUTED_CLOUD_ROLE}" != "xsubcloud" ]; then
    set_dns
    RET=$?
    if [ ${RET} -ne 0 ]; then
        echo "Failed to set DNS configuration, ret=${RET}"
        exit ${RET}
    fi

    set_time_service
    RET=$?
    if [ ${RET} -ne 0 ]; then
        echo "Failed to set $TIMESERVICE configuration, ret=${RET}"
        exit ${RET}
    fi
fi

add_partitions
RET=$?
if [ ${RET} -ne 0 ]; then
    echo "Failed to create partitions, ret=${RET}"
    exit ${RET}
fi

extend_cgts_vg
RET=$?
if [ ${RET} -ne 0 ]; then
    echo "Failed to extend cgts-vg, ret=${RET}"
    exit ${RET}
fi

add_local_storage
RET=$?
if [ ${RET} -ne 0 ]; then
    echo "Failed to add local storage, ret=${RET}"
    exit ${RET}
fi

# Early configuration of Ceph storage backend
if [ "${CONFIGURE_STORAGE_CEPH}" == "yes" -a "${WHEN_TO_CONFIG_CEPH}" == "early" ]; then
    storage_backend_enable "ceph"
    RET=$?
    if [ ${RET} -ne 0 ]; then
        echo "Failed to set Ceph storage backend configuration, ret=${RET}"
        exit ${RET}
    fi
fi

# On secondary region, if cinder is shared from primary region,
# it will be added as a service to the external backend
if [[ ${CINDER_BACKENDS} =~ "external" ]]; then
    storage_backend_enable "external"
    RET=$?
    if [ ${RET} -ne 0 ]; then
        echo "Failed to set external storage backend configuration, ret=${RET}"
        exit ${RET}
    fi
    # Because we create duplicate endpoints in the primary region, let's
    # wait a bit more
    sleep 20
fi

if [ "x${DISTRIBUTED_CLOUD_ROLE}" != "xcontroller" ]; then
    add_provider_networks
    RET=$?
    if [ ${RET} -ne 0 ]; then
        echo "Failed to add data networks, ret=${RET}"
        exit ${RET}
    fi
fi

# Setup custom firewall rules if file is specified
if [ ! -z "${FIREWALL_RULES_FILE:-}" ]; then
    setup_custom_firewall_rules
fi

install_k8s_cert
RET=$?
if [ ${RET} -ne 0 ]; then
    echo "Failed to add data interfaces, ret=${RET}"
    exit ${RET}
fi

add_k8s_label
RET=$?
if [ ${RET} -ne 0 ]; then
    echo "Failed to add labels, ret=${RET}"
    exit ${RET}
fi


if [ "x${SMALL_SYSTEM}" != "xyes" ]; then
    FILE=${HOME}/.lab_setup.group${GROUPNO}.waitfornodes
    if [ ! -f ${FILE} -a "x${PAUSE_CONFIG}" == "xyes" ]; then
        touch ${FILE}
        echo ""
        echo "WARNING:"
        echo "Stopping after last operation. Rerun this command after"
        if [ "${CONFIGURE_STORAGE_CEPH}" == "yes" -a "${WHEN_TO_CONFIG_CEPH}" == "early" ]; then
            echo "controller-1 plus all storage & worker nodes have become 'online' "
            echo "after inital installation."
            echo ""
        else
            echo "all worker nodes have become 'online' after initial"
            echo "installation."
            echo ""
        fi
        exit 0
    fi
fi

if [ "x${DISTRIBUTED_CLOUD_ROLE}" != "xcontroller" ]; then
    COUNT=$(echo ${NODES} | wc -w)
    if [ ${COUNT} -eq 0 -a -z "${STORAGE_NODES}" -a -z "${CONTROLLER_NODES}" ]; then
        echo ""
        echo "ERROR: There are no storage, worker or controller+worker nodes online"
        echo ""
        exit 1
    fi
fi

if [[ (("${VIRTUALNODES}" == "yes")) ]]; then
        write_flag_file
        RET=$?
        if [ ${RET} -ne 0 ]; then
                echo "Failed to write flags, ret=${RET}"
                exit ${RET}
        fi

        set_reserved_memory
        RET=$?
        if [ ${RET} -ne 0 ]; then
                echo "Failed to set memory, ret=${RET}"
                exit ${RET}
        fi
fi

add_interfaces
RET=$?
if [ ${RET} -ne 0 ]; then
    echo "Failed to add data interfaces, ret=${RET}"
    exit ${RET}
fi

if [ "x${BM_ENABLED}" == "xyes" ]; then
    add_board_management
    RET=$?
    if [ ${RET} -ne 0 ]; then
        echo "Failed to board management configuration, ret=${RET}"
        exit ${RET}
    fi
fi

source ${OPENRC}
# Setup the OSD if the system doesn't have separate ceph storage nodes
setup_osd_storage


setup_vswitch_cpus
RET=$?
if [ ${RET} -ne 0 ]; then
    echo "Failed to setup vswitch CPU configuration, ret=${RET}"
    exit ${RET}
fi

add_data_addresses_and_routes

RET=$?
if [ ${RET} -ne 0 ]; then
    echo "Failed to add IP addresses and routes to data interfaces, ret=${RET}"
    exit ${RET}
fi

if [ -z "${AVAIL_CONTROLLER_NODES}" -a "${SYSTEM_MODE}" != "simplex" ]; then
    if [ "${CONFIGURE_STORAGE_CEPH}" == "yes" -a -n "${CONTROLLER_NODES}" ]; then
        if [ "x${PAUSE_CONFIG}" == "xyes" ]; then
            echo ""
            echo "WARNING:"
            echo "Stopping after initial controller node setup.  Rerun this command"
            echo "after ${CONTROLLER_NODES} has been unlocked and is enabled."
            echo ""
            exit 0
        fi
    fi
fi

if [ "${CONFIGURE_STORAGE_CEPH}" == "yes" -a "${WHEN_TO_CONFIG_CEPH}" == "early" ]; then
    if [ ! -z "${STORAGE_NODES}" ]; then

        setup_ceph_storage_tiers
        RET=$?
        if [ ${RET} -ne 0 ]; then
            echo "Failed to setup additional ceph storage tiers, ret=${RET}"
            exit ${RET}
        fi

        setup_journal_storage
        RET=$?
        if [ ${RET} -ne 0 ]; then
            echo "Failed to setup Journal storage, ret=${RET}"
            exit ${RET}
        fi

        setup_osd_storage
        RET=$?
        if [ ${RET} -ne 0 ]; then
            echo "Failed to setup OSD storage, ret=${RET}"
            exit ${RET}
        fi

        setup_ceph_storage_tier_backends
        RET=$?
        if [ ${RET} -ne 0 ]; then
            echo "Failed to setup additional ceph backends, ret=${RET}"
            exit ${RET}
        fi

        FILE=${HOME}/.lab_setup.group${GROUPNO}.storage
        if [ ! -f ${FILE} -a "x${PAUSE_CONFIG}" == "xyes" ]; then
            touch ${FILE}
            echo ""
            echo "WARNING:"
            echo "Stopping after initial storage node setup.  Rerun this command"
            echo "after all storage nodes have been unlocked and are enabled, and"
            echo "all worker nodes have become 'online' after initial installation."
            echo ""
            exit 0
        fi
    fi
fi

add_ceph_mon
RET=$?
if [ ${RET} -ne 0 ]; then
    echo "Failed to add_ceph_mon, ret=${RET}"
    exit ${RET}
fi

if [ "x${DISTRIBUTED_CLOUD_ROLE}" != "xcontroller" ]; then
    FILE=${HOME}/.lab_setup.group${GROUPNO}.interfaces
    if [ ! -f ${FILE} -a "x${PAUSE_CONFIG}" == "xyes" ]; then
        touch ${FILE}
        COUNT=$(echo ${NODES} | wc -w)
        if [ "x${SMALL_SYSTEM}" != "xyes" ]; then
            echo ""
            echo "WARNING:"
            echo "Stopping after data interface setup.  Rerun this command"
            echo "after all worker nodes have been unlocked and are enabled."
            echo ""
            exit 0
        elif [ ${COUNT} -lt 2 ]; then
            echo ""
            echo "WARNING:"
            echo "Stopping after data interface setup.  Rerun this command"
            echo "after controller-0 is unlocked and enabled"
            echo ""
            exit 0
        fi

    ## continue
    fi
fi

# Late configuration of Ceph storage backend
if [ "${CONFIGURE_STORAGE_CEPH}" == "yes" -a "${WHEN_TO_CONFIG_CEPH}" == "late" ]; then
    ENABLED_CONTROLLER_NODES=$(system host-list ${CLI_NOWRAP} | awk '{if ($6=="controller" && ($10 == "enabled")) print $4;}')

    enabled_controller_nodes=( ${ENABLED_CONTROLLER_NODES} )

    if [ "${#enabled_controller_nodes[@]}" -lt 2 ]; then
        if [ "x${PAUSE_CONFIG}" == "xyes" ]; then
            echo ""
            echo "WARNING:"
            echo "Stopping after initial controller node setup.  Rerun this command"
            echo "after both controller nodes have been unlocked and enabled."
            echo ""
            exit 0
        fi
    fi

    #TODO: merge this and the early config in one function (to eliminate code duplication)
    storage_backend_enable "ceph"
    RET=$?
    if [ ${RET} -ne 0 ]; then
        echo "Failed to set Ceph storage backend configuration, ret=${RET}"
        exit ${RET}
    fi

    #TODO: Remove after sm supports in-service process restarts
    FILE=${HOME}/.lab_setup.group${GROUPNO}.storage_backend_enable_ceph
    if [ ! -f ${FILE} -a "x${PAUSE_CONFIG}" == "xyes" ]; then
        touch ${FILE}
        echo ""
        echo "WARNING:"
        echo "Stopping after Ceph backend provisioning. Rerun this command"
        echo "after doing the following steps:"
        echo " 1. lock and unlock controller-1"
        echo " 2. swact to controller-1"
        echo " 3. lock and unlock controller-0"
        echo " 4. swact to contoller-0"
        echo ""
        exit 0
    fi

    storage_nodes=$(system host-list ${CLI_NOWRAP} | grep storage | awk '{if ($12 != "offline") {print $4;}}' | wc -l)
    if [ ${storage_nodes} -lt 2 ]; then
        echo ""
        echo "WARNING:"
        echo "Stopping after adding Ceph backend. Install at least two storage nodes "
        echo "then rerun this command after they are online."
        echo ""
        exit 0
    fi

    setup_ceph_storage_tiers
    RET=$?
    if [ ${RET} -ne 0 ]; then
        echo "Failed to setup additional Ceph storage tiers, ret=${RET}"
        exit ${RET}
    fi

    setup_journal_storage
    RET=$?
    if [ ${RET} -ne 0 ]; then
        echo "Failed to setup Journal storage, ret=${RET}"
        exit ${RET}
    fi

    setup_osd_storage
    RET=$?
    if [ ${RET} -ne 0 ]; then
        echo "Failed to setup OSD storage, ret=${RET}"
        exit ${RET}
    fi

    setup_ceph_storage_tier_backends
    RET=$?
    if [ ${RET} -ne 0 ]; then
        echo "Failed to setup additional ceph backends, ret=${RET}"
        exit ${RET}
    fi

    FILE=${HOME}/.lab_setup.group${GROUPNO}.storage
    if [ ! -f ${FILE} -a "x${PAUSE_CONFIG}" == "xyes" ]; then
        touch ${FILE}
        echo ""
        echo "WARNING:"
        echo "Stopping after initial storage node setup.  Rerun this command"
        echo "after all storage nodes have been unlocked and are enabled."
        echo ""
        exit 0
    fi
fi

FILE=.no_openstack_install
if [ -f ${FILE} ]; then
    echo "File to stop exsist, if you want to continue, remove .no_openstack_install file and run."
    exit 0
fi

###Need to bring up the pods here for kubernetes:

setup_kube_pods
RET=$?
if [ ${RET} -ne 0 ]; then
    echo "Failed to apply application, ret=${RET}"
    exit ${RET}
fi
if [ "$K8S_ENABLED" == "yes" ]; then
    unset OS_AUTH_URL
    export OS_AUTH_URL=${K8S_URL}
    setup_providernet_tenants_quota_crentials
    add_network_segment_ranges

fi

if [ "x${DISTRIBUTED_CLOUD_ROLE}" != "xcontroller" ]; then

    setup_internal_networks
    RET=$?
    if [ ${RET} -ne 0 ]; then
        echo "Failed to setup infrastructure networks, ret=${RET}"
        exit ${RET}
    fi

    setup_management_networks
    RET=$?
    if [ ${RET} -ne 0 ]; then
        echo "Failed to setup management networks, ret=${RET}"
        exit ${RET}
    fi

    setup_ixia_networks
    RET=$?
    if [ ${RET} -ne 0 ]; then
        echo "Failed to setup ixia networks, ret=${RET}"
        exit ${RET}
    fi

    setup_tenant_networks
    RET=$?
    if [ ${RET} -ne 0 ]; then
        echo "Failed to setup tenant networks, ret=${RET}"
        exit ${RET}
    fi

    if [ "x${FLOATING_IP}" == "xyes" ]; then
        setup_floating_ips
        RET=$?
        if [ ${RET} -ne 0 ]; then
            echo "Failed to setup floating IP addresses, ret=${RET}"
            exit ${RET}
        fi
    fi
fi


source ${OPENRC}

resize_controller_filesystem
RET=$?
if [ ${RET} -ne 0 ]; then
    info "Failed to resize controller file systems, ret=${RET}"
    exit ${RET}
fi

log_command "system controllerfs-list"
log_command "drbd-overview"

## return to admin context
source ${OPENRC}


echo "CONFIG_FILE=${CONFIG_FILE}" > ${STATUS_FILE}
echo "CONFIG_FILE=${CONFIG_FILE}" > ${GROUP_STATUS}
echo "Done"

exit 0

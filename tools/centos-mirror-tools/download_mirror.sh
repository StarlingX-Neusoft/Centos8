#!/bin/bash -e
#
# SPDX-License-Identifier: Apache-2.0
#

usage() {
    echo "$0 [-n] [-c <yum.conf>] [-g] [-s|-S|-u|-U]"
    echo ""
    echo "Options:"
    echo "  -n: Do not use sudo when performing operations (option passed on to"
    echo "      subscripts when appropriate)"
    echo "  -c: Use an alternate yum.conf rather than the system file (option passed"
    echo "      on to subscripts when appropriate)"
    echo "  -g: do not change group IDs of downloaded artifacts"
    echo "  -s: Download from StarlingX mirror only"
    echo "  -S: Download from StarlingX mirror, upstream as backup (default)"
    echo "  -u: Download from original upstream sources only"
    echo "  -U: Download from original upstream sources, StarlingX mirror as backup"
    echo ""
}

generate_log_name() {
    filename=$1
    level=$2
    base=$(basename $filename .lst)
    echo $LOGSDIR"/"$base"_download_"$level".log"
}

need_file(){
    for f in $*; do
        if [ ! -f $f ]; then
            echo "ERROR: File $f does not exist."
            exit 1
        fi
    done
}

need_dir(){
    for d in $*; do
        if [ ! -d $d ]; then
            echo "ERROR: Directory $d does not exist."
            exit 1
        fi
    done
}

# Downloader scripts
rpm_downloader="./dl_rpms.sh"
tarball_downloader="./dl_tarball.sh"
other_downloader="./dl_other_from_centos_repo.sh"
make_stx_mirror_yum_conf="./make_stx_mirror_yum_conf.sh"

# track optional arguments
change_group_ids=1
use_system_yum_conf=1
alternate_yum_conf=""
alternate_repo_dir=""
rpm_downloader_extra_args=""
tarball_downloader_extra_args=""
distro="centos"

# lst files to use as input
rpms_from_3rd_parties="./rpms_3rdparties.lst"
rpms_from_centos_repo="./rpms_centos.lst"
rpms_from_centos_3rd_parties="./rpms_centos3rdparties.lst"
other_downloads="./other_downloads.lst"

# Overall success
success=1

# Permitted values of dl_source
dl_from_stx_mirror="stx_mirror"
dl_from_upstream="upstream"
dl_from_stx_then_upstream="$dl_from_stx_mirror $dl_from_upstream"
dl_from_upstream_then_stx="$dl_from_upstream $dl_from_stx_mirror"

# Download from what source?
#   dl_from_stx_mirror = StarlingX mirror only
#   dl_from_upstream   = Original upstream source only
#   dl_from_stx_then_upstream = Either source, STX prefered (default)"
#   dl_from_upstream_then_stx = Either source, UPSTREAM prefered"
dl_source="$dl_from_stx_then_upstream"
dl_flag=""

dl_from_stx () {
    local re="\\b$dl_from_stx_mirror\\b"
    [[ "$dl_source" =~ $re ]]
}

dl_from_upstream () {
    local re="\\b$dl_from_upstream\\b"
    [[ "$dl_source" =~ $re ]]
}


MULTIPLE_DL_FLAG_ERROR_MSG="Error: Please use only one of: -s,-S,-u,-U"

multiple_dl_flag_check () {
    if [ "$dl_flag" != "" ]; then
        echo "$MULTIPLE_DL_FLAG_ERROR_MSG"
        usage
        exit 1
    fi
}

# Parse out optional arguments
while getopts "c:nghsSuU" o; do
    case "${o}" in
        n)
            # Pass -n ("no-sudo") to rpm downloader
            rpm_downloader_extra_args="${rpm_downloader_extra_args} -n"
            ;;
        c)
            # Pass -c ("use alternate yum.conf") to rpm downloader
            use_system_yum_conf=0
            alternate_yum_conf="${OPTARG}"
            ;;
        g)
            # Do not attempt to change group IDs on downloaded packages
            change_group_ids=0
            ;;
        s)
            # Download from StarlingX mirror only. Do not use upstream sources.
            multiple_dl_flag_check
            dl_source="$dl_from_stx_mirror"
            dl_flag="-s"
            ;;
        S)
            # Download from StarlingX mirror only. Do not use upstream sources.
            multiple_dl_flag_check
            dl_source="$dl_from_stx_then_upstream"
            dl_flag="-S"
            ;;
        u)
            # Download from upstream only. Do not use StarlingX mirror.
            multiple_dl_flag_check
            dl_source="$dl_from_upstream"
            dl_flag="-u"
            ;;
        U)
            # Download from upstream only. Do not use StarlingX mirror.
            multiple_dl_flag_check
            dl_source="$dl_from_upstream_then_stx"
            dl_flag="-U"
            ;;
        h)
            # Help
            usage
            exit 0
            ;;
        *)
            usage
            exit 1
            ;;
    esac
done
shift $((OPTIND-1))

echo "--------------------------------------------------------------"

echo "WARNING: this script HAS TO access internet (http/https/ftp),"
echo "so please make sure your network working properly!!"


LOGSDIR="logs"
mkdir -p $LOGSDIR


# Check extistence of prerequisites files
need_file ${rpm_downloader} ${other_downloader} ${tarball_downloader}
need_file ${rpms_from_3rd_parties}
need_file ${rpms_from_centos_3rd_parties}
need_file ${rpms_from_centos_repo}
need_file ${other_downloads}
need_file tarball-dl.lst

#download RPMs/SRPMs from 3rd_party websites (not CentOS repos) by "wget"
echo "step #1: start downloading RPMs/SRPMs from 3rd-party websites..."

if [ ${use_system_yum_conf} -ne 0 ]; then
    # Restore StarlingX_3rd repos from backup
    REPO_SOURCE_DIR=/localdisk/yum.repos.d
    REPO_DIR=/etc/yum.repos.d
    if [ -d $REPO_SOURCE_DIR ] && [ -d $REPO_DIR ]; then
        \cp -f $REPO_SOURCE_DIR/*.repo $REPO_DIR/
    fi
fi

if [ $use_system_yum_conf -eq 0 ]; then
    need_file "${alternate_yum_conf}"
    if [ "$alternate_repo_dir" == "" ]; then
        alternate_repo_dir=$(grep '^reposdir=' "${alternate_yum_conf}" | cut -d '=' -f 2)
        if [ "$alternate_repo_dir" == "" ]; then
            alternate_repo_dir="$(dirname "${alternate_yum_conf}"/yum.repos.d)"
        fi
        need_dir "${alternate_repo_dir}"
    fi
fi

TEMP_DIR=""
rpm_downloader_extra_args="${rpm_downloader_extra_args} -D $distro"

if [ "$dl_flag" != "" ]; then
    # Pass dl_flag on to the rpm_downloader script
    rpm_downloader_extra_args="${rpm_downloader_extra_args} $dl_flag"
fi

if ! dl_from_stx; then
    # Not using stx mirror
    if [ $use_system_yum_conf -eq 0 ]; then
        # Use provided yum.conf unaltered.
        rpm_downloader_extra_args="${rpm_downloader_extra_args} -c ${alternate_yum_conf}"
    fi
else
    # We want to use stx mirror, so we need to create a new, modified yum.conf and yum.repos.d.
    # The modifications will add or substitute repos pointing to the StralingX mirror.
    TEMP_DIR=$(mktemp -d /tmp/stx_mirror_XXXXXX)
    TEMP_CONF="$TEMP_DIR/yum.conf"
    need_file ${make_stx_mirror_yum_conf}
    need_dir ${TEMP_DIR}

    if [ $use_system_yum_conf -eq 0 ]; then
        # Modify user provided yum.conf.  We expect ir to have a 'reposdir=' entry to
        # point to the repos that need to be modified as well.
        if dl_from_upstream; then
            # add
            ${make_stx_mirror_yum_conf} -R -d $TEMP_DIR -y $alternate_yum_conf -r $alternate_repo_dir -D $distro
        else
            # substitute
            ${make_stx_mirror_yum_conf} -d $TEMP_DIR -y $alternate_yum_conf -r $alternate_repo_dir -D $distro
        fi
    else
        # Modify system yum.conf and yum.repos.d.  Remember that we expect to run this
        # inside a container, and the system yum.conf has like been modified else where
        # in these scripts.
        if dl_from_upstream; then
            # add
            ${make_stx_mirror_yum_conf} -R -d $TEMP_DIR -y /etc/yum.conf -r /etc/yum.repos.d -D $distro
        else
            # substitute
            ${make_stx_mirror_yum_conf} -d $TEMP_DIR -y /etc/yum.conf -r /etc/yum.repos.d -D $distro
        fi
    fi

    rpm_downloader_extra_args="${rpm_downloader_extra_args} -c $TEMP_CONF"
fi

list=${rpms_from_3rd_parties}
level=L1
logfile=$(generate_log_name $list $level)
$rpm_downloader ${rpm_downloader_extra_args} $list $level |& tee $logfile
retcode=${PIPESTATUS[0]}
if [ $retcode -ne 0 ];then
    echo "ERROR: Something wrong with downloading files listed in $list."
    echo "   Please check the log at $(pwd)/$logfile !"
    echo ""
    success=0
fi

# download RPMs/SRPMs from 3rd_party repos by "yumdownloader"
list=${rpms_from_centos_3rd_parties}
level=L1
logfile=$(generate_log_name $list $level)
$rpm_downloader ${rpm_downloader_extra_args} $list $level |& tee $logfile
retcode=${PIPESTATUS[0]}
if [ $retcode -ne 0 ];then
    echo "ERROR: Something wrong with downloading files listed in $list."
    echo "   Please check the log at $(pwd)/$logfile !"
    echo ""
    success=0
fi

if [ ${use_system_yum_conf} -eq 1 ]; then
    # deleting the StarlingX_3rd to avoid pull centos packages from the 3rd Repo.
    \rm -f $REPO_DIR/StarlingX_3rd*.repo
    if [ "$TEMP_DIR" != "" ]; then
        \rm -f $TEMP_DIR/yum.repos.d/StarlingX_3rd*.repo
    fi
fi


echo "step #2: start 1st round of downloading RPMs and SRPMs with L1 match criteria..."
#download RPMs/SRPMs from CentOS repos by "yumdownloader"
list=${rpms_from_centos_repo}
level=L1
logfile=$(generate_log_name $list $level)
$rpm_downloader ${rpm_downloader_extra_args} $list $level |& tee $logfile
retcode=${PIPESTATUS[0]}


K1_logfile=$(generate_log_name ${rpms_from_centos_repo} K1)
if [ $retcode -ne 1 ]; then
    # K1 step not needed. Clear any K1 logs from previous download attempts.
    $rpm_downloader -x $LOGSDIR/L1_rpms_missing_centos.log K1 |& tee $K1_logfile
fi

if [ $retcode -eq 0 ]; then
    echo "finish 1st round of RPM downloading successfully!"
elif [ $retcode -eq 1 ]; then
    echo "finish 1st round of RPM downloading with missing files!"
    if [ -e "$LOGSDIR/L1_rpms_missing_centos.log" ]; then

        echo "start 2nd round of downloading Binary RPMs with K1 match criteria..."
        $rpm_downloader ${rpm_downloader_extra_args} $LOGSDIR/L1_rpms_missing_centos.log K1 centos |& tee $K1_logfile
        retcode=${PIPESTATUS[0]}
        if [ $retcode -eq 0 ]; then
            echo "finish 2nd round of RPM downloading successfully!"
        elif [ $retcode -eq 1 ]; then
            echo "finish 2nd round of RPM downloading with missing files!"
            if [ -e "$LOGSDIR/rpms_missing_K1.log" ]; then
                echo "WARNING: missing RPMs listed in $LOGSDIR/centos_rpms_missing_K1.log !"
            fi
        fi

        # Remove files found by K1 download from L1_rpms_missing_centos.txt to prevent
        # false reporting of missing files.
        grep -v -x -F -f $LOGSDIR/K1_rpms_found_centos.log $LOGSDIR/L1_rpms_missing_centos.log  > $LOGSDIR/L1_rpms_missing_centos.tmp
        mv -f $LOGSDIR/L1_rpms_missing_centos.tmp $LOGSDIR/L1_rpms_missing_centos.log


        missing_num=`wc -l $LOGSDIR/K1_rpms_missing_centos.log | cut -d " " -f1-1`
        if [ "$missing_num" != "0" ];then
            echo "ERROR:  -------RPMs missing: $missing_num ---------------"
            retcode=1
        fi
    fi

    if [ -e "$LOGSDIR/L1_srpms_missing_centos.log" ]; then
        missing_num=`wc -l $LOGSDIR/L1_srpms_missing_centos.log | cut -d " " -f1-1`
        if [ "$missing_num" != "0" ];then
            echo "ERROR: --------- SRPMs missing: $missing_num ---------------"
            retcode=1
        fi
    fi
fi

if [ $retcode -ne 0 ]; then
    echo "ERROR: Something wrong with downloading files listed in ${rpms_from_centos_repo}."
    echo "   Please check the logs at $(pwd)/$logfile"
    echo "   and $(pwd)/logs/$K1_logfile !"
    echo ""
    success=0
fi

## verify all RPMs SRPMs we download for the GPG keys
find ./output -type f -name "*.rpm" | xargs rpm -K | grep -i "MISSING KEYS" > $LOGSDIR/rpm-gpg-key-missing.txt

# remove all i686.rpms to avoid pollute the chroot dep chain
find ./output -name "*.i686.rpm" | tee $LOGSDIR/all_i686.txt
find ./output -name "*.i686.rpm" | xargs rm -f

line1=`wc -l ${rpms_from_3rd_parties} | cut -d " " -f1-1`
line2=`wc -l ${rpms_from_centos_repo} | cut -d " " -f1-1`
line3=`wc -l ${rpms_from_centos_3rd_parties} | cut -d " " -f1-1`
let total_line=$line1+$line2+$line3
echo "We expected to download $total_line RPMs."
num_of_downloaded_rpms=`find ./output -type f -name "*.rpm" | wc -l | cut -d" " -f1-1`
echo "There are $num_of_downloaded_rpms RPMs in output directory."
if [ "$total_line" != "$num_of_downloaded_rpms" ]; then
    echo "WARNING: Not the same number of RPMs in output as RPMs expected to be downloaded, need to check outputs and logs."
fi

if [ $change_group_ids -eq 1 ]; then
    # change "./output" and sub-folders to 751 (cgcs) group
    chown  751:751 -R ./output
fi


echo "step #3: start downloading other files ..."

logfile=$LOGSDIR"/otherfiles_centos_download.log"
${other_downloader} ${dl_flag} -D "$distro" ${other_downloads} ./output/stx-r1/CentOS/pike/Binary/ |& tee $logfile
retcode=${PIPESTATUS[0]}
if [ $retcode -eq 0 ];then
    echo "step #3: done successfully"
else
    echo "step #3: finished with errors"
    echo "ERROR: Something wrong with downloading from ${other_downloads}."
    echo "   Please check the log at $(pwd)/$logfile!"
    echo ""
    success=0
fi


# StarlingX requires a group of source code pakages, in this section
# they will be downloaded.
echo "step #4: start downloading tarball compressed files"
logfile=$LOGSDIR"/tarballs_download.log"
${tarball_downloader} ${dl_flag} -D "$distro" ${tarball_downloader_extra_args}  |& tee $logfile
retcode=${PIPESTATUS[0]}
if [ $retcode -eq 0 ];then
    echo "step #4: done successfully"
else
    echo "step #4: finished with errors"
    echo "ERROR: Something wrong with downloading tarballs."
    echo "   Please check the log at $(pwd)/$logfile !"
    echo ""
    success=0
fi

#
# Clean up the mktemp directory, if required.
#
if [ "$TEMP_DIR" != "" ]; then
    \rm -rf "$TEMP_DIR"
fi

echo "IMPORTANT: The following 3 files are just bootstrap versions. Based"
echo "on them, the workable images for StarlingX could be generated by"
echo "running \"update-pxe-network-installer\" command after \"build-iso\""
echo "    - out/stx-r1/CentOS/pike/Binary/LiveOS/squashfs.img"
echo "    - out/stx-r1/CentOS/pike/Binary/images/pxeboot/initrd.img"
echo "    - out/stx-r1/CentOS/pike/Binary/images/pxeboot/vmlinuz"

echo ""
if [ $success -ne 1 ]; then
    echo "Warning: Not all download steps succeeded.  You are likely missing files."
    exit 1
fi

echo "Success"
exit 0

#!/bin/bash
#
# SPDX-License-Identifier: Apache-2.0
#

usage () {
    echo "$0 <mirror-path>"
}

if [ $# -ne 1 ]; then
    usage
    exit -1
fi

if [ -z "$MY_REPO" ]; then
    echo "\$MY_REPO is not set. Ensure you are running this script"
    echo "from the container and \$MY_REPO points to the root of"
    echo "your folder tree."
    exit -1
fi

mirror_dir=$1
tarball_lst=${MY_REPO_ROOT_DIR}/stx-tools/centos-mirror-tools/tarball-dl.lst
downloads_dir=${MY_REPO}/stx/downloads
extra_downloads="mlnx-ofa_kernel-4.5-OFED.4.5.1.0.1.1.gb4fdfac.src.rpm libibverbs-41mlnx1-OFED.4.5.0.1.0.45101.src.rpm rdma-core-45mlnx1-1.45101.src.rpm"

mkdir -p ${MY_REPO}/stx/downloads

grep -v "^#" ${tarball_lst} | while read x; do
    if [ -z "$x" ]; then
        continue
    fi

    # Get first element of item & strip leading ! if appropriate
    tarball_file=$(echo $x | sed "s/#.*//" | sed "s/^!//")

    # put the file in downloads
    source_file=$(find ${mirror_dir}/downloads -name "${tarball_file}")
    if [ -z ${source_file} ]; then
        echo "Could not find ${tarball_file}"
    else
        rel_path=$(echo ${source_file} | sed "s%^${mirror_dir}/downloads/%%")
        rel_dir_name=$(dirname ${rel_path})
        if [ ! -e ${downloads_dir}/${rel_dir_name}/${tarball_file} ]; then
            mkdir -p ${downloads_dir}/${rel_dir_name}
            ln -sf ${source_file} ${downloads_dir}/${rel_dir_name}/
        fi
    fi
done

for x in ${extra_downloads}; do
    ln -sf ${mirror_dir}/downloads/$x ${downloads_dir}
done

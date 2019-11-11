#!/bin/bash
#
# SPDX-License-Identifier: Apache-2.0
#
# Copyright (C) 2019 Intel Corporation
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
dest_dir=$MY_REPO/cgcs-centos-repo
timestamp="$(date +%F_%H%M)"
mock_cfg_file=$MY_REPO/build-tools/repo_files/mock.cfg.proto
comps_xml_file=$MY_REPO/build-tools/repo_files/comps.xml
mock_cfg_dest_file=$MY_REPO/cgcs-centos-repo/mock.cfg.proto
comps_xml_dest_file=$MY_REPO/cgcs-centos-repo/Binary/comps.xml

lst_file_dir="$MY_REPO_ROOT_DIR/stx-tools/centos-mirror-tools"
rpm_lst_files="rpms_3rdparties.lst rpms_centos3rdparties.lst rpms_centos.lst"
other_lst_file="other_downloads.lst"
missing_rpms_file=missing.txt

rm -f ${missing_rpms_file}

# Strip trailing / from mirror_dir if it was specified...
mirror_dir=$(echo ${mirror_dir} | sed "s%/$%%")

if [[ ( ! -d ${mirror_dir}/Binary ) || ( ! -d ${mirror_dir}/Source ) ]]; then
    echo "The mirror ${mirror_dir} doesn't has the Binary and Source"
    echo "folders. Please provide a valid mirror"
    exit -1
fi

if [ ! -d "${dest_dir}" ]; then
    mkdir -p "${dest_dir}"
fi

for t in "Binary" "Source" ; do
    target_dir=${dest_dir}/$t
    if [ ! -d "$target_dir" ]; then
        mkdir -p "$target_dir"
    else
        mv -f "$target_dir" "$target_dir-backup-$timestamp"
        mkdir -p "$target_dir"
    fi
done

mirror_content=$(mktemp -t centos-repo-XXXXXX)
find -L ${mirror_dir} -type f > ${mirror_content}

for lst_file in ${rpm_lst_files} ; do
    grep -v "^#" ${lst_file_dir}/${lst_file} | while IFS="#" read rpmname extrafields; do
        if [ -z "${rpmname}" ]; then
            continue
        fi
        mirror_file=$(grep "/${rpmname}$" ${mirror_content})
        if [ -z "${mirror_file}" ]; then
            echo "Error -- could not find requested ${rpmname} in ${mirror_dir}"
            echo ${rpmname} >> ${missing_rpms_file}
            continue
        fi

        # Great, we found the file!  Let's strip the mirror_dir prefix from it...
        ff=$(echo ${mirror_file} | sed "s%^${mirror_dir}/%%")
        f_name=$(basename "$ff")
        sub_dir=$(dirname "$ff")

        # Make sure we have a subdir (so we don't symlink the first file as
        # the subdir name)
        mkdir -p ${dest_dir}/${sub_dir}

        # Link it!
        echo "Creating symlink for ${dest_dir}/${sub_dir}/${f_name}"
        ln -sf "${mirror_dir}/$ff" "${dest_dir}/${sub_dir}"
        if [ $? -ne 0 ]; then
            echo "Failed ${mirror_file}: ln -sf \"${mirror_dir}/$ff\" \"${dest_dir}/${sub_dir}\""
        fi
    done
done

rm -f ${mirror_content}

if [ ! -f "$mock_cfg_file" ]; then
    echo "Cannot find mock.cfg.proto file!"
    exit 1
fi

if [ ! -f "$comps_xml_file" ]; then
    echo "Cannot find comps.xml file!"
    exit 1
fi

echo "Copying mock.cfg.proto and comps.xml files."

if [ -f "$mock_cfg_dest_file" ]; then
    \cp -f "$mock_cfg_dest_file" "$mock_cfg_dest_file-backup-$timestamp"
fi
cp "$mock_cfg_file" "$mock_cfg_dest_file"

if [ -f "$comps_xml_dest_file" ]; then
    \cp -f "$comps_xml_dest_file" "$comps_xml_dest_file-backup-$timestamp"
fi
cp "$comps_xml_file" "$comps_xml_dest_file"

# Populate the contents from other list files
cat ${lst_file_dir}/${other_lst_file} | grep -v "#" | while IFS=":" read targettype item extrafields; do
    if [ "${targettype}" == "folder" ]; then
        echo "Creating folder ${item}"
        mkdir -p $MY_REPO/cgcs-centos-repo/Binary/${item}
    fi

    if [ "${targettype}" == "file" ]; then
        mkdir -p $MY_REPO/cgcs-centos-repo/Binary/$(dirname ${item})
        echo "Creating symlink for $MY_REPO/cgcs-centos-repo/Binary/${item}"
        ln -sf ${mirror_dir}/Binary/${item} $MY_REPO/cgcs-centos-repo/Binary/${item}
    fi
done

echo "Done creating repo directory"
declare -i missing_rpms_file_count=$(wc -l ${missing_rpms_file} 2>/dev/null | awk '{print $1}')
if [ ${missing_rpms_file_count} -gt 0 ]; then
    echo "WARNING: Some targets could not be found.  Your repo may be incomplete."
    echo "Missing targets:"
    cat ${missing_rpms_file}
    exit 1
fi

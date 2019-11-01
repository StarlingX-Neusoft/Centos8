#!/usr/bin/env bash

#
# SPDX-License-Identifier: Apache-2.0
#
# Copyright (C) 2019 Intel Corporation
#

# The build of StarlingX relies, besides RPM Binaries and Sources, in this
# repository which is a collection of packages in the form of Tar Compressed
# files and 3 RPMs obtained from a Tar Compressed file. This script and a text
# file containing a list of packages enable their download and the creation
# of the repository based in common and specific requirements dictated
# by the StarlingX building system recipes.

# input files:
# The file tarball-dl.lst contains the list of packages and artifacts for
# building this sub-mirror.
script_path="$(dirname $(readlink -f $0))"
tarball_file="$script_path/tarball-dl.lst"

DL_TARBALL_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}" )" )"

source $DL_TARBALL_DIR/url_utils.sh

usage () {
    echo "$0 [-D <distro>] [-s|-S|-u|-U] [-h] <other_download_list.ini> <save_path> [<force_update>]"
}

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

distro="centos"

MULTIPLE_DL_FLAG_ERROR_MSG="Error: Please use only one of: -s,-S,-u,-U"

multiple_dl_flag_check () {
    if [ "$dl_flag" != "" ]; then
        echo "$MULTIPLE_DL_FLAG_ERROR_MSG"
        usage
        exit 1
    fi
}

# Parse out optional arguments
while getopts "D:hsSuU" o; do
    case "${o}" in
        D)
            distro="${OPTARG}"
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


if [ ! -e $tarball_file ]; then
    echo "$tarball_file does not exist, please have a check!"
    exit -1
fi

# The 2 categories we can divide the list of packages in the output directory:
# - General hosted under "downloads" output directory.
# - Puppet hosted under "downloads/puppet" output directory.
# to be populated under $MY_REPO/addons/wr-cgcs/layers/cgcs/downloads/puppet

logs_dir="$script_path/logs"
output_main="$script_path/output"
output_log="$logs_dir/log_download_tarball_missing.txt"
output_path=$output_main/stx-r1/CentOS/pike
output_tarball=$output_path/downloads
output_puppet=$output_tarball/puppet

mkdir -p $output_tarball
mkdir -p $output_puppet
if [ ! -d "$logs_dir" ]; then
    mkdir "$logs_dir"
fi

is_tarball() {
    tarball_name="$1"
    mime_type=$(file --mime-type -b $tarball_name | cut -d "/" -f 2)
    types=("gzip" "x-bzip2" "x-rpm" "x-xz" "x-gzip" "x-tar")
    FOUND=1
    for t in "${types[@]}"; do
        if [ "$mime_type" == "$t" ]; then
            FOUND=0
            break;
        fi
    done
    return $FOUND
}

# Download function using wget command

download_package() {
    local tarball_name="$1"
    local upstream_url="$2"
    local stx_url=""
    local url=""
    local rc=1

    stx_url="$(url_to_stx_mirror_url "$upstream_url" "$distro")"

    for dl_src in $dl_source; do
        case $dl_src in
            $dl_from_stx_mirror)
                url="$stx_url"
                ;;
            $dl_from_upstream)
                url="$upstream_url"
                ;;
            *)
                echo "Error: Unknown dl_source '$dl_src'"
                continue
                ;;
        esac

        wget --spider "$url"
        if [ $? != 0 ]; then
            echo "Warning: '$url' is broken"
        else
            wget -q -t 5 --wait=15 -O "$tarball_name" "$url"
            if [ $? -eq 0 ]; then
                if is_tarball "$tarball_name"; then
                    echo "Ok: $download_path"
                    rc=0
                    break
                else
                    echo "Warning: File from '$url' is not a tarball"
                    \rm "$tarball_name"
                    rc=1
                fi
            else
                echo "Warning: failed to download '$url'"
                continue
            fi
        fi
    done

    if [ $rc != 0 ]; then
        echo "Error: failed to download '$upstream_url'"
        echo "$upstream_url" > "$output_log"
    fi

    return $rc
}

# This script will iterate over the tarball.lst text file and execute specific
# tasks based on the name of the package:

error_count=0;

for line in $(cat $tarball_file); do

    # A line from the text file starting with "#" character is ignored

    if [[ "$line" =~ ^'#' ]]; then
        echo "Skip $line"
        continue
    fi

    # The text file contains 3 columns separated by a character "#"
    # - Column 1, name of package including extensions as it is referenced
    #   by the build system recipe, character "!" at the beginning of the name package
    #   denotes special handling is required tarball_name=`echo $line | cut -d"#" -f1-1`
    # - Column 2, name of the directory path after it is decompressed as it is
    #   referenced in the build system recipe.
    # - Column 3, the URL for the file or git to download
    # - Column 4, download method, one of
    #             http - download a simple file
    #             http_filelist - download multiple files by appending a list of subpaths
    #                             to the base url.  Tar up the lot.
    #             http_script - download a simple file, run script whos output is a tarball
    #             git - download a git, checkout branch and tar it up
    #             git_script - download a git, checkout branch, run script whos output is a tarball
    #
    # - Column 5, utility field
    #             If method is git or git_script, this is a branch,tag,sha we need to checkout
    #             If method is http_filelist, this is the path to a file containing subpaths.
    #                 Subpaths are appended to the urls and downloaded.
    #             Otherwise unused
    # - Column 6, Path to script.
    #             Not yet supported.
    #             Intent is to run this script to produce the final tarball, replacing
    #             all the special case code currently embedded in this script.

    tarball_name=$(echo $line | cut -d"#" -f1-1)
    directory_name=$(echo $line | cut -d"#" -f2-2)
    tarball_url=$(echo $line | cut -d"#" -f3-3)
    method=$(echo $line | cut -d"#" -f4-4)
    util=$(echo $line | cut -d"#" -f5-5)
    script=$(echo $line | cut -d"#" -f6-6)

    # Remove leading '!' if present
    tarball_name="${tarball_name//!/}"

    # - For the General category and the Puppet category:
    #   - Packages have a common process: download, decompressed,
    #     change the directory path and compressed.

    if [[ "$line" =~ ^pupp* ]]; then
        download_path=$output_puppet/$tarball_name
        download_directory=$output_puppet
    else
        download_path=$output_tarball/$tarball_name
        download_directory=$output_tarball
    fi

    if [ -e $download_path ]; then
        echo "Already have $download_path"
        continue
    fi

    # We have 6 packages from the text file starting with the character "!":
    # they require special handling besides the common process: remove directory,
    # remove text from some files, clone a git repository, etc.

    if [[ "$line" =~ ^'!' ]]; then
        echo $tarball_name
        pushd $output_tarball > /dev/null
        if [ "$tarball_name" = "integrity-kmod-e6aef069.tar.gz" ]; then
            download_package "$tarball_name" "$tarball_url"
            if [ $? -ne 0 ]; then
                error_count=$((error_count + 1))
                popd > /dev/null   # pushd $output_tarball
                continue
            fi

            tar xf "$tarball_name"
            rm "$tarball_name"
            mv linux-tpmdd-e6aef06/security/integrity/ $directory_name
            tar czvf $tarball_name $directory_name
            rm -rf linux-tpmdd-e6aef06
        elif [ "$tarball_name" = "mariadb-10.1.28.tar.gz" ]; then
            download_package "$tarball_name" "$tarball_url"
            if [ $? -ne 0 ]; then
                error_count=$((error_count + 1))
                popd > /dev/null   # pushd $output_tarball
                continue
            fi

            mkdir $directory_name
            tar xf $tarball_name --strip-components 1 -C $directory_name
            rm $tarball_name
            pushd $directory_name > /dev/null
            rm -rf storage/tokudb
            rm ./man/tokuft_logdump.1 ./man/tokuftdump.1
            sed -e s/tokuft_logdump.1//g -i man/CMakeLists.txt
            sed -e s/tokuftdump.1//g -i man/CMakeLists.txt
            popd > /dev/null
            tar czvf $tarball_name $directory_name
            rm -rf $directory_name
            popd > /dev/null   # pushd $directory_name
        elif [[ "$tarball_name" = 'MLNX_OFED_SRC-4.5-1.0.1.0.tgz' ]]; then
            srpm_path="${directory_name}/SRPMS/"
            download_package "$tarball_name" "$tarball_url"
            if [ $? -ne 0 ]; then
                error_count=$((error_count + 1))
                popd > /dev/null   # pushd $output_tarball
                continue
            fi

            tar -xf "$tarball_name"
            cp "${srpm_path}/mlnx-ofa_kernel-4.5-OFED.4.5.1.0.1.1.gb4fdfac.src.rpm" .
            cp "${srpm_path}/rdma-core-45mlnx1-1.45101.src.rpm" .
            cp "${srpm_path}/libibverbs-41mlnx1-OFED.4.5.0.1.0.45101.src.rpm" .
            # Don't delete the original MLNX_OFED_LINUX tarball.
            # We don't use it, but it will prevent re-downloading this file.
            #   rm -f "$tarball_name"

            rm -rf "$directory_name"
        elif [ "$tarball_name" = "qat1.7.l.4.5.0-00034.tar.gz" ]; then
            download_package "$tarball_name" "$tarball_url"
            if [ $? -ne 0 ]; then
                error_count=$((error_count + 1))
                popd > /dev/null  # pushd $output_tarball
                continue
            fi

        elif [ "$tarball_name" = "tpm-kmod-e6aef069.tar.gz" ]; then
            download_package "$tarball_name" "$tarball_url"
            if [ $? -ne 0 ]; then
                error_count=$((error_count + 1))
                popd > /dev/null  # pushd $output_tarball
                continue
            fi

            tar xf "$tarball_name"
            rm "$tarball_name"
            mv linux-tpmdd-e6aef06/drivers/char/tpm $directory_name
            tar czvf $tarball_name $directory_name
            rm -rf linux-tpmdd-e6aef06
            rm -rf $directory_name
        elif [ "$tarball_name" = "tss2-930.tar.gz" ]; then
            dest_dir=ibmtpm20tss-tss
            for dl_src in $dl_source; do
                case $dl_src in
                    $dl_from_stx_mirror)
                        url="$(url_to_stx_mirror_url "$tarball_url" "$distro")"
                        ;;
                    $dl_from_upstream)
                        url="$tarball_url"
                        ;;
                    *)
                        echo "Error: Unknown dl_source '$dl_src'"
                        continue
                        ;;
                esac

                git clone $url $dest_dir
                if [ $? -eq 0 ]; then
                    # Success
                    break
                else
                    echo "Warning: Failed to git clone from '$url'"
                    continue
                fi
            done

            if [ ! -d $dest_dir ]; then
                echo "Error: Failed to git clone from '$tarball_url'"
                echo "$tarball_url" > "$output_log"
                error_count=$((error_count + 1))
                popd > /dev/null # pushd $output_tarball
                continue
            fi

            pushd $dest_dir > /dev/null
            branch=$util
            git checkout $branch
            rm -rf .git
            popd > /dev/null
            mv ibmtpm20tss-tss $directory_name
            tar czvf $tarball_name $directory_name
            rm -rf $directory_name
            popd > /dev/null  # pushd $dest_dir
        fi
        popd > /dev/null # pushd $output_tarball
        continue
    fi

    if [ -e $download_path ]; then
        echo "Already have $download_path"
        continue
    fi

    for dl_src in $dl_source; do
        case $dl_src in
            $dl_from_stx_mirror)
                url="$(url_to_stx_mirror_url "$tarball_url" "$distro")"
                ;;
            $dl_from_upstream)
                url="$tarball_url"
                ;;
            *)
                echo "Error: Unknown dl_source '$dl_src'"
                continue
                ;;
        esac

        download_cmd="wget -q -t 5 --wait=15 $url -O $download_path"

        if $download_cmd ; then
            if ! is_tarball "$download_path"; then
                echo "Warning: file from $url is not a tarball."
                \rm "$download_path"
                continue
            fi
            echo "Ok: $download_path"
            pushd $download_directory > /dev/null
            directory_name_original=$(tar -tf $tarball_name | head -1 | cut -f1 -d"/")
            if [ "$directory_name" != "$directory_name_original" ]; then
                mkdir -p $directory_name
                tar xf $tarball_name --strip-components 1 -C $directory_name
                tar -czf $tarball_name $directory_name
                rm -r $directory_name
            fi
            popd > /dev/null
            break
        else
            echo "Warning: Failed to download $url" 1>&2
            continue
        fi
    done

    if [ ! -e $download_path ]; then
        echo "Error: Failed to download $tarball_url" 1>&2
        echo "$tarball_url" > "$output_log"
        error_count=$((error_count + 1))
    fi
done

# End of file

if [ $error_count -ne 0 ]; then
    echo ""
    echo "Encountered $error_count errors"
    exit 1
fi

exit 0

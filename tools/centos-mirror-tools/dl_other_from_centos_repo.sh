#!/bin/bash -e

#
# SPDX-License-Identifier: Apache-2.0
#

#
# Download non-RPM files from http://vault.centos.org/7.4.1708/os/x86_64/
#

DL_OTHER_FROM_CENTOS_REPO_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}" )" )"

source $DL_OTHER_FROM_CENTOS_REPO_DIR/url_utils.sh

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

if [ $# -lt 2 ]; then
    usage
    exit -1
fi

download_list=$1
if [ ! -e $download_list ];then
    echo "$download_list does not exist, please have a check!!"
    exit -1
fi

save_path=$2
upstream_url_prefix="http://mirror.centos.org/7.6.1810/os/x86_64/"
stx_mirror_url_prefix="$(url_to_stx_mirror_url "$upstream_url_prefix" "$distro")"

echo "NOTE: please assure Internet access to $upstream_url_prefix !!"

force_update=$3

i=0
error_count=0
all=`cat $download_list`
for ff in $all; do
    ## skip commented_out item which starts with '#'
    if [[ "$ff" =~ ^'#' ]]; then
        echo "skip $ff"
        continue
    fi
    _type=`echo $ff | cut -d":" -f1-1`
    _name=`echo $ff | cut -d":" -f2-2`
    if [ "$_type" == "folder" ];then
        mkdir -p $save_path/$_name
        if [ $? -ne 0 ]; then
            echo "Error: mkdir -p '$save_path/$_name'"
            error_count=$((error_count + 1))
        fi
    else
        if [ -e "$save_path/$_name" ]; then
            echo "Already have $save_path/$_name"
            continue
        fi

        for dl_src in $dl_source; do
            case $dl_src in
                $dl_from_stx_mirror)
                    url_prefix="$stx_mirror_url_prefix"
                    ;;
                $dl_from_upstream)
                    url_prefix="$upstream_url_prefix"
                    ;;
                *)
                    echo "Error: Unknown dl_source '$dl_src'"
                    continue
                    ;;
            esac

            echo "remote path: $url_prefix/$_name"
            echo "local path: $save_path/$_name"
            if wget $url_prefix/$_name; then
                file_name=`basename $_name`
                sub_path=`dirname $_name`
                if [ -e "./$file_name" ]; then
                    let i+=1
                    echo "$file_name is downloaded successfully"

                    \mv -f ./$file_name $save_path/$_name
                    if [ $? -ne 0 ]; then
                        echo "Error: mv -f './$file_name' '$save_path/$_name'"
                        error_count=$((error_count + 1))
                    fi

                    ls -l $save_path/$_name
                fi
                break
            else
                echo "Warning: failed to download $url_prefix/$_name"
            fi
        done

        if [ ! -e "$save_path/$_name" ]; then
            echo "Error: failed to download '$url_prefix/$_name'"
            error_count=$((error_count + 1))
            continue
        fi
    fi
done

echo ""
echo "totally $i files are downloaded!"

if [ $error_count -ne 0 ]; then
    echo ""
    echo "Encountered $error_count errors"
    exit 1
fi

exit 0

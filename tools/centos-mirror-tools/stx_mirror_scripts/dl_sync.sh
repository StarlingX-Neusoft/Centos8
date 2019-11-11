#!/bin/bash

#
# SPDX-License-Identifier: Apache-2.0
#
# Update script for mirror.starlingx.cengn.ca covering
# tarballs and other files not downloaded from a yum repository.
# The list of files to download are pulled from the .lst files
# found in the stx-tools repo.
#
# IMPORTANT: This script is only to be run on the StarlingX mirror.
#            It is not for use by the general StarlinX developer.
#
# This script was originated by Scott Little.
#

DAILY_DL_SYNC_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}" )" )"

LOGFILE=/export/log/daily_dl_sync.log
DOWNLOAD_PATH_ROOT=/export/mirror/centos

STX_TOOLS_BRANCH="master"
STX_TOOLS_BRANCH_ROOT_DIR="$HOME/stx-tools"
STX_TOOLS_OS_SUBDIR="centos-mirror-tools"

if [ -f "$DAILY_DL_SYNC_DIR/stx_tool_utils.sh" ]; then
    source "$DAILY_DL_SYNC_DIR/stx_tool_utils.sh"
elif [ -f "$DAILY_DL_SYNC_DIR/../stx_tool_utils.sh" ]; then
    source "$DAILY_DL_SYNC_DIR/../stx_tool_utils.sh"
else
    echo "Error: Can't find 'stx_tool_utils.sh'"
    exit 1
fi




usage () {
    echo "$0 [-b <branch>] [-d <dir>]"
    echo ""
    echo "Options:"
    echo "  -b: Use an alternate branch of stx-tools. Default is 'master'."
    echo "  -d: Directory where we will clone stx-tools. Default is \$HOME."
    echo ""
}

while getopts "b:d:h" opt; do
    case "${opt}" in
        b)
            # branch
            STX_TOOLS_BRANCH="${OPTARG}"
            if [ $"STX_TOOLS_BRANCH" == "" ]; then
                usage
                exit 1
            fi
            ;;
        d)
            # download directory for stx-tools
            STX_TOOLS_BRANCH_ROOT_DIR="${OPTARG}"
            if [ "$STX_TOOLS_BRANCH_ROOT_DIR" == "" ]; then
                usage
                exit 1
            fi
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

STX_TOOLS_DL_ROOT_DIR="$STX_TOOLS_BRANCH_ROOT_DIR/$STX_TOOLS_BRANCH"
STX_TOOLS_DL_DIR="$STX_TOOLS_DL_ROOT_DIR/stx-tools"
LST_FILE_DIR="$STX_TOOLS_DL_DIR/$STX_TOOLS_OS_SUBDIR"


raw_dl_from_rpm_lst () {
    local FILE="$1"
    local RPM=""
    local URL=""
    local ERROR_COUNT=0

    # Expected format <rpm>#<url>
    grep -v '^#' $FILE | while IFS='#' read -r RPM URL; do
        echo "Processing: RPM=$RPM  URL=$URL"
        dl_file_from_url "$URL"
        ERR_COUNT=$((ERR_COUNT+$?))
    done

    return $ERR_COUNT
}


raw_dl_from_non_rpm_lst () {
    local FILE="$1"
    local TAR=""
    local URL=""
    local METHOD=""
    local UTIL=""
    local SCRIPT=""
    local BRANCH=""
    local SUBDIRS_FILE=""
    local TARBALL_NAME=""
    local ERROR_COUNT=0

    # Expected format <tar-file>#<tar-dir>#<url>
    #          or     !<tar-file>#<tar-dir>#<url>#<method>#[<util>]#[<script>]
    grep -v '^#' $FILE | while IFS='#' read -r TAR DIR URL METHOD UTIL SCRIPT; do
        if [ "$URL" == "" ]; then
            continue
        fi

        echo "Processing: TAR=$TAR  DIR=$DIR  URL=$URL  METHOD=$METHOD  UTIL=$UTIL  SCRIPT=$SCRIPT"
        TARBALL_NAME="${TAR//!/}"
        if [[ "$TAR" =~ ^'!' ]]; then
            case $METHOD in
                http|http_script)
                    dl_file_from_url "$URL"
                    if [ $? -ne 0 ]; then
                        echo "Error: Failed to download '$URL' while processing '$TARBALL_NAME'"
                        ERR_COUNT=$((ERR_COUNT+1))
                    fi
                    ;;
                http_filelist|http_filelist_script)
                    SUBDIRS_FILE="$LST_FILE_DIR/$UTIL"
                    if [ ! -f "$SUBDIRS_FILE" ]; then
                        echo "$SUBDIRS_FILE no found" 1>&2
                        ERR_COUNT=$((ERR_COUNT+1))
                    fi

                    grep -v '^#' "$SUBDIRS_FILE" | while read -r ARTF; do
                        if [ "$ARTF" == "" ]; then
                            continue
                        fi

                        dl_file_from_url "$URL/$ARTF"
                        if [ $? -ne 0 ]; then
                            echo "Error: Failed to download artifact '$ARTF' from list '$SUBDIRS_FILE' while processing '$TARBALL_NAME'"
                            ERR_COUNT=$((ERR_COUNT+1))
                            break
                        fi
                    done
                    ;;
                git|git_script)
                    BRANCH="$UTIL"
                    dl_bare_git_from_url "$URL" ""
                    if [ $? -ne 0 ]; then
                        echo "Error: Failed to download '$URL' while processing '$TARBALL_NAME'"
                        ERR_COUNT=$((ERR_COUNT+1))
                    fi
                    ;;
                *)
                    echo "Error: Unknown method '$METHOD' while processing '$TARBALL_NAME'"
                    ERR_COUNT=$((ERR_COUNT+1))
                    ;;
            esac
        else
            dl_file_from_url "$URL"
            if [ $? -ne 0 ]; then
                echo "Error: Failed to download '$URL' while processing '$TARBALL_NAME'"
                ERR_COUNT=$((ERR_COUNT+1))
            fi
        fi
    done

    return $ERR_COUNT
}




if [ -f $LOGFILE ]; then
    rm -f $LOGFILE
fi

(
ERR_COUNT=0

stx_tool_clone_or_update "$STX_TOOLS_BRANCH" "$STX_TOOLS_DL_ROOT_DIR"
if [ $? -ne 0 ]; then
    echo "Error: Failed to update stx_tools. Can't continue."
    exit 1
fi

# At time of writing, only expect rpms_3rdparties.lst
RPM_LST_FILES=$(grep -l '://' $LST_FILE_DIR/rpms*.lst)

# At time of writing, only expect tarball-dl.lst
NON_RPM_FILES=$(grep -l '://' $LST_FILE_DIR/*lst | grep -v '[/]rpms[^/]*$')

for RPM_LST_FILE in $RPM_LST_FILES; do
    raw_dl_from_rpm_lst "$RPM_LST_FILE"
    ERR_COUNT=$((ERR_COUNT+$?))
done

for NON_RPM_FILE in $NON_RPM_FILES; do
    raw_dl_from_non_rpm_lst "$NON_RPM_FILE"
    ERR_COUNT=$((ERR_COUNT+$?))
done

if [ $ERR_COUNT -ne 0 ]; then
    echo "Error: Failed to download $ERR_COUNT files"
    exit 1
fi

exit 0
) | tee $LOGFILE

exit ${PIPESTATUS[0]}

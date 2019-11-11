#
# SPDX-License-Identifier: Apache-2.0
#
# Utility functions to download stx-tools git
#
# This script was originated by Scott Little.
#

STX_TOOL_UTILS_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}" )" )"

if [ -f "$STX_TOOL_UTILS_DIR/dl_utils.sh" ]; then
    source "$STX_TOOL_UTILS_DIR/dl_utils.sh"
elif [ -f "$STX_TOOL_UTILS_DIR/../dl_utils.sh" ]; then
    source "$STX_TOOL_UTILS_DIR/../dl_utils.sh"
else
    echo "Error: Can't find 'dl_utils.sh'"
    exit 1
fi


STX_TOOLS_DEFAULT_BRANCH="master"
STX_TOOLS_DEFAULT_ROOT_DIR="$HOME/stx-tools"
STX_TOOLS_GIT_URL="https://git.starlingx.io/stx-tools.git"

#
# stx_tool_clone_or_update [<branch>] [<dir>]
#
# Clone stx-tools under the supplied directory, 
# and checkout the desired branch.
#

stx_tool_clone_or_update () {
    local BRANCH="$1"
    local DL_ROOT_DIR="$2"
    local CMD

    if [ "$BRANCH" == "" ]; then
        BRANCH="$STX_TOOLS_DEFAULT_BRANCH"
    fi

    if [ "$DL_ROOT_DIR" == "" ]; then
        DL_ROOT_DIR="$STX_TOOLS_DEFAULT_ROOT_DIR/$BRANCH"
    fi

    local DL_DIR="$DL_ROOT_DIR/stx-tools"

    dl_git_from_url "$STX_TOOLS_GIT_URL" "$BRANCH" "$DL_DIR"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to download '$STX_TOOLS_GIT_URL'"
        return 1;
    fi

    return 0
}


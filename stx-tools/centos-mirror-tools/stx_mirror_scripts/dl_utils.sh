#
# SPDX-License-Identifier: Apache-2.0
#
# Utility function for the download of gits and tarballs.
#
# This script was originated by Scott Little.
#

DL_UTILS_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}" )" )"

if [ -f "$DL_UTILS_DIR/url_utils.sh" ]; then
    source "$DL_UTILS_DIR/url_utils.sh"
elif [ -f "$DL_UTILS_DIR/../url_utils.sh" ]; then
    source "$DL_UTILS_DIR/../url_utils.sh"
else
    echo "Error: Can't find 'url_utils.sh'"
    exit 1
fi


DOWNLOAD_PATH_ROOT=${DOWNLOAD_PATH_ROOT:-/export/mirror/centos}


#
# dl_git_from_url <git-url> <branch> <dir>
#
# Download a git from supplied url into directory,
# and checkout desired branch.
#
dl_git_from_url () {
    local GIT_URL="$1"
    local BRANCH="$2"
    local DL_DIR="$3"

    local DL_ROOT_DIR=""
    local SAVE_DIR
    local CMD=""

    SAVE_DIR="$(pwd)"

    if [ "$DL_DIR" == "" ]; then
        DL_DIR="$DOWNLOAD_PATH_ROOT/$(repo_url_to_sub_path "$GIT_URL" | sed 's#[.]git$##')"
    fi

    echo "dl_git_from_url  GIT_URL='$GIT_URL'  BRANCH='$BRANCH'  DL_DIR='$DL_DIR'"
    DL_ROOT_DIR=$(dirname "$DL_DIR")

    if [ ! -d "$DL_DIR" ]; then
        if [ ! -d "$DL_ROOT_DIR" ]; then
            CMD="mkdir -p '$DL_ROOT_DIR'"
            echo "$CMD"
            eval $CMD
            if [ $? -ne 0 ]; then
                echo "Error: $CMD"
                cd "$SAVE_DIR"
                return 1
            fi
        fi

        CMD="cd '$DL_ROOT_DIR'"
        echo "$CMD"
        eval $CMD
        if [ $? -ne 0 ]; then
            echo "Error: $CMD"
            cd "$SAVE_DIR"
            return 1
        fi

        CMD="git clone '$GIT_URL' '$DL_DIR'"
        echo "$CMD"
        eval $CMD
        if [ $? -ne 0 ]; then
            echo "Error: $CMD"
            cd "$SAVE_DIR"
            return 1
        fi
    fi

    CMD="cd '$DL_DIR'"
    echo "$CMD"
    eval $CMD
    if [ $? -ne 0 ]; then
        echo "Error: $CMD"
        cd "$SAVE_DIR"
        return 1
    fi

    CMD="git fetch"
    echo "$CMD"
    eval $CMD
    if [ $? -ne 0 ]; then
        echo "Error: $CMD"
        cd "$SAVE_DIR"
        return 1
    fi

    CMD="git checkout '$BRANCH'"
    echo "$CMD"
    eval $CMD
    if [ $? -ne 0 ]; then
        echo "Error: $CMD"
        cd "$SAVE_DIR"
        return 1
    fi

    CMD="git pull"
    echo "$CMD"
    eval $CMD
    if [ $? -ne 0 ]; then
        echo "Error: $CMD"
        cd "$SAVE_DIR"
        return 1
    fi

    cd "$SAVE_DIR"
    return 0
}


#
# dl_bare_git_from_url <git-url> <dir>
#
# Download a bare git from supplied url into desired directory.
#
dl_bare_git_from_url () {
    local GIT_URL="$1"
    local DL_DIR="$2"

    local DL_ROOT_DIR=""
    local SAVE_DIR
    local CMD=""

    SAVE_DIR="$(pwd)"

    if [ "$DL_DIR" == "" ]; then
        DL_DIR="$DOWNLOAD_PATH_ROOT/$(repo_url_to_sub_path "$GIT_URL" | sed 's#[.]git$##')"
    fi

    echo "dl_bare_git_from_url  GIT_URL='$GIT_URL'  DL_DIR='$DL_DIR'"
    DL_ROOT_DIR=$(dirname "$DL_DIR")

    if [ ! -d "$DL_DIR" ]; then
        if [ ! -d "$DL_ROOT_DIR" ]; then
            CMD="mkdir -p '$DL_ROOT_DIR'"
            echo "$CMD"
            eval $CMD
            if [ $? -ne 0 ]; then
                echo "Error: $CMD"
                cd "$SAVE_DIR"
                return 1
            fi
        fi

        CMD="cd '$DL_ROOT_DIR'"
        echo "$CMD"
        eval $CMD
        if [ $? -ne 0 ]; then
            echo "Error: $CMD"
            cd "$SAVE_DIR"
            return 1
        fi

        CMD="git clone --bare '$GIT_URL' '$DL_DIR'"
        echo "$CMD"
        eval $CMD
        if [ $? -ne 0 ]; then
            echo "Error: $CMD"
            cd "$SAVE_DIR"
            return 1
        fi

        CMD="cd '$DL_DIR'"
        echo "$CMD"
        eval $CMD
        if [ $? -ne 0 ]; then
            echo "Error: $CMD"
            cd "$SAVE_DIR"
            return 1
        fi

        CMD="git --bare update-server-info"
        echo "$CMD"
        eval $CMD
        if [ $? -ne 0 ]; then
            echo "Error: $CMD"
            cd "$SAVE_DIR"
            return 1
        fi

        if [ -f hooks/post-update.sample ]; then
            CMD="mv -f hooks/post-update.sample hooks/post-update"
            echo "$CMD"
            eval $CMD
            if [ $? -ne 0 ]; then
                echo "Error: $CMD"
                cd "$SAVE_DIR"
                return 1
            fi
        fi
    fi

    CMD="cd '$DL_DIR'"
    echo "$CMD"
    eval $CMD
    if [ $? -ne 0 ]; then
        echo "Error: $CMD"
        cd "$SAVE_DIR"
        return 1
    fi

    CMD="git fetch"
    echo "$CMD"
    eval $CMD
    if [ $? -ne 0 ]; then
        echo "Error: $CMD"
        cd "$SAVE_DIR"
        return 1
    fi

    cd "$SAVE_DIR"
    return 0
}


#
# dl_file_from_url <url>
#
# Download a file to the current directory
#
dl_file_from_url () {
    local URL="$1"

    local DOWNLOAD_PATH=""
    local DOWNLOAD_DIR=""
    local PROTOCOL=""
    local CMD=""

    DOWNLOAD_PATH="$DOWNLOAD_PATH_ROOT/$(repo_url_to_sub_path "$URL")"
    DOWNLOAD_DIR="$(dirname "$DOWNLOAD_PATH")"
    PROTOCOL=$(url_protocol $URL)
    echo "$PROTOCOL  $URL  $DOWNLOAD_PATH"

    if [ -f "$DOWNLOAD_PATH" ]; then
        echo "Already have '$DOWNLOAD_PATH'"
        return 0
    fi

    case "$PROTOCOL" in
        https|http)
            if [ ! -d "$DOWNLOAD_DIR" ]; then
                CMD="mkdir -p '$DOWNLOAD_DIR'"
                echo "$CMD"
                eval "$CMD"
                if [ $? -ne 0 ]; then
                    echo "Error: $CMD"
                    return 1
                fi
            fi

            CMD="wget '$URL' --tries=5 --wait=15 --output-document='$DOWNLOAD_PATH'"
            echo "$CMD"
            eval $CMD
            if [ $? -ne 0 ]; then
                echo "Error: $CMD"
                return 1
            fi
            ;;
        *)
            echo "Error: Unknown protocol '$PROTOCOL' for url '$URL'"
            return 1
            ;;
    esac

    return 0
}



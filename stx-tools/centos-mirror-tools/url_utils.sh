#
# SPDX-License-Identifier: Apache-2.0
#
# A set of bash utility functions to parse a URL.
# This script was originated by Scott Little
#

url_protocol () {
    local URL="$1"

    if [ "$URL" == "" ]; then
        >&2 echo "Error: $FUNCNAME (${LINENO}): empty argument"
        return 1
    fi

    if echo "$URL" | grep -q '[:][/][/]' ;then
        echo "$URL" | sed 's#^\(.*\)://.*$#\1#'
    else
        echo "http"
    fi
    return 0
}

url_login () {
    local URL="$1"

    if [ "$URL" == "" ]; then
        >&2 echo "Error: $FUNCNAME (${LINENO}): empty argument"
        return 1
    fi

    echo "$URL" | sed 's#^.*://\([^/]*\)/.*$#\1#'
    return 0
}

url_user () {
    local URL="$1"
    local LOGIN

    if [ "$URL" == "" ]; then
        >&2 echo "Error: $FUNCNAME (${LINENO}): empty argument"
        return 1
    fi

    url_login "$URL" | sed -e '/@/! s#.*## ; s#\([^@]*\)@.*#\1#'
    if [ ${PIPESTATUS[0]} -ne 0  ]; then
        >&2 echo "Error: $FUNCNAME (${LINENO}): url_login failed"
        return 1
    fi

    return 0
}

url_port () {
    local URL="$1"
    local LOGIN

    if [ "$URL" == "" ]; then
        >&2 echo "Error: $FUNCNAME (${LINENO}): empty argument"
        return 1
    fi

    url_login "$URL" | sed -e '/:/! s#.*## ; s#[^:]*:\([^:]*\)#\1#'
    if [ ${PIPESTATUS[0]} -ne 0  ]; then
        >&2 echo "Error: $FUNCNAME (${LINENO}): url_login failed"
        return 1
    fi

    return 0
}

url_server () {
    local URL="$1"
    local LOGIN

    if [ "$URL" == "" ]; then
        >&2 echo "Error: $FUNCNAME (${LINENO}): empty argument"
        return 1
    fi

    url_login "$URL" | sed 's#^.*@## ; s#:.*$##'
    if [ ${PIPESTATUS[0]} -ne 0  ]; then
        >&2 echo "Error: $FUNCNAME (${LINENO}): url_login failed"
        return 1
    fi

    return 0
}

url_path () {
    local URL="$1"

    if [ "$URL" == "" ]; then
        >&2 echo "Error: $FUNCNAME (${LINENO}): empty argument"
        return 1
    fi

    echo "$URL" | sed 's#^.*://[^/]*/\(.*\)$#\1#'
    return 0
}

#
# url_path_to_fs_path:
#
# Convert url format path to file system format.
# e.g. replace %20 with ' '.
#
# Note: Does NOT test the output path to ensure there are
#       no illegal file system characters.
#
url_path_to_fs_path () {
    local INPUT_PATH="$1"
    local TEMP

    if [ "$INPUT_PATH" == "" ]; then
        >&2 echo "Error: $FUNCNAME (${LINENO}): empty argument"
        return 1
    fi

    # Deviate from URI spec by not substituding '+' with ' '.
    # It would alias '%20' and we need unique mappings.
    # TEMP="${INPUT_PATH//+/ }"

    TEMP="$INPUT_PATH"
    printf '%b' "${TEMP//%/\\x}"
    return 0
}

#
# fs_path_to_url_path:
#
# Convert file system format path to url format.
# e.g. replace ' ' with %20.
#
fs_path_to_url_path () {
    local INPUT_PATH="$1"
    local LENGTH
    local POS
    local CHAR

    if [ "$INPUT_PATH" == "" ]; then
        >&2 echo "Error: $FUNCNAME (${LINENO}): empty argument"
        return 1
    fi

    LENGTH="${#INPUT_PATH}"
    for (( POS = 0; POS < LENGTH; POS++ )); do
        CHAR="${1:POS:1}"
        case $CHAR in
            [/a-zA-Z0-9.~_-])
                # Reference https://metacpan.org/pod/URI::Escape
                printf "$CHAR"
                ;;
            *)
                printf '%%%02X' "'$CHAR"
                ;;
        esac
    done

    return 0
}

#
# normalize_path:
#
# 1) replace // with /
# 2) replace /./ with /
# 3) Remove trailing /
# 4) Remove leading ./
#

normalize_path () {
    local INPUT_PATH="$1"

    if [ "$INPUT_PATH" == "" ]; then
        >&2 echo "Error: $FUNCNAME (${LINENO}): empty argument"
        return 1
    fi

    echo "$INPUT_PATH" | sed 's#[/]\+#/#g ; s#[/][.][/]#/#g ; s#/$## ; s#^[.]/##'
    return 0
}


#
# repo_url_to_sub_path:
#
repo_url_to_sub_path () {
    local URL="$1"
    local FAMILY=""
    local SERVER=""
    local URL_PATH=""
    local FS_PATH=""

    if [ "$URL" == "" ]; then
        >&2 echo "Error: $FUNCNAME (${LINENO}): empty argument"
        return 1
    fi

    # set FAMILY from URL
    echo $URL | grep -q 'centos[.]org' && FAMILY=centos
    echo $URL | grep -q 'fedoraproject[.]org[/]pub[/]epel' && FAMILY=epel

    SERVER=$(url_server "$URL")
    if [ $? -ne 0  ]; then
        >&2 echo "Error: $FUNCNAME (${LINENO}): url_server '$URL'"
        return 1
    fi

    URL_PATH="$(url_path "$URL")"
    if [ $? -ne 0  ]; then
        >&2 echo "Error: $FUNCNAME (${LINENO}): url_path '$URL'"
        return 1
    fi

    FS_PATH="$(url_path_to_fs_path "$URL_PATH")"
    if [ $? -ne 0  ]; then
        >&2 echo "Error: $FUNCNAME (${LINENO}): url_path_to_fs_path '$URL_PATH'"
        return 1
    fi

    FS_PATH="$(normalize_path "$FS_PATH")"
    if [ $? -ne 0  ]; then
        >&2 echo "Error: $FUNCNAME (${LINENO}): normalize_path '$FS_PATH'"
        return 1
    fi

    normalize_path "./$FAMILY/$SERVER/$FS_PATH"
    if [ $? -ne 0  ]; then
        >&2 echo "Error: $FUNCNAME (${LINENO}): normalize_path './$FAMILY/$SERVER/$FS_PATH'"
        return 1
    fi

    return 0
}

CENGN_PROTOCOL="http"
CENGN_HOST="mirror.starlingx.cengn.ca"
CENGN_PORT="80"
CENGN_URL_ROOT="mirror"

url_to_stx_mirror_url () {
    local URL="$1"
    local DISTRO="$2"
    local URL_PATH=""
    local FS_PATH=""

    if [ "$URL" == "" ] || [ "$DISTRO" == "" ]; then
        >&2 echo "Error: $FUNCNAME (${LINENO}): empty argument"
        return 1
    fi

    FS_PATH="$(repo_url_to_sub_path "$URL")"
    if [ $? -ne 0 ]; then
        >&2 echo "Error: $FUNCNAME (${LINENO}): repo_url_to_sub_path '$URL'"
        return 1
    fi

    URL_PATH=$(fs_path_to_url_path "$FS_PATH")
    if [ $? -ne 0 ]; then
        >&2 echo "Error: $FUNCNAME (${LINENO}): fs_path_to_url_path '$FS_PATH'"
        return 1
    fi

    echo "$CENGN_PROTOCOL://$CENGN_HOST:$CENGN_PORT/$CENGN_URL_ROOT/$DISTRO/$URL_PATH"
    return 0
}

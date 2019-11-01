#!/bin/bash

#
# SPDX-License-Identifier: Apache-2.0
#

#
# Replicate a yum.conf and yum.repo.d under a temporary directory and
# then modify the files to point to equivalent repos in the StarlingX mirror.
# This script was originated by Scott Little
#

MAKE_STX_MIRROR_YUM_CONF_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}" )" )"

source "$MAKE_STX_MIRROR_YUM_CONF_DIR/url_utils.sh"

DISTRO="centos"

TEMP_DIR=""
SRC_REPO_DIR="$MAKE_STX_MIRROR_YUM_CONF_DIR/yum.repos.d"
SRC_YUM_CONF="$MAKE_STX_MIRROR_YUM_CONF_DIR/yum.conf.sample"

RETAIN_REPODIR=0

usage () {
    echo ""
    echo "$0 -d <dest_dir> [-D <distro>] [-y <src_yum_conf>] [-r <src_repos_dir>] [-R]"
    echo ""
    echo "Replicate a yum.conf and yum.repo.d under a new directory and"
    echo "then modify the files to point to equivalent repos in the StarlingX"
    echo "mirror."
    echo ""
    echo "-d <dest_dir> = Place modified yum.conf and yum.repo.d into this directory"
    echo "-D <distro>   = Target distro on StarlingX mirror. Default is 'centos'"
    echo "-y <yum_conf> = Path to yum.conf file that we will modify.  Default is"
    echo "                'yum.conf.sample' in same directory as this script"
    echo "-r <repos_dir> = Path to yum.repos.d that we will modify.  Default is"
    echo "                 'yum.repos.d' in same directory as this script"
}


#
# option processing
#
while getopts "D:d:Rr:y:" o; do
    case "${o}" in
        D)
            DISTRO="${OPTARG}"
            ;;
        d)
            TEMP_DIR="${OPTARG}"
            ;;
        r)
            SRC_REPO_DIR="${OPTARG}"
            ;;
        R)
            RETAIN_REPODIR=1
            ;;
        y)
            SRC_YUM_CONF="${OPTARG}"
            ;;
        *)
            usage
            exit 1
            ;;
    esac
done

#
# option validation
#
if [ ! -f $SRC_YUM_CONF ]; then
    echo "Error: yum.conf not found at '$SRC_YUM_CONF'"
    exit 1
fi

if [ ! -d $SRC_REPO_DIR ]; then
    echo "Error: repo dir not found at '$SRC_REPO_DIR'"
    exit 1
fi

if [ "$TEMP_DIR" == "" ]; then
    echo "Error: working dir not provided"
    usage
    exit 1
fi

if [ ! -d $TEMP_DIR ]; then
    echo "Error: working dir not found at '$TEMP_DIR'"
    exit 1
fi

#
# Get the value of the $releasever variable.
#
# If the source yum.conf has a releasever= setting, we will honor
# that, even though yum will not.
#
# Otherwise use yum to query the host environment (Docker).
# This assumes the host environmnet has the same releasever
# as that which will be used inside StarlingX.
#
# NOTE: In other scripts we will read releasever= out of yum.conf
# and push it back into yum via --releasever=<#>.
#
get_releasever () {
    if [ -f $SRC_YUM_CONF ] && grep -q '^releasever=' $SRC_YUM_CONF; then
        grep '^releasever=' $SRC_YUM_CONF | cut -d '=' -f 2
    else
        yum version nogroups | grep Installed | cut -d ' ' -f 2 | cut -d '/' -f 1
    fi
}

#
# Get the value of the $basearch variable.
#
# Just use yum to query the host environment (Docker) as we don't support
# cross compiling.
#
get_arch () {
    yum version nogroups | grep Installed | cut -d ' ' -f 2 | cut -d '/' -f 2
}


#
# Global variables we will use later.
#
CENGN_REPOS_DIR="$TEMP_DIR/yum.repos.d"
CENGN_YUM_CONF="$TEMP_DIR/yum.conf"
CENGN_YUM_LOG="$TEMP_DIR/yum.log"
CENGN_YUM_CACHDIR="$TEMP_DIR/cache/yum/\$basearch/\$releasever"

RELEASEVER=$(get_releasever)
ARCH=$(get_arch)

#
# Copy as yet unmodified yum.conf and yum.repos.d from source to dest.
#
echo "\cp -r '$SRC_REPO_DIR' '$CENGN_REPOS_DIR'"
\cp -r "$SRC_REPO_DIR" "$CENGN_REPOS_DIR"
echo "\cp '$SRC_YUM_CONF' '$CENGN_YUM_CONF'"
\cp "$SRC_YUM_CONF" "$CENGN_YUM_CONF"

#
# Add or modify reposdir= value in our new yum.conf
#
if grep -q '^reposdir=' $CENGN_YUM_CONF; then
    # reposdir= already exists, modify it
    if [ $RETAIN_REPODIR -eq 1 ]; then
        # Append CENGN_REPOS_DIR
        sed "s#^reposdir=\(.*\)\$#reposdir=\1 $CENGN_REPOS_DIR#" -i $CENGN_YUM_CONF
    else
        # replace with CENGN_REPOS_DIR
        sed "s#^reposdir=.*\$#reposdir=$CENGN_REPOS_DIR#" -i $CENGN_YUM_CONF
    fi
else
    # reposdir= doeas not yet exist, add it
    if [ $RETAIN_REPODIR -eq 1 ]; then
        # Add both SRC_REPO_DIR and CENGN_REPOS_DIR
        echo "reposdir=$SRC_REPO_DIR $CENGN_REPOS_DIR" >> $CENGN_YUM_CONF
    else
        # Add CENGN_REPOS_DIR only
        echo "reposdir=$CENGN_REPOS_DIR" >> $CENGN_YUM_CONF
    fi
fi

#
# modify or add logfile= value in our new yum.conf
#
if grep -q '^logfile=' $CENGN_YUM_CONF; then
    sed "s#^logfile=.*\$#logfile=$CENGN_YUM_LOG#" -i $CENGN_YUM_CONF
else
    echo "logfile=$CENGN_YUM_LOG" >> $CENGN_YUM_CONF
fi

#
# modify or add cachedir= value in our new yum.conf
#
if grep -q '^cachedir=' $CENGN_YUM_CONF; then
    sed "s#^cachedir=.*\$#cachedir=$CENGN_YUM_CACHDIR#" -i $CENGN_YUM_CONF
else
    echo "cachedir=$CENGN_YUM_CACHDIR" >> $CENGN_YUM_CONF
fi


#
# Modify all the repo files in our new yum.repos.d
#
for REPO in $(find "$CENGN_REPOS_DIR" -type f -name '*repo'); do
    #
    # Replace mirrorlist with baseurl if required
    #
    if grep -q '^mirrorlist=' "$REPO" ; then
        sed '/^mirrorlist=/d' -i "$REPO"
        sed 's%^#baseurl%baseurl%' -i "$REPO"
    fi

    #
    # Substitute any $releasever or $basearch variables
    #
    sed "s#/[$]releasever/#/$RELEASEVER/#g" -i "$REPO"
    sed "s#/[$]basearch/#/$ARCH/#g" -i "$REPO"

    #
    # Turn off gpgcheck for now.
    # Must revisit this at a later date!
    #
    sed 's#^gpgcheck=1#gpgcheck=0#' -i "$REPO"
    sed '/^gpgkey=/d' -i "$REPO"

    #
    # Convert baseurl(s) to cengn equivalent
    #
    for URL in $(grep '^baseurl=' "$REPO" | sed 's#^baseurl=##'); do
        CENGN_URL="$(url_to_stx_mirror_url "$URL" "$DISTRO")"

        # Test CENGN url
        wget -q --spider $CENGN_URL
        if [ $? -eq 0 ]; then
            # OK, make substitution
            sed "s#^baseurl=$URL\$#baseurl=$CENGN_URL#" -i "$REPO"
        fi
    done

    #
    # Prefix repoid and name with CENGN
    #
    sed "s#^name=\(.*\)#name=CENGN_\1#" -i "$REPO"
    sed "s#^\[\([^]]*\)\]#[CENGN_\1]#" -i "$REPO"
done

echo $TEMP_DIR

#!/bin/bash
#
# Copyright (c) 2018 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
# This utility is a workflow aid for designers adding packages to StarlingX.
# It will identify and download dependencies, as needed.
#
# See help text for more details (-h)
#
# Example usage:
#
#   Downloading multiple missing pkgs (whose dependencies happen to be met already):
#
#   $ time starlingx_add_pkgs.sh -d python-srpm-macros -d python-rpm-macros -d python2-rpm-macros -d cppcheck -d ima-evm-utils -d ima-evm-utils-devel
#   Downloading https://dl.fedoraproject.org/pub/epel/testing/7/x86_64//Packages/p/python-srpm-macros-3-22.el7.noarch.rpm
#   Downloading https://dl.fedoraproject.org/pub/epel/testing/7/x86_64//Packages/p/python-rpm-macros-3-22.el7.noarch.rpm
#   Downloading https://dl.fedoraproject.org/pub/epel/testing/7/x86_64//Packages/p/python2-rpm-macros-3-22.el7.noarch.rpm
#   Downloading https://dl.fedoraproject.org/pub/epel/7/x86_64//Packages/c/cppcheck-1.83-3.el7.x86_64.rpm
#   Downloading http://mirror.centos.org/centos/7.5.1804/os/x86_64//Packages/ima-evm-utils-1.1-2.el7.x86_64.rpm
#   Downloading http://mirror.centos.org/centos/7.5.1804/os/x86_64//Packages/ima-evm-utils-devel-1.1-2.el7.x86_64.rpm
#
#   real    1m44.437s
#   user    2m23.055s
#   sys     0m13.158s
#
#
#   Or an example of a package with dependencies to be downloaded:
#   $ time starlingx_add_pkgs.sh -d corosync
#   Downloading http://mirror.centos.org/centos/7.5.1804/updates/x86_64//Packages/corosync-2.4.3-2.el7_5.1.x86_64.rpm
#   Downloading http://mirror.centos.org/centos/7.5.1804/updates/x86_64//Packages/net-snmp-libs-5.7.2-33.el7_5.2.x86_64.rpm
#   Downloading http://mirror.centos.org/centos/7.5.1804/os/x86_64//Packages/libqb-1.0.1-6.el7.x86_64.rpm
#
#   real    1m1.419s
#   user    1m20.585s
#   sys     0m7.662s
#   $ cat downloaded.log
#   corosync-0:2.4.3-2.el7_5.1.x86_64,Starlingx-C7.5.1804-updates,http://mirror.centos.org/centos/7.5.1804/updates/x86_64//Packages/corosync-2.4.3-2.el7_5.1.x86_64.rpm
#   net-snmp-libs,Starlingx-C7.5.1804-updates,http://mirror.centos.org/centos/7.5.1804/updates/x86_64//Packages/net-snmp-libs-5.7.2-33.el7_5.2.x86_64.rpm
#   libqb,Starlingx-C7.5.1804-os,http://mirror.centos.org/centos/7.5.1804/os/x86_64//Packages/libqb-1.0.1-6.el7.x86_64.rpm
#
#
#   Or searching for the elusive “scapy” package (I added StarlingX_3rd.repo support):
#   $ time starlingx_add_pkgs.sh -d scapy
#   Downloading http://epel.blizoo.mk/epel/7Server/x86_64/s/scapy-2.2.0-2.el7.noarch.rpm
#
#   real    0m16.112s
#   user    0m22.000s
#   sys     0m1.702s
#   $ cat downloaded_3rd.log
#   scapy-0:2.2.0-2.el7.noarch,Starlingx-epel.blizoo.mk_epel_7Server_x86_64,http://epel.blizoo.mk/epel/7Server/x86_64/s/scapy-2.2.0-2.el7.noarch.rpm
#
#   Looking for a specific version?
#   $ time starlingx_add_pkgs.sh -d scapy-2.3.1
#   Failed to find a package providing scapy-2.3.1
#   Could not find in repo: scapy-2.3.1
#
#   real    0m2.003s
#   user    0m1.736s
#   sys     0m0.265s
#   $ time starlingx_add_pkgs.sh -d scapy-2.2.0
#   Failed to find a package providing scapy-2.2.0
#   Downloading http://epel.blizoo.mk/epel/7Server/x86_64/s/scapy-2.2.0-2.el7.noarch.rpm
#
#   real    0m15.748s
#   user    0m21.834s
#   sys     0m1.760s
#
#   Note: It may seem odd to see “Failed to find a package providing scapy-2.2.0”,
#   followed by a “Downloading”, but that’s because of the way the script and
#   repoquery work. It first treats the specified string as a “feature” or “capability”
#   and looks for the package that provides it (for resolving dependencies). It then
#   looks for the pkg, if that mapping failed.
#

if [ -z "$MY_REPO" ]; then
    echo "Required environment variable undefined: MY_REPO" >&2
    exit 1
fi

if [ -z "$MY_REPO_ROOT_DIR" ]; then
    echo "Required environment variable undefined: MY_REPO_ROOT_DIR" >&2
    exit 1
fi

STXTOOLS=${MY_REPO_ROOT_DIR}/stx-tools
REPO_DIR=${STXTOOLS}/centos-mirror-tools/yum.repos.d
REPOCFG_STD_FILES=$(ls ${REPO_DIR}/StarlingX*.repo | grep -v StarlingX_3rd)
REPOCFG_3RD_FILES=${REPO_DIR}/StarlingX_3rd*.repo
REPOCFG_STD_MERGED=$(mktemp /tmp/REPOCFG_STD_MERGED_XXXXXX)
cat $REPOCFG_STD_FILES > $REPOCFG_STD_MERGED
REPOCFG_3RD_MERGED=$(mktemp /tmp/REPOCFG_3RD_MERGED_XXXXXX)
cat $REPOCFG_3RD_FILES > $REPOCFG_3RD_MERGED
REPOCFG_ALL_MERGED=$(mktemp /tmp/REPOCFG_ALL_MERGED_XXXXXX)
cat $REPOCFG_STD_FILES $REPOCFG_3RD_FILES > $REPOCFG_ALL_MERGED

CGCSREPO_PATH=$MY_REPO/cgcs-centos-repo/Binary
TISREPO_PATH=$MY_WORKSPACE/std/rpmbuild/RPMS
TISREPO_PATH_ARGS=
if [ -e $TISREPO_PATH/repodata/repomd.xml ]; then
    TISREPO_PATH_ARGS="--repofrompath tis,$TISREPO_PATH"
fi

RESULTS_LOG=downloaded.log
RESULTS_3RD_LOG=downloaded_3rd.log
NOTFOUND_LOG=notfound.log
FAILED_LOG=failed.log

RPMLIST=
DOWNLOAD_LIST=

# It seems we have to manually disable the repos from /etc/yum.repos.d,
# even though we're specifying a config file
REPOQUERY_ARGS=$(grep -h '^\[' /etc/yum.repos.d/* | sed 's/[][]//g' | sed 's/^/--disablerepo=/')

REPOQUERY_CMD="repoquery --archlist=x86_64,noarch $REPOQUERY_ARGS"
REPOQUERY_STD_CMD="$REPOQUERY_CMD --quiet -c $REPOCFG_STD_MERGED"
REPOQUERY_3RD_CMD="$REPOQUERY_CMD --quiet -c $REPOCFG_3RD_MERGED"
REPOQUERY_ALL_CMD="$REPOQUERY_CMD --quiet -c $REPOCFG_ALL_MERGED"
REPOQUERY_LOCAL_CMD="$REPOQUERY_CMD --quiet --repofrompath cgcs,$CGCSREPO_PATH $TISREPO_PATH_ARGS"

function cleanup {
    rm -f $REPOCFG_STD_MERGED $REPOCFG_3RD_MERGED $REPOCFG_ALL_MERGED
}

trap cleanup EXIT

function show_usage {
    cat >&2 <<EOF
Usage:
    $(basename $0) [ -d <pkgname> ] ... [ <rpmfile> ] ...

This utility uses the cgcs-centos-repo repo, and optionally the rpmbuild/RPMS
repo from \$MY_WORKSPACE/std, as a baseline, downloading packages required
to support the list provided at command-line. The -d option allows the user to
specify a package to download, or the user can specify a downloaded RPM file
that has dependencies that must be downloaded.

The downloaded RPMs will be written to the appropriate location under the
\$MY_REPO/cgcs-centos-repo directory. The user should be able to differentiate
the downloaded files versus symlinks pointing to a downloaded or shared mirror.

In addition, this utility will record a list of downloaded RPMs in the $RESULTS_LOG
or $RESULTS_3RD_LOG files, with failures recorded in $FAILED_LOG or $NOTFOUND_LOG.

The resulting download list can then be added to the appropriate .lst file in
\$MY_REPO_ROOT_DIR/stx-tools/centos-mirror-tools

Example:
    $(basename $0) -d linuxptp -d zlib puppet-gnocchi-11.3.0-1.el7.src.rpm
        Download packages linuxptp and zlib and their depdencies, as needed.
        Download dependencies of puppet-gnocchi-11.3.0-1.el7.src.rpm, as needed.
EOF
    exit 1
}

while getopts "d:h" opt; do
    case $opt in
        d)
            DOWNLOAD_LIST="$DOWNLOAD_LIST $OPTARG"
            ;;
        h)
            show_usage
            ;;
        *)
            echo "Unsupported option" >&2
            show_usage
            ;;
    esac
done

shift $((OPTIND-1))
RPMLIST="${RPMLIST} $@"

function rpmfile_requires {
    #
    # Map a specified rpm file to its dependency list
    #
    local rpmfile=$1

    rpm -qp --requires $rpmfile | awk '{print $1}'
}

function feature_to_pkg {
    #
    # Map a feature/capability to the package that provides it
    #
    local feature=$1
    local pkg=
    pkg=$($REPOQUERY_STD_CMD $feature | head -1)
    if [ -z $pkg ]; then
        pkg=$($REPOQUERY_STD_CMD --qf='%{name}' --whatprovides $feature | head -1)
        if [ -z $pkg ]; then
            pkg=$($REPOQUERY_3RD_CMD $feature | head -1)
            if [ -z $pkg ]; then
                pkg=$($REPOQUERY_3RD_CMD --qf='%{name}' --whatprovides $feature | head -1)
                if [ -z "$pkg" ]; then
                    echo "Could not find in repo: $feature" >&2
                    echo "Could not find in repo: $feature" >> $NOTFOUND_LOG
                fi
            fi
        fi
    fi
    echo $pkg
}

function pkg_to_dependencies {
    #
    # Map a package to the list of packages it requires
    #
    local pkg=$1

    $REPOQUERY_ALL_CMD --resolve --requires --qf='%{name}' $pkg
}

function pkg_in_cgcsrepo {
    #
    # Check whether the specified package is already in the downloaded (or built) repo
    #
    local pkg=$1

    local results=
    results=$($REPOQUERY_LOCAL_CMD --whatprovides $pkg)
    if [ -n "$results" ]; then
        return 0
    fi

    local pkgname=
    pkgname=$($REPOQUERY_ALL_CMD --quiet $REPOCFG_ARGS --qf='%{name}' --whatprovides $pkg | head -1)
    if [ -z "$pkgname" ]; then
        echo "Failed to find a package providing $pkg" >&2
        return 1
    fi
    results=$($REPOQUERY_LOCAL_CMD $pkgname)

    test -n "$results"
}

function download_pkg {
    #
    # Download the specified package and its dependencies
    #
    local feature=$1
    local pkg=
    pkg=$(feature_to_pkg $feature)
    if [ -z "$pkg" ]; then
        # Error should already be to stderr
        return 1
    fi

    local repoid=
    local url=
    local relativepath=
    local arch=
    local deps=

    repoid=$($REPOQUERY_STD_CMD --qf='%{repoid}' $pkg | head -1)
    if [ -n "$repoid" ]; then
        url=$($REPOQUERY_STD_CMD --location $pkg | head -1)
        relativepath=$($REPOQUERY_STD_CMD --qf='%{relativepath}' $pkg | head -1)
        arch=$($REPOQUERY_STD_CMD --qf='%{arch}' $pkg | head -1)
        deps=$($REPOQUERY_STD_CMD --requires --qf='%{name}' $pkg | awk '{print $1}')
        LOG=$RESULTS_LOG
    else
        repoid=$($REPOQUERY_3RD_CMD --qf='%{repoid}' $pkg | head -1)
        url=$($REPOQUERY_3RD_CMD --location $pkg | head -1)
        relativepath=$($REPOQUERY_3RD_CMD --qf='%{relativepath}' $pkg | head -1)
        arch=$($REPOQUERY_3RD_CMD --qf='%{arch}' $pkg | head -1)
        deps=$($REPOQUERY_3RD_CMD --requires --qf='%{name}' $pkg | awk '{print $1}')
        LOG=$RESULTS_3RD_LOG
    fi

    echo "Downloading $url"
    wget -q -O $CGCSREPO_PATH/$arch/$(basename $relativepath) $url

    if [ $? -ne 0 ]; then
        echo "Failed to download $url" >&2
        echo "Failed to download $url" >>$FAILED_LOG
        return 1
    fi

    # Update repo
    pushd $CGCSREPO_PATH >/dev/null
    createrepo -q -g comps.xml .
    if [ $? -ne 0 ]; then
        echo "createrepo failed... Aborting" >&2
        exit 1
    fi
    popd >/dev/null

    # Log it to appropriate file
    echo "${pkg},${repoid},$url" >> $LOG

    # Now check its dependencies
    local dep=
    for dep in $deps; do
        pkg_in_cgcsrepo $dep && continue
        download_pkg $dep
    done || exit $?
}

if [ -n "$RPMLIST" ]; then
    for rf in $RPMLIST; do
        rpmfile_requires $rf | while read feature; do
            pkg=$(feature_to_pkg $feature)
            if [ -z "$pkg" ]; then
                # Already msged to stderr
                continue
            fi

            dependencies=$(pkg_to_dependencies $pkg)

            for dep in $feature $dependencies; do
                pkg_in_cgcsrepo $dep && continue

                download_pkg $dep
            done
        done || exit $?
    done
fi

if [ -n "$DOWNLOAD_LIST" ]; then
    for df in $DOWNLOAD_LIST; do
        pkg_in_cgcsrepo $df && continue
        download_pkg $df
    done
fi


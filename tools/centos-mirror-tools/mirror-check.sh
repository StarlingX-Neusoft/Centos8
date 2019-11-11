#!/bin/bash
#
# SPDX-License-Identifier: Apache-2.0
#
# Copyright (C) 2019 Intel Corporation
#

# This script checks if the required packages in the .lst file list is
# actually downloadable. Sometimes, the release number in upstream is
# changed and that causes a mismatch in the build requirements.
# We can find this problems in an early stage without the need to
# download all the packages.
#
# The yum cache contains this information, more specific the primary_db
# files, so iterating over the content of .lst, parse the name of the
# package and get the information on what is available to download
# should be enough to know the status of the mirror.
#
# If a package is not found then the script will try to get the avai-
# lable version and log that into the error log. By this way we get
# notified on what changed in the external repositories.
#
# How to run:
# This script is intended to be run inside the downloader container.
# It needs that all the CentOS repositories are well setup.
#
# ./mirror-check.sh
#
# And you should see the checking in progress.

_print_msg() { echo -en "$(date -u +"%Y-%m-%d %H-%M-%S") ==> $1"; }
info() { _print_msg "INFO: $1\n"; }
info_c() { _print_msg "INFO: $1"; }
warning() { _print_msg "WARN: $1\n"; }
error() { _print_msg "ERROR: $1\n"; }

RPMS_CENTOS_LIST="rpms_centos.lst"
RPMS_3RD_PARTY_LIST="rpms_centos3rdparties.lst"
ERROR_LOG_FILE="mirror-check-failures.log"
truncate -s 0 $ERROR_LOG_FILE
retcode=0
extra_opts=""


usage() {
    echo "$0 [-c <yum.conf>]"
    echo ""
    echo "Options:"
    echo "  -c: Use an alternate yum.conf rather than the system file (option passed"
    echo "      on to subscripts when appropriate)"
    echo ""
}

get_rpm_name() {
    _rpm_file_name=$1
    rpm_name=$(echo "$_rpm_file_name" | rev | cut -d'-' -f3- | rev)
    echo "$rpm_name"
}

get_rpm_full_name() {
    _rpm_file_name=$1
    rpm_name=$(echo "$_rpm_file_name" | rev | cut -d'.' -f2- | rev)
    echo "$rpm_name"
}

get_rpm_arch() {
    arch=$(echo "$1" | rev | cut -d'.' -f2 | rev)
    echo "$arch"
}

get_repoquery_info() {
    _arch=$1
    _package_name=$2
    if [ "$_arch" == "x86_64" ]; then
        # To filter out the i686 packages
        repoquery_opts="--archlist=x86_64"
    elif [ "$_arch" == "src" ]; then
        repoquery_opts="--archlist=src"
    else
        repoquery_opts=
    fi
    repoquery $extra_opts ${RELEASEVER} -C --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' \
              $repoquery_opts "$_package_name"
}

_check_rpms() {
    p=$1
    full_name=$(get_rpm_full_name "$p")
    rpm_name=$(get_rpm_name "$p")
    arch=$(get_rpm_arch "$p")
    info_c "Checking $full_name... "
    _repoquery=$(get_repoquery_info "$arch" "$full_name")
    if [ -z "$_repoquery" ]; then
        echo -e "FAILED!"
        available_pkgs=$(get_repoquery_info "$arch" "$rpm_name")
        echo -e "Package $full_name not found, available $available_pkgs" >> $ERROR_LOG_FILE
        retcode=1
    else
        if [ "$full_name" == "$_repoquery" ]; then
            echo -e "OK"
        else
            echo -e "FAILED!"
            retcode=1
            echo -e "Required $full_name but found $_repoquery" >> $ERROR_LOG_FILE
        fi
    fi
}

check_rpms() {
    _rpms_list=$1
    for p in $_rpms_list; do
        _check_rpms "$p"
    done
}

while getopts "c:" opt; do
    case $opt in
        c)
            extra_opts="-c ${OPTARG}"
            grep -q "releasever=" $OPTARG && RELEASEVER="--$(grep releasever= ${OPTARG})"
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            usage
            exit 1
            ;;
    esac
done

info "Getting yum cache"
if ! yum $extra_opts ${RELEASEVER} makecache; then
    error "There was a problem getting yum cache"
    exit 1
fi

for rpm_list in "$RPMS_CENTOS_LIST" "$RPMS_3RD_PARTY_LIST"; do
    info "Reading $rpm_list..."
    for arch in "src" "noarch" "x86_64"; do
        info "Getting info for $arch packages..."
        rpms=$(echo "$(grep -F "$arch.rpm" < $rpm_list)")
        check_rpms "$rpms"
    done
done

if [ $retcode -ne 0 ]; then
    error "Failures found, error log:"
    error "=========================="
    cat $ERROR_LOG_FILE
fi

exit $retcode

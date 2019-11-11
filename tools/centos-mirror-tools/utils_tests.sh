#!/bin/bash
#
# SPDX-License-Identifier: Apache-2.0
#
# Copyright (C) 2019 Intel Corporation
#

# Set of unit tests for dl_rpms.sh

set -o errexit
set -o nounset

YUMCONFOPT=""
RELEASEVER="--releasever=7"

source utils.sh

check_result() {
    local _res="$1"
    local _expect="$2"
    if [ "$_res" != "$_expect" ]; then
        echo "Fail"
        echo "expected $_expect"
        echo "returned $_res"
        exit 1
    fi
    echo "Success"
}

# get_wget_command

res=$(get_wget_command "https://libvirt.org/sources/python/libvirt-python-3.5.0-1.fc24.src.rpm")
expect="wget -q https://libvirt.org/sources/python/libvirt-python-3.5.0-1.fc24.src.rpm"
check_result "$res" "$expect"

res=$(get_wget_command "python2-httpbin-0.5.0-6.el7.noarch.rpm")
expect="wget -q https://kojipkgs.fedoraproject.org/packages/python2-httpbin/0.5.0/6.el7/noarch/python2-httpbin-0.5.0-6.el7.noarch.rpm"
check_result "$res" "$expect"

# get_url

res=$(get_url "acpid-2.0.19-9.el7.x86_64.rpm" "L1")
expect="http://vault.centos.org/centos/7.4.1708/cr/x86_64/Packages/acpid-2.0.19-9.el7.x86_64.rpm"
check_result "$res" "$expect"

res=$(get_url "python2-httpbin-0.5.0-6.el7.noarch.rpm#http://cbs.centos.org/kojifiles/packages/python-httpbin/0.5.0/6.el7/noarch/python2-httpbin-0.5.0-6.el7.noarch.rpm" "L1")
expect="http://cbs.centos.org/kojifiles/packages/python-httpbin/0.5.0/6.el7/noarch/python2-httpbin-0.5.0-6.el7.noarch.rpm"
check_result "$res" "$expect"

res=$(get_url "python2-httpbin-0.5.0-6.el7.noarch.rpm" "K1")
expect="https://kojipkgs.fedoraproject.org/packages/python2-httpbin/0.5.0/6.el7/noarch/python2-httpbin-0.5.0-6.el7.noarch.rpm"
check_result "$res" "$expect"

# get_yum_command

res=$(get_yum_command "anaconda-21.48.22.147-1.el7.centos.src.rpm" "L1")
expect="yumdownloader -q -C  --releasever=7 --source anaconda-21.48.22.147-1.el7.centos"
check_result "$res" "$expect"

res=$(get_yum_command "acpid-2.0.19-9.el7.x86_64.rpm" "L1")
expect="yumdownloader -q -C  --releasever=7 --archlist=noarch,x86_64 acpid-2.0.19-9.el7"
check_result "$res" "$expect"

# get_rpm_level_name

res=$(get_rpm_level_name "acl-2.2.51-12.el7.x86_64.rpm" "L1")
expect="acl-2.2.51-12.el7"
check_result "$res" "$expect"

res=$(get_rpm_level_name "acl-2.2.51-12.el7.x86_64.rpm" "L3")
expect="acl"
check_result "$res" "$expect"

res=$(get_rpm_level_name "anaconda-21.48.22.147-1.el7.centos.src.rpm" "L2")
expect="anaconda-21.48.22.147"
check_result "$res" "$expect"

res=$(get_arch_from_rpm "acl-2.2.51-12.el7.x86_64.rpm")
expect="x86_64"
check_result "$res" "$expect"

res=$(get_arch_from_rpm "acl-2.2.51-12.el7.noarch.rpm")
expect="noarch"
check_result "$res" "$expect"

res=$(get_arch_from_rpm "acl-2.2.51-12.el7.src.rpm")
expect="src"
check_result "$res" "$expect"

res=$(get_arch_from_rpm "acl-2.2.51-12.el7.src.rpm#https://someurl.com/acl-2.2.51-12.el7.src.rpm")
expect="src"
check_result "$res" "$expect"

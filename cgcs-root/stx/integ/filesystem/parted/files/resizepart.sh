#!/bin/bash

################################################################################
# Copyright (c) 2015 Wind River Systems, Inc.
# 
# SPDX-License-Identifier: Apache-2.0
#
################################################################################

DEVICE=$1
PARTITION=$2
SIZE=$(blockdev --getsize64 ${DEVICE})
SIZE_MB=$((SIZE / (1024*1024)))

## This is a workaround to allow cloud-init to invoke parted without needing to
## handle command prompts interactively.  Support for non-interactive parted
## commands are not supported on mounted partitions.
##
/usr/sbin/parted ---pretend-input-tty ${DEVICE} resizepart ${PARTITION} << EOF
yes
${SIZE_MB}
EOF

exit $?

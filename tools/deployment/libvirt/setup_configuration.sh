#!/usr/bin/env bash
#
# SPDX-License-Identifier: Apache-2.0
#
# Copyright (C) 2019 Intel Corporation
#

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}" )" )"
source ${SCRIPT_DIR}/functions.sh

while getopts "c:i:" o; do
    case "${o}" in
        c)
            CONFIGURATION="$OPTARG"
            ;;
        i)
            ISOIMAGE=$(readlink -f "$OPTARG")
            ;;
        *)
            usage
            exit 1
            ;;
    esac
done
shift $((OPTIND-1))

if [[ -z ${CONFIGURATION} ]] || [[ -z "${ISOIMAGE}" ]]; then
    usage
    exit -1
fi

iso_image_check ${ISOIMAGE}
configuration_check ${CONFIGURATION}

CONFIGURATION=${CONFIGURATION:-simplex}
BRIDGE_INTERFACE=${BRIDGE_INTERFACE:-stxbr}
CONTROLLER=${CONTROLLER:-controller}
WORKER=${WORKER:-worker}
WORKER_NODES_NUMBER=${WORKER_NODES_NUMBER:-1}
STORAGE=${STORAGE:-storage}
STORAGE_NODES_NUMBER=${STORAGE_NODES_NUMBER:-1}
DOMAIN_DIRECTORY=vms

bash ${SCRIPT_DIR}/destroy_configuration.sh -c $CONFIGURATION

[ ! -d ${DOMAIN_DIRECTORY} ] && mkdir ${DOMAIN_DIRECTORY}

create_controller $CONFIGURATION $CONTROLLER $BRIDGE_INTERFACE $ISOIMAGE

if ([ "$CONFIGURATION" == "controllerstorage" ] || [ "$CONFIGURATION" == "dedicatedstorage" ]); then
    for ((i=0; i<=$WORKER_NODES_NUMBER; i++)); do
        WORKER_NODE=${CONFIGURATION}-${WORKER}-${i}
        create_node "worker" ${WORKER_NODE} ${BRIDGE_INTERFACE}
    done
fi

if ([ "$CONFIGURATION" == "dedicatedstorage" ]); then
    for ((i=0; i<=$STORAGE_NODES_NUMBER; i++)); do
        STORAGE_NODE=${CONFIGURATION}-${STORAGE}-${i}
        create_node "storage" ${STORAGE_NODE} ${BRIDGE_INTERFACE}
    done
fi

sudo virt-manager

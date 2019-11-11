#!/usr/bin/env bash

BRIDGE_INTERFACE=${BRIDGE_INTERFACE:-stxbr}
EXTERNAL_NETWORK=${EXTERNAL_NETWORK:-10.10.10.0/24}
EXTERNAL_IP=${EXTERNAL_IP:-10.10.10.1/24}

for i in {1..4}; do
    BRIDGE_INTERFACE_NAME=${BRIDGE_INTERFACE}$i
    if [ -d "/sys/class/net/${BRIDGE_INTERFACE_NAME}" ]; then
        sudo ip link set dev ${BRIDGE_INTERFACE_NAME} down
        sudo ip link delete dev ${BRIDGE_INTERFACE_NAME}
    fi
done

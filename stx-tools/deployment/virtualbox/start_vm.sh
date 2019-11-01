#!/usr/bin/env bash

rdeport=`VBoxManage showvminfo $1 | grep "^VRDE:" | grep -o "Ports [0-9]*" | cut -d ' ' -f 2`
if [ "x$rdeport" == "x" ]; then
    echo "Vm $1 not found or not configured to use rde".
    exit 1
fi

VBoxManage startvm "$1" --type headless

sleep 3
echo rdesktop-vrdp -a 16 -N "127.0.0.1:$rdeport"
if xdpyinfo 2>&1 >> /dev/null; then
    rdesktop-vrdp -a 16 -N "127.0.0.1:$rdeport" &
else
    echo "Running without X display. Use a tunnel from your laptop"
    echo "ssh -L $rdeport:127.0.0.1:$rdeport -N -f -l <uname> madbuild01.ostc.intel.com"
    echo "Then run rdesktop-vrdp -a 16 -N 127.0.0.1:$rdeport from your laptop"
fi

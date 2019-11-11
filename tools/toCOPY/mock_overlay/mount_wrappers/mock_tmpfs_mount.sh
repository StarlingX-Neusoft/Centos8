#!/bin/bash

MOUNT_POINT=$1
SIZE_IN_GB=$2

id $USER | grep '(cgts)\|751(mock)' > /dev/null
if [ $? -ne 0 ]
then
    echo "Only members of group cgts may use this tool."
    exit 1
fi

MY_UID=`id -u $USER`
if [ $? -ne 0 ]
then
    echo "failed to determine UID."
    exit 1
fi

MY_GID=`getent group cgts | cut -d: -f3`
if [ $? -ne 0 ]
then
    echo "failed to determine GID."
    exit 1
fi

# echo "USER=$USER"
# echo "UID=$UID"
# echo "MY_UID=$MY_UID"
# echo "MY_GID=$MY_GID"

if [ "$SIZE_IN_GB" == "" ] || [ $SIZE_IN_GB -le 0 ]; then
    echo "Invalid size: '$SIZE_IN_GB'"
    exit 1
fi

if [ ! -d $MOUNT_POINT ]
then
    echo "'$MOUNT_POINT' is not a directory"
    exit 1
fi

echo "$MOUNT_POINT" | grep -e "/$USER/.*/mock/" > /dev/null
if [ $? -ne 0 ]
then
    echo "'$MOUNT_POINT' does not match pattern '/$USER/.*/mock/'"
    exit 1
fi

MIN_AVAIL_GB=8
AVAIL_GB=$(free -m -h | grep '^Mem:' | awk  '{ print $7 }' | sed 's/G$//')
if [ $AVAIL_GB -lt $MIN_AVAIL_GB ]; then
    echo "Below minimum available memory: $AVAIL_GB vs $MIN_AVAIL_GB"
    exit 1
fi

if [ $SIZE_IN_GB -gt $AVAIL_GB ]; then
    echo "Insufficient memory"
    exit 1
fi

REMAINDER_GB=$((AVAIL_GB-SIZE_IN_GB))
if [ $REMAINDER_GB -lt $MIN_AVAIL_GB ]; then
    echo "System would be driven below minimum available memory: ($AVAIL_GB - $SIZE_IN_GB) < $MIN_AVAIL_GB"
    exit 1
fi

# echo "mount -t tmpfs -o size=${SIZE_IN_GB}G tmpfs $MOUNT_POINT"
mount -t tmpfs -o size=${SIZE_IN_GB}G tmpfs $MOUNT_POINT
if [ $? -ne 0 ]
then
    echo "failed to mount '$MOUNT_POINT'"
    exit 1
fi

echo "'$MOUNT_POINT' mounted"
exit 0

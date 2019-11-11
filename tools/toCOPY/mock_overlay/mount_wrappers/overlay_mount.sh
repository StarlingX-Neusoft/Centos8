#!/bin/bash

LOWER=$1
UPPER=$2
MOUNT_POINT=$3

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

# echo "UID=$UID"
# echo "MY_UID=$MY_UID"
# echo "MY_GID=$MY_GID"

if [ ! -d $LOWER ]
then
    echo "'$LOWER' is not a directory"
    exit 1
fi

if [ ! -d $UPPER ]
then
    echo "'$UPPER' is not a directory"
    exit 1
fi

if [ ! -d $MOUNT_POINT ]
then
    echo "'$MOUNT_POINT' is not a directory"
    exit 1
fi

echo "$LOWER" | grep "^/localdisk/loadbuild/jenkins" > /dev/null
if [ $? -ne 0 ]
then
    echo "$LOWER" | grep "^/localdisk/sscache/jenkins" > /dev/null
    if [ $? -ne 0 ]
    then
        echo "'$LOWER' does not match pattern '/localdisk/(loadbuild|sscache)/jenkins'"
        exit 1
    fi
fi

echo "$UPPER" | grep "^/localdisk/loadbuild/$USER" > /dev/null
if [ $? -ne 0 ]
then
    echo "$UPPER" | grep "^/localdisk/sscache/$USER" > /dev/null
    if [ $? -ne 0 ]
    then
        echo "'$UPPER' does not match pattern '/localdisk/(loadbuild|sscache)/$USER'"
        exit 1
    fi
fi

echo "$MOUNT_POINT" | grep "^/localdisk/loadbuild/$USER" > /dev/null
if [ $? -ne 0 ]
then
    echo "$MOUNT_POINT" | grep "^/localdisk/sscache/$USER" > /dev/null
    if [ $? -ne 0 ]
    then
        echo "'$MOUNT_POINT' does not match pattern '/localdisk/(loadbuild|sscache)/$USER'"
        exit 1
    fi
fi

mount -l -t overlayfs_uid | grep "$MOUNT_POINT" > /dev/null
if [ $? -eq 0 ]
then
    echo "'$MOUNT_POINT' is already mounted."
    exit 1
fi


mount -t overlayfs_uid -o lowerdir=$LOWER,upperdir=$UPPER,uid=$MY_UID,gid=$MY_GID overlayfs_uid $MOUNT_POINT
if [ $? -ne 0 ]
then
    echo "failed to mount '$MOUNT_POINT'"
    exit 1
fi

echo "'$MOUNT_POINT' mounted"
exit 0


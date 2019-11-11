#!/bin/bash

LOCK_FILE=$1

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

if [ ! -f $LOCK_FILE ]
then
    echo "'$LOCK_FILE' is not a file"
    exit 1
fi

echo "$LOCK_FILE" | grep "[/]localdisk[/]loadbuild[/]$USER[/].*[/]yumcache[.]lock" > /dev/null
if [ $? -ne 0 ]
then
    echo "'$LOCK_FILE' does not match pattern '/localdisk/loadbuild/$USER/*/yumcache.lock'"
    exit 1
fi

echo "rm -f $LOCK_FILE"
\rm -f $LOCK_FILE
if [ $? -ne 0 ]
then
    echo "failed to rm '$LOCK_FILE'"
    exit 1
fi

echo "'$LOCK_FILE' deleted"
exit 0

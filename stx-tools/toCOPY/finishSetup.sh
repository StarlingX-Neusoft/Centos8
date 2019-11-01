#!/bin/bash

# Load tbuilder configuration
if [[ -r ${HOME}/buildrc ]]; then
    source ${HOME}/buildrc
fi

# start the web server
# this was done before I reallized I needed to have systemd
# running in the container. could revert to systemd startup but
# will leave that task for later

if [[ ! `ps augxww | grep lighttpd | grep conf` ]]; then
    echo "starting lighttpd up...";
    sudo /usr/sbin/lighttpd  -f /etc/lighttpd/lighttpd.conf
else
    echo "not starting up lighttpd, it's already running"
fi


# make sure the mock directories are there
# and have the right settings
mkdir -p /localdisk/loadbuild/mock
sudo chmod 775 /localdisk/loadbuild/mock
sudo chown root:mock /localdisk/loadbuild/mock
mkdir -p /localdisk/loadbuild/mock-cache
sudo chmod 775 /localdisk/loadbuild/mock-cache
sudo chown root:mock /localdisk/loadbuild/mock-cache
### may need to add these later. once it works will try on clean localdisk setup
# [builder@bavery-WS-DESK cgcs-root]$ history | grep mkdir
# 55  mkdir -p $MY_WORKSPACE/results
# 66  mkdir -p $MY_WORKSPACE/std/results/$MY_BUILD_ENVIRONMENT-std
# 78  mkdir -p $MY_WORKSPACE/rt/rpmbuild/RPMS

# make the place we will clone into
. /etc/profile.d/TC.sh
echo "MY_REPO=$MY_REPO"
mkdir -p $MY_REPO
mkdir -p $MY_WORKSPACE

cat <<EOF
Using ${SOURCE_REMOTE_URI} for build

To ease checkout do:
    eval \$(ssh-agent)
    ssh-add
To start a fresh source tree:
    cd \$MY_REPO_ROOT_DIR
    repo init -u https://opendev.org/starlingx/manifest.git -m default.xml
To build all packages:
    cd \$MY_REPO
    build-pkgs or build-pkgs <pkglist>
To make an iso:
    build-iso
EOF

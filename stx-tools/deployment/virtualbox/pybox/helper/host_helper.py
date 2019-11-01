#!/usr/bin/python3
#
# SPDX-License-Identifier: Apache-2.0
#


import time
import streamexpect
from consts.timeout import HostTimeout
from utils import serial
from utils.install_log import LOG


def unlock_host(stream, hostname):
    """
    Unlocks given host
    Args:
        stream(stream): Stream to active controller
        hostname(str): Name of host to unlock
    Steps:
        - Check that host is locked
        - Unlock host
    """
    LOG.info("#### Unlock %s", hostname)
    serial.send_bytes(stream, "system host-list | grep {}".format(hostname), expect_prompt=False)
    try:
        serial.expect_bytes(stream, "locked")
    except streamexpect.ExpectTimeout:
        LOG.info("Host %s not locked", hostname)
        return 1
    serial.send_bytes(stream, "system host-unlock {}".format(hostname), expect_prompt=False)
    LOG.info("Unlocking %s", hostname)


def lock_host(stream, hostname):
    """
    Locks the specified host.
    Args:
        stream(stream): Stream to controller-0
        hostname(str): Name of host to lock
    Steps:
        - Check that host is unlocked
        - Lock host
    """
    LOG.info("Lock %s", hostname)
    serial.send_bytes(stream, "system host-list |grep {}".format(hostname), expect_prompt=False)
    try:
        serial.expect_bytes(stream, "unlocked")
    except streamexpect.ExpectTimeout:
        LOG.info("Host %s not unlocked", hostname)
        return 1
    serial.send_bytes(stream, "system host-lock {}".format(hostname), expect_prompt="keystone")
    LOG.info("Locking %s", hostname)


def reboot_host(stream, hostname):
    """
    Reboots host specified
    Args:
        stream():
        hostname(str): Host to reboot
    """
    LOG.info("Rebooting %s", hostname)
    serial.send_bytes(stream, "system host-reboot {}".format(hostname), expect_prompt=False)
    serial.expect_bytes(stream, "rebooting", HostTimeout.REBOOT)


def install_host(stream, hostname, host_type, host_id):
    """
    Initiates install of specified host. Requires controller-0 to be installed already.
    Args:
        stream(stream): Stream to cont0
        hostname(str): Name of host
        host_type(str): Type of host being installed e.g. 'storage' or 'compute'
        host_id(int): id to identify host
    """

    time.sleep(10)
    LOG.info("Installing %s with id %s", hostname, host_id)
    if host_type is 'controller':
        serial.send_bytes(stream,
                          "system host-update {} personality=controller".format(host_id),
                          expect_prompt=False)
    elif host_type is 'storage':
        serial.send_bytes(stream,
                          "system host-update {} personality=storage".format(host_id),
                          expect_prompt=False)
    else:
        serial.send_bytes(stream,
                          "system host-update {} personality=compute hostname={}".format(host_id,
                                                                                         hostname),
                          expect_prompt=False)
    time.sleep(30)


def disable_logout(stream):
    """
    Disables automatic logout of users.
    Args:
        stream(stream): stream to cont0
    """
    LOG.info('Disabling automatic logout')
    serial.send_bytes(stream, "export TMOUT=0")


def change_password(stream, username="wrsroot", password="Li69nux*"):
    """
    changes the default password on initial login.
    Args:
        stream(stream): stream to cont0

    """
    LOG.info('Changing password to Li69nux*')
    serial.send_bytes(stream, username, expect_prompt=False)
    serial.expect_bytes(stream, "Password:")
    serial.send_bytes(stream, username, expect_prompt=False)
    serial.expect_bytes(stream, "UNIX password:")
    serial.send_bytes(stream, username, expect_prompt=False)
    serial.expect_bytes(stream, "New password:")
    serial.send_bytes(stream, password, expect_prompt=False)
    serial.expect_bytes(stream, "Retype new")
    serial.send_bytes(stream, password)


def login(stream, timeout=600, username="wrsroot", password="Li69nux*"):
    """
    Logs into controller-0.
    Args:
        stream(stream): stream to cont0
        timeout(int): Time before login fails in seconds.
    """

    serial.send_bytes(stream, "\n", expect_prompt=False)
    rc = serial.expect_bytes(stream, "ogin:", fail_ok=True, timeout=timeout)
    if rc != 0:
        serial.send_bytes(stream, "\n", expect_prompt=False)
        if serial.expect_bytes(stream, "~$", timeout=10, fail_ok=True) == -1:
            serial.send_bytes(stream, '\n', expect_prompt=False)
            serial.expect_bytes(stream, "keystone", timeout=10)
    else:
        serial.send_bytes(stream, username, expect_prompt=False)
        serial.expect_bytes(stream, "assword:")
        serial.send_bytes(stream, password)
    disable_logout(stream)


def logout(stream):
    """
    Logs out of controller-0.
    Args:
        stream(stream): stream to cont0
    """
    serial.send_bytes(stream, "exit", expect_prompt=False)
    time.sleep(5)


def check_password(stream, password="Li69nux*"):
    ret = serial.expect_bytes(stream, 'assword', fail_ok=True, timeout=5)
    if ret == 0:
        serial.send_bytes(stream, password, expect_prompt=False)

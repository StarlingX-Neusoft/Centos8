#!/usr/bin/python3
#
# SPDX-License-Identifier: Apache-2.0
#

"""
Contains helper functions that will configure basic system settings.
"""

from consts.timeout import HostTimeout

from helper import host_helper

from utils import serial
from utils.install_log import LOG

def update_platform_cpus(stream, hostname, cpu_num=5):
    """
    Update platform CPU allocation.
    """

    LOG.info("Allocating %s CPUs for use by the %s platform.", cpu_num, hostname)
    serial.send_bytes(stream, "\nsource /etc/platform/openrc; system host-cpu-modify "
                      "{} -f platform -p0 {}".format(hostname, cpu_num,
                                                     prompt='keystone', timeout=300))

def set_dns(stream, dns_ip):
    """
    Perform DNS configuration on the system.
    """

    LOG.info("Configuring DNS to %s.", dns_ip)
    serial.send_bytes(stream, "source /etc/nova/openrc; system dns-modify "
                      "nameservers={}".format(dns_ip), prompt='keystone')


def config_controller(stream, config_file=None, password='Li69nux*'):
    """
    Configure controller-0 using optional arguments
    """

    args = ''
    if config_file:
        args += '--config-file ' + config_file + ' '

    serial.send_bytes(stream, "sudo config_controller {}".format(args), expect_prompt=False)
    host_helper.check_password(stream, password=password)
    ret = serial.expect_bytes(stream, "unlock controller to proceed.",
                              timeout=HostTimeout.LAB_CONFIG)
    if ret != 0:
        LOG.info("Configuration failed. Exiting installer.")
        raise Exception("Configcontroller failed")


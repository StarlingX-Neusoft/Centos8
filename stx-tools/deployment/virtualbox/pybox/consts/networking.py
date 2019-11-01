#!/usr/bin/python3
#
# SPDX-License-Identifier: Apache-2.0
#


from sys import platform


class Subnets:
    IPV4 = {
        'mgmt_subnet': '192.168.204.0/24',
        'infra_subnet': '192.168.205.0/24',
        'oam_subnet': '10.10.10.0/24'
    }

    IPV6 = {
        'mgmt_subnet': 'aefd::/64',
        'infra_subnet': 'aced::/64',
        'oam_subnet': 'abcd::/64'
    }


class NICs:
    if platform == 'win32' or platform == 'win64':

        CONTROLLER = {
            'node_type': 'controller',
            '1': {'nic': 'hostonly', 'intnet': '', 'nictype': '82540EM', 'nicpromisc': 'deny', 'hostonlyadapter': 'VirtualBox Host-Only Ethernet Adapter'},
            '2': {'nic': 'intnet', 'intnet': 'intnet-management', 'nictype': '82540EM', 'nicpromisc': 'allow-all', 'hostonlyadapter': 'none'},
            '3': {'nic': 'intnet', 'intnet': 'intnet-data1', 'nictype': 'virtio', 'nicpromisc': 'allow-all', 'hostonlyadapter': 'none'},
            '4': {'nic': 'intnet', 'intnet': 'intnet-data2', 'nictype': 'virtio', 'nicpromisc': 'allow-all', 'hostonlyadapter': 'none'},
        }
    else:
        CONTROLLER = {
            'node_type': 'controller',
            '1': {'nic': 'hostonly', 'intnet': '', 'nictype': '82540EM', 'nicpromisc': 'deny', 'hostonlyadapter': 'vboxnet0'},
            '2': {'nic': 'intnet', 'intnet': 'intnet-management', 'nictype': '82540EM', 'nicpromisc': 'allow-all', 'hostonlyadapter': 'none'},
            '3': {'nic': 'intnet', 'intnet': 'intnet-data1', 'nictype': 'virtio', 'nicpromisc': 'allow-all', 'hostonlyadapter': 'none'},
            '4': {'nic': 'intnet', 'intnet': 'intnet-data2', 'nictype': 'virtio', 'nicpromisc': 'allow-all', 'hostonlyadapter': 'none'},
        }

    COMPUTE = {
        'node_type': 'compute',
        '1': {'nic': 'intnet', 'intnet': 'intnet-unused1', 'nictype': '82540EM', 'nicpromisc': 'allow-all', 'hostonlyadapter': 'none'},
        '2': {'nic': 'intnet', 'intnet': 'intnet-management', 'nictype': '82540EM', 'nicpromisc': 'allow-all', 'hostonlyadapter': 'none'},
        '3': {'nic': 'intnet', 'intnet': 'intnet-data1', 'nictype': 'virtio', 'nicpromisc': 'allow-all', 'hostonlyadapter': 'none'},
        '4': {'nic': 'intnet', 'intnet': 'intnet-data2', 'nictype': 'virtio', 'nicpromisc': 'allow-all', 'hostonlyadapter': 'none'},
    }

    STORAGE = {
        'node_type': 'storage',
        '1': {'nic': 'intnet', 'intnet': 'intnet-unused', 'nictype': '82540EM', 'nicpromisc': 'allow-all', 'hostonlyadapter': 'none'},
        '2': {'nic': 'intnet', 'intnet': 'intnet-management', 'nictype': '82540EM', 'nicpromisc': 'allow-all', 'hostonlyadapter': 'none'},
        '3': {'nic': 'intnet', 'intnet': 'intnet-infra', 'nictype': '82540EM', 'nicpromisc': 'allow-all', 'hostonlyadapter': 'none'},
    }

class OAM:
    OAM = {
        'ip': '10.10.10.254',
        'netmask': '255.255.255.0',
    }

class Serial:
    if platform == 'win32' or platform == 'win64':
        SERIAL = {
            'uartbase': '0x3F8',
            'uartport': '4',
            'uartmode': 'tcpserver',
            'uartpath': '10000'
        }
    else:
        SERIAL = {
            'uartbase': '0x3F8',
            'uartport': '4',
            'uartmode': 'server',
            'uartpath': '/tmp/'
        }

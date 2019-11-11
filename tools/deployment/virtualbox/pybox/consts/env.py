#!/usr/bin/python3
#
# SPDX-License-Identifier: Apache-2.0
#


import getpass
from sys import platform
import os

user = getpass.getuser()

if platform == 'win32' or platform == 'win64':
    LOGPATH = 'C:\\Temp\\pybox_logs'
    PORT = 10000
else:
    homedir = os.environ['HOME']
    LOGPATH = '{}/vbox_installer_logs'.format(homedir)

class Lab:
    VBOX = {
        'floating_ip': '10.10.10.7',
        'controller-0_ip': '10.10.10.8',
        'controller-1_ip': '10.10.10.9',
        'username': 'wrsroot',
        'password': 'Li69nux*',
    }

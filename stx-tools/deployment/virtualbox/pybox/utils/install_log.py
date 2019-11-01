#!/usr/bin/python3
#
# SPDX-License-Identifier: Apache-2.0
#


import os
import datetime
import logging
from consts.env import LOGPATH

log_dir = ""
LOG = logging.getLogger()

def init_logging(lab_name, log_path=None):
    global LOG, log_dir
    if not log_path:
        log_path = LOGPATH
    lab_log_path = log_path + "/" + lab_name

    # Setup log sub-directory for current run
    current_time = datetime.datetime.now()
    log_dir = "{}/{}_{}_{}_{}_{}_{}".format(lab_log_path,
                                            current_time.year,
                                            current_time.month,
                                            current_time.day,
                                            current_time.hour,
                                            current_time.minute,
                                            current_time.second)
    if not os.path.exists(log_dir):
        os.makedirs(log_dir)

    LOG.setLevel(logging.INFO)
    formatter = logging.Formatter("%(asctime)s: %(message)s")
    log_file = "{}/install.log".format(log_dir)
    handler = logging.FileHandler(log_file)
    handler.setFormatter(formatter)
    handler.setLevel(logging.INFO)
    LOG.addHandler(handler)
    handler = logging.StreamHandler()
    handler.setFormatter(formatter)
    LOG.addHandler(handler)

    # Create symbolic link to latest logs of this lab
    try:
        os.unlink(lab_log_path + "/latest")
    except:
        pass
    os.symlink(log_dir, lab_log_path + "/latest")

def get_log_dir():
    return log_dir

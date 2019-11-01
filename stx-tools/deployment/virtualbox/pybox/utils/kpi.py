#!/usr/bin/python3
#
# SPDX-License-Identifier: Apache-2.0
#


import time
from utils.install_log import LOG

STAGES = []
METRICS = {}
start = 0

def init_kpi_metrics():
    global start
    start = time.time()

def get_formated_time(sec):
    hours = sec // 3600
    sec %= 3600
    minutes = sec // 60
    sec %= 60
    seconds = sec
    if hours:
        return "{:.0f}h {:.0f}m {:.2f}s".format(hours, minutes, seconds)
    elif minutes:
        return "{:.0f}m {:.2f}s".format(minutes, seconds)
    elif seconds:
        return "{:.2f}s".format(seconds)

def set_kpi_metric(metric, duration):
    global METRICS, STAGES
    METRICS[metric] = duration
    STAGES.append(metric)

def print_kpi(metric):
    if metric in STAGES:
        sec = METRICS[metric]
        LOG.info("  Time in stage '%s': %s ", metric, get_formated_time(sec))
    elif metric == 'total' and start:
        duration = time.time() - start
        LOG.info("  Total time: %s", get_formated_time(duration))

def get_kpi_str(metric):
    msg = ""
    if metric in STAGES:
        sec = METRICS[metric]
        msg += ("  Time in stage '{}': {} \n".format(metric, get_formated_time(sec)))
    elif metric == 'total' and start:
        duration = time.time() - start
        msg += ("  Total time: {}\n".format(get_formated_time(duration)))
    return msg

def get_kpi_metrics_str():
    msg = "===================== Metrics ====================\n"
    for stage in STAGES:
        msg += get_kpi_str(stage)
    msg += get_kpi_str('total')
    msg += "===============================================\n"
    return msg

def print_kpi_metrics():
    LOG.info("===================== Metrics ====================")
    for stage in STAGES:
        print_kpi(stage)
    print_kpi('total')
    LOG.info("==================================================")


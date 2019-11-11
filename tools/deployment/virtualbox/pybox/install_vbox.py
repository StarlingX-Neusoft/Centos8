#!/usr/bin/python3
#
# SPDX-License-Identifier: Apache-2.0
#

"""
This tool is an automated installer to allow users to easily install
StarlingX on VirtualBox.
"""

import subprocess
import configparser
import getpass
import time
import re
import tempfile
import signal
import sys
from sys import platform
import paramiko
import streamexpect

from utils import kpi, serial
from utils.install_log import init_logging, get_log_dir, LOG
from utils.sftp import sftp_send, send_dir

from helper import vboxmanage
from helper import install_lab
from helper import host_helper

from consts import env
from consts.node import Nodes
from consts.networking import NICs, OAM, Serial
from consts.timeout import HostTimeout

from Parser import handle_args


# Global vars
vboxoptions = None


def menu_selector(stream, setup_type,
                  securityprofile, lowlatency, install_mode='serial'):
    """
    Select the correct install option.
    """

    # Wait for menu to load (add sleep so we can see what is picked)
    serial.expect_bytes(stream, "Press")
    # Pick install type
    if setup_type in [AIO_SX, AIO_DX]:
        LOG.info("Selecting AIO controller")
        serial.send_bytes(stream, "\033[B", expect_prompt=False, send=False)
    if lowlatency is True:
        LOG.info("Selecting low latency controller")
        serial.send_bytes(stream, "\033[B", expect_prompt=False, send=False)
    serial.send_bytes(stream, "\n", expect_prompt=False, send=False)
    time.sleep(4)
    # Serial or Graphical menu (picking Serial by default)
    if install_mode == "graphical":
        LOG.info("Selecting Graphical menu")
        serial.send_bytes(stream, "\033[B", expect_prompt=False, send=False)
    else:
        LOG.info("Selecting Serial menu")
    serial.send_bytes(stream, "\n", expect_prompt=False, send=False)
    time.sleep(6)
    # Security profile menu
    if securityprofile == "extended":
        LOG.info("Selecting extended security profile")
        serial.send_bytes(stream, "\033[B", expect_prompt=False, send=False)
    time.sleep(2)
    serial.send_bytes(stream, "\n", expect_prompt=False, send=False)
    time.sleep(4)


def setup_networking(stream, ctrlr0_ip, gateway_ip, password='Li69nux*'):
    """
    Setup initial networking so we can transfer files.
    """
    ip = ctrlr0_ip
    interface = "enp0s3"
    ret = serial.send_bytes(
        stream,
        "/sbin/ip address list",
        prompt=ctrlr0_ip,
        fail_ok=True,
        timeout=10)
    if ret != 0:
        LOG.info("Setting networking up.")
    else:
        LOG.info("Skipping networking setup")
        return
    LOG.info("%s being set up with ip %s", interface, ip)
    serial.send_bytes(stream,
                      "sudo /sbin/ip addr add {}/24 dev {}".format(ip, interface),
                      expect_prompt=False)
    host_helper.check_password(stream, password=password)
    time.sleep(2)
    serial.send_bytes(stream,
                      "sudo /sbin/ip link set {} up".format(interface),
                      expect_prompt=False)
    host_helper.check_password(stream, password=password)
    time.sleep(2)
    serial.send_bytes(stream,
                      "sudo route add default gw {}".format(gateway_ip),
                      expect_prompt=False)
    host_helper.check_password(stream, password=password)

    if vboxoptions.vboxnet_type == 'hostonly':
        LOG.info("Pinging controller-0 at: %s...", ip)
        tmout = HostTimeout.NETWORKING_OPERATIONAL
        while tmout:
            # Ping from machine hosting virtual box to virtual machine
            rc = subprocess.call(['ping', '-c', '1', ip])
            if rc == 0:
                break
            tmout -= 1
        else:
            raise "Failed to establish connection in {}s " \
                "to controller-0 at: {}!"
        LOG.info("Ping succeeded!")


def fix_networking(stream, release, password='Li69nux*'):
    """
    Vbox/linux bug: Sometimes after resuming a VM networking fails to comes up.
    Setting VM interface down then up again fixes it.
    """
    if release == "R2":
        interface = "eth0"
    else:
        interface = "enp0s3"
    LOG.info("Fixing networking ...")
    serial.send_bytes(stream,
                      "sudo /sbin/ip link set {} down".format(interface),
                      expect_prompt=False)
    host_helper.check_password(stream, password=password)
    time.sleep(1)
    serial.send_bytes(
        stream,
        "sudo /sbin/ip link set {} up".format(interface),
        expect_prompt=False)
    host_helper.check_password(stream, password=password)
    time.sleep(2)


def install_controller_0(cont0_stream, setup_type, securityprofile, lowlatency,
                         install_mode, ctrlr0_ip, gateway_ip,
                         username='wrsroot', password='Li69nux*'):
    """
    Installation of controller-0.
    """
    LOG.info("Starting installation of controller-0")
    start_time = time.time()
    menu_selector(
        cont0_stream,
        setup_type,
        securityprofile,
        lowlatency,
        install_mode)

    try:
        serial.expect_bytes(
            cont0_stream,
            "login:",
            timeout=HostTimeout.INSTALL)
    except Exception as e:
        LOG.info("Connection failed for controller-0 with %s", e)
        # Sometimes we get UnicodeDecodeError exception due to the output
        # of installation. So try one more time maybe
        LOG.info("So ignore the exception and wait for controller-0 to be installed again.")
        if HostTimeout.INSTALL > (time.time() - start_time):
            serial.expect_bytes(
                cont0_stream,
                "login:",
                timeout=HostTimeout.INSTALL - (time.time() - start_time))

    LOG.info("Completed installation of controller-0.")
    # Change password on initial login
    time.sleep(20)
    host_helper.change_password(
        cont0_stream,
        username=username,
        password=password)
    # Disable user logout
    time.sleep(10)
    host_helper.disable_logout(cont0_stream)
    # Setup basic networking
    time.sleep(1)
    setup_networking(cont0_stream, ctrlr0_ip, gateway_ip, password=password)


def delete_lab(labname, force=False):
    """
    This allows for the deletion of an existing lab.
    """

    node_list = vboxmanage.get_all_vms(labname, option="vms")

    if len(node_list) != 0:
        if not force:
            LOG.info("This will delete lab %s with vms: %s", labname, node_list)
            LOG.info("Continue? (y/N)")
            while True:
                choice = input().lower()
                if choice == 'y':
                    break
                else:
                    LOG.info("Aborting!")
                    exit(1)
        LOG.info("#### Deleting lab %s.", labname)
        LOG.info("VMs in lab: %s.", node_list)
        vboxmanage.vboxmanage_controlvms(node_list, "poweroff")
        time.sleep(2)
        vboxmanage.vboxmanage_deletevms(node_list)


def get_disk_sizes(comma_list):
    """
    Return the disk sizes as taken from the command line.
    """
    sizes = comma_list.split(',')
    for size in sizes:
        try:
            val = int(size)
            if val < 0:
                raise Exception()
        except:
            LOG.info("Disk sizes must be a comma separated list of positive integers.")
            raise Exception("Disk sizes must be a comma separated list of positive integers.")
    return sizes


def create_lab(vboxoptions):
    """
    Creates vms using the arguments in vboxoptions.
    """

    # Pull in node configuration
    node_config = [getattr(Nodes, attr)
                   for attr in dir(Nodes) if not attr.startswith('__')]
    nic_config = [getattr(NICs, attr)
                  for attr in dir(NICs) if not attr.startswith('__')]
    oam_config = [getattr(OAM, attr)
                  for attr in dir(OAM) if not attr.startswith('__')][0]
    serial_config = [getattr(Serial, attr)
                     for attr in dir(Serial) if not attr.startswith('__')]

    # Create nodes list
    nodes_list = []

    if vboxoptions.controllers:
        for node_id in range(0, vboxoptions.controllers):
            node_name = vboxoptions.labname + "-controller-{}".format(node_id)
            nodes_list.append(node_name)
    if vboxoptions.workers:
        for node_id in range(0, vboxoptions.workers):
            node_name = vboxoptions.labname + "-worker-{}".format(node_id)
            nodes_list.append(node_name)
    if vboxoptions.storages:
        for node_id in range(0, vboxoptions.storages):
            node_name = vboxoptions.labname + "-storage-{}".format(node_id)
            nodes_list.append(node_name)

    LOG.info("#### We will create the following nodes: %s", nodes_list)
    port = 10000
    for node in nodes_list:
        LOG.info("#### Creating node: %s", node)
        vboxmanage.vboxmanage_createvm(node, vboxoptions.labname)
        vboxmanage.vboxmanage_storagectl(
            node,
            storectl="sata",
            hostiocache=vboxoptions.hostiocache)
        disk_sizes = None
        no_disks = 0
        if "controller" in node:
            if vboxoptions.setup_type in [AIO_DX, AIO_SX]:
                node_type = "controller-AIO"
            else:
                node_type = "controller-{}".format(vboxoptions.setup_type)
            if vboxoptions.controller_disk_sizes:
                disk_sizes = get_disk_sizes(vboxoptions.controller_disk_sizes)
            else:
                no_disks = vboxoptions.controller_disks
        elif "worker" in node:
            node_type = "worker"
            if vboxoptions.worker_disk_sizes:
                disk_sizes = get_disk_sizes(vboxoptions.worker_disk_sizes)
            else:
                no_disks = vboxoptions.worker_disks
        elif "storage" in node:
            node_type = "storage"
            if vboxoptions.storage_disk_sizes:
                disk_sizes = get_disk_sizes(vboxoptions.storage_disk_sizes)
            else:
                no_disks = vboxoptions.storage_disks
        for item in node_config:
            if item['node_type'] == node_type:
                vboxmanage.vboxmanage_modifyvm(
                    node,
                    cpus=str(item['cpus']),
                    memory=str(item['memory']))
                if not disk_sizes:
                    disk_sizes = item['disks'][no_disks]
                vboxmanage.vboxmanage_createmedium(node, disk_sizes,
                                                   vbox_home_dir=vboxoptions.vbox_home_dir)
        if platform == 'win32' or platform == 'win64':
            vboxmanage.vboxmanage_modifyvm(
                node, uartbase=serial_config[0]['uartbase'],
                uartport=serial_config[
                    0]['uartport'],
                uartmode=serial_config[
                    0]['uartmode'],
                uartpath=port)
            port += 1
        else:
            vboxmanage.vboxmanage_modifyvm(
                node, uartbase=serial_config[0]['uartbase'],
                uartport=serial_config[
                    0]['uartport'],
                uartmode=serial_config[
                    0]['uartmode'],
                uartpath=serial_config[
                    0]['uartpath'],
                prefix=vboxoptions.userid)

        if "controller" in node:
            node_type = "controller"

        last_adapter = 1
        for item in nic_config:
            if item['node_type'] == node_type:
                for adapter in item.keys():
                    if adapter.isdigit():
                        last_adapter += 1
                        data = item[adapter]
                        if vboxoptions.vboxnet_name is not 'none' and data['nic'] is 'hostonly':
                            if vboxoptions.vboxnet_type == 'nat':
                                data['nic'] = 'natnetwork'
                                data['natnetwork'] = vboxoptions.vboxnet_name
                                data['hostonlyadapter'] = None
                                data['intnet'] = None
                                # data['nicpromisc1'] = None
                            else:
                                data[
                                    'hostonlyadapter'] = vboxoptions.vboxnet_name
                                data['natnetwork'] = None
                        else:
                            data['natnetwork'] = None
                        vboxmanage.vboxmanage_modifyvm(node,
                                                       nic=data['nic'], nictype=data['nictype'],
                                                       nicpromisc=data['nicpromisc'],
                                                       nicnum=int(adapter), intnet=data['intnet'],
                                                       hostonlyadapter=data['hostonlyadapter'],
                                                       natnetwork=data['natnetwork'],
                                                       prefix="{}-{}".format(vboxoptions.userid,
                                                                             vboxoptions.labname))

        if vboxoptions.add_nat_interface:
            last_adapter += 1
            vboxmanage.vboxmanage_modifyvm(node, nicnum=adapter, nictype='nat')

        # Add port forwarding rules for controllers nat interfaces
        if vboxoptions.vboxnet_type == 'nat' and 'controller' in node:
            if 'controller-0' in node:
                local_port = vboxoptions.nat_controller0_local_ssh_port
                ip = vboxoptions.controller0_ip
            elif 'controller-1' in node:
                local_port = vboxoptions.nat_controller1_local_ssh_port
                ip = vboxoptions.controller1_ip
            vboxmanage.vboxmanage_port_forward(node, vboxoptions.vboxnet_name,
                                               local_port=local_port, guest_port='22', guest_ip=ip)

    # Floating ip port forwarding
    if vboxoptions.vboxnet_type == 'nat' and vboxoptions.setup_type != 'AIO-SX':
        local_port = vboxoptions.nat_controller_floating_local_ssh_port
        ip = vboxoptions.controller_floating_ip
        name = vboxoptions.labname + 'controller-float'
        vboxmanage.vboxmanage_port_forward(name, vboxoptions.vboxnet_name,
                                           local_port=local_port, guest_port='22', guest_ip=ip)

    ctrlr0 = vboxoptions.labname + '-controller-0'
    vboxmanage.vboxmanage_storagectl(
        ctrlr0,
        storectl="ide",
        hostiocache=vboxoptions.hostiocache)
    vboxmanage.vboxmanage_storageattach(
        ctrlr0, storectl="ide", storetype="dvddrive",
        disk=vboxoptions.iso_location, device_num="0", port_num="1")


def get_hostnames(ignore=None, personalities=['controller', 'storage', 'worker']):
    """
    Based on the number of nodes defined on the command line, construct
    the hostnames of each node.
    """

    hostnames = {}
    if vboxoptions.controllers and 'controller' in personalities:
        for node_id in range(0, vboxoptions.controllers):
            node_name = vboxoptions.labname + "-controller-{}".format(node_id)
            if ignore and node_name in ignore:
                continue
            hostnames[node_name] = 'controller-{}'.format(id)
    if vboxoptions.workers and 'worker' in personalities:
        for node_id in range(0, vboxoptions.workers):
            node_name = vboxoptions.labname + "-worker-{}".format(node_id)
            if ignore and node_name in ignore:
                continue
            hostnames[node_name] = 'worker-{}'.format(id)
    if vboxoptions.storages and 'storage' in personalities:
        for node_id in range(0, vboxoptions.storages):
            node_name = vboxoptions.labname + "-storage-{}".format(node_id)
            if ignore and node_name in ignore:
                continue
            hostnames[node_name] = 'storage-{}'.format(node_id)

    return hostnames


def get_personalities(ignore=None):
    """
    Map the target to the node type.
    """

    personalities = {}
    if vboxoptions.controllers:
        for node_id in range(0, vboxoptions.controllers):
            node_name = vboxoptions.labname + "-controller-{}".format(node_id)
            if ignore and node_name in ignore:
                continue
            personalities[node_name] = 'controller'
    if vboxoptions.workers:
        for node_id in range(0, vboxoptions.workers):
            node_name = vboxoptions.labname + "-worker-{}".format(node_id)
            if ignore and node_name in ignore:
                continue
            personalities[node_name] = 'worker'
    if vboxoptions.storages:
        for node_id in range(0, vboxoptions.storages):
            node_name = vboxoptions.labname + "-storage-{}".format(node_id)
            if ignore and node_name in ignore:
                continue
            personalities[node_name] = 'storage'

    return personalities


def create_host_bulk_add():
    """
    Sample xml:
    <?xml version="1.0" encoding="UTF-8" ?>
    <hosts>
        <host>
            <personality>controller</personality>
            <mgmt_mac>08:00:27:4B:6A:6A</mgmt_mac>
        </host>
        <host>
            <personality>storage</personality>
            <mgmt_mac>08:00:27:36:14:3D</mgmt_mac>
        </host>
        <host>
            <personality>storage</personality>
            <mgmt_mac>08:00:27:B3:D0:69</mgmt_mac>
        </host>
        <host>
            <hostname>worker-0</hostname>
            <personality>worker</personality>
            <mgmt_mac>08:00:27:47:68:52</mgmt_mac>
        </host>
        <host>
            <hostname>worker-1</hostname>
            <personality>worker</personality>
            <mgmt_mac>08:00:27:31:15:48</mgmt_mac>
        </host>
    </hosts>
    """
    LOG.info("Creating content for 'system host-bulk-add'")
    vms = vboxmanage.get_all_vms(vboxoptions.labname, option="vms")
    ctrl0 = vboxoptions.labname + "-controller-0"
    vms.remove(ctrl0)

    # Get management macs
    macs = {}
    for vm in vms:
        info = vboxmanage.vboxmanage_showinfo(vm).splitlines()
        for line in info:
            try:
                k, v = line.split(b'=')
            except ValueError:
                continue
            if k == b'macaddress2':
                orig_mac = v.decode('utf-8').replace("\"", "")
                # Do for e.g.: 080027C95571 -> 08:00:27:C9:55:71
                macs[vm] = ":".join(re.findall(r"..", orig_mac))

    # Get personalities
    personalities = get_personalities(ignore=[ctrl0])
    hostnames = get_hostnames(ignore=[ctrl0])

    # Create file
    host_xml = ('<?xml version="1.0" encoding="UTF-8" ?>\n'
                '<hosts>\n')
    for vm in vms:
        host_xml += '    <host>\n'
        host_xml += '        <hostname>{}</hostname>\n'.format(hostnames[vm])
        host_xml += '        <personality>{}</personality>\n'.format(
            personalities[vm])
        host_xml += '        <mgmt_mac>{}</mgmt_mac>\n'.format(macs[vm])
        host_xml += '    </host>\n'
    host_xml += '</hosts>\n'

    return host_xml

serial_prompt_configured = False


def wait_for_hosts(ssh_client, hostnames, status,
                   timeout=HostTimeout.HOST_INSTALL, interval=20):
    """
    Wait for a given interval for the host(s) to reach the expected
    status.
    """

    start = time.time()
    while hostnames:
        LOG.info("Hosts not %s: %s", status, hostnames)
        if (time.time() - start) > HostTimeout.HOST_INSTALL:
            LOG.info("VMs not booted in %s, aborting: %s", timeout, hostnames)
            raise Exception("VMs failed to go %s!", status)
        # Get host list
        host_statuses, _, _ = run_ssh_cmd(
            ssh_client, 'source /etc/nova/openrc; system host-list', timeout=30)
        host_statuses = host_statuses[1:-1]
        for host_status in host_statuses:
            for host in hostnames:
                if host in host_status and status in host_status:
                    hostnames.remove(host)
        if hostnames:
            LOG.info("Waiting %s sec before re-checking host status.", interval)
            time.sleep(interval)

CONSOLE_UNKNOWN_MODE = 'disconnected'
CONSOLE_USER_MODE = 'user'
CONSOLE_ROOT_MODE = 'root'
serial_console_mode = CONSOLE_UNKNOWN_MODE


def run_ssh_cmd(ssh_client, cmd, timeout=5,
                log_output=True, mode=CONSOLE_USER_MODE):
    """
    Execute an arbitrary command on a target.
    """

    if mode == CONSOLE_ROOT_MODE:
        LOG.info(">>>>>")
        cmd = "sudo {}".format(cmd)
    LOG.info("#### Running command over ssh: '%s'", cmd)
    stdin, stdout, stderr = ssh_client.exec_command(cmd, timeout, get_pty=True)
    if mode == CONSOLE_ROOT_MODE:
        stdin.write('{}\n'.format(vboxoptions.password))
        stdin.flush()
    stdout_lines = []
    while True:
        if stdout.channel.exit_status_ready():
            break
        stdout_lines.append(stdout.readline().rstrip('\n'))
        if log_output and stdout:
            LOG.info("|%s", stdout_lines[-1])
    stderr_lines = stderr.readlines()
    if log_output and stderr_lines:
        LOG.info("stderr:|\n%s", "".join(stderr_lines))
    return_code = stdout.channel.recv_exit_status()
    LOG.info("Return code: %s", return_code)
    if mode == CONSOLE_ROOT_MODE:
        # Cut sudo's password echo and "Password:" string from output
        stdout_lines = stdout_lines[2:]
    return stdout_lines, stderr_lines, return_code


def set_serial_prompt_mode(stream, mode):
    """
    To make sure that we are at the correct prompt,
    we first logout, then login back again.
    Note that logging out also helps fixing some problems with passwords
    not getting accepted in some cases (prompt just hangs after inserting
    password).
    """

    global serial_console_mode

    if serial_console_mode == mode:
        LOG.info("Serial console prompt already set to '%s' mode.", mode)
        return
    if serial_console_mode != CONSOLE_USER_MODE:
        # Set mode to user first, even if we later go to root
        serial.send_bytes(stream, "exit\n", expect_prompt=False)
        if serial.expect_bytes(stream, "ogin:", fail_ok=True, timeout=4):
            serial.send_bytes(stream, "exit\n", expect_prompt=False)
            if serial.expect_bytes(stream, "ogin:", fail_ok=True, timeout=4):
                LOG.info("Expected login prompt, connect to console" \
                         "stop any running processes and log out.")
                raise Exception("Failure getting login prompt on serial console!")
        serial.send_bytes(
            stream,
            vboxoptions.username,
            prompt="assword:",
            timeout=30)
        if serial.send_bytes(stream, vboxoptions.password, prompt="~$", fail_ok=True, timeout=30):
            raise Exception("Login failure, invalid password?")
        if mode == CONSOLE_USER_MODE:
            serial.send_bytes(stream, "source /etc/nova/openrc\n",
                              timeout=30, prompt='keystone')
        serial_console_mode = CONSOLE_USER_MODE
    if mode == 'root' and serial_console_mode != 'root':
        serial.send_bytes(stream, 'sudo su -', expect_prompt=False)
        host_helper.check_password(stream, password=vboxoptions.password)
        serial.send_bytes(
            stream,
            "cd /home/wrsroot",
            prompt="/home/wrsroot# ",
            timeout=30)
        serial.send_bytes(stream, "source /etc/nova/openrc\n",
                          timeout=30, prompt='keystone')
        serial_console_mode = CONSOLE_ROOT_MODE
    serial.send_bytes(stream, "export TMOUT=0", timeout=10, prompt='keystone')
    # also reset OAM networking?


def serial_prompt_mode(mode):
    def real_decorator(func):
        def func_wrapper(*args, **kwargs):
            try:
                set_serial_prompt_mode(kwargs['stream'], mode)
            except:
                LOG.info("Serial console login as '%s' failed. Retrying once.", mode)
                set_serial_prompt_mode(kwargs['stream'], mode)
            return func(*args, **kwargs)
        return func_wrapper
    return real_decorator


def _connect_to_serial(vm=None):
    if not vm:
        vm = vboxoptions.labname + "-controller-0"
    sock = serial.connect(vm, 10000, getpass.getuser())
    return sock, streamexpect.wrap(sock, echo=True, close_stream=False)


def connect_to_serial(func):
    def func_wrapper(*args, **kwargs):
        try:
            sock, kwargs['stream'] = _connect_to_serial()
            return func(*args, **kwargs)
        finally:
            serial.disconnect(sock)

    return func_wrapper


def _connect_to_ssh():

    # Get ip and port for ssh on floating ip
    ip, port = get_ssh_ip_and_port()

    # Remove ssh key
    # For hostonly adapter we remove port 22 of controller ip
    # for nat interfaces we remove the specific port on 127.0.0.1 as
    # we have port forwarding enabled.
    if vboxoptions.vboxnet_type == 'nat':
        keygen_arg = "[127.0.0.1]:{}".format(port)
    else:
        keygen_arg = ip
    cmd = 'ssh-keygen -f "/home/{}/.ssh/known_hosts" -R {}'.format(
        getpass.getuser(), keygen_arg)
    LOG.info("CMD: %s", cmd)
    process = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE)
    for line in iter(process.stdout.readline, b''):
        LOG.info("%s", line.decode("utf-8").strip())
    process.wait()

    # Connect to ssh
    ssh = paramiko.SSHClient()
    ssh.load_system_host_keys()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())

    ssh.connect(ip, port=port, username=vboxoptions.username,
                password=vboxoptions.password, look_for_keys=False, allow_agent=False)
    return ssh


def connect_to_ssh(func):
    def func_wrapper(*args, **kwargs):
        try:
            ssh = _connect_to_ssh()
            kwargs['ssh_client'] = ssh
            return func(*args, **kwargs)
        finally:
            ssh.close()
    return func_wrapper


def stage_test_success():
    LOG.info("Executing stage_test_success")


def stage_test_fail():
    LOG.info("Executing stage_test_success")
    raise Exception("exception as of stage_test_fail")


def stage_create_lab():
    delete_lab(vboxoptions.labname, vboxoptions.force_delete_lab)
    create_lab(vboxoptions)
    # time.sleep(2)


def stage_install_controller0():
    node_list = vboxmanage.get_all_vms(vboxoptions.labname, option="vms")
    LOG.info("Found nodes: %s", node_list)

    ctrlr0 = vboxoptions.labname + "-controller-0"
    assert ctrlr0 in node_list, "controller-0 not in vm list. Stopping installation."

    vboxmanage.vboxmanage_startvm(ctrlr0)

    sock = serial.connect(ctrlr0, 10000, getpass.getuser())
    cont0_stream = streamexpect.wrap(sock, echo=True, close_stream=False)

    install_controller_0(
        cont0_stream, vboxoptions.setup_type, vboxoptions.securityprofile,
        vboxoptions.lowlatency,
        install_mode=vboxoptions.install_mode, ctrlr0_ip=vboxoptions.controller0_ip,
        gateway_ip=vboxoptions.vboxnet_ip,
        username=vboxoptions.username, password=vboxoptions.password)
    serial.disconnect(sock)
    time.sleep(5)


@connect_to_serial
def stage_config_controller(stream):
    ip, port = get_ssh_ip_and_port(
        'controller-0')  # Floating ip is not yet configured
    if True:
        # Updated config file
        LOG.info("#### Updating config_controller ini file networking" \
                 "settings and uploading it to controller.")
        destination = "/home/" + \
            vboxoptions.username + "/stx_config.ini_centos"
        configini = configparser.ConfigParser()
        configini.optionxform = str
        configini.read(vboxoptions.config_controller_ini)
        old_cidr = configini['OAM_NETWORK']['CIDR']
        new_cidr = vboxoptions.ini_oam_cidr
        LOG.info("Replacing OAM_NETWORK/CIDR from %s to %s", old_cidr, new_cidr)
        configini['OAM_NETWORK']['CIDR'] = new_cidr
        old_gateway = configini['OAM_NETWORK']['GATEWAY']
        new_gateway = vboxoptions.vboxnet_ip
        LOG.info("Replacing OAM_NETWORK/GATEWAY from %s to %s", old_gateway, new_gateway)
        configini['OAM_NETWORK']['GATEWAY'] = new_gateway
        if vboxoptions.setup_type == AIO_SX:
            old_ip_address = configini['OAM_NETWORK']['IP_ADDRESS']
            new_ip_address = vboxoptions.controller0_ip
            LOG.info("Replacing OAM_NETWORK/IP_ADDRESS from %s to %s",
                     old_ip_address, new_ip_address)
            configini['OAM_NETWORK']['IP_ADDRESS'] = new_ip_address
        else:
            old_start_addr = configini['OAM_NETWORK']['IP_START_ADDRESS']
            new_start_addr = vboxoptions.ini_oam_ip_start_address
            LOG.info("Replacing OAM_NETWORK/IP_START_ADDRESS from %s to %s",
                     old_start_addr, new_start_addr)
            configini['OAM_NETWORK']['IP_START_ADDRESS'] = new_start_addr
            old_end_addr = configini['OAM_NETWORK']['IP_END_ADDRESS']
            new_end_addr = vboxoptions.ini_oam_ip_end_address
            LOG.info("Replacing OAM_NETWORK/IP_END_ADDRESS from %s to %s",
                     old_end_addr, new_end_addr)
            configini['OAM_NETWORK']['IP_END_ADDRESS'] = new_end_addr

        # Take updated config file and copy it to controller
        with tempfile.NamedTemporaryFile(mode='w') as fp:
            configini.write(fp, space_around_delimiters=False)
            fp.flush()

            sftp_send(
                fp.name, remote_host=ip, remote_port=port, destination=destination,
                username=vboxoptions.username, password=vboxoptions.password)
    else:
        destination = "/home/" + \
            vboxoptions.username + "/stx_config.ini_centos"
        sftp_send(
            vboxoptions.config_controller_ini, remote_host=ip, remote_port=port,
            destination=destination,
            username=vboxoptions.username, password=vboxoptions.password)

    # Run config_controller
    LOG.info("#### Running config_controller")
    install_lab.config_controller(stream, config_file=destination,
                                  password=vboxoptions.password)

    # Wait for services to stabilize
    time.sleep(120)

    if vboxoptions.setup_type == AIO_SX:
        # Increase AIO responsiveness by allocating more cores to platform
        install_lab.update_platform_cpus(stream, 'controller-0')


def get_ssh_ip_and_port(node='floating'):
    if vboxoptions.vboxnet_type == 'nat':
        ip = '127.0.0.1'
        if node == 'floating':
            if vboxoptions.setup_type != 'AIO-SX':
                port = vboxoptions.nat_controller_floating_local_ssh_port
            else:
                port = vboxoptions.nat_controller0_local_ssh_port
        elif node == 'controller-0':
            port = vboxoptions.nat_controller0_local_ssh_port
        elif node == 'controller-1':
            port = vboxoptions.nat_controller_1_local_ssh_port
        else:
            raise Exception("Undefined node '{}'".format(node))
    else:
        if node == 'floating':
            if vboxoptions.setup_type != 'AIO-SX':
                ip = vboxoptions.controller_floating_ip
            else:
                ip = vboxoptions.controller0_ip
        elif node == 'controller-0':
            ip = vboxoptions.controller0_ip
        elif node == 'controller-1':
            ip = vboxoptions.controller1_ip
        else:
            raise Exception("Undefined node '{}'".format(node))
        port = 22
    return ip, port

#@connect_to_serial
#@serial_prompt_mode(CONSOLE_USER_MODE)


def stage_rsync_config():
    # Get ip and port for ssh on floating ip
    ip, port = get_ssh_ip_and_port()
    # Copy config files to controller
    if vboxoptions.config_files_dir:
        local_path = vboxoptions.config_files_dir
        send_dir(source=local_path, remote_host=ip, remote_port=port,
                 destination='/home/' + vboxoptions.username + '/',
                 username=vboxoptions.username, password=vboxoptions.password)
    if vboxoptions.config_files_dir_dont_follow_links:
        local_path = vboxoptions.config_files_dir_dont_follow_links
        send_dir(source=local_path, remote_host=ip, remote_port=port,
                 destination='/home/' + vboxoptions.username + '/',
                 username=vboxoptions.username, password=vboxoptions.password)
    if not vboxoptions.config_files_dir and not vboxoptions.config_files_dir_dont_follow_links:
        LOG.info("No rsync done! Please set config-files-dir" \
                 "and/or config-files-dir-dont-follow-links")


@connect_to_serial
@serial_prompt_mode(CONSOLE_USER_MODE)
def _run_lab_setup_serial(stream):
    conf_str = ""
    for cfg_file in vboxoptions.lab_setup_conf:
        conf_str = conf_str + " -f {}".format(cfg_file)

    serial.send_bytes(stream, "sh lab_setup.sh {}".format(conf_str),
                      timeout=HostTimeout.LAB_INSTALL, prompt='keystone')
    LOG.info("Lab setup execution completed. Checking if return code is 0.")
    serial.send_bytes(stream, "echo \"Return code: [$?]\"",
                      timeout=3, prompt='Return code: [0]')


@connect_to_ssh
def _run_lab_setup(ssh_client):
    conf_str = ""
    for cfg_file in vboxoptions.lab_setup_conf:
        conf_str = conf_str + " -f {}".format(cfg_file)

    _, _, exitcode = run_ssh_cmd(ssh_client,
                                 'source /etc/platform/openrc; '
                                 'export PATH="$PATH:/usr/local/bin; '
                                 'export PATH="$PATH:/usr/bin; '
                                 'export PATH="$PATH:/usr/local/sbin; '
                                 'export PATH="$PATH:/usr/sbin"; '
                                 'sh lab_setup.sh {}'.format(conf_str),
                                 timeout=HostTimeout.LAB_INSTALL)
    if exitcode != 0:
        msg = "Lab setup failed, expecting exit code of 0 but got {}.".format(
            exitcode)
        LOG.info(msg)
        raise Exception(msg)


def stage_lab_setup1():
    _run_lab_setup()


def stage_lab_setup2():
    _run_lab_setup()


def stage_lab_setup3():
    _run_lab_setup()


def stage_lab_setup4():
    _run_lab_setup()


def stage_lab_setup5():
    _run_lab_setup()


@connect_to_ssh
@connect_to_serial
def stage_unlock_controller0(stream, ssh_client):
    LOG.info("#### Unlocking controller-0")
    _, _, _ = run_ssh_cmd(ssh_client,
                          'source /etc/nova/openrc; system host-unlock controller-0',
                          timeout=HostTimeout.CONTROLLER_UNLOCK)

    LOG.info("#### Waiting for controller-0 to reboot")
    serial.expect_bytes(
        stream,
        'login:',
        timeout=HostTimeout.CONTROLLER_UNLOCK)

    LOG.info("Waiting 120s for services to activate.")
    time.sleep(120)

    # Make sure we login again, after reboot we are not logged in.
    serial_console_mode = CONSOLE_UNKNOWN_MODE


@connect_to_serial
@serial_prompt_mode(CONSOLE_USER_MODE)
def stage_unlock_controller0_serial(stream):
    global serial_console_mode
    if host_helper.unlock_host(stream, 'controller-0'):
        LOG.info("Host is unlocked, nothing to do. Exiting stage.")
        return

    serial.expect_bytes(
        stream,
        'login:',
        timeout=HostTimeout.CONTROLLER_UNLOCK)

    LOG.info("Waiting 120s for services to activate.")
    time.sleep(120)

    # Make sure we login again
    serial_console_mode = CONSOLE_UNKNOWN_MODE  # After reboot we are not logged in.


@connect_to_ssh
def stage_install_nodes(ssh_client):
    # Create and transfer host_bulk_add.xml to ctrl-0
    host_xml = create_host_bulk_add()

    LOG.info("host_bulk_add.xml content:\n%s", host_xml)

    # Send file to controller
    destination = "/home/" + vboxoptions.username + "/host_bulk_add.xml"
    with tempfile.NamedTemporaryFile() as fp:
        fp.write(host_xml.encode('utf-8'))
        fp.flush()
        # Connection to NAT interfaces is local
        if vboxoptions.vboxnet_type == 'nat':
            ip = '127.0.0.1'
            port = vboxoptions.nat_controller0_local_ssh_port
        else:
            ip = vboxoptions.controller0_ip
            port = 22
        sftp_send(source=fp.name, remote_host=ip, remote_port=port,
                  destination=destination,
                  username=vboxoptions.username, password=vboxoptions.password)
    # Apply host-bulk-add
    _, _, exitcode = run_ssh_cmd(ssh_client,
                                 'source /etc/nova/openrc; ',
                                 'system host-bulk-add {}'.format(destination),
                                 timeout=60)
    if exitcode != 0:
        msg = "Host bulk add failed, expecting exit code of 0 but got %s", exitcode
        LOG.info(msg)
        raise Exception(msg)

    # Start hosts one by one, wait 10s between each start
    vms = vboxmanage.get_all_vms(vboxoptions.labname, option="vms")
    runningvms = vboxmanage.get_all_vms(
        vboxoptions.labname,
        option="runningvms")
    powered_off = list(set(vms) - set(runningvms))
    LOG.info("#### Powered off VMs: %s", powered_off)
    for vm in powered_off:
        LOG.info("#### Powering on VM: %s", vm)
        vboxmanage.vboxmanage_startvm(vm, force=True)
        LOG.info("Give VM 20s to boot.")
        time.sleep(20)

    ctrl0 = vboxoptions.labname + "-controller-0"
    hostnames = list(get_hostnames(ignore=[ctrl0]).values())

    wait_for_hosts(ssh_client, hostnames, 'online')


@connect_to_ssh
def stage_unlock_controller1(ssh_client):
    # Fast for standard, wait for storage
    hostnames = list(get_hostnames().values())
    if 'controller-1' not in hostnames:
        LOG.info("Controller-1 not configured, skipping unlock.")
        return

    LOG.info("#### Unlocking controller-1")
    run_ssh_cmd(ssh_client,
                'source /etc/nova/openrc; system host-unlock controller-1',
                timeout=60)

    LOG.info("#### waiting for controller-1 to be available.")
    wait_for_hosts(ssh_client, ['controller-1'], 'available')


@connect_to_ssh
def stage_unlock_storages(ssh_client):
    # Unlock storage nodes, wait for them to be 'available'
    storages = list(get_hostnames(personalities=['storage']).values())

    for storage in storages:
        run_ssh_cmd(ssh_client,
                    'source /etc/nova/openrc; system host-unlock {}'.format(storage),
                    timeout=60)
        LOG.info("Waiting 15s before next unlock")
        time.sleep(15)

    LOG.info("#### Waiting for all hosts to be available.")
    wait_for_hosts(ssh_client, storages, 'available')


@connect_to_ssh
def stage_unlock_workers(ssh_client):
    # Unlock all, wait for all hosts, except ctrl0 to be 'available'
    workers = list(get_hostnames(personalities=['worker']).values())
    ctrl0 = vboxoptions.labname + '-controller-0'

    for worker in workers:
        run_ssh_cmd(
            ssh_client,
            'source /etc/nova/openrc; system host-unlock {}'.format(worker),
            timeout=60)
        LOG.info("Waiting 15s before next unlock")
        time.sleep(15)

    # Wait for all hosts, except ctrl0 to be available
    # At this stage we expect ctrl1 to also be available
    hosts = list(get_hostnames(ignore=[ctrl0]).values())
    wait_for_hosts(ssh_client, hosts, 'available')


def run_custom_script(script, timeout, console, mode):
    LOG.info("#### Running custom script %s with options:", script)
    LOG.info("     timeout:        %s", timeout)
    LOG.info("     console mode:   %s", console)
    LOG.info("     user mode: %s", mode)
    if console == 'ssh':
        ssh_client = _connect_to_ssh()
        _, __, return_code = run_ssh_cmd(ssh_client, "./{}".format(script),
                                         timeout=timeout, mode=mode)
        if return_code != 0:
            LOG.info("Custom script '%s' return code is not 0. Aborting.", script)
            raise Exception("Script execution failed with return code: {}".format(return_code))
    else:
        sock, stream = _connect_to_serial()
        try:
            if mode == 'root':
                set_serial_prompt_mode(stream, CONSOLE_ROOT_MODE)
                # Login as root
                serial.send_bytes(stream, 'sudo su -', expect_prompt=False)
                host_helper.check_password(
                    stream,
                    password=vboxoptions.password)
            else:
                set_serial_prompt_mode(stream, CONSOLE_USER_MODE)
            serial.send_bytes(stream, "./{}".format(script),
                              timeout=timeout, prompt='keystone')
            LOG.info("Script execution completed. Checking if return code is 0.")
            serial.send_bytes(stream,
                              "echo \"Return code: [$?]\"".format(script),
                              timeout=3, prompt='Return code: [0]')
        finally:
            sock.close()


def get_custom_script_options(options_list):
    LOG.info("Parsing custom script options: %s", options_list)
    # defaults
    script = ""
    timeout = 5
    console = 'serial'
    mode = 'user'
    # supported options
    CONSOLES = ['serial', 'ssh']
    MODES = ['user', 'root']

    # No spaces or special chars allowed
    not_allowed = ['\n', ' ', '*']
    for c in not_allowed:
        if c in options_list:
            LOG.info("Char '%s' not allowed in options list: %s.", c, options_list)
            raise Exception("Char not allowed in options_list")

    # get options
    options = options_list.split(',')
    if len(options) >= 1:
        script = options[0]
    if len(options) >= 2:
        timeout = int(options[1])
    if len(options) >= 3:
        console = options[2]
        if console not in CONSOLES:
            raise "Console must be one of {}, not {}.".format(
                CONSOLES, console)
    if len(options) >= 4:
        mode = options[3]
        if mode not in MODES:
            raise "Mode must be one of {}, not {}.".format(MODES, mode)
    return script, timeout, console, mode


def stage_custom_script1():
    if vboxoptions.script1:
        script, timeout, console, mode = get_custom_script_options(
            vboxoptions.script1)
    else:
        script = "custom_script1.sh"
        timeout = 3600
        console = 'serial'
        mode = 'user'
    run_custom_script(script, timeout, console, mode)


def stage_custom_script2():
    if vboxoptions.script2:
        script, timeout, console, mode = get_custom_script_options(
            vboxoptions.script2)
    else:
        script = "custom_script2.sh"
        timeout = 3600
        console = 'serial'
        mode = 'user'
    run_custom_script(script, timeout, console, mode)


def stage_custom_script3():
    if vboxoptions.script3:
        script, timeout, console, mode = get_custom_script_options(
            vboxoptions.script3)
    else:
        script = "custom_script3.sh"
        timeout = 3600
        console = 'serial'
        mode = 'user'
    run_custom_script(script, timeout, console, mode)


def stage_custom_script4():
    if vboxoptions.script4:
        script, timeout, console, mode = get_custom_script_options(
            vboxoptions.script4)
    else:
        script = "custom_script4.sh"
        timeout = 3600
        console = 'serial'
        mode = 'user'
    run_custom_script(script, timeout, console, mode)


def stage_custom_script5():
    if vboxoptions.script5:
        script, timeout, console, mode = get_custom_script_options(
            vboxoptions.script5)
    else:
        script = "custom_script5.sh"
        timeout = 3600
        console = 'serial'
        mode = 'user'
    run_custom_script(script, timeout, console, mode)

STG_CREATE_LAB = "create-lab"
STG_INSTALL_CONTROLLER0 = "install-controller-0"
STG_CONFIG_CONTROLLER = "config-controller"
STG_RSYNC_CONFIG = "rsync-config"
STG_LAB_SETUP1 = "lab-setup1"
STG_UNLOCK_CONTROLLER0 = "unlock-controller-0"
STG_LAB_SETUP2 = "lab-setup2"
STG_INSTALL_NODES = "install-nodes"
STG_UNLOCK_CONTROLLER1 = "unlock-controller-1"
STG_LAB_SETUP3 = "lab-setup3"
STG_UNLOCK_STORAGES = "unlock-storages"
STG_LAB_SETUP4 = "lab-setup4"
STG_UNLOCK_WORKERS = "unlock-workers"
STG_LAB_SETUP5 = "lab-setup5"
STG_CUSTOM_SCRIPT1 = "custom-script1"
STG_CUSTOM_SCRIPT2 = "custom-script2"
STG_CUSTOM_SCRIPT3 = "custom-script3"
STG_CUSTOM_SCRIPT4 = "custom-script4"
STG_CUSTOM_SCRIPT5 = "custom-script5"

# For internal testing only, one stage is always successful
# the other one always raises an exception.
STC_TEST_SUCCESS = "test-success"
STG_TEST_FAIL = "test-fail"

CALLBACK = 'callback'
HELP = 'help'

STAGE_CALLBACKS = {
    STG_CREATE_LAB:
        {CALLBACK: stage_create_lab,
         HELP: "Create VMs in vbox: controller-0, controller-1..."},
    STG_INSTALL_CONTROLLER0:
        {CALLBACK: stage_install_controller0,
         HELP: "Install controller-0 from --iso-location"},
    STG_CONFIG_CONTROLLER:
        {CALLBACK: stage_config_controller,
         HELP: "Run config controller using the --config-controller-ini" \
               "updated based on --ini-* options."},
    STG_RSYNC_CONFIG:
        {CALLBACK: stage_rsync_config,
         HELP: "Rsync all files from --config-files-dir and --config-files-dir* to /home/wrsroot."},
    STG_LAB_SETUP1:
        {CALLBACK: stage_lab_setup1,
         HELP: "Run lab_setup with one or more --lab-setup-conf files from controller-0."},
    STG_UNLOCK_CONTROLLER0:
        {CALLBACK: stage_unlock_controller0,
         HELP: "Unlock controller-0 and wait for it to reboot."},
    STG_LAB_SETUP2:
        {CALLBACK: stage_lab_setup2,
         HELP: "Run lab_setup with one or more --lab-setup-conf files from controller-0."},
    STG_INSTALL_NODES:
        {CALLBACK: stage_install_nodes,
         HELP: "Generate a host-bulk-add.xml, apply it and install all" \
               "other nodes, wait for them to be 'online."},
    STG_UNLOCK_CONTROLLER1:
        {CALLBACK: stage_unlock_controller1,
         HELP: "Unlock controller-1, wait for it to be 'available'"},
    STG_LAB_SETUP3:
        {CALLBACK: stage_lab_setup3,
         HELP: "Run lab_setup with one or more --lab-setup-conf files from controller-0."},
    STG_UNLOCK_STORAGES:
        {CALLBACK: stage_unlock_storages,
         HELP: "Unlock all storage nodes, wait for them to be 'available'"},
    STG_LAB_SETUP4:
        {CALLBACK: stage_lab_setup4,
         HELP: "Run lab_setup with one or more --lab-setup-conf files from controller-0."},
    STG_UNLOCK_WORKERS:
        {CALLBACK: stage_unlock_workers,
         HELP: "Unlock all workers, wait for them to be 'available"},
    STG_LAB_SETUP5:
        {CALLBACK: stage_lab_setup5,
         HELP: "Run lab_setup with one or more --lab-setup-conf files from controller-0."},
    STG_CUSTOM_SCRIPT1:
        {CALLBACK: stage_custom_script1,
         HELP: "Run a custom script from /home/wrsroot, make sure you" \
               "upload it in the rsync-config stage and it is +x. See help."},
    STG_CUSTOM_SCRIPT2:
        {CALLBACK: stage_custom_script2,
         HELP: "Run a custom script from /home/wrsroot, make sure you" \
               "upload it in the rsync-config stage and it is +x. See help."},
    STG_CUSTOM_SCRIPT3:
        {CALLBACK: stage_custom_script3,
         HELP: "Run a custom script from /home/wrsroot, make sure you" \
               "upload it in the rsync-config stage and it is +x. See help."},
    STG_CUSTOM_SCRIPT4:
        {CALLBACK: stage_custom_script4,
         HELP: "Run a custom script from /home/wrsroot, make sure you" \
               "upload it in the rsync-config stage and it is +x. See help."},
    STG_CUSTOM_SCRIPT5:
        {CALLBACK: stage_custom_script5,
         HELP: "Run a custom script from /home/wrsroot, make sure you" \
               "upload it in the rsync-config stage and it is +x. See help."},
    # internal testing
    STC_TEST_SUCCESS: {CALLBACK: stage_test_success,
                       HELP: "Internal only, does not do anything, used for testing."},
    STG_TEST_FAIL: {CALLBACK: stage_test_fail,
                    HELP: "Internal only, raises exception, used for testing."},
}

AVAILABLE_STAGES = [STG_CREATE_LAB,
                    STG_INSTALL_CONTROLLER0,
                    STG_CONFIG_CONTROLLER,
                    STG_RSYNC_CONFIG,
                    STG_LAB_SETUP1,
                    STG_UNLOCK_CONTROLLER0,
                    STG_LAB_SETUP2,
                    STG_INSTALL_NODES,
                    STG_UNLOCK_CONTROLLER1,
                    STG_LAB_SETUP3,
                    STG_UNLOCK_STORAGES,
                    STG_LAB_SETUP4,
                    STG_UNLOCK_WORKERS,
                    STG_LAB_SETUP5,
                    STG_CUSTOM_SCRIPT1,
                    STG_CUSTOM_SCRIPT2,
                    STG_CUSTOM_SCRIPT3,
                    STG_CUSTOM_SCRIPT4,
                    STG_CUSTOM_SCRIPT5,
                    STC_TEST_SUCCESS,
                    STG_TEST_FAIL]

AIO_SX_STAGES = [
    STG_CREATE_LAB,
    STG_INSTALL_CONTROLLER0,
    STG_CONFIG_CONTROLLER,
    STG_RSYNC_CONFIG,
    STG_LAB_SETUP1,
    STG_UNLOCK_CONTROLLER0,
    STG_LAB_SETUP2,
]

AIO_DX_STAGES = [
    STG_CREATE_LAB,
    STG_INSTALL_CONTROLLER0,
    STG_CONFIG_CONTROLLER,
    STG_RSYNC_CONFIG,
    STG_LAB_SETUP1,
    STG_UNLOCK_CONTROLLER0,
    STG_INSTALL_NODES,
    STG_LAB_SETUP2,
    STG_UNLOCK_CONTROLLER1,
    STG_LAB_SETUP3,
]

STD_STAGES = [
    STG_CREATE_LAB,
    STG_INSTALL_CONTROLLER0,
    STG_CONFIG_CONTROLLER,
    STG_RSYNC_CONFIG,
    STG_LAB_SETUP1,
    STG_UNLOCK_CONTROLLER0,
    STG_INSTALL_NODES,
    STG_LAB_SETUP2,
    STG_UNLOCK_CONTROLLER1,
    STG_LAB_SETUP3,
    STG_UNLOCK_WORKERS
]

STORAGE_STAGES = [
    STG_CREATE_LAB,
    STG_INSTALL_CONTROLLER0,
    STG_CONFIG_CONTROLLER,
    STG_RSYNC_CONFIG,
    STG_LAB_SETUP1,
    STG_UNLOCK_CONTROLLER0,
    STG_INSTALL_NODES,
    STG_LAB_SETUP2,
    STG_UNLOCK_CONTROLLER1,
    STG_LAB_SETUP3,
    STG_UNLOCK_STORAGES,
    STG_LAB_SETUP4,
    STG_UNLOCK_WORKERS,
    STG_LAB_SETUP5
]

AIO_SX = 'AIO-SX'
AIO_DX = 'AIO-DX'
STANDARD = 'STANDARD'
STORAGE = 'STORAGE'

STAGES_CHAINS = {AIO_SX: AIO_SX_STAGES,
                 AIO_DX: AIO_DX_STAGES,
                 STANDARD: STD_STAGES,
                 STORAGE: STORAGE_STAGES}
AVAILABLE_CHAINS = [AIO_SX, AIO_DX, STANDARD, STORAGE]


def load_config():
    global vboxoptions
    vboxoptions = handle_args().parse_args()

    lab_config = [getattr(env.Lab, attr)
                  for attr in dir(env.Lab) if not attr.startswith('__')]
    oam_config = [getattr(OAM, attr)
                  for attr in dir(OAM) if not attr.startswith('__')]

    if vboxoptions.controller0_ip is None:
        vboxoptions.controller0_ip = lab_config[0]['controller-0_ip']

    if vboxoptions.vboxnet_ip is None:
        vboxoptions.vboxnet_ip = oam_config[0]['ip']

    if vboxoptions.username is None:
        vboxoptions.username = lab_config[0]['username']

    if vboxoptions.password is None:
        vboxoptions.password = lab_config[0]['password']
    if vboxoptions.hostiocache:
        vboxoptions.hostiocache = 'on'
    else:
        vboxoptions.hostiocache = 'off'
    if vboxoptions.lab_setup_conf is None:
        vboxoptions.lab_setup_conf = {"~/lab_setup.conf"}
    else:
        vboxoptions.lab_setup_conf = vboxoptions.lab_setup_conf

    if vboxoptions.setup_type == AIO_SX:
        vboxoptions.controllers = 1
        vboxoptions.workers = 0
        vboxoptions.storages = 0
    elif vboxoptions.setup_type == AIO_DX:
        vboxoptions.controllers = 2
        vboxoptions.workers = 0
        vboxoptions.storages = 0
    elif vboxoptions.setup_type == STANDARD:
        vboxoptions.storages = 0


def pre_validate(vboxoptions):
    err = False
    if not vboxoptions.setup_type:
        print("Please set --setup-type")
        err = True
    if not vboxoptions.labname:
        print("Please set --labname")
        err = True
    if not vboxoptions.config_controller_ini:
        print("Please set --iso-location")
        err = True
    if err:
        print("\nMissing arguments. Please check --help and --list-stages for usage.")
        exit(5)


def validate(vboxoptions, stages):
    err = False
    # Generic
    if vboxoptions.vboxnet_type == 'nat':
        if vboxoptions.setup_type != AIO_SX:
            if not vboxoptions.nat_controller_floating_local_ssh_port:
                print("Please set --nat-controller-floating-local-ssh-port")
                err = True
        if not vboxoptions.nat_controller0_local_ssh_port:
            print("Please set --nat-controller0-local-ssh-port")
            err = True
        if vboxoptions.controllers > 1 and not vboxoptions.nat_controller1_local_ssh_port:
            print("Second controller is configured, please set --nat-controller1-local-ssh-port")
            err = True
    else:
        if vboxoptions.setup_type != AIO_SX:
            if not vboxoptions.controller_floating_ip:
                print("Please set --controller-floating-ip")
                err = True
        if not vboxoptions.controller0_ip:
            print("Please set --controller0-ip")
            err = True
        if vboxoptions.controllers > 1 and not vboxoptions.controller1_ip:
            print("Second controller is configured, please set --controller1-ip")
            err = True
    if STG_CONFIG_CONTROLLER in stages:
        if not vboxoptions.config_controller_ini:
            print("Please set --config-controller-ini "
                  "as needed by stage {}".format(STG_CONFIG_CONTROLLER))
            err = True
    if STG_RSYNC_CONFIG in stages:
        if not vboxoptions.config_files_dir and not vboxoptions.config_files_dir_dont_follow_links:
            print("Please set --config-files-dir and/or --config-files-dir-dont-follow-links "
                  "as needed by stage {} and {}".format(STG_RSYNC_CONFIG,
                                                        STG_LAB_SETUP1))
            err = True
    if (STG_LAB_SETUP1 in stages or STG_LAB_SETUP2 in stages
            or STG_LAB_SETUP3 in stages or STG_LAB_SETUP4 in stages
            or STG_LAB_SETUP5 in stages):
        if not vboxoptions.lab_setup_conf:
            print("Please set at least one --lab-setup-conf file as needed by lab-setup stages")
            err = True
        FILE = ["lab_setup.sh"]
        dirs = []
        if vboxoptions.config_files_dir:
            dirs.append(vboxoptions.config_files_dir)
        if vboxoptions.config_files_dir_dont_follow_links:
            dirs.append(vboxoptions.config_files_dir_dont_follow_links)
        for directory in dirs:
            pass
    if err:
        print("\nMissing arguments. Please check --help and --list-stages for usage.")
        exit(5)


def wrap_stage_help(stage, stage_callbacks, number=None):
    if number:
        text = "    {}. {}".format(number, stage)
    else:
        text = "    {}".format(stage)
    LEN = 30
    fill = LEN - len(text)
    text += " " * fill
    text += "# {}".format(stage_callbacks)
    return text

# Define signal handler for ctrl+c


def signal_handler(sig, frame):
    print('You pressed Ctrl+C!')
    kpi.print_kpi_metrics()
    sys.exit(1)

if __name__ == "__main__":
    kpi.init_kpi_metrics()
    signal.signal(signal.SIGINT, signal_handler)

    load_config()

    if vboxoptions.list_stages:
        print("Defined setups: {}".format(list(STAGES_CHAINS.keys())))
        if vboxoptions.setup_type and vboxoptions.setup_type in AVAILABLE_CHAINS:
            AVAILABLE_CHAINS = [vboxoptions.setup_type]
        for setup in AVAILABLE_CHAINS:
            i = 1
            print("Stages for setup: {}".format(setup))
            for stage in STAGES_CHAINS[setup]:
                print(wrap_stage_help(stage, STAGE_CALLBACKS[stage][HELP], i))
                i += 1
        print("Available stages that can be used for --custom-stages:")
        for stage in AVAILABLE_STAGES:
            print(wrap_stage_help(stage, STAGE_CALLBACKS[stage][HELP]))
        exit(0)

    pre_validate(vboxoptions)

    init_logging(vboxoptions.labname, vboxoptions.logpath)
    LOG.info("Logging to directory: %s", (get_log_dir() + "/"))

    LOG.info("Install manages: %s controllers, %s workers, %s storages.",
             vboxoptions.controllers, vboxoptions.workers, vboxoptions.storages)

    # Setup stages to run based on config
    install_stages = []
    if vboxoptions.custom_stages:
        # Custom stages
        install_stages = vboxoptions.custom_stages.split(',')
        for stage in install_stages:
            invalid_stages = []
            if stage not in AVAILABLE_STAGES:
                invalid_stages.append(stage)
            if invalid_stages:
                LOG.info("Following custom stages are not supported: %s.\n" \
                         "Choose from: %s", invalid_stages, AVAILABLE_STAGES)
                exit(1)
    else:
        # List all stages between 'from-stage' to 'to-stage'
        stages = STAGES_CHAINS[vboxoptions.setup_type]
        from_index = 0
        to_index = None
        if vboxoptions.from_stage:
            if vboxoptions.from_stage == 'start':
                from_index = 0
            else:
                from_index = stages.index(vboxoptions.from_stage)
        if vboxoptions.to_stage:
            if vboxoptions.from_stage == 'end':
                to_index = -1
            else:
                to_index = stages.index(vboxoptions.to_stage) + 1
        if to_index is not None:
            install_stages = stages[from_index:to_index]
        else:
            install_stages = stages[from_index:]
    LOG.info("Executing %s stage(s): %s.", len(install_stages), install_stages)

    validate(vboxoptions, install_stages)

    stg_no = 0
    prev_stage = None
    for stage in install_stages:
        stg_no += 1
        start = time.time()
        try:
            LOG.info("######## (%s/%s) Entering stage %s ########",
                     stg_no,
                     len(install_stages),
                     stage)
            STAGE_CALLBACKS[stage][CALLBACK]()

            # Take snapshot if configured
            if vboxoptions.snapshot:
                vboxmanage.take_snapshot(
                    vboxoptions.labname,
                    "snapshot-AFTER-{}".format(stage))

            # Compute KPIs
            duration = time.time() - start
            kpi.set_kpi_metric(stage, duration)
            kpi.print_kpi(stage)
            kpi.print_kpi('total')
        except Exception as e:
            duration = time.time() - start
            kpi.set_kpi_metric(stage, duration)
            LOG.info("INSTALL FAILED, ABORTING!")
            kpi.print_kpi_metrics()
            LOG.info("Exception details: %s", e)
            raise
        # Stage completed
        prev_stage = stage

    LOG.info("INSTALL SUCCEEDED!")
    kpi.print_kpi_metrics()

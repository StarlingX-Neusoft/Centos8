#!/usr/bin/python3
#
# SPDX-License-Identifier: Apache-2.0
#


import os
import subprocess
import re
import getpass
import time

from sys import platform
from consts import env

from utils.install_log import LOG


def vboxmanage_version():
    """
    Return version of vbox.
    """

    version = subprocess.check_output(['vboxmanage', '--version'], stderr=subprocess.STDOUT)

    return version


def vboxmanage_extpack(action="install"):
    """
    This allows you to install, uninstall the vbox extensions"
    """
    output = vboxmanage_version()
    version = re.match(b'(.*)r', output)
    version_path = version.group(1).decode('utf-8')

    LOG.info("Downloading extension pack")
    filename = 'Oracle_VM_VirtualBox_Extension_Pack-{}.vbox-extpack'.format(version_path)
    cmd = 'http://download.virtualbox.org/virtualbox/{}/{}'.format(version_path, filename)
    result = subprocess.check_output(['wget', cmd, '-P', '/tmp'], stderr=subprocess.STDOUT)
    LOG.info(result)

    LOG.info("Installing extension pack")
    result = subprocess.check_output(['vboxmanage', 'extpack', 'install', '/tmp/' + filename,
                                      '--replace'], stderr=subprocess.STDOUT)
    LOG.info(result)


def get_all_vms(labname, option="vms"):
    initial_node_list = []
    vm_list = vboxmanage_list(option)

    labname.encode('utf-8')
    # Reduce the number of VMs we query
    for item in vm_list:
        if labname.encode('utf-8') in item and (b'controller-' in item or \
           b'compute-' in item or b'storage-' in item):
            initial_node_list.append(item.decode('utf-8'))

    # Filter by group
    node_list = []
    group = bytearray('"/{}"'.format(labname), 'utf-8')
    for item in initial_node_list:
        info = vboxmanage_showinfo(item).splitlines()
        for line in info:
            try:
                k, v = line.split(b'=')
            except ValueError:
                continue
            if k == b'groups' and v == group:
                node_list.append(item)

    return node_list


def take_snapshot(labname, snapshot_name, socks=None):
    vms = get_all_vms(labname, option="vms")
    runningvms = get_all_vms(labname, option="runningvms")

    LOG.info("#### Taking snapshot %s of lab %s", snapshot_name, labname)
    LOG.info("VMs in lab %s: %s", labname, vms)
    LOG.info("VMs running in lab %s: %s", labname, runningvms)

    hosts = len(vms)

    # Pause running VMs to take snapshot
    if len(runningvms) > 1:
        for node in runningvms:
            newpid = os.fork()
            if newpid == 0:
                vboxmanage_controlvms([node], "pause")
                os._exit(0)
        for node in vms:
            os.waitpid(0, 0)
        time.sleep(2)

    if hosts != 0:
        vboxmanage_takesnapshot(vms, snapshot_name)

    # Resume VMs after snapshot was taken
    if len(runningvms) > 1:
        for node in runningvms:
            newpid = os.fork()
            if newpid == 0:
                vboxmanage_controlvms([node], "resume")
                os._exit(0)
        for node in runningvms:
            os.waitpid(0, 0)

    time.sleep(10)  # Wait for VM serial port to stabilize, otherwise it may refuse to connect

    if runningvms:
        new_vms = get_all_vms(labname, option="runningvms")
        retry = 0
        while retry < 20:
            LOG.info("Waiting for VMs to come up running after taking snapshot..."
                     "Up VMs are %s ", new_vms)
            if len(runningvms) < len(new_vms):
                time.sleep(1)
                new_vms = get_all_vms(labname, option="runningvms")
                retry += 1
            else:
                LOG.info("All VMs %s are up running after taking snapshot...", vms)
                break


def restore_snapshot(node_list, name):
    LOG.info("Restore snapshot of %s for hosts %s", name, node_list)
    if len(node_list) != 0:
        vboxmanage_controlvms(node_list, "poweroff")
        time.sleep(5)
    if len(node_list) != 0:
        for host in node_list:
            vboxmanage_restoresnapshot(host, name)
            time.sleep(5)
        for host in node_list:
            if "controller-0" not in host:
                vboxmanage_startvm(host)
                time.sleep(10)
        for host in node_list:
            if "controller-0" in host:
                vboxmanage_startvm(host)
                time.sleep(10)


def vboxmanage_list(option="vms"):
    """
    This returns a list of vm names.
    """
    result = subprocess.check_output(['vboxmanage', 'list', option], stderr=subprocess.STDOUT)
    vms_list = []
    for item in result.splitlines():
        vm_name = re.match(b'"(.*?)"', item)
        vms_list.append(vm_name.group(1))

    return vms_list


def vboxmanage_showinfo(host):
    """
    This returns info about the host
    """
    if not isinstance(host, str):
        host.decode('utf-8')
    result = subprocess.check_output(['vboxmanage', 'showvminfo', host, '--machinereadable'],
                                     stderr=subprocess.STDOUT)
    return result


def vboxmanage_createvm(hostname, labname):
    """
    This creates a VM with the specified name.
    """

    assert hostname, "Hostname is required"
    assert labname, "Labname is required"
    group = "/" + labname
    LOG.info("Creating VM %s", hostname)
    result = subprocess.check_output(['vboxmanage', 'createvm', '--name', hostname, '--register',
                                      '--ostype', 'Linux_64', '--groups', group],
                                     stderr=subprocess.STDOUT)

def vboxmanage_deletevms(hosts=None):
    """
    Deletes a list of VMs
    """

    assert hosts, "A list of hostname(s) is required"

    if len(hosts) != 0:
        for hostname in hosts:
            LOG.info("Deleting VM %s", hostname)
            result = subprocess.check_output(['vboxmanage', 'unregistervm', hostname, '--delete'],
                                             stderr=subprocess.STDOUT)
            time.sleep(10)
            # in case medium is still present after delete
            vboxmanage_deletemedium(hostname)

    vms_list = vboxmanage_list("vms")
    for items in hosts:
        assert items not in vms_list, "The following vms are unexpectedly" \
            "present {}".format(vms_list)


def vboxmanage_hostonlyifcreate(name="vboxnet0", ip=None, netmask=None):
    """
    This creates a hostonly network for systems to communicate.
    """

    assert name, "Must provide network name"
    assert ip, "Must provide an OAM IP"
    assert netmask, "Must provide an OAM Netmask"

    LOG.info("Creating Host-only Network")

    result = subprocess.check_output(['vboxmanage', 'hostonlyif', 'create'],
                                     stderr=subprocess.STDOUT)

    LOG.info("Provisioning %s with IP %s and Netmask %s", name, ip, netmask)
    result = subprocess.check_output(['vboxmanage', 'hostonlyif', 'ipconfig', name, '--ip',
                                      ip, '--netmask', netmask], stderr=subprocess.STDOUT)


def vboxmanage_hostonlyifdelete(name="vboxnet0"):
    """
    Deletes hostonly network. This is used as a work around for creating too many hostonlyifs.

    """
    assert name, "Must provide network name"
    LOG.info("Removing Host-only Network")
    result = subprocess.check_output(['vboxmanage', 'hostonlyif', 'remove', name],
                                     stderr=subprocess.STDOUT)


def vboxmanage_modifyvm(hostname=None, cpus=None, memory=None, nic=None,
                        nictype=None, nicpromisc=None, nicnum=None,
                        intnet=None, hostonlyadapter=None,
                        natnetwork=None, uartbase=None, uartport=None,
                        uartmode=None, uartpath=None, nicbootprio2=1, prefix=""):
    """
    This modifies a VM with a specified name.
    """

    assert hostname, "Hostname is required"
    # Add more semantic checks
    cmd = ['vboxmanage', 'modifyvm', hostname]
    if cpus:
        cmd.extend(['--cpus', cpus])
    if memory:
        cmd.extend(['--memory', memory])
    if nic and nictype and nicpromisc and nicnum:
        cmd.extend(['--nic{}'.format(nicnum), nic])
        cmd.extend(['--nictype{}'.format(nicnum), nictype])
        cmd.extend(['--nicpromisc{}'.format(nicnum), nicpromisc])
        if intnet:
            if prefix:
                intnet = "{}-{}".format(prefix, intnet)
            else:
                intnet = "{}".format(intnet)
            cmd.extend(['--intnet{}'.format(nicnum), intnet])
        if hostonlyadapter:
            cmd.extend(['--hostonlyadapter{}'.format(nicnum), hostonlyadapter])
        if natnetwork:
            cmd.extend(['--nat-network{}'.format(nicnum), natnetwork])
    elif nicnum and nictype == 'nat':
        cmd.extend(['--nic{}'.format(nicnum), 'nat'])
    if uartbase and uartport and uartmode and uartpath:
        cmd.extend(['--uart1'])
        cmd.extend(['{}'.format(uartbase)])
        cmd.extend(['{}'.format(uartport)])
        cmd.extend(['--uartmode1'])
        cmd.extend(['{}'.format(uartmode)])
        if platform == 'win32' or platform == 'win64':
            cmd.extend(['{}'.format(env.PORT)])
            env.PORT += 1
        else:
            if prefix:
                prefix = "{}_".format(prefix)
            if 'controller-0' in hostname:
                cmd.extend(['{}{}{}_serial'.format(uartpath, prefix, hostname)])
            else:
                cmd.extend(['{}{}{}'.format(uartpath, prefix, hostname)])
    if nicbootprio2:
        cmd.extend(['--nicbootprio2'])
        cmd.extend(['{}'.format(nicbootprio2)])
    cmd.extend(['--boot4'])
    cmd.extend(['net'])
    LOG.info(cmd)

    LOG.info("Updating VM %s configuration", hostname)
    result = subprocess.check_output(cmd, stderr=subprocess.STDOUT)

def vboxmanage_port_forward(hostname, network, local_port, guest_port, guest_ip):
    # VBoxManage natnetwork modify --netname natnet1 --port-forward-4
    # "ssh:tcp:[]:1022:[192.168.15.5]:22"
    rule_name = "{}-{}".format(hostname, guest_port)
    # Delete previous entry, if any
    LOG.info("Removing previous forwarding rule '%s' from NAT network '%s'", rule_name, network)
    cmd = ['vboxmanage', 'natnetwork', 'modify', '--netname', network,
           '--port-forward-4', 'delete', rule_name]
    try:
        result = subprocess.check_output(cmd, stderr=subprocess.STDOUT)
    except subprocess.CalledProcessError:
        pass

    # Add new rule
    rule = "{}:tcp:[]:{}:[{}]:{}".format(rule_name, local_port, guest_ip, guest_port)
    LOG.info("Updating port-forwarding rule to: %s", rule)
    cmd = ['vboxmanage', 'natnetwork', 'modify', '--netname', network, '--port-forward-4', rule]
    result = subprocess.check_output(cmd, stderr=subprocess.STDOUT)

def vboxmanage_storagectl(hostname=None, storectl="sata", hostiocache="off"):
    """
    This creates a storage controller on the host.
    """

    assert hostname, "Hostname is required"
    assert storectl, "Type of storage controller is required"
    LOG.info("Creating %s storage controller on VM %s", storectl, hostname)
    result = subprocess.check_output(['vboxmanage', 'storagectl',
                                      hostname, '--name', storectl,
                                      '--add', storectl, '--hostiocache',
                                      hostiocache], stderr=subprocess.STDOUT)


def vboxmanage_storageattach(hostname=None, storectl="sata",
                             storetype="hdd", disk=None, port_num="0", device_num="0"):
    """
    This attaches a disk to a controller.
    """

    assert hostname, "Hostname is required"
    assert disk, "Disk name is required"
    assert storectl, "Name of storage controller is required"
    assert storetype, "Type of storage controller is required"
    LOG.info("Attaching %s storage to storage controller %s on VM %s",
             storetype, storectl, hostname)
    result = subprocess.check_output(['vboxmanage', 'storageattach',
                                      hostname, '--storagectl', storectl,
                                      '--medium', disk, '--type',
                                      storetype, '--port', port_num,
                                      '--device', device_num], stderr=subprocess.STDOUT)
    return result

def vboxmanage_deletemedium(hostname, vbox_home_dir='/home'):
    assert hostname, "Hostname is required"

    if platform == 'win32' or platform == 'win64':
        return

    username = getpass.getuser()
    vbox_home_dir = "{}/{}/vbox_disks/".format(vbox_home_dir, username)

    disk_list = [f for f in os.listdir(vbox_home_dir) if
                 os.path.isfile(os.path.join(vbox_home_dir, f)) and hostname in f]
    LOG.info("Disk mediums to delete: %s", disk_list)
    for disk in disk_list:
        LOG.info("Disconnecting disk %s from vbox.", disk)
        try:
            result = subprocess.check_output(['vboxmanage', 'closemedium', 'disk',
                                              "{}{}".format(vbox_home_dir, disk), '--delete'],
                                             stderr=subprocess.STDOUT)
            LOG.info(result)
        except subprocess.CalledProcessError as e:
            # Continue if failures, disk may not be present
            LOG.info("Error disconnecting disk, continuing. "
                     "Details: stdout: %s stderr: %s", e.stdout, e.stderr)
        LOG.info("Removing backing file %s", disk)
        try:
            os.remove("{}{}".format(vbox_home_dir, disk))
        except:
            pass


def vboxmanage_createmedium(hostname=None, disk_list=None, vbox_home_dir='/home'):
    """
    This creates the required disks.
    """

    assert hostname, "Hostname is required"
    assert disk_list, "A list of disk sizes is required"

    username = getpass.getuser()
    device_num = 0
    port_num = 0
    disk_count = 1
    for disk in disk_list:
        if platform == 'win32' or platform == 'win64':
            file_name = "C:\\Users\\" + username + "\\vbox_disks\\" + \
                        hostname + "_disk_{}".format(disk_count)
        else:
            file_name = vbox_home_dir + '/' + username + "/vbox_disks/" \
                        + hostname + "_disk_{}".format(disk_count)
        LOG.info("Creating disk %s of size %s on VM %s on device %s port %s",
                 file_name, disk, hostname, device_num, port_num)

        try:
            result = subprocess.check_output(['vboxmanage', 'createmedium',
                                              'disk', '--size', str(disk),
                                              '--filename', file_name,
                                              '--format', 'vdi',
                                              '--variant', 'standard'],
                                             stderr=subprocess.STDOUT)
            LOG.info(result)
        except subprocess.CalledProcessError as e:
            LOG.info("Error stdout: %s stderr: %s", e.stdout, e.stderr)
            raise
        vboxmanage_storageattach(hostname, "sata", "hdd", file_name + \
                                 ".vdi", str(port_num), str(device_num))
        disk_count += 1
        port_num += 1
    time.sleep(5)


def vboxmanage_startvm(hostname=None, force=False):
    """
    This allows you to power on a VM.
    """

    assert hostname, "Hostname is required"

    if not force:
        LOG.info("Check if VM is running")
        running_vms = vboxmanage_list(option="runningvms")
    else:
        running_vms = []

    if hostname.encode('utf-8') in running_vms:
        LOG.info("Host %s is already started", hostname)
    else:
        LOG.info("Powering on VM %s", hostname)
        result = subprocess.check_output(['vboxmanage', 'startvm',
                                          hostname], stderr=subprocess.STDOUT)
        LOG.info(result)

    # Wait for VM to start
    tmout = 20
    while tmout:
        tmout -= 1
        running_vms = vboxmanage_list(option="runningvms")
        if hostname.encode('utf-8') in running_vms:
            break
        time.sleep(1)
    else:
        raise "Failed to start VM: {}".format(hostname)
    LOG.info("VM '%s' started.", hostname)


def vboxmanage_controlvms(hosts=None, action=None):
    """
    This allows you to control a VM, e.g. pause, resume, etc.
    """

    assert hosts, "Hostname is required"
    assert action, "Need to provide an action to execute"

    for host in hosts:
        LOG.info("Executing %s action on VM %s", action, host)
        result = subprocess.call(["vboxmanage", "controlvm", host,
                                  action], stderr=subprocess.STDOUT)
    time.sleep(1)


def vboxmanage_takesnapshot(hosts=None, name=None):
    """
    This allows you to take snapshot of VMs.
    """

    assert hosts, "Hostname is required"
    assert name, "Need to provide a name for the snapshot"

    for host in hosts:
        LOG.info("Taking snapshot %s on VM %s", name, host)
        result = subprocess.call(["vboxmanage", "snapshot", host, "take",
                                  name], stderr=subprocess.STDOUT)


def vboxmanage_restoresnapshot(host=None, name=None):
    """
    This allows you to restore snapshot of a VM.
    """

    assert host, "Hostname is required"
    assert name, "Need to provide the snapshot to restore"

    LOG.info("Restoring snapshot %s on VM %s", name, host)
    result = subprocess.call(["vboxmanage", "snapshot", host, "restore",
                              name], stderr=subprocess.STDOUT)
    time.sleep(10)


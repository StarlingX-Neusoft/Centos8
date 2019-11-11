#!/usr/bin/python3
#
# SPDX-License-Identifier: Apache-2.0
#


import getpass
import os
import time
import subprocess
import paramiko
from utils.install_log import LOG


def sftp_send(source, remote_host, remote_port, destination, username, password):
    """
    Send files to remote server
    """
    LOG.info("Connecting to server %s with username %s", remote_host, username)

    ssh_client = paramiko.SSHClient()
    ssh_client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

    ## TODO(WEI): need to make this timeout handling better
    retry = 0
    while retry < 8:
        try:
            ssh_client.connect(remote_host, port=remote_port,
                               username=username, password=password,
                               look_for_keys=False, allow_agent=False)
            sftp_client = ssh_client.open_sftp()
            retry = 8
        except Exception as e:
            LOG.info("******* try again")
            retry += 1
            time.sleep(10)

    LOG.info("Sending file from %s to %s", source, destination)
    sftp_client.put(source, destination)
    LOG.info("Done")
    sftp_client.close()
    ssh_client.close()

def send_dir(source, remote_host, remote_port, destination, username,
             password, follow_links=True, clear_known_hosts=True):
    # Only works from linux for now
    if not source.endswith('/') or not source.endswith('\\'):
        source = source + '/'
    params = {
        'source': source,
        'remote_host': remote_host,
        'destination': destination,
        'port': remote_port,
        'username': username,
        'password': password,
        'follow_links': "L" if follow_links else "",
        }
    if clear_known_hosts:
        if remote_host == '127.0.0.1':
            keygen_arg = "[127.0.0.1]:{}".format(remote_port)
        else:
            keygen_arg = remote_host
        cmd = 'ssh-keygen -f "/home/%s/.ssh/known_hosts" -R' \
              ' %s', getpass.getuser(), keygen_arg
        LOG.info("CMD: %s", cmd)
        process = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE)
        for line in iter(process.stdout.readline, b''):
            LOG.info("%s", line.decode("utf-8").strip())
        process.wait()

    LOG.info("Running rsync of dir: {source} ->"  \
             "{username}@{remote_host}:{destination}".format(**params))
    cmd = ("rsync -av{follow_links} "
           "--rsh=\"/usr/bin/sshpass -p {password} ssh -p {port} -o StrictHostKeyChecking=no -l {username}\" "
           "{source}* {username}@{remote_host}:{destination}".format(**params))
    LOG.info("CMD: %s", cmd)

    process = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE)
    for line in iter(process.stdout.readline, b''):
        LOG.info("%s", line.decode("utf-8").strip())
    process.wait()
    if process.returncode:
        raise Exception("Error in rsync, return code:{}".format(process.returncode))


def send_dir_fallback(source, remote_host, destination, username, password):
    """
    Send directory contents to remote server, usually controller-0
    Note: does not send nested directories only files.
    args:
    - source: full path to directory
    e.g. /localhost/loadbuild/jenkins/latest_build/
    - Remote host: name of host to log into, controller-0 by default
    e.g. myhost.com
    - destination: where to store the file on host: /home/myuser/
    """
    LOG.info("Connecting to server %s with username %s", remote_host, username)
    ssh_client = paramiko.SSHClient()
    ssh_client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh_client.connect(remote_host, username=username, password=password, look_for_keys=False, allow_agent=False)
    sftp_client = ssh_client.open_sftp()
    path = ''
    send_img = False
    for items in os.listdir(source):
        path = source+items
        if os.path.isfile(path):
            if items.endswith('.img'):
                remote_path = destination+'images/'+items
                LOG.info("Sending file from %s to %s", path, remote_path)
                sftp_client.put(path, remote_path)
                send_img = True
            elif items.endswith('.iso'):
                pass
            else:
                remote_path = destination+items
                LOG.info("Sending file from %s to %s", path, remote_path)
                sftp_client.put(path, remote_path)
    LOG.info("Done")
    sftp_client.close()
    ssh_client.close()
    if send_img:
        time.sleep(10)


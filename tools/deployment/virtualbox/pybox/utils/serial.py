#!/usr/bin/python3
#
# SPDX-License-Identifier: Apache-2.0
#


import re
import socket
from sys import platform, stdout
import time
import streamexpect
from utils.install_log import LOG


def connect(hostname, port=10000, prefix=""):
    """
    Connect to local domain socket and return the socket object.

    Arguments:
    - Requires the hostname of target, e.g. controller-0
    - Requires TCP port if using Windows
    """

    if prefix:
        prefix = "{}_".format(prefix)
    socketname = "/tmp/{}{}".format(prefix, hostname)
    if 'controller-0'in hostname:
        socketname += '_serial'
    LOG.info("Connecting to %s at %s", hostname, socketname)
    if platform == 'win32' or platform == 'win64':
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP)
    else:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        if platform == 'win32' or platform == 'win64':
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
            sock.connect(('localhost', port))
        else:
            sock.connect(socketname)
    except:
        LOG.info("Connection failed")
        pass
        # disconnect(sock)
        sock = None
    # TODO (WEI): double check this
    sock.setblocking(0)

    return sock


def disconnect(sock):
    """
    Disconnect a local doamin socket.

    Arguments:
    - Requires socket
    """

    # Shutdown connection and release resources
    LOG.info("Disconnecting from socket")
    sock.shutdown(socket.SHUT_RDWR)
    sock.close()

def get_output(stream, cmd, prompts=None, timeout=5, log=True, as_lines=True, flush=True):
    #TODO: Not testested, will not work if kernel or other processes throw data on stdout or stderr
    """
    Execute a command and get its output. Make sure no other command is executing.
    And 'dmesg -D' was executed.
    """
    POLL_PERIOD = 0.1
    MAX_READ_BUFFER = 1024
    data = ""
    line_buf = ""
    lines = []
    if not prompts:
        prompts = [':~$ ', ':~# ', ':/home/wrsroot# ', '(keystone_.*)]$ ', '(keystone_.*)]# ']
    # Flush buffers
    if flush:
        try:
            trash = stream.poll(1)  # flush input buffers
            if trash:
                try:
                    LOG.info("Buffer has bytes before cmd execution: %s",
                             trash.decode('utf-8'))
                except Exception:
                    pass
        except streamexpect.ExpectTimeout:
            pass

    # Send command
    stream.sendall("{}\n".format(cmd).encode('utf-8'))

    # Get response
    patterns = []
    for prompt in prompts:
        patterns.append(re.compile(prompt))

    now = time.time()
    end_time = now + float(timeout)
    prev_timeout = stream.gettimeout()
    stream.settimeout(POLL_PERIOD)
    incoming = None
    try:
        while (end_time - now) >= 0:
            try:
                incoming = stream.recv(MAX_READ_BUFFER)
            except socket.timeout:
                pass
            if incoming:
                data += incoming
                if log:
                    for c in incoming:
                        if c != '\n':
                            line_buf += c
                        else:
                            LOG.info(line_buf)
                            lines.append(line_buf)
                            line_buf = ""
                for pattern in patterns:
                    if pattern.search(data):
                        if as_lines:
                            return lines
                        else:
                            return data
                now = time.time()
        raise streamexpect.ExpectTimeout()
    finally:
        stream.settimeout(prev_timeout)


def expect_bytes(stream, text, timeout=180, fail_ok=False, flush=True):
    """
    Wait for user specified text from stream.
    """
    time.sleep(1)
    if timeout < 60:
        LOG.info("Expecting text within %s seconds: %s\n", timeout, text)
    else:
        LOG.info("Expecting text within %s minutes: %s\n", timeout/60, text)
    try:
        stream.expect_bytes("{}".format(text).encode('utf-8'), timeout=timeout)
    except streamexpect.ExpectTimeout:
        if fail_ok:
            return -1
        else:
            stdout.write('\n')
            LOG.error("Did not find expected text")
            # disconnect(stream)
            raise
    except Exception as e:
        LOG.info("Connection failed with %s", e)
        raise

    stdout.write('\n')
    LOG.info("Found expected text: %s", text)

    time.sleep(1)
    if flush:
        try:
            incoming = stream.poll(1)  # flush input buffers
            if incoming:
                incoming += b'\n'
                try:
                    LOG.info(">>> expect_bytes: Buffer has bytes!")
                    stdout.write(incoming.decode('utf-8')) # streamexpect hardcodes it
                except Exception:
                    pass
        except streamexpect.ExpectTimeout:
            pass

    return 0


def send_bytes(stream, text, fail_ok=False, expect_prompt=True,
               prompt=None, timeout=180, send=True, flush=True):
    """
    Send user specified text to stream.
    """
    time.sleep(1)
    if flush:
        try:
            incoming = stream.poll(1)  # flush input buffers
            if incoming:
                incoming += b'\n'
                try:
                    LOG.info(">>> send_bytes: Buffer has bytes!")
                    stdout.write(incoming.decode('utf-8')) # streamexpect hardcodes it
                except Exception:
                    pass
        except streamexpect.ExpectTimeout:
            pass

    LOG.info("Sending text: %s", text)
    try:
        if send:
            stream.sendall("{}\n".format(text).encode('utf-8'))
        else:
            stream.sendall("{}".format(text).encode('utf-8'))
        if expect_prompt:
            time.sleep(1)
            if prompt:
                return expect_bytes(stream, prompt, timeout=timeout, fail_ok=fail_ok)
            else:
                rc = expect_bytes(stream, "~$", timeout=timeout, fail_ok=True)
                if rc != 0:
                    send_bytes(stream, '\n', expect_prompt=False)
                    expect_bytes(stream, 'keystone', timeout=timeout)
                    return
    except streamexpect.ExpectTimeout:
        if fail_ok:
            return -1
        else:
            LOG.error("Failed to send text, logging out.")
            stream.sendall("exit".encode('utf-8'))
            raise
    except Exception as e:
        LOG.info("Connection failed with %s.", e)
        raise

    return 0

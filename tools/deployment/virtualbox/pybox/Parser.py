#!/usr/bin/python3
#
# SPDX-License-Identifier: Apache-2.0
#

"""
Parser to handle command line arguments
"""


import argparse
import getpass


def handle_args():
    """
    Handle arguments supplied to the command line
    """

    parser = argparse.ArgumentParser(formatter_class=argparse.RawTextHelpFormatter)

    """
    **************************************
    * Setup type & install configuration *
    **************************************
    """
    parser.add_argument("--setup-type", help=
                        """
                        Type of setup:
                            AIO-SX
                            AIO-DX
                            STANDARD
                            STORAGE
                        """,
                        choices=['AIO-SX', 'AIO-DX', 'STANDARD', 'STORAGE'],
                        type=str)
    parser.add_argument("--controllers", help=
                        """
                        Number of controllers:
                        1 - single controller
                        2 - two controllers
                        """,
                        choices=[1, 2],
                        type=int,
                        default=2)
    parser.add_argument("--workers", help=
                        """
                        Number of workers:
                        1 - single worker
                        2 - two workers
                        etc.
                        """,
                        type=int,
                        default=2)
    parser.add_argument("--storages", help=
                        """
                        Number of storage nodes:
                        1 - single storage node
                        2 - two storage nodes
                        etc.\n
                        """,
                        type=int,
                        default=2)
    parser.add_argument("--from-stage", help=
                        """
                        Start stage.
                        For a list of stages run --list-stages
                        \n
                        """,
                        type=str)
    parser.add_argument("--to-stage", help=
                        """
                        End stage.
                        For a list of stages run --list-stages
                        \n
                        """,
                        type=str)
    parser.add_argument("--custom-stages", help=
                        """
                        Custom, comma separated list of stages.
                        For a list of stages run --list-stages
                        \n
                        """,
                        type=str,
                        default=None)

    """
    ******************************************
    * Config folders and files configuration *
    ******************************************
    """
    parser.add_argument("--iso-location", help=
                        """
                        Location of ISO including the filename:
                            /folk/myousaf/bootimage.ISO
                        """,
                        type=str)
    parser.add_argument("--config-files-dir", help=
                        """
                        Directory with config files, scripts, images (i.e.
                        lab_setup.sh, lab_setup.conf, ...) that are needed
                        for the install. All files at this location are
                        transfered to controller-0 in /home/wrsroot. You
                        can add you own scripts that you need to be
                        present on the controller.  Caution: rsync will
                        follow links and will fail if links are broken!
                        Use --config-files-dir-dont-follow-links
                        instead. Also, you can use both options for
                        different folders.
                        """,
                        type=str)
    parser.add_argument("--config-files-dir-dont-follow-links", help=
                        """
                        Same as --config-files-dir but keep symbolic link as is.
                        """,
                        type=str)
    parser.add_argument("--config-controller-ini", help=
                        """
                        Path to the local config_controller .ini. This
                        file is transfered to the controller.  NOTE: OAM
                        configuration in this ini is updated dynamically
                        based on networking related args.
                        (e.g. stx_config.ini_centos,
                        ~/stx_config.ini_centos, /home/myousaf ...).
                        """,
                        type=str)
    parser.add_argument("--vbox-home-dir", help=
                        """
                        This is the folder where vbox disks will be
                        placed. e.g. /home or /folk/cgts/users
                        The disks will be in /home/wzhou/vbox_disks/ or
                        /folk/cgts/users/wzhou/vbox_disks/
                        """,
                        type=str, default='/home')
    parser.add_argument("--lab-setup-conf", help=
                        """
                        Path to the config file to use
                        """,
                        action='append')
    """
    **************************************
    * Disk number and size configuration *
    **************************************
    """
    parser.add_argument("--controller-disks", help=
                        """
                        Select the number of disks for a controller VM. default is 3
                        """,
                        type=int, default=3, choices=[1, 2, 3, 4, 5, 6, 7])
    parser.add_argument("--storage-disks", help=
                        """
                        Select the number of disks for storage VM. default is 3
                        """,
                        type=int, default=3, choices=[1, 2, 3, 4, 5, 6, 7])
    parser.add_argument("--worker-disks", help=
                        """
                        Select the number of disks for a worker VM. default is 2
                        """,
                        type=int, default=2, choices=[1, 2, 3, 4, 5, 6, 7])
    parser.add_argument("--controller-disk-sizes", help=
                        """
                        Configure size in MiB of controller disks as a comma separated list.
                        """,
                        type=str)
    parser.add_argument("--storage-disk-sizes", help=
                        """
                        Configure size in MiB of storage disks as a comma separated list.
                        """,
                        type=str)
    parser.add_argument("--worker-disk-sizes", help=
                        """
                        Configure size in MiB of worker disks as a comma separated list.
                        """,
                        type=str)
    """
    **************
    * Networking *
    **************
    """
    parser.add_argument("--vboxnet-name", help=
                        """
                        Which host only network to use for setup.
                        """,
                        type=str)
    parser.add_argument("--vboxnet-ip", help=
                        """
                        The IP address of the host only adapter as it
                        is configured on the host (i.e. gateway). This is also used to
                        update GATEWAY_IP in [OAM_NETWORK] of config_controller config file.
                        """,
                        type=str)
    parser.add_argument("--add-nat-interface", help=
                        """
                        Add a new NAT interface to hosts.
                        """,
                        action='store_true')
    parser.add_argument("--controller-floating-ip", help=
                        """
                        OAM floating IP.
                        """,
                        type=str)
    parser.add_argument("--controller0-ip", help=
                        """
                        OAM IP of controller-0. This is also used to
                        update IP_ADDRESS in [OAM_NETWORK] of
                        config_controller config file of an AIO SX setup.
                        This should not be the floating IP.
                        """,
                        type=str)
    parser.add_argument("--controller1-ip", help=
                        """
                        OAM IP of controller-1.
                        This should not be the floating IP.
                        """,
                        type=str)
    parser.add_argument("--vboxnet-type", help=
                        """
                        Type of vbox network, either hostonly on nat
                        """,
                        choices=['hostonly', 'nat'],
                        type=str,
                        default='hostonly')
    parser.add_argument("--nat-controller-floating-local-ssh-port", help=
                        """
                        When oam network is configured as 'nat' a port on
                        the vbox host is used for connecting to ssh on
                        floating controller.  No default value is
                        configured. This is mandatory if --vboxnet-type is
                        'nat' for non AIO-SX deployments.
                        """,
                        type=str)
    parser.add_argument("--nat-controller0-local-ssh-port", help=
                        """
                        When oam network is configured as 'nat' a port on
                        the vbox host is used for connecting to ssh on
                        controller-0.  This is mandatory if --vboxnet-type
                        is 'nat'. No default value is configured.
                        """,
                        type=str)
    parser.add_argument("--nat-controller1-local-ssh-port", help=
                        """
                        When oam network is configured as 'nat' a port on
                        the vbox host is used for connecting to ssh on
                        controller-1.  No default value is configued. This
                        is mandatory if --vboxnet-type is 'nat' for non
                        AIO-SX deployments or if second controller is
                        installed.
                        """,
                        type=str)
    parser.add_argument("--ini-oam-cidr", help=
                        """
                        The IP network and mask for the oam net, used to
                        update CIDR value in [OAM_NETWORK] of
                        config_controller config file.  Default is
                        10.10.10.0/24
                        """,
                        type=str)
    parser.add_argument("--ini-oam-ip-start-address", help=
                        """
                        The start for the oam net allocation, used to
                        update IP_START_ADDRESS value in [OAM_NETWORK] of
                        config_controller config file.  Not needed for AIO
                        SX setups.
                        """,
                        type=str)
    parser.add_argument("--ini-oam-ip-end-address", help=
                        """
                        The end for the oam net allocation, used to update
                        IP_END_ADDRESS value in [OAM_NETWORK] of
                        config_controller config file.  Not needed for AIO
                        SX setups.
                        """,
                        type=str)
    """
    ******************
    * Custom scripts *
    ******************
    """
    parser.add_argument("--script1", help=
                        """
                        Name of an executable script file plus options.
                        Has to be present in --config-files-dir.
                        It will be transfered to host in rsync-config
                        stage and executed as part of custom-script1
                        stage.
                        Example: --script1 'scripts/k8s_pv_cfg.sh,50,ssh,user'
                        Contains a comma separated value of:
                            <script_name>,<timeout>,<serial or ssh>,<user/root> Where:
                            script_name = name of the script, either .sh or .py;
                            timeout = how much to wait, in seconds, before considering failure;
                            serial/ssh = executed on the serial console;
                            user/root = as a user or as root (sudo <script_name);

                        Script executes successfully if return code is 0. Anything else
                        is considered error and further execution is aborted.
                        """,
                        default=None,
                        type=str)
    parser.add_argument("--script2", help=
                        """
                        See --script1
                        """,
                        default=None,
                        type=str)
    parser.add_argument("--script3", help=
                        """
                        See --script1
                        """,
                        default=None,
                        type=str)
    parser.add_argument("--script4", help=
                        """
                        See --script1
                        """,
                        default=None,
                        type=str)
    parser.add_argument("--script5", help=
                        """
                        See --script1
                        """,
                        default=None,
                        type=str)
    """
    **************************************
    * Other *
    **************************************
    """
    parser.add_argument("--list-stages", help=
                        """
                        List stages that can be used by autoinstaller.
                        """,
                        action='store_true')
    parser.add_argument("--logpath", help=
                        """
                        Base directory to store logs.
                        """,
                        type=str)
    parser.add_argument("--force-delete-lab", help=
                        """
                        Don't ask for confirmation when deleting a lab.
                        """,
                        action='store_true')
    parser.add_argument("--snapshot", help=
                        """
                        Take snapshot at different stages when the lab is installed.
                        E.g. before and after config_controller, before and after lab_setup.
                        """,
                        action='store_true')
    parser.add_argument("--securityprofile", help=
                        """
                        Security profile to use:
                        standard
                        extended
                        Standard is the default
                        """,
                        type=str, choices=['standard', 'extended'],
                        default='standard')
    parser.add_argument("--lowlatency", help=
                        """
                        Whether to install an AIO system as low latency.
                        """,
                        action='store_true')
    parser.add_argument("--install-mode", help=
                        """
                        Lab will be installed using the mode specified. Serial mode by default
                        """,
                        type=str, choices=['serial', 'graphical'], default='serial')
    parser.add_argument("--username", help=
                        """
                        Username. default is 'wrsroot'
                        """,
                        type=str)
    parser.add_argument("--password", help=
                        """
                        Password. default is 'Li69nux*'
                        """,
                        type=str)
    parser.add_argument("--labname", help=
                        """
                        The name of the lab to be created.
                        """,
                        type=str)
    parser.add_argument("--userid", help=
                        """
                        Unique user id to differentiate vbox machine
                        unique names such as interface names or serial
                        ports even if setups have the same names for
                        different users. Default is your username on this
                        machine.
                        """,
                        type=str,
                        default=getpass.getuser())
    parser.add_argument("--hostiocache", help=
                        """
                        Turn on host i/o caching
                        """,
                        action='store_true')
    return parser

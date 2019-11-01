Pybox
=====

The automated installer provides you with an easy tool to install
StarlingX AIO-SX, AIO-DX, Standard, and Storage setups on Linux hosts on
Virtualbox 5.1.x.

The main concepts of the autoinstaller is the stage and the chain. A stage
is an atomic set of actions taken by the autoinstaller. A chain is a set
of stages executed in a specific order. Stages can be executed
independently and repeated as many times the user needs. Chains can be
configured with the desired stages by the user. Or, the user can select a
specific chain from the available ones.

Example stages:

- create-lab           # Create VMs in vbox: controller-0, controller-1...
- install-controller-0 # Install controller-0 from --iso-location
- config-controller    # Run config controller using the
- config-controller-ini updated based on --ini-* options.
- rsync-config         # Rsync all files from --config-files-dir and
                         --config-files-dir* to /home/wrsroot.
- lab-setup1           # Run lab_setup with one or more --lab-setup-conf
                         files from controller-0.
- unlock-controller-0  # Unlock controller-0 and wait for it to reboot.
- lab-setup2           # Run lab_setup with one or more --lab-setup-conf
                         files from controller-0.

Example chains: [create-lab, install-controller-0, config-controller,
rsync-config, lab-setup1, unlock-controller-0, lab-setup2]. This chain
will install an AIO-SX.

The autoinstaller has a predefined set of chains. The user can select from
these chains and choose from which stage to which stage to do the install.
For example, if the user already executed config_controller, they can choose
to continue from rsync-config to lab-setup2.

The user can also create a custom set of chains, as he sees fit by
specifying them in the desired order. This allows better customization of
the install process. For example, the user might want to execute his own
script after config_controller.  In this case, he will have to specify a
chain like this: [create-lab, install-controller-0, config-controller,
rsync-config, custom-script1, lab-setup1, unlock-controller-0, lab-setup2]

The installer supports creating virtualbox snapshots after each stage so
the user does not need to reinstall from scratch. The user can restore the
snapshot of the previous stage, whether to retry or fix the issue
manually, then continue the process.

List of Features
----------------

Basic:
- Multi-user, and multiple lab installs can run at the same time.
- Uses config_controller ini and lab_setup.sh script to drive the
  configuration [therefore their requirements have to be met prior to
  execution].
- Specify setup (lab) name - this will group all nodes related to
  this lab in a virtual box group
- Setup type - specify what you want to install (SX,DX,Standard,
  Storage)
- Specify start and end stages or a custom list of stages
- Specify your custom ISO, config_controller ini file locations
- Updates config_controller ini automatically with your custom OAM
  networking options so that you don't need to update the ini file for
  each setup
- Rsync entire content from a couple of folders on your disk
  directly on the controller /home/wrsroot thus allowing you easy access
  to your scripts and files
- Take snapshots after each stage

Configuration:
- Specify the number of nodes you want for your setup (one or two controllers,
  x storages, y workers)
- Specify the number of disks attached to each node. They use the
  default sizes configured) or you can explicitly specify the sizes of the
  disks
- Use either 'hostonly' adapter or 'NAT' interface with automated
  port forwarding for SSH ports.

Advanced chains:
- Specify custom chain using any of the existing stages
- Ability to run your own custom scripts during the install process
- Ability to define what scripts are executed during custom script
  stages, their timeout, are executed over ssh or serial, are executed as
  normal user or as root.

Other features
- Log files per lab and date.
- Enable hostiocache option for virtualbox VMs storage controllers
  to speed up install
- Basic support for Kubernetes (AIO-SX installable through a custom
  chain)
- Support to install lowlatency and securityprofile

Installation
------------

Prerequisites:

- Install Virtualbox.  It is recommend v5.1.x.  Use v5.2 at your own risk
- Configure at least a vbox hostonly adapter network. If you want to
  use NAT, you must also configue a NAT Network.
- Make sure you have rsync, ssh-keygen, and sshpass commands installed.
- Install python3 and pip3 if not already done.

Sample Usage
------------

./install_vbox.py --setup-type AIO-SX --iso-location
"/home/myousaf/bootimage.iso" --labname test --install-mode serial
--config-files-dir /home/myousaf/pybox/configs/aio-sx/
--config-controller-ini
/home/myousaf/pybox/configs/aio-sx/stx_config.ini_centos --vboxnet-name
vboxnet0 --controller0-ip 10.10.10.8 --ini-oam-cidr '10.10.10.0/24'

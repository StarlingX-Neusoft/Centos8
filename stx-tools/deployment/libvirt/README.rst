StarlingX Deployment on Libvirt
===============================

This is a quick reference for deploying StarlingX on libvirt/qemu systems.
It assumes you have a working libvirt/qemu installation for a non-root user
and that your user has NOPASSWD sudo permissions.

Refer also to pages "Installation Guide" on the StarlingX Documentation:
https://docs.starlingx.io/installation_guide/index.html

Overview
--------

We create 4 bridges to use for the STX cloud.  This is done in an initial step
separate from the VM management.

Depending on which basic configuration is chosen, we create a number of VMs
for one or more controllers and storage nodes.

These scripts are configured using environment variables that all have built-in
defaults.  On shared systems you probably do not want to use the defaults.
The simplest way to handle this is to keep an rc file that can be sourced into
an interactive shell that configures everything.  Here's an example::

	export CONTROLLER=madcloud
	export WORKER=madnode
	export BRIDGE_INTERFACE=madbr
	export EXTERNAL_NETWORK=172.30.20.0/24
	export EXTERNAL_IP=172.30.20.1/24

There is also a script ``cleanup_network.sh`` that will remove networking
configuration from libvirt.

Networking
----------

Configure the bridges using ``setup_network.sh`` before doing anything else. It
will create 4 bridges named ``stxbr1``, ``stxbr2``, ``stxbr3`` and ``stxbr4``.
Set the BRIDGE_INTERFACE environment variable if you need to change stxbr to
something unique.

The ``destroy_network.sh`` script does the reverse, and should not be used lightly.
It should also only be used after all of the VMs created below have been destroyed.

Controllers
-----------

There is one script for creating the controllers: ``setup_configuration.sh``. It
builds different StarlingX cloud configurations:

- simplex
- duplex
- controllerstorage
- dedicatedstorage

You need an StarlingX ISO file for the installation. The script takes the
configuration name with the ``-c`` option and the ISO file name with the
``-i`` option::

	./setup_configuration.sh -c simplex -i stx-2018-08-28-93.iso

And the setup will begin.  The script create one or more VMs and start the boot
of the first controller, named oddly enough ``controller-0``.  If you have Xwindows
available you will get virt-manager running.
If not, Ctrl-C out of that attempt if it doesn't return to a shell prompt.
Then connect to the serial console::

	virsh console controller-0

Continue the usual StarlingX installation from this point forward.

Tear down the VMs giving the configuration name with the ``-c`` option::

>-------./destroy_configuration.sh -c simplex

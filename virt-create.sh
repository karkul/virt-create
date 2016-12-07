#!/bin/bash

# Take one argument from the commandline: VM name
if ! [ $# -eq 5 ]; then
    echo "Usage: $0 <node-name> <memory> <vcpus> <disk-GB> <ip-address>"
    exit 1
fi

# Check if domain already exists
virsh dominfo $1 > /dev/null 2>&1
if [ "$?" -eq 0 ]; then
    echo -n "[WARNING] $1 already exists.  "
    read -p "Do you want to overwrite $1 [y/N]? " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo ""
    else
        echo -e "\nNot overwriting $1. Exiting..."
        exit 1
    fi
fi

# Directory to store images
DIR=/var/lib/libvirt/images

# Location of cloud image
IMAGE=$DIR/CentOS-7-x86_64-GenericCloud.qcow2

# Amount of RAM in MB
MEM=$2

# Number of virtual CPUs
CPUS=$3
DISK_GB=$4
IPADDR=$5
GWTY=192.168.122.1
MSK=255.255.255.0
DNS=192.168.122.1
DOMAIN=netlab.t-systems.mx

# Cloud init files
USER_DATA=user-data
META_DATA=meta-data
CI_ISO=$1-cidata.iso
DISK=$1.qcow2

# Bridge for VMs (default on Fedora is bridge0)
BRIDGE=br0

# Start clean
rm -rf $DIR/$1
mkdir -p $DIR/$1

pushd $DIR/$1 > /dev/null

    # Create log file
    touch $1.log

    echo "$(date -R) Destroying the $1 domain (if it exists)..."

    # Remove domain with the same name
    virsh destroy $1 >> $1.log 2>&1
    virsh undefine $1 >> $1.log 2>&1

    # cloud-init config: set hostname, remove cloud-init package,
    # and add ssh-key
    cat > $USER_DATA << _EOF_
#cloud-config

# Hostname management
preserve_hostname: False
hostname: $1
fqdn: $1.$DOMAIN

# Remove cloud-init when finished with it
runcmd:
  - [ yum, -y, remove, cloud-init ]
  - echo "GATEWAY=$GWTY" >> /etc/sysconfig/network
  - echo "nameserver $DNS" >> /etc/resolv.conf
  - echo "domain $DOMAIN" >> /etc/resolv.conf
  - /etc/init.d/network restart
  - ifdown eth0
  - ifup eth0
  - [ yum, -y, update ]
  - [ yum, -y, install, docker ]

# Configure where output will go
output:
  all: ">> /var/log/cloud-init.log"

chpasswd:
  list: |
    centos:reverse
  expire: False

# configure interaction with ssh server
ssh_svcname: ssh
ssh_deletekeys: True
ssh_genkeytypes: ['rsa', 'ecdsa']

# Install my public ssh key to the first user-defined user configured
# in cloud.cfg in the template (which is centos for CentOS cloud images)
ssh_authorized_keys:
  - ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDE1yHWGZ13fe2cGN+5Ou5ZP/FSQ3ALnkGEUrFc8iHdOxXjpjOnnYsEn9WA6sRlU+PirGQwANKrVgaNO6wSAF35UZvZ3OPoXKzxK+hX++vOW8/ib22KPIhllYcMbzAEJaSRu3YVCcpyjUqa2cw7fXRoZNpovqBiMsL/DuyYK6swEFIP0bQd8yGnf0YVFednXR+KqbFWxVQn0xv5QgtjuwbEoCkRkPUafjVSQKdQE/XSpCilO1K3oPkRfN+m9l6zu7Axzb9GEJ92fBXL6Aq5R2y2ddlnkIM6KhLrXt13RMxizgTcdwdS8YPfLNiNT9O90YtU/1OtD68Ry6SDd5OgEb0v root@nuage.netlab.t-systems.mx
_EOF_

# Manging metadata cloud-init now
cat > $META_DATA << _EOF_
instance-id: $1
local-hostname: $1
network-interfaces: |
  iface eth0 inet static
  address $IPADDR
  network ${IPADDR%.*}.0
  netmask $MSK
  broadcast ${IPADDR%.*}.255

# bootcmd:
#  - ifdown eth0
#  - ifup eth0
_EOF_
    #echo "instance-id: $1; local-hostname: $1" > $META_DATA

    echo "$(date -R) Copying template image..."
    echo "INFO: qemu-img create -f qcow2 -o preallocation=metadata $DISK ${DISK_GB}G"
    qemu-img create -f qcow2 -o preallocation=metadata $DISK ${DISK_GB}G
    virt-resize --expand /dev/sda1 $IMAGE $DISK

    echo "Converting and sizing $IMAGE to $DISK"
    #cp $IMAGE $DISK

    # Create CD-ROM ISO with cloud-init config
    echo "$(date -R) Generating ISO for cloud-init..."
    genisoimage -output $CI_ISO -volid cidata -joliet -r $USER_DATA $META_DATA &>> $1.log

    echo "$(date -R) Installing the domain and adjusting the configuration..."
    echo "[INFO] Installing with the following parameters:"
    echo "virt-install --import --name $1 --ram $MEM --vcpus $CPUS --disk \
    $DISK,format=qcow2,bus=virtio --disk $CI_ISO,device=cdrom --network \
    bridge=$BRIDGE,model=virtio --os-type=linux --os-variant=rhel6 --noautoconsole --noapic"


    virt-install --import --name $1 --ram $MEM --vcpus $CPUS --disk \
    $DISK,format=qcow2,bus=virtio --disk $CI_ISO,device=cdrom --network \
    bridge=$BRIDGE,model=virtio --os-type=linux --os-variant=rhel6 --noautoconsole --noapic \
    --accelerate

    #virsh console $1


    FAILS=0
    while true; do
        ping -c 1 $IPADDR >/dev/null 2>&1
        if [ $? -ne 0 ] ; then #if ping exits nonzero...
           FAILS=$[FAILS + 1]
           echo "INFO: Checking if server $1 with IP $IPADDR is online. ($FAILS out of 20)"
        else
           echo "INFO: server $1 is alive. let's remove cloud init files"
           break
        fi
        if [ $FAILS -gt 20 ]; then
           echo "INFO: Server is still offline after 20min. I will end here!"
           exit
        fi
        sleep 60
    done

    # Eject cdrom
    echo "$(date -R) Cleaning up cloud-init..."
    virsh change-media $1 hda --eject --config >> $1.log

    # Remove the unnecessary cloud init files
    rm $USER_DATA $CI_ISO

    echo "$(date -R) DONE. SSH to $1 using $IP, with  username 'centos'."

popd > /dev/null


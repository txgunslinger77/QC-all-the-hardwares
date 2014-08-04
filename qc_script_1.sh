#!/bin/bash
 
# TODO: Group udev and /etc/network/interfaces fixes into this script so that a single reboot and everything is working (unless it has been physically cabled wrong...)
# TODO: Sanatize script so that it can be run repeatedly without anything breaking.
# TODO: Break groups of code into functions
# TODO: Fix variable names
 
# Standardize /etc/hosts and /etc/hostname
# TODO: Assuming eth0 is probably not useful often. If an interface isn't passed, we should assume an interface with a typical management address 10.240.0.x/22
# One step further, we should probably be passing the management subnet as an arg and finding the interface on that subnet
INTERFACE="${1:-eth0}"
cp /etc/hosts /root/hosts.bak
ADDRESS=$(ip a s dev ${INTERFACE} | awk '/inet / {sub(/\/[0-9]+$/, "", $2); print $2; exit}')
echo -e "127.0.0.1\tlocalhost.localdomain localhost" > /etc/hosts
echo -e "${ADDRESS}\t${RS_SERVER_NAME} $(hostname -s)" >> /etc/hosts
echo -e "$(hostname -s)" > /etc/hostname
service hostname restart
 
# Resize any swap disks larger than 8GB to 8GB - TODO Run only if 8G > swap00 > 7G, possibly check boot size as well
swapoff /dev/mapper/vglocal00-swap00
lvresize -f -L8G /dev/vglocal00/swap00
mkswap /dev/mapper/vglocal00-swap00
swapon -a
lvresize -l+100%FREE /dev/mapper/vglocal00-root00
resize2fs /dev/mapper/vglocal00-root00 
 
# Un-blacklist Modules - Line will only modify file if file exists and blacklist e1000e or blacklist ixgbe exists at the beginning of a line.
if [ -a /etc/modprobe.d/blacklist.local.conf ]; then
    sed -i 's/^blacklist e1000e/#blacklist e1000e/g' /etc/modprobe.d/blacklist.local.conf
    sed -i 's/^blacklist ixgbe/#blacklist ixgbe/g' /etc/modprobe.d/blacklist.local.conf
fi
 
# TODO (Thomas M. / Charles F.): Need to upgrade ixgbe version here
# Add bonding and NIC modules to /etc/modules file
#We only need to add these lines if they don't exist. No need to add them repeatedly if the script is rerun
MODULES="/etc/modules"
grep -q '^bonding$' "${MODULES}" || echo 'bonding' >> "${MODULES}"
grep -q '^e1000e$' "${MODULES}" || echo 'e1000e' >> "${MODULES}"
grep -q '^ixgbe$' "${MODULES}" || echo 'ixgbe' >> "${MODULES}"
 
modprobe bonding; modprobe e1000e; modprobe ixgbe
 
# Create file to configure console serial redirection over DRAC
# (this will allow you to access DRAC from your terminal session window)
cat << EOF > /etc/init/ttyS0.conf
# ttyS0 - getty
#
# This service maintains a getty on ttyS0 from the point the system is
# started until it is shut down again.
   
start on runlevel [2345] and (
            not-container or
            container CONTAINER=lxc or
            container CONTAINER=lxc-libvirt)
   
stop on runlevel [!2345]
   
respawn
exec /sbin/getty -8 -L 115200 ttyS0 ansi
EOF
 
start ttyS0
 
# TODO: Wrap these updates into functions so that if a certain parameter is passed it will skip updating the system.
# Update kernel from 3.2 > 3.8
apt-get install -y --install-recommends linux-generic-lts-raring
 
# Ensure necessary packages are installed and up to date, and install Dell OpenManage for Ubuntu
apt-get update && apt-get -y dist-upgrade
apt-get install -y dsh curl ethtool ifenslave vim sysstat linux-crashdump; \
sed -i 's/BLED=\"false\"/BLED=\"true\"/' /etc/default/sysstat; \
echo 'deb http://linux.dell.com/repo/community/deb/latest /' | sudo tee -a /etc/apt/sources.list.d/linux.dell.com.sources.list; \
gpg --keyserver pool.sks-keyservers.net --recv-key 1285491434D8786F; \
gpg -a --export 1285491434D8786F | sudo apt-key add -; \
apt-get update && apt-get -y install srvadmin-all; \
service dataeng start
 
# Give OpenManage services chance to start
sleep 35
 
# Apply BIOS changes to allow console serial redirection over DRAC
/opt/dell/srvadmin/bin/omconfig chassis biossetup attribute=extserial setting=rad
/opt/dell/srvadmin/bin/omconfig chassis biossetup attribute=fbr setting=115200
/opt/dell/srvadmin/bin/omconfig chassis biossetup attribute=serialcom setting=com2
/opt/dell/srvadmin/bin/omconfig chassis biossetup attribute=crab setting=enabled
 
# Enable the performance profile in the BIOS
/opt/dell/srvadmin/bin/omconfig chassis biossetup attribute=SysProfile setting=PerfOptimized
 
sleep 10
 
# Apply DRAC settings to allow console serial redirection over DRAC
/opt/dell/srvadmin/sbin/racadm config -g cfgSerial -o cfgSerialBaudRate 115200
/opt/dell/srvadmin/sbin/racadm config -g cfgSerial -o cfgSerialConsoleEnable 1
/opt/dell/srvadmin/sbin/racadm config -g cfgSerial -o cfgSerialSshEnable 1
/opt/dell/srvadmin/sbin/racadm config -g cfgSerial -o cfgSerialHistorySize 2000
 
# Apply kernel update with reboot
reboot
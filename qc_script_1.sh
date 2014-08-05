#!/bin/bash

# USAGE:
# ./script.sh [MGMT Subnet address]

# TODO: Sanatize script so that it can be run repeatedly without anything breaking.


bdf_sort () {
	# This sorts by using some sed magic. It view groups as lines with breaks in between them. It uses "vertical tabs" to allow sorting. This only sorts based on the first line in each group. See Sam Yaple if it needs to sort by a line other than the first one.
	# This does require Ubuntu to generate comment lines with "PCI device $attr{vendor}:$attr{device} ($driver)". I think 14.04 changes this. Works great on 12.04
        # Sort by PCI BDF notation
        sed -r ':r;/(^|\n)$/!{$!{N;br}};s/\n/\v/g' "${BAK_UDEV_NET}"    | \
        sort                                                            | \
        sed 's/\v/\n/g'                                                 | \
        awk '/SUBSYSTEM/ {print $0}'                                    | \
        awk 'BEGIN {i=0} {sub(/eth[0-9].*$/,"eth"i"\"") ; i++} {print $0}' > "${UDEV_NET}"
}

bdf_mac_sort () {
        # Sort by PCI BDF notation, use Bus Device then MAC address (instead of Function) for sorting
        for MAC_VEN in $(sed -r ':r;/(^|\n)$/!{$!{N;br}};s/\n/\v/g' "${BAK_UDEV_NET}"   | \
                                sort                                                    | \
                                sed 's/\v/\n/g'                                         | \
                                awk '/SUBSYSTEM/ {print $0}'                            | \
                                awk -F\" '{print $8}'                                   | \
                                awk -F: '{print $1":"$2":"$3}'                          | \
                                uniq
                        ); do
                grep "${MAC_VEN}" "${BAK_UDEV_NET}" | sort;
                        done | \
                        awk 'BEGIN {i=0} {sub(/eth[0-9].*$/,"eth"i"\"") ; i++} {print $0}' > "${UDEV_NET}"
}

udev_fix () {
	UDEV_NET=/etc/udev/rules.d/70-persistent-net.rules
	BAK_UDEV_NET=/root/70-persistent-net.rules.bak

	# Remove existing rule and regenerate 70-persistent-net.rules with PCI names in comments
	rm "${UDEV_NET}"
	udevadm trigger --action=add
	udevadm settle
	# Dont trust udev! It says it has finished when it hasn't!
	sleep 2
	udevadm settle

	cp "${UDEV_NET}" "${BAK_UDEV_NET}"

	# Using BDF MAC sorting as I believe that is the correct way. Still need to verify
	bdf_mac_sort

	# You need to reboot now, but wait until you are sure rearranging the names isn't going to hose your access when you reboot.
}

interfaces_fix () {
	# TODO: Generate /etc/network/interfaces
}

hosts_fix () {
	# Standardize /etc/hosts and /etc/hostname
	HOSTS="/etc/hosts"
	HOSTS_BAK="/root/hosts.bak"
	HOST="$(echo ${RS_SERVER_NAME} | awk -F. '{print $1}')"
	FQDN="${RS_SERVER_NAME}"
	MGMT_SUBNET="$(echo ${1:-10.240.0.0} | awk -F. {print $1"."$2})"
	ADDRESS=$(ip a | awk '/inet "${MGMT_SUBNET}"/ {sub(/\/[0-9]+$/, "", $2); print $2; exit}')

	if [[ -z "${ADDRESS}" ]]; then
		ADDRESS=$(ip a | awk '/inet/ {sub(/\/[0-9]+$/, "", $2); print $2; exit}')
		echo "Failed to get management ip address. Assuming ${ADDRESS} is the management ip"
	fi
	
	cp "${HOSTS}" "${HOSTS_BAK}"

	cat << EOF > "${HOSTS}"
127.0.0.1\tlocalhost.localdomain localhost
${ADDRESS}\t${FQDN} ${HOST}
EOF
	
	echo "${HOST}" > /etc/hostname
	service hostname restart
}

networking () {
	hosts_fix

	udev_fix

	interfaces_fix
}

volumes () { 
	# Resize any swap disks larger than 8GB to 8GB - TODO Run only if 8G > swap00 > 7G, possibly check boot size as well
	swapoff /dev/mapper/vglocal00-swap00
	lvresize -f -L8G /dev/vglocal00/swap00
	mkswap /dev/mapper/vglocal00-swap00
	swapon -a
	lvresize -l+100%FREE /dev/mapper/vglocal00-root00
	resize2fs /dev/mapper/vglocal00-root00 
}

modules () {
	# Un-blacklist Modules - Line will only modify file if file exists and blacklist e1000e or blacklist ixgbe exists at the beginning of a line.
	BLACKLIST="/etc/modprobe.d/blacklist.local.conf"
	if [ -a "${BLACKLIST}" ]; then
		sed -i 's/^blacklist e1000e/#blacklist e1000e/g' "${BLACKLIST}"
		sed -i 's/^blacklist ixgbe/#blacklist ixgbe/g' "${BLACKLIST}"
	fi
	 
	# TODO (Thomas M. / Charles F.): Need to upgrade ixgbe version here
	# Add bonding and NIC modules to /etc/modules file
	# We only need to add these lines if they don't exist. No need to add them repeatedly if the script is rerun
	MODULES="/etc/modules"
	grep -q '^bonding$' "${MODULES}" || echo 'bonding' >> "${MODULES}"
	grep -q '^e1000e$' "${MODULES}" || echo 'e1000e' >> "${MODULES}"
	grep -q '^ixgbe$' "${MODULES}" || echo 'ixgbe' >> "${MODULES}"
 
	modprobe bonding; modprobe e1000e; modprobe ixgbe
}

sol () { 
	# Create file to configure console serial redirection over DRAC
	# (this will allow you to access DRAC from your terminal session window)
	cat << EOF > /etc/init/ttyS0.conf
# ttyS0 - getty
#
# This service maintains a getty on ttyS0 from the point the system is
# started until it is shut down again.

start on runlevel [2345] and (
\tnot-container or
\tcontainer CONTAINER=lxc or
\tcontainer CONTAINER=lxc-libvirt)
 
stop on runlevel [!2345]
  
respawn
exec /sbin/getty -8 -L 115200 ttyS0 ansi
EOF
 
	start ttyS0

	# Apply BIOS changes to allow console serial redirection over DRAC
	/opt/dell/srvadmin/bin/omconfig chassis biossetup attribute=extserial setting=rad
	/opt/dell/srvadmin/bin/omconfig chassis biossetup attribute=fbr setting=115200
	/opt/dell/srvadmin/bin/omconfig chassis biossetup attribute=serialcom setting=com2
	/opt/dell/srvadmin/bin/omconfig chassis biossetup attribute=crab setting=enabled
 
	# Apply DRAC settings to allow console serial redirection over DRAC
	/opt/dell/srvadmin/sbin/racadm config -g cfgSerial -o cfgSerialBaudRate 115200
	/opt/dell/srvadmin/sbin/racadm config -g cfgSerial -o cfgSerialConsoleEnable 1
	/opt/dell/srvadmin/sbin/racadm config -g cfgSerial -o cfgSerialSshEnable 1
	/opt/dell/srvadmin/sbin/racadm config -g cfgSerial -o cfgSerialHistorySize 2000
}
 
update_kernel () {
	# TODO: Wrap these updates into functions so that if a certain parameter is passed it will skip updating the system.
	# Update kernel from 3.2 > 3.8
	apt-get-update && apt-get install -y --install-recommends linux-generic-lts-raring
}

update_os () {
	# Ensure necessary packages are installed and up to date, and install Dell OpenManage for Ubuntu
	apt-get update && apt-get -y dist-upgrade
}

install_tools () {
	apt-get update && apt-get install -y dsh curl ethtool ifenslave vim sysstat linux-crashdump
	sed -i 's/ENABLED=\"false\"/ENABLED=\"true\"/' /etc/default/sysstat
}

install_dell_om () {
	echo 'deb http://linux.dell.com/repo/community/deb/latest /' > /etc/apt/sources.list.d/linux.dell.com.list
	gpg --keyserver pool.sks-keyservers.net --recv-key 1285491434D8786F
	gpg -a --export 1285491434D8786F | sudo apt-key add -
	apt-get update && apt-get -y install srvadmin-all
	service dataeng start

	# Give OpenManage services chance to start
	sleep 35

	# Enable the performance profile in the BIOS
	/opt/dell/srvadmin/bin/omconfig chassis biossetup attribute=SysProfile setting=PerfOptimized
	sleep 10
}

networking
volumes
modules
update_kernel
update_os
install_tools
install_dell_om
sol

# Apply kernel update with reboot
reboot

exit

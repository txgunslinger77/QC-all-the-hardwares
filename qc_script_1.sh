#!/bin/bash

#               QC
#                          ,,
#                         ';;
#                          ''
#            ____          ||
#           ;    \         ||
#            \,---'-,-,    ||
#            /     (  o)   ||
#          (o )__,--'-' \  ||
#,,,,       ;'uuuuu''   ) ;;
#\   \      \ )      ) /\//
# '--'       \'nnnnn' /  \
#   \\      //'------'    \
#    \\    //  \           \
#     \\  //    )           )
#      \\//     |           |
#       \\     /            |
#
#          ALL THE HARDWARES

# USAGE:
# ./qc.sh [options] [MGMT Subnet address]

# TODO: Sanitize script so that it can be run repeatedly

###Default Params, overriden by cli options passed

networking="true"
resize_swap="false"
upgrade_os="true"
upgrade_kernel="false"
dell_om="true"
sol="true"
restart_node="false"
modules="true"
MGMT_SUBNET="10.240.0.0/22"

OMCONFIG_BIN="/opt/dell/srvadmin/bin/omconfig"
RACADM_BIN="/opt/dell/srvadmin/bin/omconfig"

args=($@)

usage () {
	cat << EOF
Usage: qc [ OPTIONS ] [ MGMT_IP ]
where OPTIONS := {
			--without-networking, -n
			--resize-swap, -r
			--without-system-upgrade, -u
			--kernel-upgrade, -k
			--without-dell-om, -d
			--without-serail-setup, -s
			--no-restart
		}

examples:
	Full Install
		./qc -r -k

	Full Install with uncommon MGMT
		./qc -r -k 10.12.0.0/21

	Partial Install with garunteed no restart
		./qc --no-restart
EOF
}

parameters () {
	# Parse shell script parameters
	# We use "false" instead of a boolean for readability

	while getopts ":afhrt" opt; do
		case "$opt" in
		d)
			distro_update=1
			;;
		k)
			kernel_update=1
			;;
		m)
			modules=1
			;;
		n)
			networking=1
			;;
		o)
			dell_om=1
			;;
		r)
			lvm_resize=1
			;;

		s)
			sol=1
			;;

		h)
			usage
			exit 0
			;;
		\?)
			echo "Invalid option: -$OPTARG" >&2
			usage
			exit 1
			;;
		esac
	done
}

bdf_sort () {
	# This sorts by using some sed magic. It view groups as lines with
	# breaks in between them. It uses "vertical tabs" to allow sorting.
	# This only sorts based on the first line in each group. See Sam Yaple
	# if it needs to sort by a line other than the first one.

	# This does require Ubuntu to generate comment lines with "PCI device 
	# $attr{vendor}:$attr{device} ($driver)". I think 14.04 changes this.
	# Works great on 12.04

	# Sort by PCI BDF notation
	sed -r ':r;/(^|\n)$/!{$!{N;br}};s/\n/\v/g' "${BAK_UDEV_NET}"	    | \
	sort								    | \
	sed 's/\v/\n/g'							    | \
	awk '/SUBSYSTEM/ {print $0}'					    | \
	awk 'BEGIN {i=0} {sub(/eth[0-9].*$/,"eth"i"\"") ; i++} {print $0}' \
								> "${UDEV_NET}"
}

bdf_mac_sort () {
	# Sort by PCI BDF notation, use Bus Device then MAC address for sorting
	for MAC_VEN in $(
	       sed -r ':r;/(^|\n)$/!{$!{N;br}};s/\n/\v/g' "${BAK_UDEV_NET}" | \
	       sort  							    | \
	       sed 's/\v/\n/g'						    | \
	       awk -F\" '/SUBSYSTEM/ {print $8}'			    | \
	       awk -F: '{print $1":"$2":"$3}'				    | \
	       uniq
			); do
	       			grep "${MAC_VEN}" "${BAK_UDEV_NET}" | sort;
	       done | \
	 awk 'BEGIN {i=0} {sub(/eth[0-9].*$/,"eth"i"\"") ; i++} {print $0}' \
								> "${UDEV_NET}"
}

udev_fix () {
	UDEV_NET=/etc/udev/rules.d/70-persistent-net.rules
	BAK_UDEV_NET=/root/70-persistent-net.rules.bak

	# Remove existing rule and regenerate 70-persistent-net.rules with PCI
	# names in comments
	rm "${UDEV_NET}"
	udevadm trigger --action=add
	udevadm settle
	# Dont trust udev! It says it has finished when it hasn't!
	sleep 2
	udevadm settle

	cp "${UDEV_NET}" "${BAK_UDEV_NET}"

	# TODO: Using BDF MAC sorting as I believe that is the correct way.
	# Still need to verify
	bdf_mac_sort

	# You need to reboot now, but wait until you are sure rearranging the
	# names isn't going to hose your access when you reboot.
}

interfaces_fix () {
	# TODO: Generate /etc/network/interfaces
	echo I did nothing
}

hosts_fix () {
	# Standardize /etc/hosts and /etc/hostname
	HOSTS="/etc/hosts"
	HOSTS_BAK="/root/hosts.bak"
	HOST="$(echo ${RS_SERVER_NAME} | awk -F. '{print $1}')"
	FQDN="${RS_SERVER_NAME}"
	MGMT_SUBNET="$(echo ${1:-10.240.0.0} | awk -F. '{print $1"."$2}')"
	ADDRESS=$(ip a | awk '/inet '"${MGMT_SUBNET}"'/ \
				{sub(/\/[0-9]+$/, "", $2); print $2; exit}')

	if [[ -z "${ADDRESS}" ]]; then
		ADDRESS=$(ip a | awk '/inet 10/ {sub(/\/[0-9]+$/, "", $2); \
							print $2; exit}')
		echo "Failed to get management ip address. Assuming \
					${ADDRESS} is the management ip"
	fi
	
	cp "${HOSTS}" "${HOSTS_BAK}"

	cat << EOF > "${HOSTS}"
127.0.0.1	localhost.localdomain localhost
${ADDRESS}	${FQDN} ${HOST}
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
	# Resize any swap disks larger than 8GB to 8GB
	# TODO Run only if swap00 > 7G

	swapoff /dev/mapper/vglocal00-swap00
	lvresize -f -L8G /dev/vglocal00/swap00
	mkswap /dev/mapper/vglocal00-swap00
	swapon -a
	lvresize -l+100%FREE /dev/mapper/vglocal00-root00
	resize2fs /dev/mapper/vglocal00-root00 
}

modules () {
	# Un-blacklist Modules - Line will only modify file if file exists \
	# and blacklist e1000e or blacklist ixgbe exists at the beginning \ 
	# of a line.

	BLACKLIST="/etc/modprobe.d/blacklist.local.conf"
	if [ -a "${BLACKLIST}" ]; then
		sed -i 's/^blacklist e1000e/#blacklist e1000e/g' "${BLACKLIST}"
		sed -i 's/^blacklist ixgbe/#blacklist ixgbe/g' "${BLACKLIST}"
	fi
	 
	# TODO (Thomas M. / Charles F.): Need to upgrade ixgbe version here
	# Add bonding and NIC modules to /etc/modules file
	# We only need to add these lines if they don't exist. No need to add
	# them repeatedly if the script is rerun

	MODULES="/etc/modules"
	grep -q '^bonding$' "${MODULES}" || echo 'bonding' >> "${MODULES}"
	grep -q '^e1000e$' "${MODULES}" || echo 'e1000e' >> "${MODULES}"
	grep -q '^ixgbe$' "${MODULES}" || echo 'ixgbe' >> "${MODULES}"
 
	modprobe bonding; modprobe e1000e; modprobe ixgbe
}

sol () { 
	# Create file to configure console serial redirection over DRAC
	# (this will allow access to DRAC from your terminal session window)

	# This is set manually since it doesn't exist in $PATH sometimes
	OMCONFIG_BIN="/opt/dell/srvadmin/bin/omconfig"
	RACADM_BIN="/opt/dell/srvadmin/sbin/racadm"
	
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

	# Apply BIOS changes to allow console serial redirection over DRAC

	"${OMCONFIG_BIN}" chassis biossetup attribute=extserial setting=rad
	"${OMCONFIG_BIN}" chassis biossetup attribute=fbr setting=115200
	"${OMCONFIG_BIN}" chassis biossetup attribute=serialcom setting=com2
	"${OMCONFIG_BIN}" chassis biossetup attribute=crab setting=enabled
 
	# Apply DRAC settings to allow console serial redirection over DRAC

	"${RACADM_BIN}" config -g cfgSerial -o cfgSerialBaudRate 115200
	"${RACADM_BIN}" config -g cfgSerial -o cfgSerialConsoleEnable 1
	"${RACADM_BIN}" config -g cfgSerial -o cfgSerialSshEnable 1
	"${RACADM_BIN}" config -g cfgSerial -o cfgSerialHistorySize 2000
}
 
update_kernel () {
	# Update kernel from 3.2 > 3.8

	apt-get update
	apt-get install -y --install-recommends linux-generic-lts-raring
}

update_distro () {
	# Ensure necessary packages are installed and up to date

	apt-get update && apt-get -y dist-upgrade
}

install_tools () {
	# TODO: Should we still allow this even if we don't upgrade OS?
	# I think yes

	apt-get update && apt-get install -y dsh curl ethtool ifenslave vim \
							sysstat linux-crashdump
	sed -i 's/ENABLED=\"false\"/ENABLED=\"true\"/' /etc/default/sysstat
}

install_dell_om () {
	# The precise repo has been show to work on trusty. The 740 ensures it is v7.4
	echo 'deb http://linux.dell.com/repo/community/ubuntu precise openmange/740' \
				> /etc/apt/sources.list.d/linux.dell.com.list
	gpg --keyserver pool.sks-keyservers.net --recv-key 1285491434D8786F
	gpg -a --export 1285491434D8786F | sudo apt-key add -
	apt-get update && apt-get -y install srvadmin-all
	service dataeng start

	# Give OpenManage services chance to start
	sleep 35

	# Enable the HT and performance profile in the BIOS
	"${OMCONFIG_BIN}" chassis biossetup attribute=cpuht setting=enabled
	"${OMCONFIG_BIN}" chassis biossetup attribute=SysProfile \
							setting=PerfOptimized
	sleep 10

	# Serial console setup
	sol
}

restart_node () {
	reboot
}

parameters

[[ "${networking}" -eq 1 ]] && networking
[[ "${volumes}" -eq 1 ]] && volumes
[[ "${modules}" -eq 1 ]] && modules
[[ "${update_kernel}" -eq 1 ]] && update_kernel
[[ "${update_distro}" -eq 1 ]] && update_os
[[ "${install_tools}" -eq 1 ]] && install_tools
[[ "${install_dell_om}" -eq 1 ]] && install_dell_om

[[ "${restart}" -eq 1 ]] && restart_node

exit

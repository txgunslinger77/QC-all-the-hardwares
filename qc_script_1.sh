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

OMCONFIG_BIN="/opt/dell/srvadmin/bin/omconfig"
RACADM_BIN="/opt/dell/srvadmin/sbin/racadm"

usage () {
	cat << EOF
Usage: qc [ OPTIONS ]
where OPTIONS := {
			-d, Distro Update
			-k, Kernel Update
			-m, /etc/modules inserts
			-n, networking -- fix it all (BROKEN)
			-o, Dell OpenManage tools
			-r, Resize swap (for preseed problems)
			-s, Serial console setup
			-t, Standard system tools
			-h, HELP! IM TRAPPED IN A SCRIPT FACTORY!
		}
EOF
}

error_check () {
        exit_status=$1
        message=$2

        if [[ $exit_status -ne 0 ]]; then
                echo "RBA START STATUS:"
                echo "FAIL"
                echo "RBA END STATUS:"
                echo "RBA START DATA:"
                echo "$message"
                echo "RBA END DATA:"

                exit 1
        fi
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

lvm_resize () { 
	# Resize swap disk larger than 8GB to 8GB

	# This returns number of sectors
	swap_size=$(lvdisplay vglocal00/swap00 -c | awk -F: '{print $7}')

	echo "Swap is currently ${swap_size}"

	# 8GiB / 512 byte sectors = 16777216 sectors
	if [[ "${swap_size}" -gt 16777216 ]]; then
		echo "Swap is going to resize"
		swapoff /dev/mapper/vglocal00-swap00
		lvresize -f -L8G /dev/vglocal00/swap00
		mkswap /dev/mapper/vglocal00-swap00
		swapon -a
		lvresize -l+100%FREE /dev/mapper/vglocal00-root00
		resize2fs /dev/mapper/vglocal00-root00
		echo "Swap is now ${swap_size}"
	else
		echo "Swap is not resizing"
	fi
}

modules () {
	# Un-blacklist Modules - Line will only modify file if file exists
	# and blacklist e1000e or blacklist ixgbe exists at the beginning 
	# of a line.

	BLACKLIST="/etc/modprobe.d/blacklist.local.conf"
	echo "Removing blacklisted modules from ${BLACKLIST} if they exist"
	if [ -a "${BLACKLIST}" ]; then
		sed -i 's/^blacklist e1000e/#blacklist e1000e/g' "${BLACKLIST}"
		sed -i 's/^blacklist ixgbe/#blacklist ixgbe/g' "${BLACKLIST}"
	fi
 
	# Add bonding and NIC modules to /etc/modules file
	# We only need to add these lines if they don't exist. No need to add
	# them repeatedly if the script is rerun

	MODULES="/etc/modules"
	echo "Inserting 'bonding' module into ${MODULES}"
	grep -q '^bonding$' "${MODULES}" && echo "'bonding' found in ${MODULES}" \
					|| echo 'bonding' >> "${MODULES}"

	echo "Inserting 'e1000e' module into ${MODULES}"
	grep -q '^e1000e$' "${MODULES}" && echo "'e1000e' found in ${MODULES}" \
					|| echo 'e1000e' >> "${MODULES}"

	echo "Inserting 'ixgbe' module into ${MODULES}"
	grep -q '^ixgbe$' "${MODULES}" && echo "'ixgbe' found in ${MODULES}" \
					|| echo 'ixgbe' >> "${MODULES}"
 
	modprobe bonding || echo "bonding module failed to load"
	modprobe e1000e || echo "e1000e module failed to load"
	modprobe ixgbe || echo "ixgbe module failed to load"
}

serial () { 
	# Create file to configure console serial redirection over DRAC
	# (this will allow access to DRAC from your terminal session window)

	SOL_CONF="/etc/init/ttyS0.conf"

	echo "Creating or overwriting ${SOL_CONF} to allow serial redirection"
	cat << EOF > "${SOL_CONF}"
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

	echo "Configuring chassis for serial redirection"

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
 
kernel_update () {
	# Update kernel from 3.2 > 3.8

	echo "Current kernel version: $(uname -r)"
	echo "Attempting to install newer kernel..."
	apt-get update
	apt-get install -y --install-recommends linux-generic-lts-raring
}

distro_update () {
	# Ensure necessary packages are installed and up to date

	echo "Installing any Distro upgrades that are available"
	apt-get update
	apt-get -y dist-upgrade
}

tools_install () {
	# Setup basic tools

	apt-get update
	apt-get install -y dsh curl ethtool ifenslave vim sysstat linux-crashdump
	sed -i 's/ENABLED=\"false\"/ENABLED=\"true\"/' /etc/default/sysstat
}

dell_om_install () {
	# Install OpenManage 7.4 from dell
	echo ###############################################################################
	echo "Installing Dell OpenManage 7.4"
	echo ###############################################################################
	# The precise repo has been show to work on trusty. The 740 ensures it is v7.4
	echo 'deb http://linux.dell.com/repo/community/ubuntu precise openmanage/740' \
				> /etc/apt/sources.list.d/linux.dell.com.list
	gpg --keyserver pool.sks-keyservers.net --recv-key 1285491434D8786F
	gpg -a --export 1285491434D8786F | sudo apt-key add -
	apt-get update
	apt-get -y install srvadmin-all
	service dataeng start

	# Give OpenManage services chance to start
	sleep 35

	echo ###############################################################################
	echo "Enabling Hyperthreading..."
	echo ###############################################################################
	# Enable the HT in the BIOS
	"${OMCONFIG_BIN}" chassis biossetup attribute=cpuht setting=enabled

	# TODO: Check if node is R710 and don't run; This causes the script to FAIL
	echo ###############################################################################
	echo "Enabling PerfOptimized to prevent phantom load issue"
	echo "This will fail on R710 nodes, it is safe to ignore"
	echo ###############################################################################
	# Enable performance profile, this fails on R710s "with unknown attribute"
	"${OMCONFIG_BIN}" chassis biossetup attribute=SysProfile \
							setting=PerfOptimized
	sleep 10
}

restart_node () {
	reboot
}


###############################################################################
#
#				Main
#
###############################################################################

# Parse shell script parameters

while getopts ":dkmnorsth" opt; do
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
		dell_om_install=1
		;;
	r)
		lvm_resize=1
		;;
	s)
		serial=1
		;;
	t)
		tools_install=1
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

# Setting up the directory used for logging
LOG_DIR="/home/rack/qc_logs_$(date +%s)"
LOG_DIR_LATEST="/home/rack/qc_logs_latest"
mkdir -p "${LOG_DIR}"
ln -sf "${LOG_DIR}" "${LOG_DIR_LATEST}"

# List of all valid functions. If you want it to be executed, it need to be here.
# Order matters if you are passing multiple command line options
current_functions=(lvm_resize modules dell_om_install serial kernel_update distro_update tools_install)

# This will loop through the functions and execute them
# Unless logging is broken, this section should probably not been modified.
for function in "${current_functions[@]}"; do
	eval func_val=\$$function
	if [[ "${func_val}" -eq 1 ]]; then
		# The craziness here allows us to break the function if a
		# command fails without breaking the whole script
		(set -e && eval ${function} 2>&1) > "${LOG_DIR}/${function}.log"
		exit_status=$?
		set +e
		error_check "$exit_status" "${function} has failed. Please check the logs at ${LOG_DIR}/${function}.log"
	fi
done

echo "RBA START STATUS:"
echo "PASS"
echo "RBA END STATUS:"

exit 0
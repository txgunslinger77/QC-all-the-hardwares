#!/bin/bash
#
# Initial Script 2014-08-01 - Sam Yaple
#

UDEV_NET=/etc/udev/rules.d/70-persistent-net.rules
BAK_UDEV_NET=/root/70-persistent-net.rules.bak

# This sorts by using some sed magic. It view groups as lines with breaks in between them. It uses "vertical tabs" to allow sorting. This only sorts based on the first line in each group. See Sam Yaple if it needs to sort by a line other than the first one.
# This does require Ubuntu to generate comment lines with "PCI device $attr{vendor}:$attr{device} ($driver)". I think 14.04 changes this. Works great on 12.04
bdf_sort () {
        # Sort by PCI BDF notation
        sed -r ':r;/(^|\n)$/!{$!{N;br}};s/\n/\v/g' "${BAK_UDEV_NET}"    | \
        sort                                                            | \
        sed 's/\v/\n/g'                                                 | \
        awk '/SUBSYSTEM/ {print $0}'                                    | \
        awk 'BEGIN {i=0} {sub(/eth[0-9].*$/,"eth"i"\"") ; i++} {print $0}' > "${UDEV_NET}"
}

# I hate myself for using so many pipes.
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
exit

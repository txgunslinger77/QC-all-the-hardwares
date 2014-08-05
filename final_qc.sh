#!/bin/bash
#
# Initial Script 2014-08-01 - Sam Yaple
#

# This checks OS Release type, Hyperthreading, Memory, HW raid status, CPU health
# This does NOT check networking

REPORT="/root/qc_report-`date +%s`"
QC_COMPLETE="/root/qc-status-`date +%s`"

DESIRED_RELEASE="Ubuntu 12.04 x86_64"

HYPERTHREADING=$(omreport chassis processors index=0 | awk '/HT/ && $0 != "" { getline; getline; print $3}')
RELEASE=$(awk -F= '{ORS=" "} /^DISTRIB_ID=/{print $2} /^DISTRIB_RELEASE=/{print $2}' /etc/lsb-release; uname -p)
MEM_SLOTS_USED=$(omreport chassis memory | awk '/^Slots Used/ {print $4}')
MEM_SLOTS_OK=$(omreport chassis memory | awk '/^Status.*Ok$/ {print $0}' | wc -l)
RAID_STATUS=$(omreport storage vdisk controller=0 | awk '/^(Status|State|Layout)/ {printf "%s", $3} END {print}')
CPU_HEALTH=$(omreport chassis processors | awk '/^Health/ {print $3}')
CPU_HW_COUNT=$(omreport chassis processors | awk '/^Core Count/ {COUNT+=$4} END {print COUNT*2}')
CPU_OS_COUNT=$(awk '/^model name/ {print $0}' /proc/cpuinfo | wc -l)

[ "${HYPERTHREADING}" != "Yes" ] && echo "Hyperthreading Disabled" >> "${REPORT}"
[ "${RELEASE}" != "${DESIRED_RELEASE}" ] && echo "Wrong release: ${RELEASE}" >> "${REPORT}"
[ "${MEM_SLOTS_USED}" != "${MEM_SLOTS_OK}" ] && echo "There are $((MEM_SLOTS_USED-MEM_SLOTS_OK)) memory module(s) with problems" >> "${REPORT}"
[ "${RAID_STATUS}" != "OkReadyRAID-10" ] && echo "The current raid status is ${RAID_STATUS}" >> "${REPORT}"
[ "${CPU_HEALTH}" != "Ok" ] && echo "The CPU is reporting ${CPU_HEALTH}" >> "${REPORT}"
[ "${CPU_HW_COUNT}" != "${CPU_OS_COUNT}" ] && [ "${HYPERTHREADING}" != "Yes" ] && echo "The hardware is reporting ${CPU_HW_COUNT} CPUs, but the OS is only seeing ${CPU_OS_COUNT}." >> "${REPORT}"

if [[ ! -a "${REPORT}" ]]; then echo No problems detected!; else cat "${REPORT}"; fi

exit

# Once this script checks for everything, we can safely write out a qc-status file
date > "${QC_COMPLETE}"
echo SERVER QC-INTENSIFICATION COMPLETE >> "${QC_COMPLETE}"

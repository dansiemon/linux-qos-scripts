#!/bin/bash
##
# Dan Siemon <dan@coverfire.com>
# http://www.coverfire.com
#
# This script attempts to create per host fairness on the network
# and for each host three priority classes. The hierarchy looks like:
#
#                           Interface
#				|
#			     HTB 1:1
#			     /     \
#		    Host Bucket 1  .. NUM_HOST_BUCKETS [Classes 1:10-1:(10+NUM_HOST_BUCKETS)]
#		    /    |    \
#		 High  Normal Low [Priority classes are named 1:(HOST_BUCKET * 16 + 1)]
#			|
#	Flow Bucket 1  .. NUM_FLOW_BUCKETS [Flow QDiscs are named (HOST_BUCKET * 16 + 1 + 1):0]
#
# The 0->NUM_FLOW_BUCKETS exist under every high, normal and low class. SFQ, SFB and FQ_CODEL
# have embedded classes per flow and do not use NUM_FLOW_BUCKETS.
#
# Yes, the class and QDisc naming is confusing and there are probably bugs
# if you set the NUM_HOST_BUCKETS or NUM_FLOW_BUCKETS too high.
#
####
# Config
####

#TC="/usr/local/sbin/tc"
TC=`which tc`

#_DEBUG="on"
#_CDEBUG="on"

DEVICE="ppp0"

# The number of host buckets. All hosts are hashed into one of these buckets
# so you'll want this to approximate (but probably be lower) the number of hosts
# in your network.
NUM_HOST_BUCKETS=8

if [ ${NUM_HOST_BUCKETS} -gt 150 ] ; then
	# Safety valve. Script won't work after ~160 today. This is because
	# the parent class for each of the per host classes is encoded in the
	# class minor number.  This makes debugging easier but wastes the minor
	# number space.
	echo "Sorry, can't do more than 150 hosts right now."
	exit
fi

# The number of flow buckets within each high, normal and low class.
# If SFQ, SFB or FQ_CODEL are used this value is not used as these QDiscs
# have many embedded queues.
NUM_FLOW_BUCKETS=32

####
# Bandwidth rates
####
# All rates are kbit/sec.
# RATE should be set to just under your link rate.
RATE="6400"
# Below three rates should add up to RATE.
# Priority of these classes is 1 (Higest) -> 3 (Lowest)
RATE_1="2000"
RATE_2="2400"
RATE_3="2000"

####
# Queue size
####
# Size the queue. Only used with the simple FIFO QDiscs
# ie not SFQ, FQ_CODEL. Fun for experimentation but you
# probably don't want to use these simple QDiscs.
FIFO_LEN=100

####
# How often to perturb the hashes.
####
# This should probably be on the order of minutes so as to avoid the packet
# reordering which can happen when the flows are redistributed
# into different queues. Some of the new QDiscs may handle reordering properly.
#PERTURB=5
PERTURB=300

####
# Packet overhead
####
# Examples:
#   ADSL:
#	- http://www.adsl-optimizer.dk/thesis/
#	(http://web.archive.org/web/20090422131547/http://www.adsl-optimizer.dk/thesis/)
#	- If you are using ADSL you probably want LINKLAYER="atm" too.
#   VDSL2 (without ATM) w/ PPPoE:
#	- 40 bytes for 802.3
#	- 8 bytes for PPPoE
OVERHEAD=48

####
# Set linklayer to one of ethernet,adsl (adsl == atm).
####
#LINKLAYER="adsl"
LINKLAYER="ethernet"

####
# The MTU of the underlying interface.
####
MTU="1492"

####
# The keys that are used to identify individual flows.
####
# For 5-tuple (flow) fairness
#FLOW_KEYS="src,dst,proto,proto-src,proto-dst"
# For 5-tuple (flow) fairness when the same device is performing NAT
FLOW_KEYS="nfct-src,nfct-dst,nfct-proto,nfct-proto-src,nfct-proto-dst"

####
# The keys that are used to identify a host's traffic.
####
# No NAT
#HOST_KEYS="src"
# With local device doing NAT
HOST_KEYS="nfct-src"

# Set R2Q (HTB knob) low if you use low bitrates. You may see warning from the kernel
# in /var/log/messages indicating this value should be modified. If you set the
# MTU/QUANTUM changing this isn't required.
#R2Q=2

####
# Choosing the type of queue for each class
####
# For each of the traffic classes you can choose which QDisc to use by uncommenting
# the appropriate function call below.

###########################################
###########################################
# Other than picking QDisc type there is nothing to change below here.
###########################################
###########################################

######################
# Expand the config variables to tc arguments if they are defined.
######################
if [ "${OVERHEAD}" != "" ]; then
	OVERHEAD="overhead ${OVERHEAD}"
fi

if [ "${LINKLAYER}" != "" ]; then
	LINKLAYER="linklayer ${LINKLAYER}"
fi

if [ "${R2Q}" != "" ]; then
	R2Q="r2q ${R2Q}"
fi

if [ "${PERTURB}" != "" ]; then
	PERTURB="perturb ${PERTURB}"
fi

QUANTUM=${MTU}
if [ "${QUANTUM}" != "" ]; then
	QUANTUM="quantum ${QUANTUM}"
fi

######################
# Util functions
######################

function DEBUG()
{
	[ "$_DEBUG" == "on" ] && "$@"
}

# Debug function for print the tc command lines.
function CDEBUG()
{
	[ "$_CDEBUG" == "on" ] && "$@"
}

function hex_replace {
	if [[ "$1" =~ ":" ]]; then
		QDISC=${1%%:*}
		CLASS=${1##*:}

		if [ "${CLASS}" == "" ]; then
			D2H=`printf "%x:" ${QDISC}`
		else
			D2H=`printf "%x:%x" ${QDISC} ${CLASS}`
		fi
	else
		D2H=`printf "%x" $1`
	fi
}

###
# Function to wrap the tc command and convert the qdisc and class
# identifiers to hex before calling tc.
###
function tc_h {
	OUTPUT="${TC} "

	PTMP=$@
	CDEBUG printf "Command before: %s\n" "${PTMP}"

	while [ "$1" != "" ]; do
		case "$1" in
			"classid" | "flowid" | "parent" | "baseclass" | "handle")
				hex_replace $2

				OUTPUT="${OUTPUT} $1 ${D2H} "
				shift
				;;
			* )
				OUTPUT="${OUTPUT} $1 "
		esac

		shift
	done

	CDEBUG printf "Command after: ${OUTPUT}\n"
	${OUTPUT}
}

######################
# Functions to create QDiscs at the leaves.
######################

function drr {
	PARENT=$1
	HANDLE=$2

	# Create the QDisc.
	tc_h qdisc add dev ${DEVICE} parent ${PARENT} handle ${HANDLE} drr

	# Create NUM_FLOW_BUCKETS classes and add a pfifo_head_drop to each.
	for J in `seq ${NUM_FLOW_BUCKETS}`; do
		tc_h class add dev ${DEVICE} parent ${HANDLE} classid ${HANDLE}:${J} drr ${QUANTUM}
		tc_h qdisc add dev ${DEVICE} parent ${HANDLE}:${J} pfifo_head_drop limit ${FIFO_LEN}
	done

	# Add a filter to direct the packets.
	tc_h filter add dev ${DEVICE} prio 1 protocol ip parent ${HANDLE}: handle 1 flow hash keys ${FLOW_KEYS} divisor ${NUM_FLOW_BUCKETS} ${PERTURB} baseclass ${HANDLE}:1
}

function sfq {
	PARENT=$1
	HANDLE=$2
	DEBUG printf "\t\t\tsfq parent %s handle %s\n" ${PARENT} ${HANDLE}

	#tc_h qdisc add dev ${DEVICE} parent ${PARENT} handle ${HANDLE} sfq limit ${FIFO_LEN} ${QUANTUM} divisor 1024
	tc_h qdisc add dev ${DEVICE} parent ${PARENT} handle ${HANDLE} sfq ${QUANTUM} divisor 1024

	# Don't use the SFQ default classifier.
	tc_h filter add dev ${DEVICE} prio 1 protocol ip parent ${HANDLE}: handle 1 flow hash keys ${FLOW_KEYS} divisor 1024 ${PERTURB} baseclass ${HANDLE}:1
}

function fq_codel {
	PARENT=$1
	HANDLE=$2
	DEBUG printf "\t\t\tfq_codel parent %s handle %s\n" ${PARENT} ${HANDLE}

	tc_h qdisc add dev ${DEVICE} parent ${PARENT} handle ${HANDLE} fq_codel ${QUANTUM} flows 4096

	# Don't use the default classifier.
	tc_h filter add dev ${DEVICE} prio 1 protocol ip parent ${HANDLE}: handle 1 flow hash keys ${FLOW_KEYS} divisor 4096 ${PERTURB} baseclass ${HANDLE}:1
}

function sfb {
	PARENT=$1
	HANDLE=$2

	#tc_h qdisc add dev ${DEVICE} parent ${PARENT} handle ${HANDLE} sfb
	tc_h qdisc add dev ${DEVICE} parent ${PARENT} handle ${HANDLE} sfb target 20 max 25 increment 0.005 decrement 0.0001

	# TODO - Should this have divisor?
	tc_h filter add dev ${DEVICE} prio 1 protocol ip parent ${HANDLE}: handle 1 flow hash keys ${FLOW_KEYS} divisor 1024 ${PERTURB}
}

function pfifo_head_drop {
	PARENT=$1
	HANDLE=$2

	tc_h qdisc add dev ${DEVICE} parent ${PARENT} handle ${HANDLE} pfifo_head_drop limit ${FIFO_LEN}
}

function pfifo {
	PARENT=$1
	HANDLE=$2

	tc_h qdisc add dev ${DEVICE} parent ${PARENT} handle ${HANDLE} pfifo limit ${FIFO_LEN}
}

######################
# The real work starts here.
######################

# Calculate the divided rate values for use later.
DIV_RATE=`expr ${RATE} / ${NUM_HOST_BUCKETS}`
DIV_RATE_1=`expr ${RATE_1} / ${NUM_HOST_BUCKETS}`
DIV_RATE_2=`expr ${RATE_2} / ${NUM_HOST_BUCKETS}`
DIV_RATE_3=`expr ${RATE_3} / ${NUM_HOST_BUCKETS}`

echo "Number of host buckets: ${NUM_HOST_BUCKETS}"
echo "Rate per host (DIV_RATE):" ${DIV_RATE}
echo "High priority rate per host (DIV_RATE_1):" ${DIV_RATE_1}
echo "Normal priority rate per host (DIV_RATE_2):" ${DIV_RATE_2}
echo "Low priority rate per host (DIV_RATE_3):" ${DIV_RATE_3}

# Delete any existing qdiscs if they exist.
tc_h qdisc del dev ${DEVICE} root

# HTB QDisc at the root. Default all traffic into the prio qdisc.
tc_h qdisc add dev ${DEVICE} root handle 1: htb ${R2Q}

# Create a top level class with the max rate.
tc_h class add dev ${DEVICE} parent 1: classid 1:1 htb rate ${RATE}kbit ${QUANTUM} prio 0 ${LINKLAYER} ${OVERHEAD}

######
# Create NUM_HOST_BUCKETS classes within the top-level class.
# Within each of these create three priority classes.
######
for HOST_NUM in `seq ${NUM_HOST_BUCKETS}`; do
	DEBUG printf "Create host class: %i\n" $HOST_NUM

	QID=`expr ${HOST_NUM} '+' 9` # 1+9=10 - Start host buckets at 10. Arbitrary.
	DEBUG printf "\tQID: %i\n" ${QID}
	tc_h class add dev ${DEVICE} parent 1:1 classid 1:${QID} htb rate ${DIV_RATE}kbit ceil ${RATE}kbit ${QUANTUM} prio 0 ${LINKLAYER} ${OVERHEAD}

	######
	# Within each host bucket add three sub-classes, high, normal and low priority.
	# Priority classes are named 1:[HOST_BUCKET * 16 + 1]
	# Why 16? Because tc shows major:minor in hex so this makes it easy to match
	# the three sub class to the parent host bucket.
	#
	# Within each priority class uncomment one of the QDisc types.
	######

	###
	# High priority class
	###
	QID_1=`expr $QID '*' 16 + 0`
	DEBUG printf "\t\tHigh: %i\n" ${QID_1}
	tc_h class add dev ${DEVICE} parent 1:${QID} classid 1:${QID_1} htb rate ${DIV_RATE_1}kbit ceil ${RATE}kbit ${QUANTUM} prio 0 ${LINKLAYER} ${OVERHEAD}

	# Choose one of the below QDiscs for this class.
	#drr 1:${QID_1} ${QID_1}
	#sfq 1:${QID_1} ${QID_1}
	fq_codel 1:${QID_1} ${QID_1}
	#sfb 1:${QID_1} ${QID_1}
	#pfifo_head_drop 1:${QID_1} ${QID_1}
	#pfifo 1:${QID_1} ${QID_1}

	###
	# Normal priority class
	###
	QID_2=`expr $QID '*' 16 + 1`
	DEBUG printf "\t\tNormal: %i\n" ${QID_2}
	tc_h class add dev ${DEVICE} parent 1:${QID} classid 1:${QID_2} htb rate ${DIV_RATE_2}kbit ceil ${RATE}kbit ${QUANTUM} prio 1 ${LINKLAYER} ${OVERHEAD}

	# Choose one of the below QDiscs for this class.
	#drr 1:${QID_2} ${QID_2}
	#sfq 1:${QID_2} ${QID_2}
	fq_codel 1:${QID_2} ${QID_2}
	#sfb 1:${QID_2} ${QID_2}
	#pfifo_head_drop 1:${QID_2} ${QID_2}
	#pfifo 1:${QID_2} ${QID_2}

	###
	# Low priority class
	###
	QID_3=`expr $QID '*' 16 + 2`
	DEBUG printf "\t\tLow: %i\n" ${QID_3}
	tc_h class add dev ${DEVICE} parent 1:${QID} classid 1:${QID_3} htb rate ${DIV_RATE_3}kbit ceil ${RATE}kbit ${QUANTUM} prio 2 ${LINKLAYER} ${OVERHEAD}

	# Choose one of the below QDiscs for this class.
	#drr 1:${QID_3} ${QID_3}
	#sfq 1:${QID_3} ${QID_3}
	fq_codel 1:${QID_3} ${QID_3}
	#sfb 1:${QID_3} ${QID_3}
	#pfifo_head_drop 1:${QID_3} ${QID_3}
	#pfifo 1:${QID_3} ${QID_3}


	######
	# Add filters to classify based on the TOS bits.
	# Only mask against the three (used) TOS bits. The final two bits are used for ECN.
	# TOS field is XXXDTRXX.
	# X= Not part of the TOS field.
	# D= Delay bit
	# T= Throughput bit
	# R= Reliability bit
	#
	# OpenSSH terminal sets D.
	# OpenSSH SCP/SFTP sets T.
	# It's easy to configure the Transmission Bittorrent client to set T (settings.json).
	# For home VoIP devices use an Iptables rule to set all of their traffic to have D.
	#
	# The thinking behind the below rules is to use D as an indication of delay sensitive
	# and T as an indication of background (big transfer). All other combinations are put into
	# default which is effectively a medium priority.
	######
	DEBUG printf "\t\tCreating filters\n"

	# D bit set.
	tc_h filter add dev ${DEVICE} parent 1:${QID} protocol ip prio 10 u32 match ip tos 0x10 0x1c flowid 1:${QID_1}

	# Diffserv expedited forwarding. Put this in the high priority class.
	# Some VoIP clients set this (ie Ekiga).
	# DSCP=b8
	tc_h filter add dev ${DEVICE} parent 1:${QID} protocol ip prio 10 u32 match ip tos 0xb8 0xfc flowid 1:${QID_1}

	# T bit set.
	tc_h filter add dev ${DEVICE} parent 1:${QID} protocol ip prio 10 u32 match ip tos 0x08 0x1c flowid 1:${QID_3}

	# Everything else into default.
	tc_h filter add dev ${DEVICE} parent 1:${QID} protocol ip prio 10 u32 match ip tos 0x00 0x00 flowid 1:${QID_2}
done

# Send everything that hits the top level QDisc to the top class.
tc_h filter add dev ${DEVICE} prio 1 protocol ip parent 1:0 u32 match u32 0 0 flowid 1:1

# From the top level class hash into the host classes.
tc_h filter add dev ${DEVICE} prio 1 protocol ip parent 1:1 handle 1 flow hash keys ${HOST_KEYS} divisor ${NUM_HOST_BUCKETS} ${PERTURB} baseclass 1:10

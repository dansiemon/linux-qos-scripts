#!/bin/bash
##
# Dan Siemon <dan@coverfire.com>
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
#		 High  Normal Low [Priority classes are named 1:(HOST_BUCKET * 100 + 1)]
#			|
#	Flow Bucket 1  .. NUM_FLOW_BUCKETS [Flow QDiscs are named (HOST_BUCKET * 100 + 1 + 1):0]
#
# The 0->NUM_FLOW_BUCKETS exist under every high, normal and low class.
#
# Yes, the class and QDisc naming is confusing and there are probably bugs
# if you set the NUM_HOST_BUCKETS or NUM_FLOW_BUCKETS too high.
#
# The traffic is directed into the High, Normal and Low classes within each host bucket
# based on the value of the TOS bits (see the comment below).The key thing to note is
# that a malicious user who sets all of their traffic to high priority does not cause
# any problems for other users, only themselves. This additional restriction makes TOS
# based classification usable.
#
##
# Config
# Other than the variables in the top secton of this script you'll
# also want to remove 'linklayer adsl' if you aren't using ATM
# (most DSL types use ATM).
##

DEVICE="tunl1"

# The number of host buckets. All hosts are hashed into one of these buckets
# so you'll want this to approximate (but probably be lower) the number of hosts
# in your network.
NUM_HOST_BUCKETS=8

# The number of flow buckets within each high, normal and low class.
# Not sure what's the best way to determine this value.
# If SFQ or SFB are used below this value is not used.
NUM_FLOW_BUCKETS=32

# All rates are kbit/sec.
# RATE should be set to just under your upload link rate.
RATE="700"
# Below three rates should add up to RATE.
# Priority of these classes is 1 (Higest) -> 3 (Lowest)
RATE_1="180"
RATE_2="320"
RATE_3="200"

# Size the queues for sane latency.
# Ex: 3 * 1436 = 4308 / (700000 / 8) = 49ms
FIFO_LEN=3

# How often to perturb the hashes.
PERTURB=60
#PERTURB=3000

# PPPoE overhead is 40 bytes (http://www.adsl-optimizer.dk/thesis/)
# 20 bytes for IPIP tunnel
OVERHEAD=60

# Set R2Q (HTB knob) low because of the low bitrates.
# If your rates aren't low you might not need this. Remove it from the
# HTB line below.
R2Q=2

# The MTU of the underlying interface.
MTU="1436"

###########################################
###########################################

# TC QDisc and class IDs are in hex.
function dec_to_hex {
	echo `printf %x $1`
}

function drr {
	PARENT=$1
	HANDLE=$2

	# Create the QDisc.
	tc qdisc add dev ${DEVICE} parent ${PARENT} handle ${HANDLE} drr

	# Create NUM_FLOW_BUCKETS classes.
	for J in `seq ${NUM_FLOW_BUCKETS}`; do
		tc class add dev ${DEVICE} parent ${HANDLE} classid ${HANDLE}:`dec_to_hex ${J}` drr quantum ${MTU}
		tc qdisc add dev ${DEVICE} parent ${HANDLE}:`dec_to_hex ${J}` pfifo limit ${FIFO_LEN}
	done

	# Add a filter to direct the packets.
	tc filter add dev ${DEVICE} prio 1 protocol ip parent ${HANDLE}: handle 1 flow hash keys nfct-src,nfct-dst,proto,nfct-proto-src,nfct-proto-dst divisor ${NUM_FLOW_BUCKETS} perturb ${PERTURB} baseclass ${HANDLE}:1
}

function sfq {
	PARENT=$1
	HANDLE=$2

	tc qdisc add dev ${DEVICE} parent ${PARENT} handle ${HANDLE} sfq perturb ${PERTURB} limit ${FIFO_LEN}
}

function sfb {
	PARENT=$1
	HANDLE=$2

	tc qdisc add dev ${DEVICE} parent ${PARENT} handle ${HANDLE} sfb
}

# Get the dividied rate values for use later.
DIV_RATE=`expr ${RATE} / ${NUM_HOST_BUCKETS}`
DIV_RATE_1=`expr ${RATE_1} / ${NUM_HOST_BUCKETS}`
DIV_RATE_2=`expr ${RATE_2} / ${NUM_HOST_BUCKETS}`
DIV_RATE_3=`expr ${RATE_3} / ${NUM_HOST_BUCKETS}`

echo "DIV_RATE:" ${DIV_RATE}
echo "DIV_RATE_1:" ${DIV_RATE_1}
echo "DIV_RATE_2:" ${DIV_RATE_2}
echo "DIV_RATE_3:" ${DIV_RATE_3}

# Delete the existing qdiscs etc if they exist.
tc qdisc del dev ${DEVICE} root

# HTB QDisc at the root. Default all traffic into the prio qdisc.
tc qdisc add dev ${DEVICE} root handle 1: htb r2q ${R2Q}

# Create a top level class with the max rate.
tc class add dev ${DEVICE} parent 1: classid 1:1 htb rate ${RATE}kbit linklayer adsl overhead ${OVERHEAD}

###
# Create NUM_HOST_BUCKETS classes within the top-level class.
###
for HOST_NUM in `seq ${NUM_HOST_BUCKETS}`; do
	echo "Create host class:" $HOST_NUM

	QID=`expr ${HOST_NUM} '+' 9` # 1+9=10 - Start classes at 10.
	tc class add dev ${DEVICE} parent 1:1 classid 1:${QID} htb rate ${DIV_RATE}kbit ceil ${RATE}kbit prio 0 linklayer adsl overhead ${OVERHEAD}

	###
	# Within each host bucket add three classes, high, normal and low priority.
	# Priority classes are named 1:[HOST_BUCKET * 100 + 1]
	###
	QID_1=`expr $QID '*' 100 + 1`
	tc class add dev ${DEVICE} parent 1:${QID} classid 1:${QID_1} htb rate ${DIV_RATE_1}kbit ceil ${RATE}kbit prio 0 linklayer adsl overhead ${OVERHEAD}
	QID_2=`expr $QID '*' 100 + 2`
	tc class add dev ${DEVICE} parent 1:${QID} classid 1:${QID_2} htb rate ${DIV_RATE_2}kbit ceil ${RATE}kbit prio 1 linklayer adsl overhead ${OVERHEAD}
	QID_3=`expr $QID '*' 100 + 3`
	tc class add dev ${DEVICE} parent 1:${QID} classid 1:${QID_3} htb rate ${DIV_RATE_3}kbit ceil ${RATE}kbit prio 2 linklayer adsl overhead ${OVERHEAD}

	###
	# Within each priority class add a QDisc for flow fairness.
	###
	QID_1_1=`expr ${QID_1} + 1`
	drr 1:${QID_1} ${QID_1_1}
	#sfq 1:${QID_1} ${QID_1_1}
	#sfb 1:${QID_1} ${QID_1_1}

	QID_2_1=`expr ${QID_2} + 1`
	drr 1:${QID_2} ${QID_2_1}
	#sfq 1:${QID_2} ${QID_2_1}
	#sfb 1:${QID_2} ${QID_2_1}

	QID_3_1=`expr ${QID_3} + 1`
	drr 1:${QID_3} ${QID_3_1}
	#sfq 1:${QID_3} ${QID_3_1}
	#sfb 1:${QID_3} ${QID_3_1}

	###
	# Add filters to classify based on the TOS bits.
	# Only mask against the three (used) TOS bits. The final two bits are used for ECN.
	# TOS field is XXXDTRXX.
	# X= Not part of the TOS field.
	# D= Delay bit
	# T= Throughput bit
	# R= Reliability bit
	#
	# OpenSSH terminal sets D.
	# OpenSSH SCP sets T.
	# It's easy to configure the Transmission Bittorrent client to set T (settings.json).
	# For home VoIP devices use an Iptables rule to set all of their traffic to have D.
	#
	# The thinking behind the below rules is to use D as an indication of delay sensitive
	# and T as an indication of background (big transfer). All other combinations are put into
	# default which is effectively a medium priority.
        #
        # Why is this OK? Because this only changes the priority *within the sources own* traffic.
        # That is, a malicious who sets all their traffic to high priority only hurts themselves
        # no one else.
	###

	# D bit set.
	tc filter add dev ${DEVICE} parent 1:${QID} protocol ip prio 10 u32 match ip tos 0x10 0x1c flowid 1:${QID_1}

	# T bit set.
	tc filter add dev ${DEVICE} parent 1:${QID} protocol ip prio 10 u32 match ip tos 0x08 0x1c flowid 1:${QID_3}

	# Diffserv expedited forwarding. Put this in the high priority class.
	# Some VoIP clients set this (ie Ekiga).
	# DSCP=b8
	tc filter add dev ${DEVICE} parent 1:${QID} protocol ip prio 10 u32 match ip tos 0xb8 0xfc flowid 1:${QID_1}

	# Everything else into default.
	tc filter add dev ${DEVICE} parent 1:${QID} protocol ip prio 10 u32 match ip tos 0x00 0x00 flowid 1:${QID_2}
done

# Send everything that hits the top level QDisc to the top class.
tc filter add dev ${DEVICE} prio 1 protocol ip parent 1:0 u32 match u32 0 0 flowid 1:1

# From the top level class hash into the host classes.
tc filter add dev ${DEVICE} prio 1 protocol ip parent 1:1 handle 1 flow hash keys nfct-src divisor ${NUM_HOST_BUCKETS} perturb ${PERTURB} baseclass 1:10

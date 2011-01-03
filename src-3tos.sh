#!/bin/bash

DEVICE="ppp0"
NUM_HOST_BUCKETS=4
NUM_FLOW_BUCKETS=64

# All rates are kbit/sec.
# RATE should be set to just under your upload link rate.
RATE="620"
# TODO - take RATE /3 to get the below ??
# Below three rates should add up to RATE.
RATE_1="220"
RATE_2="220"
RATE_3="180"

FIFO_LEN=4
PERTURB=15
OVERHEAD=40 # PPPoE
R2Q=2

###############
###############

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
		tc class add dev ${DEVICE} parent ${HANDLE} classid ${HANDLE}:`dec_to_hex ${J}` drr
		tc qdisc add dev ${DEVICE} parent ${HANDLE}:`dec_to_hex ${J}` pfifo limit ${FIFO_LEN}
	done

	# Add a filter to direct the packets.
	tc filter add dev ${DEVICE} prio 1 protocol ip parent ${HANDLE}: handle 1 flow hash keys src,dst,proto,proto-src,proto-dst divisor ${NUM_FLOW_BUCKETS} perturb ${PERTURB} baseclass ${HANDLE}:1
}

function sfq {
	PARENT=$1
	HANDLE=$2

	tc qdisc add dev ${DEVICE} parent ${PARENT} handle ${HANDLE} sfq perturb ${PERTURB} limit ${FIFO_LEN}
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
tc class add dev ${DEVICE} parent 1: classid 1:1 htb rate ${RATE}kbit linklayer atm overhead ${OVERHEAD}

###
# Create NUM_HOST_BUCKETS classes within the top-level class.
###
for HOST_NUM in `seq ${NUM_HOST_BUCKETS}`; do
	echo "Create host class:" $HOST_NUM

	QID=`expr ${HOST_NUM} '+' 9` # 1+9=10 - Start classes at 10.
	tc class add dev ${DEVICE} parent 1:1 classid 1:${QID} htb rate ${DIV_RATE}kbit ceil ${RATE}kbit prio 0 linklayer atm overhead ${OVERHEAD}

	###
	# Within each top level class add three classes, high, normal and low priority.
	###
	QID_1=`expr $QID '*' 100 + 1`
	tc class add dev ${DEVICE} parent 1:${QID} classid 1:${QID_1} htb rate ${DIV_RATE_1}kbit ceil ${RATE}kbit prio 0 linklayer atm overhead ${OVERHEAD}
	QID_2=`expr $QID '*' 100 + 2`
	tc class add dev ${DEVICE} parent 1:${QID} classid 1:${QID_2} htb rate ${DIV_RATE_2}kbit ceil ${RATE}kbit prio 1 linklayer atm overhead ${OVERHEAD}
	QID_3=`expr $QID '*' 100 + 3`
	tc class add dev ${DEVICE} parent 1:${QID} classid 1:${QID_3} htb rate ${DIV_RATE_3}kbit ceil ${RATE}kbit prio 2 linklayer atm overhead ${OVERHEAD}

	###
	# Within each priority class add a QDisc for flow fairness.
	###
	QID_1_1=`expr ${QID_1} + 1`
	drr 1:${QID_1} ${QID_1_1}
	#sfq 1:${QID_1} ${QID_1_1}

	QID_2_1=`expr ${QID_2} + 1`
	drr 1:${QID_2} ${QID_2_1}
	#sfq ${QID_2} ${QID_2_1}

	QID_3_1=`expr ${QID_3} + 1`
	drr 1:${QID_3} ${QID_3_1}
	#sfq 1:${QID_3} ${QID_3_1}

	###
	# Add filters to classify based on the TOS bits.
	# Only mask against the three (used) TOS bits. The final two bits are used for ECN.
	# TODO: Just look at delay 100 and throughput 001, everthing else to default.
	###
	tc filter add dev ${DEVICE} parent 1:${QID} protocol ip prio 10 u32 match ip tos 0x00 0x1c flowid 1:${QID_2}
	tc filter add dev ${DEVICE} parent 1:${QID} protocol ip prio 10 u32 match ip tos 0x04 0x1c flowid 1:${QID_2}
	tc filter add dev ${DEVICE} parent 1:${QID} protocol ip prio 10 u32 match ip tos 0x08 0x1c flowid 1:${QID_3}
	tc filter add dev ${DEVICE} parent 1:${QID} protocol ip prio 10 u32 match ip tos 0x0c 0x1c flowid 1:${QID_3}
	tc filter add dev ${DEVICE} parent 1:${QID} protocol ip prio 10 u32 match ip tos 0x10 0x1c flowid 1:${QID_1}
	tc filter add dev ${DEVICE} parent 1:${QID} protocol ip prio 10 u32 match ip tos 0x14 0x1c flowid 1:${QID_1}
	tc filter add dev ${DEVICE} parent 1:${QID} protocol ip prio 10 u32 match ip tos 0x18 0x1c flowid 1:${QID_2}
	tc filter add dev ${DEVICE} parent 1:${QID} protocol ip prio 10 u32 match ip tos 0x1c 0x1c flowid 1:${QID_2}

	# Diffserv expedited forwarding. Put this in the high priority class.
	tc filter add dev ${DEVICE} parent 1:${QID} protocol ip prio 10 u32 match ip tos 0xb8 0xfc flowid 1:${QID_1}
done

# Send everything that hits the top level QDisc to the top class.
tc filter add dev ${DEVICE} prio 1 protocol ip parent 1:0 u32 match u32 0 0 flowid 1:1

# From the top level class hash into the host classes.
tc filter add dev ${DEVICE} prio 1 protocol ip parent 1:1 handle 1 flow hash keys src divisor ${NUM_HOST_BUCKETS} perturb ${PERTURB} baseclass 1:10

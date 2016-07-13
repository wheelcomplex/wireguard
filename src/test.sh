#!/bin/bash

# This is a simple test suite for WireGuard. At some point it might be
# nice to transition this to Sharness, like git, cgit, and pass, but
# it's possible that kernel upstream won't like the bulkiness of that
# very much. So for now we'll leave it to a single simple file like
# this one here.

[[ $UID != 0 ]] && exec sudo bash "$(readlink -f "$0")" "$@"
set -ex
date
cd "$(dirname "$(readlink -f "$0")")"

unset netns0 netns1 netns2
while [[ $netns1 == "$netns2" || $netns0 == "$netns1" || $netns0 == "$netns2" ]]; do
	netns0="wgtestns$RANDOM"
	netns1="wgtestns$RANDOM"
	netns2="wgtestns$RANDOM"
done

n0() { ip netns exec $netns0 "$@"; }
n1() { ip netns exec $netns1 "$@"; }
n2() { ip netns exec $netns2 "$@"; }

cleanup() {
	set +e
	n0 ip link del dev wg0
	n1 ip link del dev wg0
	n2 ip link del dev wg0
	rmmod wireguard
	killall iperf3
	ip netns del $netns1
	ip netns del $netns2
	ip netns del $netns0
	exit
}

trap "echo '!!! TESTS FAILED !!!' >&2" ERR
trap "cleanup" EXIT

rmmod wireguard 2>/dev/null || true
# We consider insertion part of the tests because when compiled in debug mode,
# the module will fail to insert if the internal kernel self-tests fail.
insmod wireguard.ko

ip netns del $netns0 2>/dev/null || true
ip netns del $netns1 2>/dev/null || true
ip netns del $netns2 2>/dev/null || true
ip netns add $netns0
ip netns add $netns1
ip netns add $netns2

n0 ip link set up dev lo
n0 ip link add dev wg0 type wireguard
n0 ip link set wg0 netns $netns1
n0 ip link add dev wg0 type wireguard
n0 ip link set wg0 netns $netns2

n1 ip addr add 192.168.241.1/24 dev wg0
n1 ip addr add abcd::1/24 dev wg0
n2 ip addr add 192.168.241.2/24 dev wg0
n2 ip addr add abcd::2/24 dev wg0

key1="$(tools/wg genkey)"
key2="$(tools/wg genkey)"
pub1="$(tools/wg pubkey <<<"$key1")"
pub2="$(tools/wg pubkey <<<"$key2")"
psk="$(tools/wg genpsk)"
[[ -n $key1 && -n $key2 && -n $psk ]]

n1 tools/wg set wg0 \
	private-key <(echo "$key1") \
	preshared-key <(echo "$psk") \
	listen-port 1 \
	peer "$pub2" \
		allowed-ips 192.168.241.2/32,abcd::2/128
n2 tools/wg set wg0 \
	private-key <(echo "$key2") \
	preshared-key <(echo "$psk") \
	listen-port 2 \
	peer "$pub1" \
		allowed-ips 192.168.241.1/32,abcd::1/128

n1 ip link set up dev wg0
n2 ip link set up dev wg0

tests() {
	# Status before
	n1 wg
	n2 wg

	# Ping over IPv4
	n2 ping -c 10 -f -W 1 192.168.241.1
	n1 ping -c 10 -f -W 1 192.168.241.2

	# Ping over IPv6
	n2 ping6 -c 10 -f -W 1 abcd::1
	n1 ping6 -c 10 -f -W 1 abcd::2

	# TCP over IPv4
	n2 iperf3 -s -D -B 192.168.241.2
	n1 iperf3 -i 1 -n 1G "$@" -c 192.168.241.2

	# TCP over IPv6
	n1 iperf3 -s -D -B abcd::1
	n2 iperf3 -Z -i 1 -n 1G "$@" -c abcd::1

	# UDP over IPv4
	n1 iperf3 -s -D -B 192.168.241.1
	n2 iperf3 -i 1 -n 1G "$@" -c 192.168.241.1

	# UDP over IPv6
	n2 iperf3 -s -D -B abcd::2
	n1 iperf3 -Z -i 1 -n 1G "$@" -b 0 -u -c abcd::2

	# Status after
	n1 wg
	n2 wg
}

# Test using IPv4 as outer transport
n1 tools/wg set wg0 peer "$pub2" endpoint 127.0.0.1:2
n2 tools/wg set wg0 peer "$pub1" endpoint 127.0.0.1:1
tests

# Test using IPv6 as outer transport
n1 tools/wg set wg0 peer "$pub2" endpoint [::1]:2
n2 tools/wg set wg0 peer "$pub1" endpoint [::1]:1
tests

date
echo '!!! TESTS SUCCEEDED !!!' >&2

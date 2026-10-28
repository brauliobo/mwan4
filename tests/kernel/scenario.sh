#!/bin/sh
# Runs inside `unshare -rnm` (see run.sh): the real mwan4 scripts against the real kernel nft and ip, with a fake
# uci/ubus/uloop and dummy interfaces. A UDP flood of never repeating flows crosses the mwan4 chains while the
# service is reloaded; a probe table behind them counts every packet that left them without a WAN mark.

here=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$here/../.." && pwd)
WORK=$KERNEL_WORK
export KERNEL_WORK KLOG=$WORK/commands.log
UC="ucode -S -L $here/fakes -L $ROOT/files/lib/mwan4"
INCLUDES=/usr/share/nftables.d/ruleset-post

mount -t tmpfs tmpfs /run && mount -t tmpfs tmpfs /usr/share || exit 9
mkdir -p $INCLUDES /run/netns "$WORK/uci" "$WORK/ubus" "$WORK/shim"

# Commands that mwan4 runs are logged by wrappers; the ones that are not available here are stubs.
for tool in ip nft; do
	printf '#!/bin/sh\necho "%s $*" >> "$KLOG"\nexec %s "$@"\n' $tool "$(command -v $tool)" > "$WORK/shim/$tool"
done
for tool in fw4 conntrack logger dnsmasq; do
	printf '#!/bin/sh\necho "%s $*" >> "$KLOG"\nexit %d\n' $tool $([ $tool = fw4 ] && echo 1 || echo 0) > "$WORK/shim/$tool"
done
chmod +x "$WORK"/shim/*
export PATH=$WORK/shim:$PATH
: > "$KLOG"

# Two WANs and a third one for the interface that joins later, a LAN with a peer that floods
ip link set lo up
wan() {
	ip link add $1 type dummy
	ip link set $1 up
	ip addr add $2 dev $1
	ip route add default via $3 dev $1 metric $4
}
wan wan0 192.0.2.2/24 192.0.2.1 10
wan wan1 198.51.100.2/24 198.51.100.1 20
wan wan2 203.0.113.2/24 203.0.113.1 30
ip netns add peer
ip link add lan0 type veth peer name peer0
ip link set peer0 netns peer
ip addr add 10.9.0.1/24 dev lan0
ip link set lan0 up
ip -n peer link set lo up
ip -n peer addr add 10.9.0.2/24 dev peer0
ip -n peer link set peer0 up
ip -n peer route add default via 10.9.0.1
nft -f "$here/probe.nft"

netifd() { printf '{"up":true,"l3_device":"%s","device":"%s","ipv4-address":[{"address":"%s","mask":24}]}' $2 $2 $3 > "$WORK/ubus/network.interface.$1~status.json"; }
netifd wan wan0 192.0.2.2
netifd wanb wan1 198.51.100.2
netifd wanc wan2 203.0.113.2

PASS=0
FAIL=0
check() {
	if [ "$2" = "$3" ]; then
		PASS=$((PASS + 1))
	else
		FAIL=$((FAIL + 1))
		echo "FAIL $1: got [$2] want [$3]"
	fi
}
cfg() { cp "$here/configs/$1.json" "$WORK/uci/mwan4.json"; }
counter() { nft list counter inet probe $1 | sed -n 's/.*packets \([0-9]*\).*/\1/p'; }
objects() { nft -t list table inet fw4 | sed -n 's/^\t\(chain\|set\|map\|counter\) \([^ ]*\) {$/\1 \2/p' | sort; }
trackers() { sort /run/mwan4/trackers; }
count() { grep -c "$1" "$2"; }
positive() { [ "$1" -gt 0 ] && echo yes || echo no; }
reload() { cfg $1; : > "$KLOG"; $UC "$ROOT/files/lib/mwan4/init_reload.uc"; check "reload $1 exits 0" $? 0; }
load_includes() { for f in $INCLUDES/*.nft; do nft -f $f || echo "cannot load $f"; done; }

# --- cold start: what fw4 does afterwards is loading the persisted includes into a fresh table
cfg A
$UC "$ROOT/files/lib/mwan4/init_setup.uc"
nft delete table inet fw4
load_includes
check "cold start lists both trackers" "$(wc -l < /run/mwan4/trackers)" 2
mkdir -p /run/mwan4track/wan_ipv4 /run/mwan4track/wanb_ipv4
printf 'online\n' > /run/mwan4track/wan_ipv4/STATUS
printf 'online\n' > /run/mwan4/iface_state/wan
nft add element inet fw4 mwan4_dom_r_dom_ipv4 '{ 1.2.3.4 }'
nft add element inet fw4 mwan4_dom_r_old_ipv4 '{ 5.6.7.8 }'
nft add element inet fw4 mwan4_rule_ipv4_r_src '{ 10.9.0.77 : 0x200 }'
nft add element inet fw4 mwan4_dynamic_ipv4 '{ 9.9.9.0/24 }'
ip rule > "$WORK/rules.A"

stop=$WORK/stop
ip netns exec peer python3 "$here/send.py" $stop > "$WORK/sent" &
sleep 1

# --- unchanged configuration
reload A
check "unchanged: dom element kept" "$(nft list set inet fw4 mwan4_dom_r_dom_ipv4 | count 1.2.3.4 /dev/stdin)" 1
check "unchanged: dynamic element kept" "$(nft list set inet fw4 mwan4_dynamic_ipv4 | count 9.9.9.0 /dev/stdin)" 1
check "unchanged: sticky element kept" "$(nft list map inet fw4 mwan4_rule_ipv4_r_src | count 10.9.0.77 /dev/stdin)" 1
check "unchanged: no fw4 reload" "$(count '^fw4' "$KLOG")" 0
check "unchanged: no conntrack flush" "$(count '^conntrack' "$KLOG")" 0
check "unchanged: ip rules identical" "$(ip rule | md5sum)" "$(md5sum < "$WORK/rules.A")"
check "unchanged: no ip rule change" "$(count 'ip -[46] rule \(add\|del\)' "$KLOG")" 0

# --- B: a changed rule
objects > "$WORK/objects.A"
trackers > "$WORK/trackers.A"
reload B
check "B: same objects" "$(objects | md5sum)" "$(md5sum < "$WORK/objects.A")"
check "B: rule changed live" "$(positive "$(nft list chain inet fw4 mwan4_rules_ipv4 | count '10.9.0.0/25' /dev/stdin)")" yes
check "B: trackers untouched" "$(trackers | md5sum)" "$(md5sum < "$WORK/trackers.A")"
check "B: dom element kept" "$(nft list set inet fw4 mwan4_dom_r_dom_ipv4 | count 1.2.3.4 /dev/stdin)" 1
check "B: sticky element kept" "$(nft list map inet fw4 mwan4_rule_ipv4_r_src | count 10.9.0.77 /dev/stdin)" 1
check "B: counters survive" "$(positive "$(nft list counter inet fw4 mwan4_counter_rule_r_src_ipv4 | sed -n 's/.*packets \([0-9]*\).*/\1/p')")" yes

# --- C: strategy, rule and domain set added and removed, sticky timeout and a tracker option changed
reload C
trackers > "$WORK/trackers.C"
check "C: only the wanb tracker restarts" "$(diff "$WORK/trackers.A" "$WORK/trackers.C" | count '^>' /dev/stdin)" 1
check "C: new set" "$(nft list sets inet fw4 | count mwan4_dom_r_new_ipv4 /dev/stdin)" 1
check "C: old set gone" "$(nft list sets inet fw4 | count mwan4_dom_r_old_ipv4 /dev/stdin)" 0
check "C: new strategy chain" "$(nft list chains inet fw4 | count mwan4_strategy_new_strat_ipv4 /dev/stdin)" 1
check "C: old strategy chain gone" "$(nft list chains inet fw4 | count mwan4_strategy_old_strat_ipv4 /dev/stdin)" 0
check "C: old counters gone" "$(nft list counters inet fw4 | count strategy_old_strat /dev/stdin)" 0
check "C: dom element kept" "$(nft list set inet fw4 mwan4_dom_r_dom_ipv4 | count 1.2.3.4 /dev/stdin)" 1
check "C: sticky map recreated with the new timeout" "$(nft list map inet fw4 mwan4_rule_ipv4_r_src | count 'timeout 5m' /dev/stdin)" 1
check "C: no fw4 reload, no conntrack flush" "$(count '^\(fw4\|conntrack\)' "$KLOG")" 0
check "C: validated before and loaded once" "$(count '^nft -f' "$KLOG")" 1
check "C: persisted include follows" "$(positive "$(count new_strat $INCLUDES/10-mwan4.nft)")" yes

# --- D: wanb removed, wanc added
printf 'online\n' > /run/mwan4/iface_state/wanb
reload D
check "D: wanb rules gone" "$(ip rule | count 'lookup 2$' /dev/stdin)" 0
check "D: wanc rules present" "$(ip rule | count 'lookup 3$' /dev/stdin)" 2
check "D: wanb table flushed" "$(ip route list table 2 | wc -l)" 0
check "D: wanc table filled" "$(ip route list table 3 | count default /dev/stdin)" 1
check "D: wanb state gone" "$(ls /run/mwan4/iface_state | tr '\n' ' ')" "wan wanc "
check "D: wanb chain gone" "$(nft list chains inet fw4 | count mwan4_iface_in_wanb_ipv4 /dev/stdin)" 0
check "D: wanc chain" "$(nft list chains inet fw4 | count mwan4_iface_in_wanc_ipv4 /dev/stdin)" 1
check "D: trackers" "$(trackers | cut -d' ' -f1 | sort | tr '\n' ' ')" "wan wanc "
add=$(grep -n 'rule add' "$KLOG" | tail -1 | cut -d: -f1)
swap=$(grep -n '^nft -f' "$KLOG" | cut -d: -f1)
del=$(grep -n 'rule del' "$KLOG" | head -1 | cut -d: -f1)
check "D: rules are added before and retired after the swap" "$([ "$add" -lt "$swap" ] && [ "$swap" -lt "$del" ] && echo yes)" yes

# --- storm: every change above, repeatedly, while the flood runs
for i in 1 2 3 4; do
	for c in B A C A D A; do reload $c; done
done
check "storm: dom element kept" "$(nft list set inet fw4 mwan4_dom_r_dom_ipv4 | count 1.2.3.4 /dev/stdin)" 1

# --- a transaction the kernel refuses changes nothing
nft add chain inet fw4 external
nft add rule inet fw4 external jump mwan4_strategy_old_strat_ipv4
objects > "$WORK/objects.before"
trackers > "$WORK/trackers.before"
ip rule > "$WORK/rules.before"
cat $INCLUDES/*.nft | md5sum > "$WORK/includes.before"
cfg C
: > "$KLOG"
$UC "$ROOT/files/lib/mwan4/init_reload.uc"
check "rejected: exits 1" $? 1
check "rejected: objects unchanged" "$(objects | md5sum)" "$(md5sum < "$WORK/objects.before")"
check "rejected: trackers unchanged" "$(trackers | md5sum)" "$(md5sum < "$WORK/trackers.before")"
check "rejected: ip rules unchanged" "$(ip rule | md5sum)" "$(md5sum < "$WORK/rules.before")"
check "rejected: includes unchanged" "$(cat $INCLUDES/*.nft | md5sum)" "$(cat "$WORK/includes.before")"
check "rejected: nothing loaded" "$(count '^nft -f' "$KLOG")" 0
nft flush chain inet fw4 external
nft delete chain inet fw4 external
reload A

# --- hotplug events swap the ruleset without an fw4 reload
hotplug() { : > "$KLOG"; ACTION=$1 FIRSTCONNECT=$2 INTERFACE=wanb DEVICE=wan1 $UC "$ROOT/files/lib/mwan4/hotplug_iface.uc"; }
hotplug disconnected 0
check "hotplug: wanb leaves its strategy" "$(nft list chain inet fw4 mwan4_strategy_wanb_only_ipv4 | count 'mark set 0x00000200' /dev/stdin)" 0
check "hotplug: no fw4 reload" "$(count '^fw4' "$KLOG")" 0
check "hotplug: dom element kept" "$(nft list set inet fw4 mwan4_dom_r_dom_ipv4 | count 1.2.3.4 /dev/stdin)" 1
hotplug connected 1
check "hotplug: wanb back in its strategy" "$(nft list chain inet fw4 mwan4_strategy_wanb_only_ipv4 | count 'mark set 0x00000200' /dev/stdin)" 1
check "hotplug: persisted include follows" "$(positive "$(count 'mark set 0x200' $INCLUDES/10-mwan4.nft)")" yes

# --- a service started by the previous release is adopted, not restarted from initial_state
rm /run/mwan4/applied.json /run/mwan4/trackers
reload A
check "adopted: wan stays online" "$(cat /run/mwan4/iface_state/wan)" online
check "adopted: trackers listed" "$(wc -l < /run/mwan4/trackers)" 2
check "adopted: dom element kept" "$(nft list set inet fw4 mwan4_dom_r_dom_ipv4 | count 1.2.3.4 /dev/stdin)" 1

# --- the flood saw a WAN mark on every packet of all of the above
touch $stop
wait
check "flood: packets were sent" "$(positive "$(counter total)")" yes
check "flood: no packet left the chains unmarked" "$(counter unmarked)" 0
echo "flood: $(counter total) packets, $(counter unmarked) unmarked"

# --- control: the same probe notices a flush that is not atomic
ip netns exec peer python3 "$here/send.py" $stop.2 > /dev/null &
before=$(counter unmarked)
for i in 1 2 3; do
	nft flush chain inet fw4 mwan4_rules_ipv4
	sleep 0.05
	nft -f $INCLUDES/11-mwan4-rules.nft
done
touch $stop.2
wait
check "control: a non-atomic flush is visible to the probe" "$(positive $(($(counter unmarked) - before)))" yes

# --- stop then start hands the health over
printf 'online\n' > /run/mwan4track/wan_ipv4/STATUS
printf '7\n' > /run/mwan4track/wan_ipv4/SCORE
printf '555\n' > /run/mwan4track/wan_ipv4/ONLINE
mkdir -p /run/mwan4/held
printf 'flapping 99999999999\n' > /run/mwan4/held/wan
cfg A
$UC "$ROOT/files/lib/mwan4/init_teardown.uc" 2> /dev/null
check "stop: state wiped" "$(ls /run/mwan4 2> /dev/null | wc -l)" 0
check "stop: nft includes removed" "$(ls $INCLUDES | wc -l)" 0
check "stop: ip rules removed" "$(ip rule | count 'lookup [123]$' /dev/stdin)" 0
$UC "$ROOT/files/lib/mwan4/init_setup.uc"
check "start: verdict restored" "$(cat /run/mwan4track/wan_ipv4/STATUS) $(cat /run/mwan4track/wan_ipv4/SCORE) $(cat /run/mwan4track/wan_ipv4/ONLINE)" "online 7 555"
check "start: hold restored" "$(cat /run/mwan4/held/wan)" "flapping 99999999999"
check "start: state follows the verdict, not initial_state" "$(cat /run/mwan4/iface_state/wan)" online
check "start: stash consumed" "$(ls /run/mwan4.state 2> /dev/null | wc -l)" 0
$UC "$ROOT/files/lib/mwan4/init_teardown.uc" 2> /dev/null
printf '1\n' > /run/mwan4.state/stamp
$UC "$ROOT/files/lib/mwan4/init_setup.uc"
check "stale stash: no verdict restored" "$(ls /run/mwan4track/wan_ipv4/STATUS 2> /dev/null | wc -l)" 0
check "stale stash: initial_state applies" "$(cat /run/mwan4/iface_state/wan)" offline

# --- a restarted tracker resumes its previous verdict (the event loop is a stub: start, connect, return)
tracker() { : > "$KLOG"; $UC "$ROOT/files/lib/mwan4/mwan4track.uc" wan ipv4 signature > /dev/null 2>&1; }
mkdir -p /run/mwan4track/wan_ipv4
printf 'online\n' > /run/mwan4track/wan_ipv4/STATUS
printf '8\n' > /run/mwan4track/wan_ipv4/SCORE
cut -d. -f1 /proc/uptime > /run/mwan4track/wan_ipv4/TIME
tracker
check "tracker: resumes as online" "$(cat /run/mwan4track/wan_ipv4/STATUS)" online
check "tracker: says so" "$(count 'resumes as online with score 8' "$KLOG")" 1
check "tracker: no connected event" "$(count 'is online' "$KLOG")" 0
rm -rf /run/mwan4track/wan_ipv4
tracker
check "tracker: no previous run applies initial_state" "$(cat /run/mwan4track/wan_ipv4/STATUS)" offline
printf 'online\n' > /run/mwan4track/wan_ipv4/STATUS
printf '8\n' > /run/mwan4track/wan_ipv4/SCORE
printf '1\n' > /run/mwan4track/wan_ipv4/TIME
tracker
check "tracker: a stale verdict is ignored" "$(cat /run/mwan4track/wan_ipv4/STATUS)" offline

echo "PASS=$PASS FAIL=$FAIL"
[ $FAIL = 0 ]

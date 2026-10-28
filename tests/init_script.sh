#!/bin/sh
# Drives files/etc/init.d/mwan4 with stand-ins for rc.common, procd and ucode and prints what it does.

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/lib" "$root/run"
: > "$root/lib/functions.sh"
export IPKG_INSTROOT="$root"

# The init script with its state directory moved under the temporary root
sed "s|/var/run/mwan4|$root/run|" ./files/etc/init.d/mwan4 > "$root/mwan4"

procd_open_instance() { echo "  instance $1"; }
procd_set_param() { shift_name=$1; shift; echo "    $shift_name $*"; }
procd_close_instance() { :; }
procd_set_config_changed() { echo "  config changed: $1"; }
procd_lock() { echo "  lock"; }
logger() { echo "  logger $*"; }
ucode() {
	for script; do :; done
	echo "  ucode ${script##*/}"
	[ "${script##*/}" = init_reload.uc ] && return "${RELOAD_RC:-0}"
	return 0
}
ip() { return 0; }

. "$root/mwan4"

# What rc.common does around the functions of a USE_PROCD script, defined after the script was sourced
start() { echo "start"; start_service; }
stop() { echo "stop"; stop_service; service_stopped; }
reload() { echo "reload"; reload_service; }

applied() { printf 'wan ipv4 aa11\nwan ipv6 aa11\nwanb ipv4 bb22\n' > "$root/run/trackers"; }
torn_down() { rm -f "$root/run/trackers"; }

echo "# start on a fresh system"
torn_down
start

echo "# restart of a running service"
applied
restart

echo "# reload (config commit)"
reload

echo "# start of a running service"
start

echo "# reload rejected by the validation"
RELOAD_RC=1
reload
RELOAD_RC=0

echo "# stop"
stop
torn_down

echo "# restart of a stopped service"
restart

'use strict';
// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright 2026 MOSSDeF, Stan Grishin (stangri@melmac.ca).
// Based on original mwan3 by Florian Eckert <fe@dev.tdt.de>
//
// Conntrack flushing of one WAN: flows that never got a reply go at once, the rest only if the WAN stays offline.

import { unlink, writefile, stat } from 'fs';

const STATE_DIR = '/var/run/mwan4';
const FLUSH_DIR = STATE_DIR + '/flush';

// Flows without a reply (conntrack -u UNREPLIED: no reply seen yet): nothing came back through the WAN, so they cannot be healthy.
const DEAD_FLOWS = ['-u UNREPLIED', '-p tcp --state SYN_SENT', '-p tcp --state SYN_RECV'];

function conntrack_delete(mark, mask, filter_args) {
	return sprintf('conntrack -D --mark %s/%s%s 2>/dev/null', mark, mask, filter_args ? ' ' + filter_args : '');
}

function flush_all(mark, mask) {
	system(conntrack_delete(mark, mask));
}

function flush_dead(mark, mask) {
	for (let filter_args in DEAD_FLOWS)
		system(conntrack_delete(mark, mask, filter_args));
}

// The job runs detached from the hotplug lock (fd 1000 stays locked while any descendant holds it). It is single
// flight per WAN through flock; a new request only moves the deadline file the running job keeps polling, and
// removing that file cancels it. A WAN that came back before the deadline keeps its flows.
function job_command(iface, mark, mask) {
	let deadline = sprintf('%s/%s.deadline', FLUSH_DIR, iface);
	return sprintf('(flock -n 9 || exit 0; while [ -f %s ]; do d=$(cat %s); n=$(date +%%s); ' +
		'[ $n -ge $d ] || { sleep $((d - n)); continue; }; rm -f %s; ' +
		'[ "$(cat %s/iface_state/%s 2>/dev/null)" = online ] || %s; done) 9>%s/%s.lock </dev/null >/dev/null 2>&1 1000>&- &',
		deadline, deadline, deadline, STATE_DIR, iface, conntrack_delete(mark, mask), FLUSH_DIR, iface);
}

function schedule_remaining(iface, mark, mask, grace, now) {
	if (!stat(FLUSH_DIR)) system(sprintf("mkdir -p '%s'", FLUSH_DIR));
	writefile(sprintf('%s/%s.deadline', FLUSH_DIR, iface), (now + grace) + '\n');
	system(job_command(iface, mark, mask));
}

function cancel(iface) {
	unlink(sprintf('%s/%s.deadline', FLUSH_DIR, iface));
}

export default {
	flush_all,
	flush_dead,
	job_command,
	schedule_remaining,
	cancel,
};

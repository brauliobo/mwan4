'use strict';
// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright 2026 MOSSDeF, Stan Grishin (stangri@melmac.ca).
// Based on original mwan3 by Florian Eckert <fe@dev.tdt.de>

import { readfile } from 'fs';
import m from 'mwan4';
import stability from 'stability';

m.set_scriptname('mwan4-hotplug');
m.init();

let ACTION = getenv('ACTION');
let INTERFACE = getenv('INTERFACE');
let DEVICE = getenv('DEVICE');
let MWAN4_STARTUP = getenv('MWAN4_STARTUP');
let FIRSTCONNECT = getenv('FIRSTCONNECT') == '1';

// Check interface enabled
let enabled = m.uci_bool(m.uci_get(INTERFACE, 'enabled'));
if (!enabled) {
	m.LOG('notice', 'mwan4 hotplug on', INTERFACE, 'not called because interface disabled');
	exit(0);
}

function setup_ready() {
	if (m.nft_file('exists', 'dynamic'))
		return true;
	m.LOG('warn', 'hotplug called on', INTERFACE, 'before mwan4 has been set up');
	return false;
}

// Determine initial status
let hp_status;
let initial_state = m.uci_get(INTERFACE, 'initial_state') || 'online';
if (initial_state == 'offline') {
	hp_status = 'offline';
	let families = m.get_families(INTERFACE);
	for (let family in families) {
		let status_iface = INTERFACE + '_' + family;
		let fam_status = rtrim(readfile(sprintf('%s/%s/STATUS', m.pkg.TRACK_STATUS_DIR, status_iface)) || '', '\n');
		if (fam_status == 'online') {
			hp_status = 'online';
			break;
		}
	}
} else {
	hp_status = 'online';
}

m.LOG('notice', sprintf('Execute %s event on interface %s (%s)', ACTION, INTERFACE, DEVICE || 'unknown'));

function signal_trackers(signame) {
	let families = m.get_families(INTERFACE);
	let svc = m.ubus_call('service', 'list', { name: 'mwan4' });
	if (!svc?.mwan4?.instances) return;

	for (let family in families) {
		let instance = 'track_' + INTERFACE + '_' + family;
		let pid = svc.mwan4.instances?.[instance]?.pid;
		if (pid)
			system(sprintf('kill -%s %d 2>/dev/null', signame, pid));
	}
}

// Strategies read the hold and quality state files, so changing them only needs a rebuild.
function apply_strategies() {
	m.rebuild_dynamic();
	m.nft_file('install', 'dynamic');
	m.fw4_reload();
}

switch (ACTION) {
case 'connected':
	m.set_iface_hotplug_state(INTERFACE, 'online');
	stability.link_connected(INTERFACE, m.stability_opts(INTERFACE), FIRSTCONNECT, time());
	if (!setup_ready()) exit(0);
	apply_strategies();
	break;

case 'ifup':
	m.set_iface_hotplug_state(INTERFACE, hp_status);
	if (!setup_ready()) exit(0);
	m.create_iface_rules(INTERFACE, DEVICE);
	m.create_iface_route(INTERFACE);
	if (MWAN4_STARTUP != 'init') {
		m.set_general_rules();
		apply_strategies();
	}
	signal_trackers('USR2');
	break;

case 'disconnected':
	m.set_iface_hotplug_state(INTERFACE, 'offline');
	stability.link_disconnected(INTERFACE, 'probe', time());
	if (!setup_ready()) exit(0);
	apply_strategies();
	break;

case 'ifdown':
	m.set_iface_hotplug_state(INTERFACE, 'offline');
	stability.link_disconnected(INTERFACE, 'ifdown', time());
	if (!setup_ready()) exit(0);
	m.delete_iface_rules(INTERFACE);
	m.delete_iface_route(INTERFACE);
	signal_trackers('USR1');
	apply_strategies();
	break;

case 'released':
	if (stability.link_released(INTERFACE, time()) && setup_ready())
		apply_strategies();
	break;

case 'quality':
	stability.link_quality_changed(INTERFACE, time());
	if (setup_ready())
		apply_strategies();
	break;
}

m.flush_conntrack(INTERFACE, ACTION);

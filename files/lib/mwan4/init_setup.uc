'use strict';
// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright 2026 MOSSDeF, Stan Grishin (stangri@melmac.ca).
// Based on original mwan3 by Florian Eckert <fe@dev.tdt.de>
//
// Called by init.d/mwan4 start_service to set up nftables, routes and rules.
// Procd instance management (trackers, rtmon) stays in shell.

import m from 'mwan4';
import stability from 'stability';

m.set_scriptname('mwan4-init');
m.init();
stability.history_restore();
m.restore_state();

m.update_iface_to_table();
m.set_general_rules();
m.persist_policy_ownership();

// ifup all enabled interfaces (creates IP rules and sets hotplug state)
m.uci_foreach('interface', function(s) {
	m.ifup(s['.name'], 'init');
});

// Seed hotplug state from tracker first-connect status before strategies render.
m.init_iface_hotplug_states();

// Apply mwan4-owned MPTCP sysctl, limits, and endpoint definitions after WAN
// source addresses/devices are known.
m.apply_mptcp_config();

// Rules need their persisted ids before the rules file records them in conntrack marks.
m.ensure_rule_ids();

// Generate the dynamic file (base structure + interfaces + strategies) and the rules file (sets + user rules)
let rules = m.collect_user_rules();
m.generate_nft(rules);

// dnsmasq must know the domain sets before fw4 reload prefetches them
m.sync_dnsmasq(rules);

// Validate combined and install (fw4 reload prefetches domain sets)
m.nft_file('install', 'all');
m.fw4_reload();

// What a later reload compares against, and the trackers the init script starts
m.record_applied(rules);

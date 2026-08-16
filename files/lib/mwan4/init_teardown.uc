'use strict';
// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright 2026 MOSSDeF, Stan Grishin (stangri@melmac.ca).
// Based on original mwan3 by Florian Eckert <fe@dev.tdt.de>
//
// Called by init.d/mwan4 stop_service to tear down nftables, routes and rules.

import m from 'mwan4';

m.set_scriptname('mwan4-init');
m.init();

// Remove only endpoints previously created by mwan4. This avoids flushing
// externally managed MPTCP endpoints.
m.remove_mptcp_managed_endpoints();

// Shutdown all interfaces
m.uci_foreach('interface', function(s) {
	m.interface_shutdown(s['.name']);
});

let ownership = m.get_installed_policy_ownership();
if (!length(ownership.tables) && !length(ownership.rule_prefs))
	ownership = m.get_policy_ownership();

// Flush routing tables and delete only mwan4-owned IP rules per family.
for (let family in ['ipv4', 'ipv6']) {
	if (family == 'ipv6' && m.no_ipv6) continue;
	let ip = (family == 'ipv4') ? 'ip -4' : 'ip -6';

	for (let tid in ownership.tables)
		system(sprintf('%s route flush table %d 2>/dev/null', ip, tid));

	for (let pref in ownership.rule_prefs)
		system(sprintf('%s rule del pref %d 2>/dev/null', ip, pref));
}

// Remove nftables include and temp files (fw4 reload is triggered by service_stopped)
m.nft_file('delete', 'all');
system('rm -f /var/run/mwan4.nft*');

// Remove status directories
system('rm -rf /var/run/mwan4 /var/run/mwan4track');

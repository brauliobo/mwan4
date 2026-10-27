'use strict';
// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright 2026 MOSSDeF, Stan Grishin (stangri@melmac.ca).
// Based on original mwan3 by Florian Eckert <fe@dev.tdt.de>
//
// One-pass parser for /proc/net/nf_conntrack. Pure functions: callers read the
// file and describe the mark layout, so the parser needs no fs/uci access.

const ENTRY_RE = /^(ipv[46]) .* mark=([0-9]+)/;
const TUPLE_RE = /^(src|dst|sport|dport|packets|bytes)=(.*)$/;

function family_counts(ipv4, ipv6) {
	return { ipv4: ipv4 ?? 0, ipv6: ipv6 ?? 0, total: (ipv4 ?? 0) + (ipv6 ?? 0) };
}

function bump(counts, family) {
	counts[family]++;
	counts.total++;
}

// Inverse of id2mask(): collect the bits of `value` under `mask` into a dense integer.
function gather_bits(value, mask) {
	let result = 0, position = 0;
	for (let bit = 0; bit < 32; bit++) {
		if (!((mask >> bit) & 1)) continue;
		if ((value >> bit) & 1) result |= 1 << position;
		position++;
	}
	return result;
}

// /proc prints IPv6 addresses fully expanded; shorten them like `ip` does.
function compress_ipv6(addr) {
	let groups = map(split(addr, ':'), g => sprintf('%x', hex(g)));
	let best = { start: -1, length: 0 };
	for (let i = 0, run = 0; i < length(groups); i++) {
		run = groups[i] == '0' ? run + 1 : 0;
		if (run > best.length) best = { start: i - run + 1, length: run };
	}
	if (best.length < 2) return join(':', groups);
	let head = join(':', slice(groups, 0, best.start));
	let tail = join(':', slice(groups, best.start + best.length));
	return head + '::' + tail;
}

function format_address(addr) {
	return index(addr, ':') < 0 ? addr : compress_ipv6(addr);
}

// The first src/dst/sport/dport are the original direction; packets/bytes cover both.
function parse_entry(line, mark) {
	let tokens = split(trim(line), /\s+/);
	let entry = {
		family: tokens[0], proto: tokens[2], timeout: int(tokens[4]),
		state: index(tokens[5], '=') < 0 ? tokens[5] : '',
		src: '', dst: '', sport: null, dport: null, packets: 0, bytes: 0, mark,
	};
	let seen = {};
	for (let token in tokens) {
		let kv = match(token, TUPLE_RE);
		if (!kv) continue;
		if (kv[1] == 'packets' || kv[1] == 'bytes') entry[kv[1]] += int(kv[2]);
		else if (!seen[kv[1]]) entry[kv[1]] = kv[2];
		seen[kv[1]] = true;
	}
	entry.src = format_address(entry.src);
	entry.dst = format_address(entry.dst);
	entry.sport = entry.sport != null ? int(entry.sport) : null;
	entry.dport = entry.dport != null ? int(entry.dport) : null;
	return entry;
}

// Single pass over the conntrack table. Only connections carrying mwan4 WAN bits
// are counted (`layout.wan_mask`); counts are keyed by rule id and by WAN mark.
// `want(family, rule_id, wan)` selects the entries that are also fully parsed.
function scan(text, layout, want) {
	let counts = { total: family_counts(), rules: {}, wans: {} };
	let entries = [];

	for (let line in split(text, '\n')) {
		let found = match(line, ENTRY_RE);
		if (!found) continue;

		let mark = int(found[2]);
		let wan = mark & layout.wan_mask;
		if (!wan) continue;

		let family = found[1];
		let rule_id = gather_bits(mark & layout.rule_mask, layout.rule_mask);
		bump(counts.total, family);
		bump(counts.rules['' + rule_id] ??= family_counts(), family);
		bump(counts.wans['' + wan] ??= family_counts(), family);

		if (want && want(family, rule_id, wan))
			push(entries, { ...parse_entry(line, mark), rule_id, wan });
	}

	return { counts, entries };
}

export default { scan, gather_bits, family_counts, parse_entry, compress_ipv6 };

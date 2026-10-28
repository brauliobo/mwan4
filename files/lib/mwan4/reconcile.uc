'use strict';
// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright 2026 MOSSDeF, Stan Grishin (stangri@melmac.ca).
//
// Turns a desired state into the smallest change of the live one: ip rules to add or delete, and one nft
// transaction that swaps the mwan4 ruleset atomically. Pure: callers run the commands.

const NFT_PREFIX = 'mwan4_';
const DECLARATION_RE = /^\t(chain|set|map|counter) ([A-Za-z0-9_]+) \{$/;

// ── ip rules ─────────────────────────────────────────────────────────

function rule_key(r) {
	let mark = r.fwmark ? sprintf('%x/%x', r.fwmark.value, r.fwmark.mask) : '';
	return sprintf('%d|%s|%s|%s', r.pref, r.iif ?? '', mark, r.action);
}

function parse_fwmark(text) {
	let parts = split(text, '/');
	return { value: +parts[0], mask: length(parts) > 1 ? +parts[1] : 0xffffffff };
}

// `1001:	from all iif eth0 lookup 1` as the same object the callers build for the rules they expect.
function parse_rule(line) {
	let head = match(line, /^([0-9]+):\s+from all (.*)$/);
	if (!head) return null;

	let rule = { pref: int(head[1]) };
	let words = split(trim(head[2]), /\s+/);
	for (let i = 0; i < length(words); i++) {
		switch (words[i]) {
		case 'iif':
			rule.iif = words[++i];
			break;
		case 'fwmark':
			rule.fwmark = parse_fwmark(words[++i]);
			break;
		case 'lookup':
			rule.action = 'lookup ' + words[++i];
			break;
		case 'blackhole':
		case 'unreachable':
		case 'prohibit':
			rule.action = words[i];
			break;
		}
	}
	return rule.action ? rule : null;
}

// Rules to add (before the new ruleset goes live) and to delete (after it did). Only rules on `owned` prefs are
// ever deleted, so rules of other owners on the same table are left alone.
function plan_rules(existing_lines, expected, owned) {
	let present = {}, wanted = {};
	let existing = filter(map(existing_lines, parse_rule), r => r && owned[r.pref]);
	for (let r in existing) present[rule_key(r)] = true;
	for (let r in expected) wanted[rule_key(r)] = true;

	return {
		add: filter(expected, r => !present[rule_key(r)]),
		del: filter(existing, r => !wanted[rule_key(r)]),
	};
}

// ── nft transaction ──────────────────────────────────────────────────

// Chains, sets, maps and counters declared by generated files, one tab deep inside `table ... {`.
// Sets with `elements` are refreshed on every apply, the others keep what the kernel or dnsmasq put in them.
function declarations(lines) {
	let found = { chain: {}, set: {}, map: {}, counter: {} };
	let current = null;

	for (let line in lines) {
		let head = match(line, DECLARATION_RE);
		if (head) {
			current = found[head[1]][head[2]] ??= { signature: [], refresh: false, filled: false };
		} else if (line == '\t}') {
			current = null;
		} else if (current) {
			current.filled = true;
			if (match(line, /^\t\telements = \{/)) current.refresh = true;
			else if (match(line, /^\t\t(type|typeof|flags|auto-merge|timeout)\b/)) push(current.signature, trim(line));
		}
	}
	return found;
}

// Names of the mwan4 objects in `nft -t list table` output.
function live_objects(listing) {
	let live = { chain: {}, set: {}, map: {}, counter: {} };
	for (let line in split(listing ?? '', '\n')) {
		let head = match(line, DECLARATION_RE);
		if (head && index(head[2], NFT_PREFIX) == 0) live[head[1]][head[2]] = true;
	}
	return live;
}

// Definition of every map by name, to notice a changed timeout.
function map_definitions(maps) {
	let definitions = {};
	for (let name in keys(maps))
		definitions[name] = join(' ', maps[name].signature);
	return definitions;
}

function map_signatures(lines) {
	return map_definitions(declarations(lines).map);
}

// What only mwan4 owns and may delete: fw4 defines the sets of rule `ipset` options itself.
const OBSOLETE_PREFIX = {
	chain:   NFT_PREFIX,
	counter: NFT_PREFIX + 'counter_',
	set:     NFT_PREFIX + 'dom_',
	map:     NFT_PREFIX + 'rule_',
};

function object_ref(kind, table, name) {
	return sprintf('%s inet %s %s', kind, table, name);
}

// One batch, applied atomically by `nft -f`: every live chain is flushed and the desired ones re-filled in the
// same transaction, sets keep their elements, obsolete objects go last. `maps` holds the map signatures of the
// previous apply: a map whose definition changed is recreated, an unknown one is left as it is.
function transaction(lines, live, maps, table) {
	let want = declarations(lines);
	let before = [], after = [];
	let created = [];

	for (let name in keys(live.chain))
		push(before, 'flush ' + object_ref('chain', table, name));
	for (let name in keys(want.set)) {
		if (live.set[name] && want.set[name].refresh) push(before, 'flush ' + object_ref('set', table, name));
		if (!live.set[name]) push(created, name);
	}
	let definitions = map_definitions(want.map);
	for (let name in keys(definitions))
		if (live.map[name] && maps?.[name] != null && maps[name] != definitions[name])
			push(before, 'delete ' + object_ref('map', table, name));
	for (let kind in ['chain', 'set', 'map', 'counter'])
		for (let name in keys(live[kind]))
			if (!want[kind][name] && index(name, OBSOLETE_PREFIX[kind]) == 0)
				push(after, 'delete ' + object_ref(kind, table, name));

	return {
		text: join('\n', [...before, ...lines, ...after]) + '\n',
		created,
		maps: definitions,
	};
}

export default {
	parse_rule,
	rule_key,
	plan_rules,
	declarations,
	live_objects,
	transaction,
	map_signatures,
};

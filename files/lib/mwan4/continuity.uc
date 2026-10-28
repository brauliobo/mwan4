'use strict';
// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright 2026 MOSSDeF, Stan Grishin (stangri@melmac.ca).
//
// State that outlives a configuration change: which interfaces changed since the last apply, the health a restarted
// tracker resumes from, and the state a stop/start hands over. Pure except for the files named below.

import { readfile, writefile, rename, lsdir } from 'fs';

const STATE_DIR = '/var/run/mwan4';
const TRACK_DIR = '/var/run/mwan4track';
const APPLIED_FILE = STATE_DIR + '/applied.json';
const TRACKERS_FILE = STATE_DIR + '/trackers';
// stop wipes STATE_DIR and TRACK_DIR; what start may take over is parked here (tmpfs, so a reboot clears it).
const STASH_DIR = '/var/run/mwan4.state';
const CARRY_MAX_AGE = 900;
const TRACK_FILES = ['STATUS', 'SCORE', 'ONLINE', 'OFFLINE', 'TIME'];
const STATE_KINDS = ['held', 'quality'];

// ── Signatures ───────────────────────────────────────────────────────

function canonical(value) {
	switch (type(value)) {
	case 'object':
		return '{' + join(',', map(sort(keys(value)), k => k + ':' + canonical(value[k]))) + '}';
	case 'array':
		return '[' + join(',', map(value, canonical)) + ']';
	}
	return '' + value;
}

function fnv32(text, seed) {
	let h = seed;
	for (let i = 0; i < length(text); i++)
		h = ((h ^ ord(text, i)) * 16777619) & 0xffffffff;
	return h;
}

// 64 bit digest of any value, independent of key order.
function digest(value) {
	let text = canonical(value);
	return sprintf('%08x%08x', fnv32(text, 2166136261), fnv32(text, 0x9747b28c));
}

// Interfaces that are new, changed, unchanged or gone since the last apply. `known` lists the interfaces that have
// live state, so a service started by an older release (no signatures yet) counts as changed, not as new.
function classify(previous, known, current) {
	let result = { added: [], changed: [], unchanged: [], removed: [] };
	let live = {};
	for (let name in [...known, ...keys(previous)])
		live[name] = true;

	for (let name in sort(keys(current))) {
		if (!live[name])
			push(result.added, name);
		else
			push(previous[name] == current[name] ? result.unchanged : result.changed, name);
	}
	result.removed = sort(filter(keys(live), name => !exists(current, name)));
	return result;
}

// ── Tracker health ───────────────────────────────────────────────────

function clamp(value, low, high) {
	return min(max(value, low), high);
}

// What a restarted tracker resumes from, given the verdict files of its previous run ({ status, score, age }).
// A link that was online stays online with its score, so only failing probes take it down; one that was
// offline or recovering stays offline. Nothing usable means the caller applies initial_state.
function carry_over(previous, up, down) {
	if (!previous?.status || (previous.age != null && previous.age > CARRY_MAX_AGE))
		return null;

	switch (previous.status) {
	case 'online':
	case 'disconnecting':
		return { status: 'online', score: clamp(previous.score ?? down + up, up + 1, down + up) };
	case 'offline':
		return { status: 'offline', score: 0 };
	case 'connecting':
		return { status: 'offline', score: clamp(previous.score ?? 0, 0, up - 1) };
	}
	return null;
}

// One line per tracker instance, read by the init script: interface, family, signature of its configuration.
function render_trackers(trackers) {
	return join('', map(trackers, t => sprintf('%s %s %s\n', t.iface, t.family, t.sig)));
}

// ── Applied state ────────────────────────────────────────────────────

function write_atomic(path, data) {
	writefile(path + '.tmp', data);
	rename(path + '.tmp', path);
}

function load_applied() {
	let text = readfile(APPLIED_FILE);
	return text ? json(text) : {};
}

function save_applied(applied) {
	write_atomic(APPLIED_FILE, sprintf('%J\n', applied));
}

function save_trackers(trackers) {
	write_atomic(TRACKERS_FILE, render_trackers(trackers));
}

function known_interfaces() {
	return lsdir(STATE_DIR + '/iface_state') ?? [];
}

// ── Stop / start hand-over ───────────────────────────────────────────

function copy_files(from, to, names) {
	system(sprintf("mkdir -p '%s'", to));
	for (let name in names) {
		let data = readfile(from + '/' + name);
		if (data != null) writefile(to + '/' + name, data);
	}
}

function stash(now) {
	system(sprintf("rm -rf '%s'", STASH_DIR));
	for (let dir in lsdir(TRACK_DIR) ?? [])
		copy_files(TRACK_DIR + '/' + dir, STASH_DIR + '/track/' + dir, TRACK_FILES);
	for (let kind in STATE_KINDS)
		copy_files(STATE_DIR + '/' + kind, STASH_DIR + '/' + kind, lsdir(STATE_DIR + '/' + kind) ?? []);
	writefile(STASH_DIR + '/stamp', now + '\n');
}

// Puts back the stashed tracker verdicts and holds of the interfaces `keep` accepts, if the stash is young enough.
function restore(now, keep) {
	let stamp = int(readfile(STASH_DIR + '/stamp'));
	if (stamp && now - stamp <= CARRY_MAX_AGE) {
		for (let dir in lsdir(STASH_DIR + '/track') ?? []) {
			let tracker = match(dir, /^(.+)_(ipv4|ipv6)$/);
			if (tracker && keep(tracker[1]))
				copy_files(STASH_DIR + '/track/' + dir, TRACK_DIR + '/' + dir, TRACK_FILES);
		}
		for (let kind in STATE_KINDS) {
			let stashed = lsdir(STASH_DIR + '/' + kind) ?? [];
			copy_files(STASH_DIR + '/' + kind, STATE_DIR + '/' + kind, filter(stashed, keep));
		}
	}
	system(sprintf("rm -rf '%s'", STASH_DIR));
}

export default {
	CARRY_MAX_AGE,
	digest,
	classify,
	carry_over,
	render_trackers,
	load_applied,
	save_applied,
	save_trackers,
	known_interfaces,
	stash,
	restore,
};

'use strict';
// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright 2026 MOSSDeF, Stan Grishin (stangri@melmac.ca).
// Based on original mwan3 by Florian Eckert <fe@dev.tdt.de>
//
// Unstable-link handling: transition log, flap damping, failback hold and quality steering state.
// Every function takes the time as an argument so the behaviour can be simulated deterministically.

import { readfile, writefile, unlink, rename, stat } from 'fs';

const STATE_DIR = '/var/run/mwan4';
const HISTORY_DIR = STATE_DIR + '/history';
const HELD_DIR = STATE_DIR + '/held';
const QUALITY_DIR = STATE_DIR + '/quality';
// mwan4 stop wipes STATE_DIR; the log is parked here so reloads keep it.
const HISTORY_STASH = '/var/run/mwan4.history';
const HISTORY_MAX = 200;
const QUALITY_WINDOW = 3;
const QUALITY_LEAVE_RATIO = 0.8;
const QUALITY_NO_ANSWER = 99;

const DEFAULTS = {
	flap_damping:   1,
	flap_threshold: 3,
	flap_window:    300,
	flap_holddown:  120,
	recovery_hold:  30,
	flush_grace:    10,
	quality_hold:   30,
};

// Numeric options with their [min, max]; flap_damping is the only boolean.
const RANGES = {
	flap_threshold: [2, 1000],
	flap_window:    [30, 86400],
	flap_holddown:  [0, 86400],
	recovery_hold:  [0, 86400],
	flush_grace:    [0, 3600],
	quality_hold:   [0, 86400],
};

// ── Files ────────────────────────────────────────────────────────────

function ensure_dir(dir) {
	if (!stat(dir))
		system(sprintf("mkdir -p '%s'", dir));
}

function write_file(dir, name, data) {
	ensure_dir(dir);
	writefile(dir + '/' + name + '.tmp', data);
	rename(dir + '/' + name + '.tmp', dir + '/' + name);
}

function read_text(dir, name) {
	return trim(readfile(dir + '/' + name) || '');
}

function mean(values) {
	if (!length(values)) return null;
	let sum = 0.0;
	for (let v in values) sum += v;
	return sum / length(values);
}

function history_stash() {
	system(sprintf("rm -rf '%s'; mv '%s' '%s' 2>/dev/null", HISTORY_STASH, HISTORY_DIR, HISTORY_STASH));
}

function history_restore() {
	ensure_dir(STATE_DIR);
	system(sprintf("[ -d '%s' ] && mv '%s' '%s'", HISTORY_STASH, HISTORY_STASH, HISTORY_DIR));
}

// ── Transition log ───────────────────────────────────────────────────

function parse_event(line) {
	let f = match(line, /^([0-9]+) (\S+) ?(.*)$/);
	return f ? { time: int(f[1]), state: f[2], reason: f[3] } : null;
}

function format_event(e) {
	return sprintf('%d %s %s', e.time, e.state, e.reason);
}

function history_events(iface) {
	return filter(map(split(read_text(HISTORY_DIR, iface), '\n'), parse_event), e => e);
}

// online/offline are the only states that carry availability; repeating one adds nothing.
function last_link_state(events) {
	let changes = filter(events, e => e.state == 'online' || e.state == 'offline');
	return changes[length(changes) - 1];
}

function history_append(iface, state, reason, now) {
	let events = history_events(iface);
	if ((state == 'online' || state == 'offline') && last_link_state(events)?.state == state)
		return;
	push(events, { time: now, state, reason: replace(reason, /\s+/g, '_') });
	write_file(HISTORY_DIR, iface, join('\n', map(slice(events, -HISTORY_MAX), format_event)) + '\n');
}

function history_flaps(events, window, now) {
	let offline = filter(events, e => e.state == 'offline');
	return { count_window: length(filter(offline, e => e.time > now - window)), window, total: length(offline) };
}

// Percentage of [from, to] the link was online and the seconds of that span the log covers.
function uptime_stats(events, from, to) {
	let changes = filter(events, e => e.state == 'online' || e.state == 'offline');
	if (!length(changes)) return null;

	let start = max(from, changes[0].time);
	if (to <= start) return null;

	let up = 0, current = null, since = start;
	for (let e in changes) {
		if (e.time <= start) { current = e.state; continue; }
		if (e.time > to) break;
		if (current == 'online') up += e.time - since;
		since = e.time;
		current = e.state;
	}
	if (current == 'online') up += to - since;
	return { pct: int(up * 1000.0 / (to - start) + 0.5) / 10.0, observed: to - start };
}

// A percentage is only meaningful with the span it was measured over: a log shorter than the window covers less of it.
function availability(events, now) {
	let hour = uptime_stats(events, now - 3600, now), day = uptime_stats(events, now - 86400, now);
	return { pct_1h: hour?.pct, observed_1h: hour?.observed, pct_24h: day?.pct, observed_24h: day?.observed };
}

function duration_text(seconds) {
	if (seconds < 120) return seconds + 's';
	if (seconds < 7200) return int(seconds / 60) + 'm';
	if (seconds < 172800) return int(seconds / 3600) + 'h' + (seconds % 3600 >= 60 ? sprintf('%02dm', int(seconds % 3600 / 60)) : '');
	return int(seconds / 86400) + 'd';
}

// "99.2% over 24h", or "23.1% over the last 4h25m" while the log is shorter than the window.
function availability_text(pct, observed, window) {
	if (pct == null) return 'n/a';
	return sprintf('%.1f%% over %s', pct, observed >= window ? duration_text(window) : 'the last ' + duration_text(observed));
}

// ── Holds ────────────────────────────────────────────────────────────

function hold_read(iface) {
	let f = match(read_text(HELD_DIR, iface), /^([a-z]+) ([0-9]+)$/);
	return f ? { reason: f[1], until: int(f[2]) } : null;
}

function hold_clear(iface) {
	unlink(HELD_DIR + '/' + iface);
}

function held_info(iface, now) {
	let hold = hold_read(iface);
	let active = hold != null && hold.until > now;
	return {
		active,
		reason:    active ? hold.reason : null,
		until:     active ? hold.until : null,
		remaining: active ? hold.until - now : 0,
	};
}

function hold_expired(iface, now) {
	let hold = hold_read(iface);
	return hold != null && hold.until <= now;
}

// Flapping outranks failback; a zero duration disables that hold.
function hold_for(events, opts, now) {
	let flapping = opts.flap_damping && history_flaps(events, opts.flap_window, now).count_window >= opts.flap_threshold;
	let holds = [
		{ reason: 'flapping',   seconds: flapping ? opts.flap_holddown : 0 },
		{ reason: 'recovering', seconds: opts.recovery_hold },
	];
	return filter(holds, h => h.seconds > 0)[0];
}

// ── Quality state ────────────────────────────────────────────────────

// Strategy name -> how far past its limits the link was when the degraded set last changed.
function quality_read(iface) {
	let result = {};
	for (let line in split(read_text(QUALITY_DIR, iface), '\n')) {
		let f = match(line, /^(\S+) ([0-9.]+)$/);
		if (f) result[f[1]] = +f[2];
	}
	return result;
}

function quality_clear(iface) {
	unlink(QUALITY_DIR + '/' + iface);
}

function quality_write(iface, degraded) {
	if (!length(degraded)) return quality_clear(iface);
	write_file(QUALITY_DIR, iface, join('\n', map(sort(keys(degraded)), s => sprintf('%s %.2f', s, degraded[s]))) + '\n');
}

// One tracker cycle: latency over the probes that answered, loss over all of them.
function quality_sample(probes) {
	let answered = filter(probes, p => p.result == 0 && p.latency != null);
	return {
		latency: mean(map(answered, p => p.latency)),
		loss:    mean(map(probes, p => p.loss ?? (p.result == 0 ? 0 : 100))),
	};
}

function quality_average(samples) {
	return { latency: mean(filter(map(samples, s => s.latency), v => v != null)), loss: mean(map(samples, s => s.loss)) };
}

// Worst measured/limit ratio of the configured limits; a link that never answers is far past any limit.
function quality_ratio(avg, limit) {
	let ratios = [0];
	if (limit.max_latency)
		push(ratios, avg.latency == null ? QUALITY_NO_ANSWER : avg.latency / limit.max_latency);
	if (limit.max_loss != null)
		push(ratios, limit.max_loss > 0 ? avg.loss / limit.max_loss : (avg.loss > 0 ? QUALITY_NO_ANSWER : 0));
	return max(...ratios);
}

function quality_state() {
	return { samples: [], degraded: {}, below: {} };
}

// Feeds one sample and updates the degraded set: entering is immediate on the smoothed value, leaving needs the
// value under 80% of the limit for `hold` seconds. Returns true when the set changed.
function quality_step(state, sample, limits, hold, now) {
	state.samples = slice([...state.samples, sample], -QUALITY_WINDOW);
	if (length(state.samples) < QUALITY_WINDOW) return false;

	let avg = quality_average(state.samples);
	let before = join(',', sort(keys(state.degraded)));
	for (let limit in limits) {
		let name = limit.strategy, ratio = quality_ratio(avg, limit);
		if (!exists(state.degraded, name)) {
			if (ratio > 1) state.degraded[name] = ratio;
		} else if (ratio > QUALITY_LEAVE_RATIO) {
			state.degraded[name] = ratio;
			delete state.below[name];
		} else {
			state.below[name] ??= now;
			if (now - state.below[name] >= hold) {
				delete state.degraded[name];
				delete state.below[name];
			}
		}
	}
	return before != join(',', sort(keys(state.degraded)));
}

// ── Link events (serialised by the hotplug lock) ─────────────────────

// A link that is healthy when mwan4 starts joins at once; only a later recovery is held.
function link_connected(iface, opts, first, now) {
	let hold = first ? null : hold_for(history_events(iface), opts, now);
	history_append(iface, 'online', first ? 'start' : 'recovered', now);
	quality_clear(iface);
	hold_clear(iface);
	if (!hold) return null;

	write_file(HELD_DIR, iface, sprintf('%s %d\n', hold.reason, now + hold.seconds));
	history_append(iface, 'held', hold.reason, now);
	return hold;
}

function link_disconnected(iface, reason, now) {
	history_append(iface, 'offline', reason, now);
	quality_clear(iface);
	hold_clear(iface);
}

function link_released(iface, now) {
	let hold = hold_read(iface);
	if (!hold) return false;
	hold_clear(iface);
	history_append(iface, 'released', hold.reason, now);
	return true;
}

function link_quality_changed(iface, now) {
	let degraded = sort(keys(quality_read(iface)));
	history_append(iface, length(degraded) ? 'degraded' : 'restored', join(',', degraded), now);
}

export default {
	DEFAULTS,
	RANGES,
	HISTORY_MAX,
	history_stash,
	history_restore,
	history_events,
	history_append,
	history_flaps,
	availability,
	availability_text,
	held_info,
	hold_expired,
	hold_for,
	quality_read,
	quality_write,
	quality_clear,
	quality_sample,
	quality_state,
	quality_step,
	link_connected,
	link_disconnected,
	link_released,
	link_quality_changed,
};

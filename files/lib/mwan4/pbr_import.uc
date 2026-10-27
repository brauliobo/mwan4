'use strict';
// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright 2026 MOSSDeF, Stan Grishin (stangri@melmac.ca).
//
// Converts /etc/config/pbr policies into mwan4 rules, strategies and tunnel
// interfaces. Preview by default; `apply` writes /etc/config/mwan4 (after
// saving /etc/config/mwan4.pre-pbr-import). /etc/config/pbr is never touched.

import { readfile, writefile } from 'fs';
import { cursor } from 'uci';
import m from 'mwan4';

const BACKUP = '/etc/config/mwan4.pre-pbr-import';
const MARKER = 'pbr_import';
const NAME_MAX = 15;
const RULE_BASE_MAX = 11;
const DEFAULT_RULES = ['default_rule_v4', 'default_rule_v6'];
const TUNNEL_PROTOS = ['wireguard', 'gre', 'gretap', 'grev6', 'grev6tap', 'vti', 'vti6', '6in4', '6rd', '6to4', 'ipip6'];
const PUBLIC_TRACK_IPS = { ipv4: '1.1.1.1', ipv6: '2606:4700:4700::1111' };
const TUNNEL_TRACKING = {
	track_method: 'ping', reliability: '1', count: '1', timeout: '2', interval: '5',
	failure_interval: '2', recovery_interval: '2', down: '3', up: '3', initial_state: 'online',
};

function as_list(value) {
	return value == null ? [] : (type(value) == 'array' ? value : [value]);
}

function read_sections(config, stype) {
	let c = cursor();
	c.load(config);
	let result = [];
	c.foreach(config, stype, s => push(result, s));
	return result;
}

function tokens(value) {
	let result = [];
	for (let part in as_list(value))
		push(result, ...filter(split(trim('' + part), /[ \t,;]+/), t => length(t)));
	return uniq(result);
}

function slug(text, max) {
	return trim(substr(trim(replace(lc(text), /[^a-z0-9]+/g, '_'), '_'), 0, max), '_');
}

// ── Existing mwan4 configuration ─────────────────────────────────────

function is_tunnel_section(s) {
	return s.type == 'tunnel' || m.uci_bool(s.default_route);
}

function read_mwan4() {
	let cfg = { interfaces: {}, routes: [], strategies: {}, taken: {}, ids: [], tables: [] };
	let ordinal = 0;

	for (let s in read_sections('mwan4', null)) {
		let stale = s[MARKER] != null && s['.type'] != 'interface';
		if (stale) continue;
		cfg.taken[s['.name']] = true;
		switch (s['.type']) {
		case 'interface':
			cfg.interfaces[s['.name']] = s;
			push(cfg.ids, int(s.id) || ordinal + 1);
			push(cfg.tables, int(s.table_id) || cfg.ids[-1]);
			ordinal++;
			break;
		case 'route':
			push(cfg.routes, s);
			break;
		case 'strategy':
			cfg.strategies[s['.name']] = s;
			break;
		}
	}
	return cfg;
}

function read_network() {
	let net = {};
	for (let s in read_sections('network', 'interface'))
		net[s['.name']] = { ...s, peers: read_sections('network', 'wireguard_' + s['.name']) };
	return net;
}

// ── Name allocation ──────────────────────────────────────────────────

function claim_name(ctx, base, max) {
	let name = base;
	for (let n = 2; ctx.taken[name]; n++)
		name = substr(base, 0, max - length('_' + n)) + '_' + n;
	ctx.taken[name] = true;
	return name;
}

function variant_names(stem, count) {
	let names = [];
	for (let i = 1; i <= count; i++) push(names, count > 1 ? `${stem}_${i}` : stem);
	return names;
}

// Rule names for the variants of one policy; a clash bumps the shared stem (name_2, name_3...).
function claim_variant_names(ctx, base, count) {
	let stem = base;
	for (let n = 2; length(filter([stem, ...variant_names(stem, count)], name => ctx.taken[name])); n++)
		stem = substr(base, 0, RULE_BASE_MAX - length('_' + n)) + '_' + n;
	let names = variant_names(stem, count);
	for (let name in [stem, ...names]) ctx.taken[name] = true;
	return names;
}

// ── Target resolution ────────────────────────────────────────────────

function wan_group_key(ctx, iface) {
	let v4 = match(iface, /^(.+)6$/)?.[1];
	return (v4 && ctx.mwan4.interfaces[v4]) ? v4 : iface;
}

function wan_group(ctx, key) {
	let members = [key];
	if (ctx.mwan4.interfaces[key + '6']) push(members, key + '6');
	return members;
}

function wan_enabled(ctx, name) {
	let s = ctx.mwan4.interfaces[name];
	return !is_tunnel_section(s) && m.uci_bool(s.enabled);
}

function wan_group_keys(ctx) {
	let metric = {};
	for (let r in ctx.mwan4.routes)
		metric[r.interface] = min(metric[r.interface] ?? 256, int(r.metric) || 1);

	let keys_ = uniq(map(filter(keys(ctx.mwan4.interfaces), n => wan_enabled(ctx, n)), n => wan_group_key(ctx, n)));
	let group_metric = key => min(...map(wan_group(ctx, key), n => metric[n] ?? 999));
	return sort(keys_, (a, b) => group_metric(a) - group_metric(b));
}

function add_strategy(ctx, name, groups) {
	let routes = [];
	for (let rank, members in groups)
		for (let iface in members)
			push(routes, { name: claim_name(ctx, sprintf('%s_r%d', name, length(routes) + 1), 64), interface: iface, metric: rank + 1 });
	push(ctx.plan.strategies, { name, routes });
	return name;
}

function wan_strategy(ctx, iface) {
	let key = wan_group_key(ctx, iface);
	ctx.strategies[key] ??= add_strategy(ctx,
		claim_name(ctx, substr(replace(key, /^wan_/, ''), 0, NAME_MAX - length('_first')) + '_first', NAME_MAX),
		map([key, ...filter(wan_group_keys(ctx), k => k != key)], k => wan_group(ctx, k)));
	return ctx.strategies[key];
}

function tunnel_strategy(ctx, iface) {
	let stem = (iface + '_only');
	if (length(stem) > NAME_MAX) stem = substr(replace(iface, /^wg_/, ''), 0, NAME_MAX - length('_only')) + '_only';
	ctx.strategies[iface] ??= add_strategy(ctx, claim_name(ctx, stem, NAME_MAX), [[iface]]);
	return ctx.strategies[iface];
}

function net_addresses(net) {
	return map(as_list(net.addresses ?? net.ipaddr), a => replace('' + a, /\/.*$/, ''));
}

function tunnel_families(net) {
	let addrs = net_addresses(net);
	let families = [];
	if (length(filter(addrs, a => index(a, ':') < 0)) || !length(addrs)) push(families, 'ipv4');
	if (length(filter(addrs, a => index(a, ':') >= 0))) push(families, 'ipv6');
	return families;
}

function host_peer_addresses(net) {
	let hosts = [];
	for (let peer in net.peers)
		for (let ip in as_list(peer.allowed_ips))
			if (match('' + ip, /\/(32|128)$/)) push(hosts, replace('' + ip, /\/.*$/, ''));
	return hosts;
}

// Tunnel peer/dns addresses reachable through the device, else a public anycast address.
function tunnel_track_ips(net, families) {
	let candidates = [...map(as_list(net.dns), d => '' + d), ...host_peer_addresses(net)];
	let ips = [];
	for (let family in families) {
		let valid = filter(candidates, c => m.validate_rule_address(c, family));
		push(ips, ...(length(valid) ? slice(valid, 0, 2) : [PUBLIC_TRACK_IPS[family]]));
	}
	return uniq(ips);
}

function create_tunnel_interface(ctx, iface, net) {
	let id = max(0, ...ctx.mwan4.ids, ...ctx.mwan4.tables) + 1;
	if (id > m.iface_max) return null;

	let families = tunnel_families(net);
	let options = {
		...TUNNEL_TRACKING,
		enabled: '0', type: 'tunnel', default_route: '1',
		transport_type: net.proto == 'wireguard' ? 'wireguard' : 'generic',
		id: '' + id, table_id: '' + id, mark: m.id2mask(id, m.mmx_mask),
		track_ip: tunnel_track_ips(net, families), family: families,
		[MARKER]: '1',
	};
	push(ctx.mwan4.ids, id);
	push(ctx.mwan4.tables, id);
	ctx.mwan4.interfaces[iface] = options;
	push(ctx.plan.interfaces, { name: iface, options });
	return iface;
}

// Returns { strategy } or { reason }; creates the interface/strategy objects on demand.
function resolve_target(ctx, iface) {
	if (!iface) return { reason: 'policy has no interface' };
	if (iface == 'ignore') return { strategy: 'default' };

	let named = match(iface, /^mwan4_strategy_(.+)$/)?.[1];
	if (named) {
		return ctx.mwan4.strategies[named] ? { strategy: named } : { reason: `mwan4 strategy '${named}' does not exist` };
	}

	let section = ctx.mwan4.interfaces[iface];
	if (section) return { strategy: is_tunnel_section(section) ? tunnel_strategy(ctx, iface) : wan_strategy(ctx, iface) };

	let net = ctx.network[iface];
	if (!net) return { reason: `interface '${iface}' is unknown to netifd and mwan4` };
	if (index(TUNNEL_PROTOS, net.proto) < 0) return { reason: `interface '${iface}' (${net.proto}) is not an mwan4 WAN or tunnel` };
	if (index(ctx.ignored, iface) >= 0) return { reason: `interface '${iface}' is ignored in pbr` };
	if (length(ctx.supported) && index(ctx.supported, iface) < 0) return { reason: `interface '${iface}' is unsupported in pbr` };
	if (!create_tunnel_interface(ctx, iface, net)) return { reason: `no free mwan4 interface id for '${iface}'` };
	return { strategy: tunnel_strategy(ctx, iface) };
}

// ── Policy conversion ────────────────────────────────────────────────

function classify_dest(token) {
	if (m.validate_rule_address(token, 'ipv4') || m.validate_rule_address(token, 'ipv6')) return 'dest_ip';
	return m.validate_hostname(token) ? 'domain' : null;
}

// A MAC also matches the IPv6 address pattern, so it is checked first.
function classify_src(ctx, token) {
	if (m.validate_mac(token)) return 'src_mac';
	if (m.validate_rule_address(token, 'ipv4') || m.validate_rule_address(token, 'ipv6')) return 'src_ip';
	if (match(token, /^@[A-Za-z0-9_]+$/) || ctx.network[token]) return 'src_iface';
	return null;
}

// Option groups ORed by pbr; each group becomes its own mwan4 rule variant.
function match_variants(values, fields) {
	let variants = [];
	for (let field in fields) {
		if (field == 'src_iface')
			push(variants, ...map(values.src_iface || [], v => ({ src_iface: replace(v, /^@/, '') })));
		else if (length(values[field]))
			push(variants, { [field]: values[field] });
	}
	return length(variants) ? variants : [{}];
}

function group_tokens(toks, classify) {
	let groups = {};
	let rejected = [];
	for (let t in toks) {
		let field = classify(t);
		if (!field) push(rejected, t);
		else groups[field] = [...(groups[field] || []), (field == 'domain' || field == 'src_mac') ? lc(t) : t];
	}
	return { groups, rejected };
}

function policy_ports(s) {
	let ports = {};
	for (let field in ['src_port', 'dest_port']) {
		let value = join(',', tokens(s[field]));
		if (!length(value)) continue;
		if (!m.validate_ports(value)) return { reason: `unsupported ${field} '${s[field]}'` };
		ports[field] = value;
	}
	return { ports };
}

// Ports need tcp/udp, so a protocol-less policy with ports (pbr default "tcp udp") fans out.
function expand_all_proto(protos) {
	let result = [];
	for (let p in protos) push(result, ...(p == 'all' ? ['tcp', 'udp'] : [p]));
	return result;
}

function policy_protos(s, has_ports) {
	let protos = map(tokens(s.proto), p => lc(p));
	if (!length(protos)) protos = ['all'];
	if (has_ports) protos = uniq(expand_all_proto(protos));
	let bad = filter(protos, p => !m.validate_protocol(p));
	return length(bad) ? { reason: `unsupported protocol '${bad[0]}'` } : { protos };
}

function describe(variant, strategy) {
	let parts = map(filter(keys(variant), k => k != 'proto' || variant.proto != 'all'), k => `${k}=${join(',', as_list(variant[k]))}`);
	return `${join(' ', parts) || 'all traffic'} -> ${strategy}`;
}

function policy_variants(ctx, s, result) {
	let src = group_tokens(tokens(s.src_addr), t => classify_src(ctx, t));
	let dest = group_tokens(tokens(s.dest_addr), classify_dest);
	let rejected = [...src.rejected, ...dest.rejected];
	if (length(rejected)) return { reason: `unsupported address '${rejected[0]}'` };

	let ports = policy_ports(s);
	if (ports.reason) return ports;
	let protos = policy_protos(s, length(keys(ports.ports)));
	if (protos.reason) return protos;

	let srcs = match_variants(src.groups, ['src_ip', 'src_mac', 'src_iface']);
	let dests = match_variants(dest.groups, ['dest_ip', 'domain']);
	if (!length(keys(src.groups)) && !length(keys(dest.groups)) && !length(keys(ports.ports)))
		return { reason: 'policy matches all traffic' };

	let variants = [];
	for (let sv in srcs)
		for (let dv in dests)
			for (let proto in protos.protos)
				push(variants, { ...sv, ...dv, ...(proto == 'all' ? {} : { proto }), ...(index(['tcp', 'udp'], proto) >= 0 ? ports.ports : {}) });
	return { variants };
}

function convert_policy(ctx, s) {
	let toks = tokens(s.dest_addr);
	let name = trim(s.name || '') || toks[0] || s['.name'];
	let enabled = m.uci_bool(s.enabled ?? '1');
	let result = { pbr_section: s['.name'], name, enabled, action: 'skip', reason: '', rule: null, rules: [], target: s.interface ?? null, strategy: null, summary: '' };

	let vars = policy_variants(ctx, s, result);
	let target = vars.reason ? vars : resolve_target(ctx, s.interface);
	if (target.reason) return { ...result, reason: target.reason };

	let names = claim_variant_names(ctx, slug(name, RULE_BASE_MAX) || 'policy', length(vars.variants));
	for (let i, variant in vars.variants) {
		let options = {
			...variant, label: name, enabled: enabled ? '1' : '0', local: s.chain == 'output' ? '1' : '0',
			use_strategy: target.strategy, [MARKER]: '1',
		};
		push(ctx.plan.rules, { name: names[i], options });
	}
	if (enabled && ctx.mwan4.interfaces[s.interface]) ctx.used[s.interface] = true;
	return { ...result, action: 'import', rule: names[0], rules: names, strategy: target.strategy,
		summary: join('; ', map(vars.variants, v => describe(v, target.strategy))) };
}

function unmapped_warnings(pbr_sections) {
	let warnings = [];
	for (let s in pbr_sections) {
		switch (s['.type']) {
		case 'dns_policy':
			push(warnings, `dns_policy '${s.name || s['.name']}' is not supported by mwan4`);
			break;
		case 'include':
			push(warnings, `include '${s.path}' is not supported by mwan4`);
			break;
		case 'pbr':
			for (let key in filter(keys(s), k => match(k, /_dscp$/)))
				push(warnings, `pbr option ${key} '${s[key]}' (interface DSCP tagging) is not supported by mwan4`);
			break;
		}
	}
	return warnings;
}

function build_plan() {
	let pbr = read_sections('pbr', null);
	let globals = filter(pbr, s => s['.type'] == 'pbr')[0] || {};
	let ctx = {
		mwan4: read_mwan4(), network: read_network(), strategies: {}, used: {},
		ignored: as_list(globals.ignored_interface), supported: as_list(globals.supported_interface),
		plan: { interfaces: [], strategies: [], rules: [] },
	};
	ctx.taken = ctx.mwan4.taken;

	let policies = map(filter(pbr, s => s['.type'] == 'policy'), s => convert_policy(ctx, s));
	for (let iface in ctx.plan.interfaces)
		iface.options.enabled = ctx.used[iface.name] ? '1' : '0';
	return { plan: ctx.plan, policies, warnings: unmapped_warnings(pbr) };
}

// ── Applying ─────────────────────────────────────────────────────────

function set_options(c, name, options) {
	for (let key, value in options)
		if (value != null && value != '' && !(type(value) == 'array' && !length(value)))
			c.set('mwan4', name, key, value);
}

function add_section(c, name, stype, options) {
	c.set('mwan4', name, stype);
	set_options(c, name, options);
}

function remove_previous(c) {
	let stale = [];
	c.foreach('mwan4', null, s => s['.type'] != 'interface' && s[MARKER] != null ? push(stale, s['.name']) : null);
	for (let name in stale) c.delete('mwan4', name);
}

// Re-importing keeps the rule_id of every rule that comes back under the same name.
function rule_ids(c) {
	let ids = {};
	c.foreach('mwan4', 'rule', s => s.rule_id != null ? (ids[s['.name']] = s.rule_id) : null);
	return ids;
}

// Default catch-alls must stay the last rules.
function move_defaults_last(c) {
	let count = 0;
	c.foreach('mwan4', null, s => ++count);
	for (let name in DEFAULT_RULES)
		if (c.get('mwan4', name)) c.reorder('mwan4', name, count - 1);
}

function write_plan(plan) {
	let c = cursor();
	c.load('mwan4');
	writefile(BACKUP, readfile('/etc/config/mwan4') || '');

	let ids = rule_ids(c);
	remove_previous(c);
	for (let iface in plan.interfaces) add_section(c, iface.name, 'interface', iface.options);
	for (let strategy in plan.strategies) {
		for (let route in strategy.routes)
			add_section(c, route.name, 'route', { interface: route.interface, metric: '' + route.metric, weight: '1', [MARKER]: '1' });
		add_section(c, strategy.name, 'strategy', { use_route: map(strategy.routes, r => r.name), last_resort: 'unreachable', [MARKER]: '1' });
	}
	for (let rule in plan.rules) add_section(c, rule.name, 'rule', { ...rule.options, rule_id: ids[rule.name] });
	m.assign_rule_ids(c);
	move_defaults_last(c);

	c.save('mwan4');
	c.commit('mwan4');
}

function pbr_import(args) {
	let built = build_plan();
	let apply = !!args?.apply;
	if (apply) write_plan(built.plan);

	return {
		ok: true, applied: apply, policies: built.policies, warnings: built.warnings,
		interfaces: map(built.plan.interfaces, i => i.name),
		strategies: map(built.plan.strategies, s => s.name),
	};
}

export default { pbr_import };

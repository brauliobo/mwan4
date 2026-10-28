import { readfile, writefile } from 'fs';

function load_config(name) {
	let data = readfile(getenv('KERNEL_WORK') + '/uci/' + name + '.json');
	if (!data) return null;
	let raw = json(data), cfg = {}, n = 0;
	for (let stype in keys(raw))
		for (let sobj in raw[stype])
			cfg[sobj['.name']] = { ...sobj, '.type': stype, '.anonymous': false, '.index': n++ };
	return cfg;
}

export function cursor() {
	return {
		_c: {},
		load: function(file) { let c = load_config(file); if (c) this._c[file] = c; return !!c; },
		get: function(config, section, option) {
			let s = this._c[config]?.[section];
			return s ? (option ? s[option] : s['.type']) : null;
		},
		get_all: function(config, section) { return section ? this._c[config]?.[section] : this._c[config]; },
		set: function(config, section, option, value) { this._c[config][section][option] = '' + value; return true; },
		save: function() { return true; },
		commit: function(config) {
			let out = {};
			for (let sid, s in this._c[config]) {
				out[s['.type']] ??= [];
				push(out[s['.type']], s);
			}
			writefile(getenv('KERNEL_WORK') + '/uci/' + config + '.json', sprintf('%J', out));
			return true;
		},
		foreach: function(config, stype, cb) {
			let cfg = this._c[config];
			if (!cfg) return false;
			for (let sid in sort(keys(cfg), (a, b) => cfg[a]['.index'] - cfg[b]['.index']))
				if ((stype == null || cfg[sid]['.type'] == stype) && cb({ ...cfg[sid] }) === false) break;
			return true;
		},
	};
}

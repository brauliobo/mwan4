let mocklib = global.mocklib; // ucode-lsp disable

let byte = (str, off) => { // ucode-lsp disable
	let v = ord(str, off);
	return type(v) == 'array' ? v[0] : v;
};

let hash = (s) => { // ucode-lsp disable
	let h = 7;

	for (let i = 0; i < length(s); i++)
		h = h * 31 + byte(s, i);

	return h;
};

let id = (config, t, n) => { // ucode-lsp disable
	while (true) {
		let id = sprintf('cfg%08x', hash(t + n));

		if (!exists(config, id))
			return id;

		n++;
	}
};

let fixup_config = (config) => { // ucode-lsp disable
	let rv = {};
	let n_section = 0;

	for (let stype in config) {
		switch (type(config[stype])) {
		case 'object':
			config[stype] = [ config[stype] ];
			/* fall through */

		case 'array':
			for (let idx, sobj in config[stype]) {
				let sid, anon;

				if (exists(sobj, '.name') && !exists(rv, sobj['.name'])) {
					sid = sobj['.name'];
					anon = false;
				}
				else {
					sid = id(rv, stype, idx);
					anon = true;
				}

				rv[sid] = {
					'.index': n_section++,
					...sobj,
					'.name': sid,
					'.type': stype,
					'.anonymous': anon
				};
			}

			break;
		}
	}

	for (let n, sid in sort(keys(rv), (a, b) => rv[a]['.index'] - rv[b]['.index']))
		rv[sid]['.index'] = n;

	return rv;
};

return {
	cursor: () => ({
		_configs: {},

		load: function(file) {
			let basename = replace(file, /^.+\//, ''),
			    path = sprintf("uci/%s.json", basename),
			    mock = mocklib.read_json_file(path);

			/* Configs committed through a cursor shadow the fixture. */
			if (exists(mocklib.uci_store, basename)) {
				this._configs[basename] = json(sprintf('%J', mocklib.uci_store[basename]));
				return true;
			}

			if (!mock || mock != mock) {
				mocklib.I("No configuration fixture defined for uci package %s.", file);
				mocklib.I("Provide a mock configuration through the following JSON file:\n%s\n", path);

				return null;
			}

			this._configs[basename] = fixup_config(mock);
		},

		_get_section: function(config, section) {
			if (!exists(this._configs, config)) {
				this.load(config);

				if (!exists(this._configs, config))
					return null;
			}

			let cfg = this._configs[config],
			    extended = match('' + section, /^@([A-Za-z0-9_-]+)\[(-?[0-9]+)\]$/);

			if (extended) {
				let stype = extended[1],
				    sindex = +extended[2];

				let sids = sort(
					filter(keys(cfg), sid => cfg[sid]['.type'] == stype),
					(a, b) => cfg[a]['.index'] - cfg[b]['.index']
				);

				if (sindex < 0)
					sindex = length(sids) + sindex;

				return cfg[sids[sindex]];
			}

			return cfg[section];
		},

		get: function(config, section, option) {
			let sobj = this._get_section(config, section);

			if (option && index(option, ".") == 0)
				return null;
			else if (sobj && option)
				return sobj[option];
			else if (sobj)
				return sobj[".type"];
		},

		get_all: function(config, section) {
			return section ? this._get_section(config, section) : this._configs[config];
		},

		_sorted: function(config) {
			let cfg = this._configs[config];
			return sort(keys(cfg), (a, b) => cfg[a]['.index'] - cfg[b]['.index']);
		},

		_reindex: function(config, order) {
			for (let n, sid in order)
				this._configs[config][sid]['.index'] = n;
		},

		set: function(config, section, option, value) {
			if (!exists(this._configs, config))
				this.load(config);

			let cfg = this._configs[config];

			if (value == null) {
				cfg[section] = { '.name': section, '.type': option, '.anonymous': false, '.index': length(keys(cfg)) };
				return true;
			}

			cfg[section][option] = type(value) == 'array' ? map(value, v => '' + v) : '' + value;
			return true;
		},

		delete: function(config, section, option) {
			let cfg = this._configs[config];

			if (option)
				delete cfg[section][option];
			else {
				delete cfg[section];
				this._reindex(config, this._sorted(config));
			}

			return true;
		},

		reorder: function(config, section, index) {
			let order = filter(this._sorted(config), sid => sid != section);

			splice(order, index, 0, section);
			this._reindex(config, order);

			return true;
		},

		save: function(config) {
			return true;
		},

		commit: function(config) {
			mocklib.uci_store[config] = this._configs[config];

			return true;
		},

		foreach: function(config, stype, cb) {
			let rv = false;

			if (!exists(this._configs, config))
				this.load(config);

			if (exists(this._configs, config)) {
				let cfg = this._configs[config],
				    sids = sort(keys(cfg), (a, b) => cfg[a]['.index'] - cfg[b]['.index']);

				for (let i, sid in sids) {
					if (stype == null || cfg[sid]['.type'] == stype) {
						if (cb({ ...(cfg[sid]) }) === false)
							break;

						rv = true;
					}
				}
			}

			return rv;
		}
	})
};

'use strict';
// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright 2026 MOSSDeF, Stan Grishin (stangri@melmac.ca).

import { popen } from 'fs';

const FEATURE_PACKAGES = {
	'advanced_probes': [ 'httping', 'nping', 'iputils-arping' ],
	'bfd':             [ 'frr', 'frr-zebra', 'frr-bfdd', 'frr-vtysh' ],
	'ipsec':           [ 'strongswan-swanctl', 'strongswan-mod-kdf' ],
	'openvpn':         [ 'openvpn-openssl' ],
	'pbr':             [ 'pbr', 'luci-app-pbr' ],
	'vrf':             [ 'ip-full', 'kmod-vrf' ],
	'wireguard':       [ 'wireguard-tools', 'kmod-wireguard', 'luci-proto-wireguard' ],
};

function shell_quote(s) {
	return "'" + replace('' + s, "'", "'\\''") + "'";
}

function run(c) {
	return system(c + ' >/dev/null 2>&1');
}

function cmd_output(c) {
	let p = popen(c, 'r');
	if (!p) return '';
	let out = p.read('all');
	p.close();
	return out || '';
}

function contract_problem(code, section, message) {
	return {
		'code':    code,
		'section': section || null,
		'message': message,
	};
}

function helper_available(name) {
	if (!name) return true;
	return length(trim(cmd_output(sprintf('command -v %s 2>/dev/null', shell_quote(name))))) > 0;
}

function package_manager() {
	if (helper_available('apk')) return 'apk';
	if (helper_available('opkg')) return 'opkg';
	return null;
}

function validate_package_name(value) {
	return value != null && !!match('' + value, /^[A-Za-z0-9][A-Za-z0-9_.+:-]{0,127}$/);
}

function validate_feature_name(value) {
	return value != null && exists(FEATURE_PACKAGES, '' + value);
}

function feature_packages(feature) {
	return validate_feature_name(feature) ? FEATURE_PACKAGES['' + feature] : [];
}

function feature_package_map() {
	let result = {};

	for (let feature in sort(keys(FEATURE_PACKAGES))) {
		let packages = [];
		for (let pkgname in FEATURE_PACKAGES[feature])
			push(packages, pkgname);
		result[feature] = packages;
	}

	return result;
}

function package_installed(manager, pkgname) {
	if (!validate_package_name(pkgname)) return false;
	if (manager == 'apk')
		return system(sprintf('apk info -e %s >/dev/null 2>&1', shell_quote(pkgname))) == 0;
	if (manager == 'opkg')
		return system(sprintf('opkg list-installed %s >/dev/null 2>&1', shell_quote(pkgname))) == 0;
	return false;
}

function package_version(manager, pkgname) {
	if (!validate_package_name(pkgname)) return null;
	let out = '';
	if (manager == 'apk') {
		let prefix = pkgname + '-';
		out = trim(cmd_output(sprintf('apk list --installed %s 2>/dev/null', shell_quote(pkgname))));
		for (let line in split(out, '\n')) {
			line = trim(line);
			if (substr(line, 0, length(prefix)) != prefix) continue;
			let fields = split(substr(line, length(prefix)), ' ');
			return length(fields[0]) ? fields[0] : null;
		}
	} else if (manager == 'opkg') {
		let prefix = pkgname + ' - ';
		out = trim(cmd_output(sprintf('opkg list-installed %s 2>/dev/null', shell_quote(pkgname))));
		for (let line in split(out, '\n')) {
			line = trim(line);
			if (substr(line, 0, length(prefix)) != prefix) continue;
			return trim(substr(line, length(prefix))) || null;
		}
	}
	return null;
}

function diagnostics_packages() {
	let manager = package_manager();
	let features = {};
	let missing = [];
	let warnings = [];

	if (!manager)
		push(warnings, { 'code': 'packageManagerMissing', 'message': 'Neither apk nor opkg is available, so package readiness could not be verified.' });

	for (let feature in sort(keys(FEATURE_PACKAGES))) {
		let rows = [];
		let ready = manager != null;
		for (let pkgname in FEATURE_PACKAGES[feature]) {
			let installed = manager ? package_installed(manager, pkgname) : false;
			let version = installed ? package_version(manager, pkgname) : null;
			if (!installed) {
				ready = false;
				push(missing, { 'feature': feature, 'package': pkgname });
			}
			push(rows, {
				'name':      pkgname,
				'installed': installed,
				'version':   version,
			});
		}

		features[feature] = {
			'ready':    ready,
			'packages': rows,
		};
	}

	return {
		'manager':  manager,
		'features': features,
		'missing':  missing,
		'warnings': warnings,
	};
}

function install_feature_packages(feature) {
	let manager = package_manager();
	let packages = feature_packages(feature);
	let errors = [];

	if (!length(packages))
		push(errors, contract_problem('invalidFeature', feature,
			sprintf("Unsupported package feature '%s'.", feature || '')));
	if (!manager)
		push(errors, contract_problem('packageManagerMissing', feature,
			'Neither apk nor opkg is available.'));

	if (length(errors))
		return { 'ok': false, 'feature': feature || null, 'packages': packages, 'manager': manager, 'errors': errors };

	let quoted = [];
	for (let pkgname in packages)
		push(quoted, shell_quote(pkgname));

	let update_cmd = manager == 'apk' ? 'apk --allow-untrusted update' : 'opkg update';
	let install_cmd = manager == 'apk'
		? 'apk --allow-untrusted add --upgrade ' + join(' ', quoted)
		: 'opkg install ' + join(' ', quoted);

	let rc_update = run(update_cmd);
	let rc_install = rc_update == 0 ? run(install_cmd) : 1;

	if (rc_update != 0)
		push(errors, contract_problem('packageIndexUpdateFailed', feature,
			sprintf("Package index update failed for '%s'.", manager)));
	if (rc_update == 0 && rc_install != 0)
		push(errors, contract_problem('packageInstallFailed', feature,
			sprintf("Package installation failed for feature '%s'.", feature)));

	return {
		'ok':        length(errors) == 0,
		'feature':   feature,
		'packages':  packages,
		'manager':   manager,
		'commands':  [ update_cmd, install_cmd ],
		'errors':    errors,
	};
}

export default {
	FEATURE_PACKAGES,
	feature_package_map,
	diagnostics_packages,
	install_feature_packages,
	package_installed,
	package_manager,
	package_version,
};

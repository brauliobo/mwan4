#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const sourcePath = process.env.MWAN4TRACK_SOURCE || path.join(root, 'files/lib/mwan4/mwan4track.uc');
const source = sourcePath == '-' ? fs.readFileSync(0, 'utf8') : fs.readFileSync(sourcePath, 'utf8');

assert.match(source, /function parse_ping_result\(result\)/,
	'ping probe output should be parsed into latency/loss metrics');
assert.match(source, /function parse_httping_result\(result\)/,
	'httping probe output should be parsed into latency/loss metrics');
assert.match(source, /case 'nslookup':/,
	'DNS nslookup probes should remain available to LuCI when the helper is installed');

assert.doesNotMatch(source,
	/if \(!check_quality\) \{\s*result = wrap\(sprintf\('%s -n -c %d -W %d -s %d -t %d -q %s >\/dev\/null 2>&1'/,
	'ping availability checks must not discard probe output before target metrics can be recorded');
assert.doesNotMatch(source,
	/if \(!check_quality\) \{\s*result = wrap\(sprintf\('httping -c %d -t %d -q %s >\/dev\/null 2>&1'/,
	'httping availability checks must not discard probe output before target metrics can be recorded');

assert.match(source, /update_track\(track_ip, 'up', p\.latency, p\.loss\)/,
	'successful availability-only checks should persist latency/loss for LuCI display');
assert.match(source, /update_track\(track_ip, 'down', p\.latency, p\.loss\)/,
	'failed availability-only checks should persist latency/loss for LuCI display');

console.log('tracker metric persistence expectations passed');

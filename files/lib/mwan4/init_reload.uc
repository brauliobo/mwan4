'use strict';
// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright 2026 MOSSDeF, Stan Grishin (stangri@melmac.ca).
//
// Called by init.d/mwan4 when the service is already running: applies the configuration without a teardown.
// A non-zero exit means the configuration was rejected and the running state is untouched.

import m from 'mwan4';

m.set_scriptname('mwan4-init');
m.init(null, true);

exit(m.reload_running() ? 0 : 1);

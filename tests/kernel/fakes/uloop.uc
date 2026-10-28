// Runs nothing: the tracker starts, connects and returns.
return {
	init: function() {},
	timer: function(ms, cb) { return { cancel: function() {} }; },
	signal: function() {},
	run: function() {},
	done: function() {},
};

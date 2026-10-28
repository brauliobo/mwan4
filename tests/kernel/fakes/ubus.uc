let fs = require('fs');

return {
	connect: function() {
		return {
			call: function(object, method, args) {
				let data = fs.readfile(getenv('KERNEL_WORK') + '/ubus/' + object + '~' + method + '.json');
				return data ? json(data) : null;
			},
		};
	},
};

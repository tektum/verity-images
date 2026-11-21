const greeting = require('greeting');
process.stdout.write(`${greeting} node=${process.versions.node.split('.')[0]}\n`);

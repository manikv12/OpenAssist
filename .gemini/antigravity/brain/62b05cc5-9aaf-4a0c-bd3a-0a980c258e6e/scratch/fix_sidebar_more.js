const fs = require('fs');
const path = require('path');
const file = path.join(process.cwd(), 'electron-react/src/styles.css');
let content = fs.readFileSync(file, 'utf8');

// Also remove 56px and 34px blur variants added for sidebar
content = content.replace(/.*backdrop-filter: blur\(var\(--theme-sidebar-blur.*$/gm, '');
content = content.replace(/.*backdrop-filter: blur\(56px\).*$/gm, '');
content = content.replace(/.*backdrop-filter: blur\(34px\).*$/gm, '');

fs.writeFileSync(file, content, 'utf8');
console.log('Fixed styles.css more');

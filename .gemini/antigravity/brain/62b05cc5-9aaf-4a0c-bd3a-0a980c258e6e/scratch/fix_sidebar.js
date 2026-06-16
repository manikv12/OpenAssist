const fs = require('fs');
const path = require('path');
const file = path.join(process.cwd(), 'electron-react/src/styles.css');
let content = fs.readFileSync(file, 'utf8');

// Remove backdrop-filter lines that are inside .app-sidebar or related blocks.
// A safe way is to replace lines matching backdrop-filter if they have theme-sidebar-blur or specific blurs
content = content.replace(/.*backdrop-filter: blur\(var\(--theme-sidebar-blur.*$/gm, '');
content = content.replace(/.*backdrop-filter: blur\(34px\).*$/gm, '');
content = content.replace(/.*backdrop-filter: blur\(28px\).*$/gm, '');

fs.writeFileSync(file, content, 'utf8');
console.log('Fixed styles.css');

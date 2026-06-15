const fs = require('fs');
const path = require('path');
const file = path.join(process.cwd(), 'web/chat/src/styles.css');
let content = fs.readFileSync(file, 'utf8');

// The sidebar in web/chat/src/styles.css is .oa-react-sidebar
// Remove its backdrop-filter
content = content.replace(/\s*-webkit-backdrop-filter: blur\(var\(--glass-blur\)\) saturate\(180%\);\s*\n\s*backdrop-filter: blur\(var\(--glass-blur\)\) saturate\(180%\);/gm, '');

fs.writeFileSync(file, content, 'utf8');
console.log('Fixed web styles.css');

const fs = require('fs');
const path = require('path');
const file = path.join(process.cwd(), 'web/chat/src/styles.css');
let content = fs.readFileSync(file, 'utf8');

// The sidebar in web/chat/src/styles.css is .sidebar-shell
// Let's remove backdrop-filter from it. We can just replace all backdrop-filter lines that are inside .sidebar-shell
// A simple way is to match --glass-blur or just remove all backdrop-filter in styles.css that are for sidebar.
// Actually, let's just do the same replace for any var(--glass-blur) or similar that might be causing it.
// Let's first check what it is.

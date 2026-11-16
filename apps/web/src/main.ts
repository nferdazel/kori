import "./app.css";
import { startConfig } from "./config";
import { startOverview } from "./overview";
import { startRequests } from "./requests";
import { startRoutes } from "./routes";

const PAGES: Record<string, string> = {
  "1": "index.html",
  "2": "requests.html",
  "3": "routes.html",
  "4": "config.html",
};

// 1 to 4 move between pages, except while a filter has focus. A shortcut, not a dependency: every
// page is a plain link and JavaScript is not needed to navigate.
document.addEventListener("keydown", (e) => {
  if (e.metaKey || e.ctrlKey || e.altKey) return;
  const target = e.target as HTMLElement | null;
  if (target && /^(SELECT|INPUT|TEXTAREA)$/.test(target.tagName)) return;
  const dest = PAGES[e.key];
  if (dest) {
    e.preventDefault();
    location.href = dest;
  }
});

const page = document.body.dataset.page;
if (page === "index.html") startOverview();
else if (page === "requests.html") startRequests();
else if (page === "routes.html") startRoutes();
else if (page === "config.html") startConfig();

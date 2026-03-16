---
title: 'We Put a Browser Inside Electron (and Rewrote It Twice)'
description: 'The story of building an embedded browser for an anime tracking app — from native overlays to DOM elements, z-index nightmares, and why the "deprecated" approach won.'
pubDate: '2026-03-16'
tags: ['electron', 'shiroani', 'architecture']
---

We put a browser inside an Electron app, and it only took rewriting it twice to get it right.

ShiroAni is an anime tracking desktop app. Users watch anime on Polish community sites like ogladajanime.pl and shinden.pl — so instead of making people alt-tab between a tracker and a browser, we embedded one. Open a tab, watch your show, and the app tracks it automatically. Your Discord status even updates with what you're watching.

Sounds simple enough. It was not.

## Attempt 1: The "Correct" Way

Electron's recommended approach for embedding web content is `WebContentsView` — a native view that renders a separate web page. Each browser tab gets its own `WebContentsView` instance, managed in the main process. This is the "proper" Electron architecture. Separate processes, clean boundaries, security isolation.

We built it. A 555-line `BrowserManager` class in the main process, managing a `Map<string, ManagedTab>`. Fifteen IPC handlers covering every operation — open tab, close tab, switch tab, navigate, go back, go forward, reload, resize, hide, show, reorder, get state, execute script, and more.

It worked. For about two days.

### The z-index nightmare

Here's the thing about `WebContentsView`: **it's a native overlay that floats above the DOM.** It doesn't participate in CSS. It doesn't know about your React components. It paints directly on top of the window at the OS level.

This means `display: none` does nothing. `visibility: hidden` does nothing. `z-index` does nothing. If you want to hide the browser — say, because the user clicked "Library" in the sidebar — you have to explicitly call IPC to the main process:

```typescript
// The old way: native overlay ignores CSS entirely
hideAllViews(): void {
  for (const tab of this.tabs.values()) {
    try {
      this.mainWindow.contentView.removeChildView(tab.view);
    } catch { /* View may already be removed */ }
  }
}
```

Every single view transition in the app needed an explicit `browser:hide` IPC call. Forget one, and the browser content paints over your library, your settings, everything.

### The resize problem

Since `WebContentsView` doesn't participate in CSS layout, you can't just put it in a flex container and let it fill the available space. Instead, the renderer had to:

1. Render a placeholder `<div>` where the browser should be
2. Attach a `ResizeObserver` to that div
3. Measure the exact pixel bounds
4. Send them over IPC to the main process
5. Main process calls `tab.view.setBounds({ x, y, width, height })`

This created constant visual glitches during window resize. And when you exited fullscreen? There was a timing gap between the fullscreen exit and the `ResizeObserver` reporting correct bounds. The solution? Hardcoded magic numbers:

```typescript
const SIDEBAR_WIDTH = 68;
const CHROME_HEIGHT = 108;
```

These were fallback bounds. If you ever changed the sidebar width or toolbar height, you had to remember to update two hardcoded pixel values buried in a different file. Cool.

### The state synchronization tax

Tab state — URL, title, loading status, navigation history — lived in the main process. But the React UI needed it. So every change had to be forwarded:

```
Main process: tab.webContents.on('did-navigate', ...)
  → mainWindow.webContents.send('browser:tab-updated', tabId, changes)
    → Renderer: ipcRenderer.on('browser:tab-updated', ...)
      → Update React state
```

Every. Single. State. Change. Across the process boundary. With all the race conditions that implies.

### The straw that broke it

Over twelve commits in two days, we kept layering features: tab persistence, HTML5 fullscreen, `executeScript` for page metadata scraping, tab reordering, favicon tracking. Each feature added more IPC handlers and more state sync complexity. The browser manager grew to 555 lines with 15 IPC handlers.

The fullscreen support alone was absurd. When a video player entered HTML5 fullscreen, the main process had to: set `mainWindow.setFullScreen(true)`, resize the view to cover the entire screen, and tell the renderer to hide its chrome. When exiting, it had to *guess* the chrome dimensions using those magic pixel numbers while waiting for the `ResizeObserver` to catch up.

Two days in, it was clear this wasn't sustainable.

## Attempt 2: The "Deprecated" Way

Electron has another way to embed web content: the `<webview>` tag. It's technically deprecated — Electron recommends `WebContentsView` instead. But `<webview>` has one killer property: **it's a DOM element.**

A DOM element that participates in CSS layout. That respects `display: none`. That lives in the React component tree. That you can reference with a ref and call methods on directly.

We rewrote the entire browser in a single commit.

### The contrast is absurd

Hiding the browser:

```typescript
// Before: IPC to main process to manipulate native overlays
await window.electronAPI.browser.hide();

// After: CSS
const ACTIVE_STYLE = { display: 'inline-flex', width: '100%', height: '100%' };
const HIDDEN_STYLE = { display: 'none' };
```

Opening a tab:

```typescript
// Before: IPC round-trip, main process creates WebContentsView,
// returns tab state, renderer syncs...

// After: local Zustand state update
openTab(url) {
  const id = crypto.randomUUID();
  set((state) => ({
    tabs: [...state.tabs, { id, url, title: 'New Tab', ... }],
    activeTabId: id,
  }));
}
```

Navigating:

```typescript
// Before: IPC to main process, main process calls loadURL on WebContentsView

// After: direct DOM method call
getWebview(activeTabId)?.loadURL(url);
```

No IPC. No state sync. No resize observers. No magic pixel numbers.

### What the main process does now

The `BrowserManager` went from 555 lines managing tabs, views, lifecycle, and state to 207 lines managing exactly one thing: **the session.**

```typescript
// The entire file's comment says it all:
// "Tab lifecycle is entirely handled by the renderer process
//  via <webview> DOM elements."
```

It configures the `persist:browser` session with:
- A Chrome user agent (so anime sites don't serve degraded content)
- Media permissions (video players need `media`, `mediaKeySystem`, `fullscreen`)
- Header manipulation for iframe embedding (surgical — only strips `frame-ancestors` from subframe CSP, leaves main frame security intact)
- Adblock integration via `@ghostery/adblocker-electron`

Fifteen IPC handlers became two: `toggle-adblock` and `set-fullscreen`.

### The numbers

| Metric | WebContentsView | `<webview>` |
|--------|-----------------|-------------|
| Browser manager | 555 lines | 207 lines |
| IPC handlers | 15 | 2 |
| Tab state location | Main process | React/Zustand |
| Hiding a tab | IPC + native removeChildView | `display: none` |
| Resizing | ResizeObserver + IPC + setBounds | CSS flex layout |
| Magic pixel constants | 2 | 0 |
| Time to build | 2 days | 1 day |
| Files deleted in migration | 3 | — |

## The Messy Details

The migration wasn't just "swap WebContentsView for webview." There were real architectural decisions hiding in the details.

### Two sessions, two security models

The app runs two Electron sessions with different security postures:

**`defaultSession`** powers the React renderer. It has strict CSP (`script-src 'self'`, `object-src 'none'`), only allows clipboard permissions, and is locked down. This is the "trusted" zone.

**`persist:browser`** powers all webview tabs. It has a Chrome user agent, permissive media permissions, and strips iframe-blocking headers from subframe responses. The `persist:` prefix means cookies survive app restarts. This is the "wild west" zone — anime sites do whatever they want.

The critical subtlety: the CSP on `defaultSession` is **URL-scoped**. It only applies to the renderer's own pages:

```typescript
const urlFilter = isDev
  ? { urls: [`http://localhost:${VITE_DEV_PORT}/*`] }
  : { urls: ['file://*'] };
```

Without this filter, the strict CSP would also apply to webview content loaded through the default session, breaking every website. This took an embarrassingly long time to figure out.

### Security: will-attach-webview

Every `<webview>` tag goes through a security gate before it's allowed to attach:

```typescript
mainWindow.webContents.on('will-attach-webview', (_event, prefs) => {
  prefs.nodeIntegration = false;
  prefs.contextIsolation = true;
  prefs.allowRunningInsecureContent = true;
  delete prefs.preload;
});
```

Two things stand out:
- `allowRunningInsecureContent = true` because anime sites frequently load HTTP resources from HTTPS pages. Welcome to the real web.
- We explicitly *don't* enable sandbox mode. macOS sandboxed renderers break cross-origin iframes, which are essential for embedded video players. Discovered the hard way.

### Discord knows what you're watching

The fun payoff: since tabs live in the renderer, we can read their URLs directly. A `detectAnimeFromUrl()` function pattern-matches against known anime sites:

```typescript
// ogladajanime.pl: /anime/naruto-shippuuden/player/12345
// → title: "Naruto Shippuuden", episode from URL structure

// shinden.pl: /episode/789-anime-title/view/456
// → title extracted from slug

// youtube.com: page title minus " - YouTube" suffix
```

This fires on every navigation event. The main process throttles Discord RPC updates to one every 15 seconds. Your friends see "Watching Naruto Shippuuden" in your Discord status, and the community bot can post it to an activity channel.

The entire detection pipeline runs in the renderer. No IPC. Just reading a DOM element's URL and parsing it.

## What I Learned

**Native overlays are the wrong abstraction for embedded browsing.** `WebContentsView` is great when you need process isolation for a fixed-position panel. It's terrible when you need something that participates in your app's layout and responds to CSS.

**State should live where it's used.** Tab state is consumed by React components. Making it live in the main process and syncing over IPC was pure overhead with zero benefit.

**The IPC tax is real.** Every process boundary crossing adds latency, complexity, and race conditions. Fifteen IPC handlers is a smell. Two is right.

**"Deprecated" doesn't mean "wrong."** The `<webview>` tag is deprecated because Electron wants people to use `WebContentsView`. But for our use case — a DOM element that renders web content within a React layout — webview is objectively the better tool. Sometimes the deprecated API is the one that actually solves your problem.

**Rewrite early.** We caught the architecture mismatch two days in. If we'd waited longer and built more features on top of the native overlay approach, the migration would have been much more painful. The best time to rewrite a bad foundation is before you've built too much on it.

---

The browser now works. Tabs open and close. Videos play. Adblock blocks. Discord updates. And the code is simple enough that I can explain it without a whiteboard.

That's the real test, isn't it?

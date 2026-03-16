---
title: 'Hello, World'
description: 'The obligatory first post — why I started this blog, what to expect, and what I have been building lately.'
pubDate: '2026-03-16'
tags: ['meta', 'intro']
---

If you're reading this, the blog is live. Nice.

I've been meaning to write things down for a while now. Not tutorials (there are plenty of those), but more like **field notes** from building stuff — the decisions that worked, the ones that didn't, and everything in between.

## What I'm working on

Right now, most of my time goes into **ShiroAni** — an Electron app for tracking anime, complete with a built-in browser, Discord Rich Presence, and a community Discord bot. The stack is TypeScript everywhere: React + Zustand on the frontend, NestJS + Prisma on the backend, and discord.js powering the bot.

It's been a wild ride. Turns out, building a browser inside an Electron app teaches you a lot about session management, CSP headers, and why `<webview>` is both a blessing and a curse.

## What to expect here

Mostly posts about:

- **Building desktop apps** with Electron — the good, the bad, and the chromium
- **Discord bots** — NestJS patterns, gateway events, the joys of rate limits
- **Frontend things** — React patterns, Zustand, Tailwind, whatever I'm experimenting with
- **Random explorations** — new tools, libraries, side projects

No schedule, no pressure. Just writing when something feels worth sharing.

Let's see where this goes.

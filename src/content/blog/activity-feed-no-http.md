---
title: 'Building an Activity Feed Without Opening a Single Port'
description: 'How we built a "currently watching" feed for our Discord community — and why we ditched the HTTP endpoint in favor of something already running.'
pubDate: '2026-03-16'
tags: ['discord', 'shiroani', 'architecture']
---

We wanted an activity feed for our Discord server. When a community member watches anime in the ShiroAni desktop app, the bot posts it to a channel: "Shirone is watching Attack on Titan." Simple social feature, helps people discover shows, maybe sparks a conversation.

The obvious approach: add an HTTP endpoint to the bot, have the desktop app POST to it. Simple REST call.

We didn't do that. Here's why.

## The obvious approach

ShiroAni's Discord bot runs on NestJS. It's currently a pure Discord gateway client — connects to Discord's WebSocket, listens for events, responds to slash commands. No HTTP server, no exposed ports. To add an HTTP endpoint, we'd need to:

1. Switch `NestFactory.createApplicationContext()` to `NestFactory.create()` with an HTTP adapter
2. Add a POST endpoint like `/api/activity`
3. Generate and share an API key between the desktop app and bot
4. Expose the port through our Docker/Coolify/Traefik stack
5. Add rate limiting to prevent spam
6. Handle authentication, validation, error responses

That's a meaningful change to the bot's architecture. It goes from "pure gateway client, no attack surface" to "HTTP server exposed to the internet." For a single feature.

But more importantly — do we actually need it?

## What the desktop app already does

Here's the thing. The ShiroAni desktop app already broadcasts what the user is watching. Every time someone watches anime, the app sets their Discord Rich Presence:

```
Details: "Ogląda anime"
State: "Attack on Titan"
Large Image: anime cover art URL
Buttons: ["Pokaż na AniList" → anilist.co/anime/16498]
```

This data is visible to anyone who checks the user's Discord profile. And more relevantly — it's visible to the **Discord gateway.**

## The gateway already knows

Discord fires a `presenceUpdate` event every time a user's presence changes. The bot is already connected to the gateway. All we need is:

1. Enable the `GuildPresences` intent (one line)
2. Listen for `presenceUpdate` events
3. Filter for activities from our app (match application ID `1481042476402872361`)
4. Post to the configured channel

No HTTP server. No exposed port. No API key. No authentication. No new infrastructure. The data is already flowing through a channel we're already connected to.

```
Desktop app → Discord RPC → Discord servers → Gateway event → Bot → Channel message
```

Compare:

```
Desktop app → HTTP POST → Bot API → Channel message
```

The gateway path has one more hop (through Discord's servers), but it eliminates the entire HTTP stack from our bot. The latency difference is seconds at most — presence updates propagate through the gateway in 1-5 seconds.

## The trade-off table

| | Gateway (presenceUpdate) | HTTP endpoint |
|---|---|---|
| Port exposure | None | Exposed to internet |
| Auth needed | None (Discord handles it) | API key + validation |
| Desktop app changes | None | Need HTTP client code |
| Bot architecture change | Add one intent | Switch to HTTP adapter |
| New dependencies | None | Express/Fastify adapter |
| Attack surface | Zero | Auth bypass, DoS, SSRF |
| Data available | What RPC exposes | Full control |
| Latency | ~1-5 seconds | ~instant |

The only advantage of HTTP is full control over the payload and instant latency. But we don't need either. The RPC presence already contains everything: anime title, episode info, cover art URL, and AniList ID. And "user started watching" isn't a time-critical event — a few seconds delay is invisible.

## Implementation

The actual event handler is short. The interesting part is the filter chain — `presenceUpdate` fires for **every** presence change for **every** guild member. That includes going online/offline, changing game activity, updating Spotify status, everything. The handler needs to be extremely lightweight for the 99% of events we don't care about.

```
presenceUpdate fires
  → no guild? return                     (free)
  → bot user? return                     (free)
  → no ShiroAni activity? return         (array scan, usually 0-3 items)
  → no anime title in state? return      (free)
  → user not opted in? return            (Redis EXISTS, O(1))
  → no activity channel configured? return (DB query, cached)
  → duplicate within 30 min? return      (Redis SET NX, O(1))
  → send embed to channel
```

The ShiroAni application ID check is the first meaningful filter. Most presence updates don't involve our app at all, so they bail out after checking 0-3 activities — microseconds. The more expensive checks (Redis, database) only run for users actually running ShiroAni.

## The opt-in question

One concern came up immediately: privacy. Not everyone wants their watching habits broadcast to a channel. The HTTP approach would've been naturally opt-in — you'd only send data if you configured the API endpoint. But with gateway-based detection, the bot sees everyone's presence whether they like it or not.

Solution: **opt-in by default.** Users run `/activity-optin` to start sharing. The bot stores a Redis key (`activity:opted-in:{guildId}:{userId}`) and only posts for users who have explicitly opted in. `/activity-optout` removes the key instantly.

This check happens early in the filter chain — right after the app ID match, before any database queries. If you haven't opted in, the bot ignores your presence update at near-zero cost.

## Deduplication

The desktop app updates presence every 15 seconds while active. Without dedup, someone watching a 24-minute episode would generate ~96 presence updates, each triggering the event handler. Even with all the early-return filters, we'd hit the database and potentially post duplicate messages.

The fix: a Redis key per user per anime title with a 30-minute TTL, using `SET NX EX` (set if not exists, with expiry):

```typescript
const dedupKey = `activity:${guildId}:${userId}:${title.toLowerCase().trim()}`;
const isNew = await redis.set(dedupKey, '1', 'EX', 1800, 'NX');
if (!isNew) return; // Already posted within 30 minutes
```

One Redis call does both the check and the set atomically. If the key exists, `NX` makes `SET` return null and we skip. If it doesn't exist, we set it with a 30-minute expiry and post the message.

Switching anime creates a new dedup key (different title), so the new show gets posted immediately. Same show rewatched after 30 minutes? Gets posted again — that's fine, it's a new viewing session.

## What about the HTTP endpoint we didn't build?

We might still add an HTTP adapter to the bot eventually. Health checks for Docker, a future web dashboard, maybe the anime search feature wanting to pre-warm a cache. But we won't add it *for the activity feed.*

The lesson: before adding infrastructure, check if the data is already flowing through a channel you have access to. Discord's gateway is a firehose of events. Most bots only tap a fraction of it. The presence data was already there — we just weren't listening.

Sometimes the best architecture is the one that doesn't exist.

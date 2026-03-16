<div align="center">
  <img src="public/mascot.png" alt="shirone.blog mascot" width="160" />

  <h1>shirone.blog</h1>

  <p><strong>Field notes from building things — Electron apps, Discord bots, and whatever catches my curiosity next.</strong></p>

  <p>
    <a href="https://shirone.blog">
      <img src="https://img.shields.io/website?url=https%3A%2F%2Fshirone.blog&style=flat&label=shirone.blog" alt="Website" />
    </a>
    <a href="https://github.com/Shironex/shirone-blog/actions/workflows/ci.yml">
      <img src="https://img.shields.io/github/actions/workflow/status/Shironex/shirone-blog/ci.yml?style=flat&label=CI" alt="CI" />
    </a>
    <a href="https://shirone.blog/rss.xml">
      <img src="https://img.shields.io/badge/RSS-feed-orange?style=flat" alt="RSS" />
    </a>
    <a href="LICENSE">
      <img src="https://img.shields.io/badge/License-MIT-blue?style=flat" alt="License" />
    </a>
  </p>

</div>

---

### Stack

- **[Astro 6](https://astro.build)** — static site generator with MDX + React islands
- **[Tailwind CSS v4](https://tailwindcss.com)** — styling with typography plugin
- **Shiki** (vitesse-dark) — code syntax highlighting
- **Docker** + **[Coolify](https://coolify.io)** — deployment

### Development

```sh
pnpm install
pnpm dev          # localhost:4321
pnpm build        # static output → ./dist/
pnpm astro check  # typecheck
```

### Writing a post

Create a `.md` or `.mdx` file in `src/content/blog/`:

```yaml
---
title: 'Post Title'
description: 'One-line summary.'
pubDate: '2026-03-16'
tags: ['electron', 'architecture']
draft: false
---
```

### Deployment

The `Dockerfile` builds a static site served by `serve` on port 3000. Point Coolify (or any Docker host) at the repo and set the domain.

### License

MIT

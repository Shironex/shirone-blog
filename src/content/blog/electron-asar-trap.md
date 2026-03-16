---
title: 'The asar Trap: When Your AI Agent Works in Dev but Dies in Production'
description: 'Electron bundles everything into a readonly archive. AI SDKs need to spawn binaries. These two facts are incompatible, and the fix is weirder than you think.'
pubDate: '2026-03-12'
tags: ['electron', 'gitchorus', 'packaging']
---

Everything worked. The AI agent validated GitHub issues, reviewed PRs, spawned tools, read code. I packaged the app, shipped a build, and got a crash report within minutes.

```
Error: MODULE_NOT_FOUND
Cannot find module '@anthropic-ai/claude-agent-sdk'
```

The module was right there in `node_modules`. I could see it in the built output. It had installed correctly. It worked five minutes ago in dev mode.

Welcome to the asar trap.

## What asar actually does

Electron bundles your entire app into a single file called `app.asar`. It's a flat archive format — think tar without compression. Node's `require()` is patched to read from it transparently, so your JavaScript code runs fine. You never notice the archive exists.

Until you need to spawn a binary.

`app.asar` is readonly. There's no filesystem path to executables inside it. You can `require()` a JS module from the archive, but you cannot `execFile()` or `spawn()` a binary that lives in it. The OS doesn't know how to run a file inside an archive.

AI agent SDKs don't just `require()` things. The Claude Agent SDK spawns `cli.js` as a child process with its own Node runtime. It ships WASM files. It bundles platform-specific ripgrep binaries for code search. None of that works inside a readonly archive.

This isn't Claude-specific. Any AI SDK that spawns binaries — Codex wrapping a native binary per platform, LangChain shelling out to tools, anything that calls `execFile()` — hits the same wall. The archive is transparent for `require()` and completely opaque for `spawn()`.

In dev mode, `app.isPackaged` is false. Everything lives on the real filesystem. Binaries spawn fine. You'd never know this problem exists until you ship.

## The fix: asarUnpack

electron-builder has an `asarUnpack` option that extracts matching files from the archive to a parallel directory called `app.asar.unpacked/`:

```json
{
  "asarUnpack": [
    "node_modules/@anthropic-ai/claude-agent-sdk/**/*"
  ]
}
```

The glob needs to match everything the SDK ships — JavaScript files, WASM binaries, bundled tools like ripgrep. Miss a subdirectory and a specific feature silently breaks in production while working perfectly in dev.

Now the SDK's files live at a real filesystem path. But the SDK doesn't know that. It still tries to resolve its own binary using normal module resolution, which points into `app.asar`. You have to tell it where the unpacked binary actually lives.

## The path resolution rabbit hole

Once files are unpacked, the SDK doesn't know they've moved. It still tries to resolve modules relative to `app.asar`. You need to construct the unpacked path yourself:

```typescript
path.join(
  process.resourcesPath,        // /Applications/GitChorus.app/Contents/Resources
  'app.asar.unpacked',          // the parallel unpacked directory
  'node_modules',
  '@anthropic-ai',
  'claude-agent-sdk'            // the unpacked SDK root
)
```

This path varies per platform. On macOS it's buried inside the `.app` bundle. On Linux it's next to the executable. On Windows it's in the `resources` directory. `process.resourcesPath` abstracts this, but you still need to verify the files actually exist:

```typescript
if (!existsSync(candidate)) {
  logger.warn(`Bundled SDK not found at expected path: ${candidate}`);
  return undefined;
}
```

The result is cached — the path doesn't change at runtime, so resolving it once avoids hitting the filesystem on every agent invocation.

SDKs with native per-platform binaries (like Codex, which ships a compiled binary for each OS/arch combo) have it even worse — the path includes platform target triples like `aarch64-apple-darwin` or `x86_64-unknown-linux-musl`, turning one lookup into a six-entry mapping table.

## The PATH problem

Fix the asar issue, rebuild, ship. The binary is found. But now the agent's tool calls fail — `git` not found, `rg` not found. The Codex agent spawns subprocesses to read your codebase, and those subprocesses can't find basic CLI tools.

macOS GUI apps launched from Finder (or Spotlight, or the Dock) inherit a minimal PATH:

```
/usr/bin:/bin:/usr/sbin:/sbin
```

That's it. No `/opt/homebrew/bin`. No `~/.nvm/versions/...`. No `~/.cargo/bin`. The user's shell profile never runs. Every tool installed through Homebrew, nvm, npm global, or cargo is invisible.

The fix is to spawn a login shell at startup, extract the real PATH, and inject it into `process.env` before any child processes launch:

```typescript
function buildShellArgs(shellName: string): string[] {
  const command = `echo -n "${DELIMITER}"; command env | grep "^PATH="; echo -n "${DELIMITER}"`;

  if (shellName === 'fish') {
    return ['-l', '-i', '-c', command];
  }
  return ['-ilc', command];
}
```

Fish shell gets special handling because it doesn't support combined flags (`-ilc`). It needs them separated: `-l -i -c`. Get this wrong and fish users see a 10-second timeout on every app launch followed by a broken agent.

The shell cascade: try the user's default shell, fall back through `/bin/zsh` then `/bin/bash` then `/bin/sh`. Parse the output using delimiters (not line-based, because shell profiles print all kinds of garbage). Strip ANSI escape codes. Validate the result contains at least `/usr/bin`. All of this runs synchronously at startup, blocking for up to 10 seconds in the worst case, because every subsequent `spawn()` depends on having the correct PATH.

## The ESM problem (bonus round)

Some AI SDKs ship as ESM-only. Electron's main process runs CommonJS. You can't `require()` an ESM module from CJS — Node throws `ERR_REQUIRE_ESM`.

The standard workaround is dynamic `import()`, but TypeScript compiles `import()` to `require()` in CJS output mode, defeating the purpose. The nuclear option:

```typescript
const dynamicImport = new Function('specifier', 'return import(specifier)');
```

`new Function` creates a function at runtime that TypeScript's compiler can't see or transform. The `import()` call inside it survives compilation intact. It's ugly. It works. It's the same trick VS Code uses. You'll hit this with any ESM-only dependency in Electron's main process — AI SDKs are just the most common case right now.

## The full stack of problems

| Layer | Dev behavior | Production behavior | Fix |
|-------|-------------|-------------------|-----|
| Module loading | `require()` from filesystem | `require()` from `app.asar` | `asarUnpack` extracts to real filesystem |
| Binary execution | SDK finds its own binary | Binary trapped in readonly archive | Override path to unpacked location |
| Path resolution | Flat `node_modules` | 8-segment platform-specific path | Target triple lookup table + `existsSync` |
| Shell PATH | Terminal has full PATH | GUI app has `/usr/bin:/bin` only | Spawn login shell at startup, extract PATH |
| ESM imports | TypeScript `import()` works | Compiled to `require()`, throws | `new Function('specifier', 'return import(specifier)')` |

Each layer looks independent. They're not. The asar fix means nothing without the PATH fix — the agent binary runs but its tools don't. The PATH fix means nothing without the ESM fix — you can't even load the SDK. And all of it works perfectly in development because none of these conditions exist outside a packaged build.

## What I'd tell past me

**Test packaged builds early.** `electron-builder --dir` produces an unpacked production build in seconds without creating a DMG. Run it after adding any native dependency.

**AI SDKs are not normal npm packages.** They ship binaries, spawn processes, shell out to tools. Every one of these operations hits the asar boundary. Treat them like native modules — they need `asarUnpack`.

**The `onlyLoadAppFromAsar` fuse is not the enemy.** This security fuse restricts Electron's *app code loading* to the asar archive. It does not conflict with `asarUnpack` — your code accesses unpacked files through `fs` and `spawn`, not through Electron's module loader. Don't disable it.

**Shell PATH resolution is a prerequisite, not an afterthought.** If your app spawns anything — git, node, rg, any CLI tool — you need the user's real PATH. Build this before you build the feature that needs it.

**Cache the resolved paths.** Binary paths and shell PATH don't change at runtime. Resolve once, store the result. The filesystem checks add up when an agent might run dozens of times per session.

PR [#10](https://github.com/Shironex/gitchorus/pull/10) (`fix/asar-claude-agent-sdk`) fixed the original asar issue in 2 files and 43 lines. The three follow-up problems took considerably more.

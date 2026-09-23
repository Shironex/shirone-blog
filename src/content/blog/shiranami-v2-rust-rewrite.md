---
title: 'Swapping the Engine Mid-Flight: Shiranami 2 and a 186k-Line Merge'
description: 'I rewrote the backend of my music player from Electron to Rust and Tauri on one long-lived branch, then merged 390 commits into master without users losing a single track. Here is the plan, the guardrails, and the Windows bugs no test caught.'
pubDate: '2026-09-23'
tags: ['rust', 'tauri', 'electron', 'shiranami', 'process', 'ai']
---

Shiranami is my lofi music player. Version 1 was an Electron app: a React UI over a TypeScript backend, a SQLite library, yt-dlp for downloads, and a small C++ addon for waveforms. It worked and people used it. It also shipped a 134 MB installer and sat at around 700 MB of RAM on an idle Mac.

On September 22 I merged the `v2` branch into master. It had **390 commits, 1,238 files, +186,028 lines**, and the whole backend was now Rust and Tauri. The React UI came through almost untouched. Since then, the first real user has upgraded from v1, and their library, covers, playlists and settings were all still there.

This post covers how that happened: the plan, the handover I shipped before any v2 code existed, the guardrails that kept a seven-week branch honest, and the Windows bugs that only showed up on real hardware.

## The decision: full port, UI stays

The goal was simple: same app, a fraction of the weight. The research phase set a few constraints that shaped everything after it:

- **Full Rust port, no Node sidecar.** A sidecar would have kept half the RAM problem.
- **The React UI stays.** It was the most polished part of the app. The web app keeps calling `window.electronAPI.*`, and a shim routes those calls to Tauri commands through generated `tauri-specta` bindings. The UI didn't need to know the backend had changed.
- **Audio stays in the renderer.** Playback runs on Web Audio as before, fed by a loopback `axum` server rather than custom URI schemes, because of a WebKit bug on current macOS.
- **The backend became 11 domain crates:** core, net, db, serve, audio, metadata, library, downloader, integrations, media-controls and recommendation, plus a thin Tauri shell. The C++ waveform addon was rewritten in Rust too.

All of it went into `docs/v2/architecture.md`: 22 phases, 25 decisions, 24 named risks, and an **amendment ledger**. Whenever reality disagreed with the plan, the deviation went into the ledger with a reason, so the doc never drifted into fiction.

## How the work actually ran

I didn't write 186k lines by hand. I ran it the way I run most of my projects now: Claude as coordinator, with specialist agents doing research and implementation. Each phase in the plan was tagged **Sequential** (on the main checkout) or **Worktree** (parallel lanes, each agent in its own git worktree off `v2`). The coordinator merged lanes back and ran the gates before anything was pushed.

The first day was absurd: 212 commits on August 1, covering phases 1 to 17. By that night, all 11 crates were ported and the full command surface was live. After that it slowed to 20 to 35 commits a day: a feature wave, an expansion wave of about 20 PRs, then the long tail of testing and packaging. In total the branch had 33 internal merges and 31 PRs.

Two lessons from running it that way:

- **Isolated agents need relative paths.** An agent in a worktree that's given the absolute repo path edits the *main* checkout instead of its own.
- **Check what actually got committed.** An unanchored `bin/` in `.gitignore` silently dropped `crates/shiranami-downloader/src/bin/` from a lane's commit: 2,519 lines. I recovered them by replaying the agent's edit transcript. The pattern is now `/bin/`, and merging a lane now includes checking `git ls-files` against the file list the lane reported.

## Ship the bridge before the thing

This is the part I'm proudest of, and it went out before any v2 code existed.

`electron-updater` can't install a Tauri app. If v1 only learned about v2 at launch time, every v1 user would have been stranded. The research turned up a real example of this: an app whose users stayed on v1 because the migration hook shipped too late.

So **v1.0.1** shipped a *dormant* handover bridge. It polls `shiranami.app/v2.json` shortly after launch and then hourly. It has a 5-second timeout and a 64 KB body cap. Any failure (a 404, being offline, bad JSON) returns nothing and logs at most one line. It never reports to Sentry and never interrupts the user. For weeks it fetched a file that didn't exist and did nothing, which was the point.

The file itself is small:

```json
{
  "enabled": true,
  "version": "2.0.0",
  "min_v1_version": "1.0.1",
  "platforms": {
    "darwin-arm64": { "url": "…/Shiranami_2.0.0_aarch64.dmg", "sha256": "…", "size": 16479379 },
    "win32-x64":    { "url": "https://shiranami.app/download", "sha256": "…", "size": 12475189 }
  },
  "download_page": "https://shiranami.app/download"
}
```

That gave me three controls without shipping a new build:

- **`enabled` is a kill switch.** The bridge fetches with `cache: 'no-store'`, so flipping it back takes effect on the next landing-page deploy.
- **`min_v1_version` is a floor.** Only builds that carry the bridge are addressed.
- **The URL decides the UX.** The bridge can install silently on Windows, but only when the URL points at an `.exe`. I pointed Windows at the download page on purpose, because the 1.0.1 release notes promised users it would ask before installing anything. Both platforms get the same "Download / Later" dialog.

Before the handover, the bridge also writes a handoff file for v2: where the v1 database and downloads live, the v1 version, and a snapshot of the UI's local settings. v2 reads it on first launch.

## Data continuity: copy, never move

A player that opens to an empty library after an update has lost your trust. So Phase 17 had strict rules:

1. Back up the database first.
2. **Copy** the database, album art, waveform peaks, binaries, logs and config. Never move or delete anything, so v1 still boots if you go back.
3. Import the config key by key and seed the UI settings from the handoff snapshot.
4. Write a `migrated_from_v1.json` marker.
5. **If any step fails, refuse to start** rather than open an empty library.

The schema moved from drizzle to sqlx. Instead of replaying drizzle's migrations, v2 stamps a squashed baseline and leaves drizzle's migration table in place as a rollback breadcrumb.

The dry run against my real profile migrated 519 tracks, 514 covers and 49 waveform files. Checksums over all 572 source files were unchanged afterwards. The first boot took 2.3 seconds including the copy; the second took 260 ms. My dev profile was **correctly refused**, because it carried a migration from a branch that was never merged. That refusal was the feature working.

## The guardrails

A seven-week branch with parallel agents is where drift goes to hide. These are the checks that caught it.

**Contract pins.** The IPC surface is roughly 160 commands. A test pins the exact command count against what's registered, and the list of v2-only channels on the TypeScript side is checked against the Rust event definitions. You can't add a command in one place and forget the other.

**A drift guard that has to fail.** CI regenerates the TypeScript bindings and fails on any diff. That check alone isn't enough, though. A drift guard in [nightcore](https://github.com/noctcore/nightcore) once passed silently for its whole life because it was checking the wrong thing. So `pnpm verify:drift-guard` deliberately breaks a type and **requires the check to go red**. A guard nobody has seen fail isn't really a guard.

**Golden baselines against v1.** Album art has to keep working across the upgrade, so a script runs v1's actual image pipeline and records the results, and Rust tests pin v2 against them. It found something funny along the way: v1's own two image pipelines agreed on geometry in 4 of 4 cases and on hashes in 0 of 4. v2 matches the geometry, which is the part that matters.

**lint-meta.** The ESLint side runs an in-repo plugin with rules for component folder shape, no cross-feature imports, no narration comments and similar. On top of that sits `lint-meta`, which carries the file-shape and layering discipline over from nightcore and the [noctcore](https://github.com/noctcore/eslint-plugins) tooling:

- Every rule is `error` or `off`. A `warn` fails the build.
- No inline `eslint-disable` and no `@ts-ignore`.
- **Rust modules are capped at 400 code lines.** This forced at least seven real splits during v2. That's annoying when it happens and much better than a 2,000-line `commands.rs` six months later.
- **Crate layering is ranked.** A lower-level crate can't import from a higher one, and Tauri commands can only live where the plan says they live.

With agents writing most of the code, these rules are what keep the shape. An agent under pressure takes the shortest path to green. lint-meta closes off most of those paths.

**The e2e lane.** Eleven WebdriverIO specs drive the real packaged app. They found two production bugs no unit test could: the local server's shutdown path could never run, and the `electronAPI` bridge was being **tree-shaken out of production bundles**. The dev build worked perfectly and the release build would have been dead on arrival.

**Keeping `v2` close to master.** Master fixes, including a CVE bump, were merged into `v2` along the way, so the final merge wouldn't carry seven weeks of divergence.

One honest miss: for the first ten days, **CI didn't run the pnpm suite on `v2` PRs at all.** Four lanes merged in one day on local runs alone before I noticed. Now CI runs on whatever branch the work is on, from day one.

## Windows: where the tests lied

I develop on a Mac. Most of the testing ran on Ubuntu in CI. Instead of a formal updater spike, the plan was that I'd take the branch to my Windows PC and do the upgrade by hand, the way a user would. It was the most valuable testing of the whole project.

- **The migration couldn't copy a single file.** Calling `sync_data` on a read-only handle is `FlushFileBuffers` on Windows, which needs write access. It was invisible because `cargo test` only ran on Linux: 16 tests were failing on Windows and nobody knew. Fixed, and `cargo test` now runs on the Windows runner too.
- **Every upgrading user would have started with an empty library.** v2 looked for v1's data in `%APPDATA%\Shiranami`. v1 actually stored it in `%APPDATA%\@shiranami\desktop`, because Electron uses the package `name` when there's no `productName`. The test that pinned the path and the e2e fixture were both wrong in the same way, so they agreed with each other and everything passed. **This one alone justified the whole manual pass.**
- **v1 would never have been uninstalled.** An NSIS string-unquoting step dropped the `r` from `/currentuser`, which would have left users with two Shiranamis in Add/Remove Programs.
- **The test binary wouldn't start.** A Tauri plugin needs comctl32 v6, and test binaries don't get the embedded manifest (`STATUS_ENTRYPOINT_NOT_FOUND`).
- **Papercuts:** a CRLF checkout failed `cargo fmt --check` on 490 files, one golden test took 28 minutes because of 120k autocommit inserts, and yt-dlp flashed console windows because a spawn was missing `CREATE_NO_WINDOW`.

The final manual run went from an installed v1.0.1 to the release candidate: a 12.5 MB installer, one entry in Add/Remove Programs, 224 MB copied in 0.4 seconds, an 863 ms first boot, and every count matching. I also checked the kill switch against the installed v1.0.1.

## Being my own first user in production

Local testing proves the code. It doesn't prove the release. So after publishing 2.0.0, and before flipping `enabled` to `true`, I went through the real path against production myself: a v1.0.1 install, the real `v2.json` on shiranami.app, the real release assets.

Only after that did the flag go live, together with the 2.0.0 changelog on the landing page. Then the first real user came through, and their library came with them.

## The merge

With all that behind it, the merge itself was almost boring, which is how it should be:

- **A merge commit, not a squash.** Squashing would have turned 390 commits of history into one line and left `v2` looking unmerged.
- **Two conflicted files:** a release workflow and `pnpm-lock.yaml`. The lockfile wasn't hand-merged. I started from `v2`'s, ran `pnpm install` against the merged manifests, and checked that master's security pins survived.
- **One follow-up:** the art baseline had to be regenerated because master had moved v1's image library by a patch version. All four hashes were identical; only a label changed.

The same day, a second PR deleted the Electron app entirely (**−85,127 lines**) and renamed `desktop-tauri` to `desktop`. A day later, 1.0.1 was declared the last v1 release.

## By the numbers

| | v1 (Electron) | v2 (Rust + Tauri) |
|---|---|---|
| macOS download | 134 MB | 17 MB |
| Windows installer | 110 MB | 12.5 MB |
| Idle RAM (macOS) | ~688 MB | ~291 MB* |
| Cold boot | — | 189 ms |
| Rust tests | — | 1,000+ in core/db/downloader/serve, 518 in the desktop crate |

\*Measured early, on an empty v2 library against a 519-track v1 library, so treat it as indicative. The release notes say "roughly half", and that's the claim I stand behind.

## What I'd keep, and what I'd change

**Keep:** the plan with an amendment ledger. Shipping the bridge first. Copy-never-move migration with refuse-to-start. Guards that are required to fail. lint-meta's hard file and layer limits.

**Change:** run CI on the long-lived branch from the first commit, and run the test suite on every OS I ship to from the first commit too. Every Windows bug above was cheap to fix and expensive to find late. The most dangerous one, the wrong data path, got through *because* two tests agreed with each other. When a test and a fixture share an assumption, only a real machine will contradict them.

186k lines sounds like a big-bang rewrite. It didn't feel like one, because none of the steps was big: a bridge that did nothing for weeks, phases that each merged green, a flag that could be flipped back, and a person clicking through the upgrade on a real Windows PC before anyone else had to.

---
title: 'Green Is Not Evidence: How I Keep AI-Written Code Honest'
description: 'AI agents write most of the code in the ERP I am building. Type safety and lint rules catch the typos. What they do not catch is a false claim. Here is the harness I built for that.'
pubDate: '2026-09-23'
tags: ['ai', 'typescript', 'eslint', 'tooling', 'process']
---

Most of the code in Settly, the multi-tenant ERP I'm building, is written by AI agents. I plan the work, split it into lanes, and several agents implement in parallel, each in its own git worktree. I review, merge and ship.

It works. It also taught me something I didn't expect. The bugs that hurt were almost never syntax errors or type errors. TypeScript catches those, and agents fix them fast. The bugs that hurt came from **claims**:

- "All tests pass." (On a tree that changed halfway through the run.)
- "That failure was already on main." (It wasn't.)
- "I updated every call site." (Three of four.)
- "The isolation suite covers this." (It didn't. It just passed.)

None of these is a lie in the human sense. The agent believes it. It saw green output. But green is not evidence. Green only tells you that nothing complained, and a check can stay quiet for many reasons.

So I stopped trying to make the agents more careful and started building a harness that doesn't need them to be. This post covers the layers, in the order a change hits them.

## Layer 1: types you can't opt out of

This is the boring part, and it has to be airtight because everything else sits on it.

- `strict` TypeScript everywhere, including the tooling scripts.
- End-to-end types from the database to the UI: Prisma generates the models, tRPC carries them over the wire, zod validates at every boundary, and the React client infers everything from the router type. A renamed column breaks the frontend build.
- No escape hatches. `as any`, `@ts-ignore`, `@ts-expect-error`, inline `eslint-disable` and empty `catch {}` are all build errors.

The last point is the one that matters for AI. When an agent is stuck on a type error, the shortest path to "done" is a cast. It's not malicious. It's just the path of least resistance. If that path exists, it will be taken, at scale, across hundreds of edits you never read line by line.

## Layer 2: catch it at edit time, not at CI time

A rule that fails in CI costs a full round trip: the agent finishes, reports done, CI goes red, someone reads the log, the agent tries again. Multiply by six parallel lanes and it adds up.

So the same rules also run inside the agent loop. Claude Code supports hooks, and the repo ships two of them in a tracked `.claude/settings.json`, so every worktree gets them for free:

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Edit|Write|MultiEdit",
        "hooks": [{ "type": "command", "command": "node scripts/hooks/guard-edit.mjs" }] }
    ],
    "PostToolUse": [
      { "matcher": "Edit|Write|MultiEdit",
        "hooks": [{ "type": "command", "command": "node scripts/hooks/lint-edited.mjs" }] }
    ]
  }
}
```

`guard-edit` **denies** an edit that adds a new `as any`, `@ts-ignore`, inline disable or empty catch. The edit never lands, and the agent is told why. Two details made it work in practice:

1. **It counts, it doesn't match.** It compares the number of occurrences in the new text against the text being replaced. Moving an existing line is fine; only a net increase is blocked. Otherwise every refactor near old code gets stuck.
2. **It adds no policy.** It imports the same regexes the CI gate uses. The hook is a faster mirror of the gate, never a second source of truth. If they disagree, the gate wins.

`lint-edited` runs ESLint on the file that was just written and feeds the problems back. The agent fixes them while the file is still in its head.

## Layer 3: lint rules for the bugs generic linters can't see

`typescript-eslint` is great at language-level mistakes. It knows nothing about *your* system: that every query on a tenant model must be scoped, that audit writes must not sit inside the transaction they describe, that a redirect target must be sanitized, that money is never a float.

Those are the rules that stop real bugs, so I write them. Over time I moved the general ones out of Settly into an open source org, [noctcore](https://github.com/noctcore/eslint-plugins): nine `@noctcore/*` plugins, [documented here](https://noctcore.github.io/eslint-plugins/).

| Plugin | Guards against |
|---|---|
| `prisma` | Unscoped clients, raw SQL, missing tenant and soft-delete filters, multi-write without a transaction, mutations that never reach the audit log |
| `security` | Injection, path traversal, SSRF, open redirects |
| `async-safety` | `fetch` with no timeout, dropped `AbortSignal`s, shared-state races |
| `contracts` | zod schema naming, wire discriminants, direct `process.env` reads, float money |
| `observability` | Interpolated log messages, sensitive fields in logs, lost error detail |
| `react`, `architecture`, `monorepo`, `code-quality` | Structure: feature boundaries, package boundaries, hook and prop surface, test discipline |

My rule for promoting a rule: **it has to catch something real first.** When Settly switched on the newly promoted security rules at `error`, they found three genuine defects on day one: an OAuth return URL that was sanitized in one file and used in another, an external verification response parsed without checking its status, and server-issued paths joined to an origin without validation. All three had passed review. All three were in code an agent wrote and I approved.

One more thing: **warnings don't exist.** Every rule is `error` or `off`, and a meta-check fails the build if anything is set to `warn`. An agent treats a warning as noise, and after a while so do you.

## Layer 4: whole-repo invariants

ESLint sees one file at a time. Many of my worst bugs spanned files: a registry and the tests that were supposed to cover it, a CI workflow and the pre-push hook meant to mirror it, a doc that cites a rule that was deleted last month.

For those I use a second runner, [`@noctcore/harness`](https://github.com/noctcore/nightcore/tree/main/packages/harness), with its own rule set ("lint-meta"). Examples of what it checks:

- GitHub Actions are pinned to a SHA and Docker images to a digest.
- Every workspace package is enrolled in the test runner, and every source file has a sibling test where the layer requires one.
- File sizes follow a ratchet: a file can shrink, and it can't grow past its recorded size.
- The generated architecture map matches the tree.
- Invariant docs stay true. Each invariant in `docs/invariants/*.md` must have an `Enforced by:` line, and that line must point to a rule or test that still exists.

That last one exists because the worst bugs in Settly broke an **invariant**, not a code path. "Every session re-issue keeps the session-kind stamp." "The tenant scope survives a transaction." Each was true, known, and written down nowhere a reviewer (or an agent) would look. Now they're Markdown that agents read *and* CI enforces.

## Layer 5: verify the claim, not the output

This is the layer I didn't know I needed until I'd been burned enough times.

**The tree fingerprint.** `pnpm verify` hashes HEAD plus the contents of every tracked and untracked-but-not-ignored file, before and after the run. If the fingerprint moved, the result is reported **blocked**. A run on a moving tree proves nothing about either tree. With parallel agents in a shared checkout, this was not hypothetical.

**Skipped is not passed.** Every check reports `pass`, `fail` or `blocked`. A check that couldn't run because Postgres was down, or a report file was missing, is `blocked`, and a blocked run is never green. The pre-push hook exits with a separate "incomplete" code when it skipped a gate.

**The differential baseline.** An agent will sometimes blame its failures on main, and sometimes main really is red. So the gate records the base commit's failures and grades a lane only on what it *introduced*. The comparison counts failures instead of treating them as a set, so a lane that adds a second copy of an existing failure is still caught. A red baseline stops the whole wave, and a known failure is only ignored when someone has recorded, by name, that it should be.

## Layer 6: test the tests

This part changed how I think about coverage.

**Mutation canaries.** Settly has a tenant registry: the list of models that must be isolated per company. It also has an isolation test suite that looked thorough and was green. So I wrote a canary: for each model, build a mutant of the registry with that one model removed, run the suite, and expect named tests to go red.

**Six of twelve mutants survived.** Half of the tenant-scoped models could be removed from the isolation boundary and the suite stayed green. The tests only *looked* like they covered those models. After the fix, every mutant is caught, and a rule fails the build if a new scoped model is added without a canary entry.

**Manifests that reconcile both ways.** Every security finding from an audit gets a spec and a row in `findings.json` listing the cases it expects. The reconciler compares the run to the manifest in **both directions**: a case that was deleted, renamed, skipped or never run is a failure, just like one that went red. A passing suite alone proves nothing, because deleting the failing test also makes it pass, and that's exactly the shortcut an agent under pressure takes.

New findings are scaffolded **red on purpose**. `pnpm new:finding` writes the spec and the manifest row together, and every case throws until someone writes a real assertion. A scaffold that passed would look covered and wouldn't be.

## What this actually buys

None of these layers is clever on its own. What they share is one idea: **every "done" has to come with evidence that doesn't depend on the agent's word.** Types that can't be cast away. Rules that stop the edit instead of the build. Results tied to a specific tree. Skips that count as failures. Tests that are themselves tested.

It isn't free. The harness has its own test suite, and a meaningful share of my time goes into the tooling rather than the product. But it's the reason I can let six agents work in parallel on an ERP that holds employee records, review at the level of intent, and still sleep.

The ESLint half is open source today in [noctcore/eslint-plugins](https://github.com/noctcore/eslint-plugins). The rest (the fingerprinted verify gate, the both-ways manifest reconciler, the mutation canary, and the edit-time hooks as an installable package) is what I'm pulling out of Settly next. If you're shipping with agents and one of these problems sounds familiar, I'd like to hear how you handle it.

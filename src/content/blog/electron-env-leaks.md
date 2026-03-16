---
title: 'Your Electron App Is Leaking Secrets (and How We Fixed It)'
description: 'When you spawn a subprocess, it inherits every environment variable — including API keys, tokens, and passwords. Most apps do nothing about this.'
pubDate: '2026-03-11'
tags: ['security', 'electron', 'omniscribe']
---

Run this in your terminal:

```bash
env | wc -l
```

I got 97. Ninety-seven environment variables, including `ANTHROPIC_API_KEY`, `GITHUB_TOKEN`, a couple of database connection strings, and whatever else has accumulated in my `.zshrc` over the years.

Now here's the thing: when your Electron app calls `child_process.spawn()`, every single one of those variables is inherited by the child process. By default. No opt-in. No warning.

## Where this actually bit us

[Omniscribe](https://github.com/Shironex/omniscribe) is a desktop app that spawns terminal sessions — shells, AI agents, git commands. The terminal service uses `node-pty` to create pseudo-terminals. The first version looked like this:

```typescript
const ptyProcess = pty.spawn(shell, args, {
  cwd: resolvedCwd,
  env: process.env, // <-- every secret you own
});
```

That `process.env` pass-through is the default if you don't specify `env` at all. It's also what most apps do. Every Electron tutorial I've seen does it. The Node.js docs mention it in passing and move on.

But think about what's running inside that terminal. In Omniscribe's case: Claude Code. An AI agent that can read files, execute commands, and make network requests. An agent that receives its environment variables and could, in theory, read them and send them anywhere.

## Why AI apps make this worse

A traditional subprocess — `git commit`, `npm install` — runs deterministic code you can audit. An LLM-powered agent runs non-deterministic code that changes with every invocation. The attack surface is fundamentally different:

- A compromised npm package in your subprocess can exfiltrate `process.env`. This is a known supply chain attack vector.
- An AI agent doesn't even need to be "compromised." A prompt injection in a file it reads could instruct it to `curl` your environment to an external server.
- Even without malicious intent, AI agents log aggressively. Your `GITHUB_TOKEN` could end up in a debug log, a crash report, or a telemetry payload.

This isn't theoretical. The [Electron project itself](https://github.com/electron/electron/issues/8212) has discussed environment variable leaking. Electron injects its own variables (`ELECTRON_RUN_AS_NODE`, `GOOGLE_API_KEY`) that you definitely don't want in child processes.

## The naive fix: blocklist

First attempt — filter out variables that look like secrets:

```typescript
const BLOCKED = [/SECRET/i, /PASSWORD/i, /TOKEN/i, /API_KEY/i];

function filterEnv(env: Record<string, string>) {
  return Object.fromEntries(
    Object.entries(env).filter(([key]) => !BLOCKED.some(p => p.test(key)))
  );
}
```

This catches `ANTHROPIC_API_KEY`, `GITHUB_TOKEN`, `DB_PASSWORD`. Good start. But:

- `MY_SUPER_KEY` passes through. No blocked pattern matches.
- `OPENAI_ORGANIZATION` passes through. Not a "key" or "token."
- `DATABASE_URL` with credentials embedded in the connection string? Passes through.
- Any new secret format you add to your shell profile? Passes through until you update the blocklist.

A blocklist is playing whack-a-mole with an infinite number of holes.

## The better fix: allowlist

Flip the model. Instead of asking "what should we block?", ask "what does a subprocess actually need?"

Turns out, not much. A shell needs to know where to find binaries (`PATH`), who the user is (`HOME`, `USER`), what language to use (`LANG`, `LC_*`), and where temp files go (`TMPDIR`). Development tools need their version manager directories (`NVM_DIR`, `VOLTA_HOME`, `CARGO_HOME`). That's roughly it.

Here's the allowlist from Omniscribe's `buildSafeEnv()`:

```typescript
export const ENV_ALLOWLIST: string[] = [
  // Shell basics
  'HOME', 'USER', 'LOGNAME', 'SHELL', 'LANG',
  'LC_ALL', 'LC_CTYPE', 'LC_MESSAGES', /* ...other LC_* */
  // Path
  'PATH',
  // Windows
  'COMSPEC', 'SYSTEMROOT', 'APPDATA', 'LOCALAPPDATA', /* ... */
  // Temp
  'TMPDIR', 'TMP', 'TEMP',
  // Display (Linux)
  'DISPLAY', 'WAYLAND_DISPLAY', 'XDG_RUNTIME_DIR', /* ... */
  // SSH
  'SSH_AUTH_SOCK', 'SSH_AGENT_PID',
  // Dev tools
  'NVM_DIR', 'VOLTA_HOME', 'PNPM_HOME', 'GOPATH',
  'CARGO_HOME', 'RUSTUP_HOME', 'PYENV_ROOT', /* ... */
  // Editor, git, proxy
  'EDITOR', 'VISUAL', 'TERM', 'GIT_EXEC_PATH',
  'HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY', /* ... */
];
```

90 variables. Cross-platform. Covers Windows, macOS, Linux, X11, Wayland. Every version manager I could find. Proxy settings for corporate environments. That's the entire surface area a subprocess needs from its parent.

Everything else — every API key, every token, every database URL — is dropped silently.

## The defense-in-depth: both

The allowlist alone would be enough if you trust it to never contain a secret. But what if someone adds `HOMEBREW_GITHUB_API_TOKEN` to the allowlist because "it's a Homebrew variable"? What if a future dev tool stores secrets in a variable that pattern-matches something on the list?

So we run both. Blocklist takes precedence:

```typescript
export const ENV_BLOCKLIST_PATTERNS: RegExp[] = [
  /^ELECTRON_/i,
  /^NODE_OPTIONS$/i,
  /SECRET/i, /PASSWORD/i, /TOKEN/i,
  /CREDENTIAL/i, /API_KEY/i, /PRIVATE_KEY/i,
  // Injection vectors
  /^LD_PRELOAD$/i,
  /^LD_LIBRARY_PATH$/i,
  /^DYLD_/i,
  /^BASH_ENV$/i,
  /^ENV$/i,
  /^BASH_FUNC_/i,
];

export function buildSafeEnv(
  extra?: Record<string, string>
): Record<string, string> {
  const safeEnv: Record<string, string> = {};

  for (const key of ENV_ALLOWLIST) {
    const value = process.env[key];
    if (value !== undefined
        && !ENV_BLOCKLIST_PATTERNS.some(p => p.test(key))) {
      safeEnv[key] = value;
    }
  }

  if (extra) {
    for (const [key, value] of Object.entries(extra)) {
      if (!ENV_BLOCKLIST_PATTERNS.some(p => p.test(key))) {
        safeEnv[key] = value;
      }
    }
  }

  return safeEnv;
}
```

The `extra` parameter matters. Callers can pass session-specific variables (like a working directory override), but those still go through the blocklist. No backdoor.

## The injection vectors most people miss

The blocklist isn't just about secrets. Some environment variables are code execution vectors:

| Variable | Attack | Platform |
|----------|--------|----------|
| `LD_PRELOAD` | Forces the dynamic linker to load an arbitrary shared library into every spawned process. Attacker's `.so` runs before `main()`. | Linux |
| `DYLD_INSERT_LIBRARIES` | Same thing, macOS edition. Injects a dylib into the process. | macOS |
| `BASH_ENV` | Bash executes this file on startup for non-interactive shells. Point it at a malicious script and every `bash -c` call runs your code first. | All |
| `BASH_FUNC_*` | ShellShock-era function export mechanism. Can inject arbitrary functions into bash subshells. | All |
| `NODE_OPTIONS` | Injects `--require` hooks into every Node.js process. Your subprocess now loads attacker code before its own entry point. | All |
| `ENV` | Like `BASH_ENV` but for POSIX `sh`. | All |

These aren't secrets — they're control flow. If you only filter for patterns like `SECRET` and `TOKEN`, you miss all of them.

## The comparison

| Approach | Secrets blocked | Injection vectors blocked | Maintenance burden | Risk of breaking subprocesses |
|----------|:-:|:-:|:-:|:-:|
| Do nothing (default) | None | None | Zero | Zero |
| Blocklist only | Known patterns | If you add them | Grows with every new secret format | Low |
| Allowlist only | All unknown vars | All unknown vars | Grows with every new tool | Medium — miss a var and something breaks |
| Allowlist + blocklist | All unknown + known patterns | All, including allowlist mistakes | Both lists need maintenance | Medium, but safer |

We went with the last option. The allowlist catches unknown threats. The blocklist catches mistakes in the allowlist.

## What we actually ship

In Omniscribe's terminal service, every subprocess spawn goes through `buildSafeEnv()`:

```typescript
const finalEnv: Record<string, string> = {
  ...buildSafeEnv(env),
  TERM: 'xterm-256color',
  COLORTERM: 'truecolor',
  TERM_PROGRAM,
  LANG: process.env.LANG || 'en_US.UTF-8',
};
```

The function lives in a shared package (`@omniscribe/shared`) so both the desktop app and provider plugins use the same implementation. When we started building [GitChorus](https://github.com/Shironex/gitchorus) — a separate Electron app that also spawns AI agents — we identified this as a day-one requirement in the [pitfalls research](https://github.com/Shironex/gitchorus/blob/main/.planning/research/PITFALLS.md) and ported the same code.

The recovery cost column from that research document tells the real story:

| Pitfall | Recovery cost |
|---------|:---:|
| AI hallucination in findings | LOW |
| GitHub API 406 on large diffs | MEDIUM |
| **Environment variable leaking** | **HIGH** |
| Comment size limit exceeded | LOW |

High recovery cost. Because if you've already shipped and secrets have been exposed to subprocesses, you need to rotate every credential that might have leaked. If the subprocess logged its environment anywhere — crash reports, telemetry, debug files — those credentials are now in the wild.

## The test

Straightforward to verify:

```typescript
it('excludes non-allowlisted variables', () => {
  process.env['MY_CUSTOM_VAR'] = 'value';
  const env = buildSafeEnv();
  expect(env['MY_CUSTOM_VAR']).toBeUndefined();
});

it('filters extra variables against blocklist', () => {
  const env = buildSafeEnv({
    MY_SECRET: 'hidden',
    SAFE_VAR: 'visible',
  });
  expect(env['MY_SECRET']).toBeUndefined();
  expect(env['SAFE_VAR']).toBe('visible');
});

it('blocks injection vectors', () => {
  expect(ENV_BLOCKLIST_PATTERNS.some(p =>
    p.test('LD_PRELOAD'))).toBe(true);
  expect(ENV_BLOCKLIST_PATTERNS.some(p =>
    p.test('DYLD_INSERT_LIBRARIES'))).toBe(true);
  expect(ENV_BLOCKLIST_PATTERNS.some(p =>
    p.test('BASH_ENV'))).toBe(true);
});
```

If a new variable needs to pass through, you add it to the allowlist and the test suite tells you if the blocklist catches it. If someone adds `HOMEBREW_GITHUB_API_TOKEN` to the allowlist, the blocklist rejects it because it contains `TOKEN`.

## Lessons

1. **`process.env` inheritance is opt-out, not opt-in.** Node's `child_process.spawn()` copies the entire parent environment by default. You have to explicitly pass `env: {}` to prevent it. Most apps never do.

2. **Allowlist beats blocklist.** You can enumerate what a subprocess needs (roughly 90 variables). You cannot enumerate every possible secret format a user might have in their shell profile.

3. **Use both anyway.** The blocklist is a safety net for mistakes in the allowlist. Defense in depth costs a few regex checks per spawn — negligible.

4. **Environment variables aren't just data — some are code execution vectors.** `LD_PRELOAD`, `DYLD_INSERT_LIBRARIES`, `BASH_ENV`, `NODE_OPTIONS` all inject code into subprocesses. Filter them even if you're not worried about secrets.

5. **AI agents change the threat model.** A deterministic subprocess probably won't read its own environment and exfiltrate it. An LLM-powered agent might, especially under prompt injection. Treat agent subprocesses as untrusted.

6. **Do this on day one.** The recovery cost of "we shipped and secrets leaked" is credential rotation across every user who ran the app. The prevention cost is a 140-line utility with tests.

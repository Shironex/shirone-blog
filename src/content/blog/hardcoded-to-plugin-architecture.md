---
title: 'From if-statements to Plugins in 17 Days'
description: 'How we extracted a hardcoded AI provider into a plugin architecture with 57 documented decisions, and why we chose bundled plugins over a marketplace.'
pubDate: '2026-03-15'
tags: ['architecture', 'omniscribe', 'plugins']
---

Omniscribe started as a Claude Code wrapper. Every service knew it was talking to Claude. The session launcher built Claude CLI flags. The usage panel parsed Claude's output format. The status tracker matched Claude's terminal patterns. It worked, because there was only one provider.

Then someone asked: "What about Codex?"

## The problem with if-statements

Here is what adding a second AI provider looked like in the v2 codebase:

```typescript
// This was real code. It was in 6 different services.
if (aiMode === 'claude') {
  return this.claudeCliService.buildLaunchCommand(context);
} else if (aiMode === 'plain') {
  return { command: 'bash', args: [] };
}
// Adding Codex means touching every one of these.
```

`SessionLauncherService`, `CliCommandService`, `UsageService`, `SessionGateway`, the frontend settings, the status display -- all had Claude baked in. Adding a provider meant modifying every file that touched sessions. That is the textbook definition of shotgun surgery.

We counted: **6 services with provider-specific branching**, **3 frontend components with hardcoded Claude imports**, and a `type AiMode = 'claude' | 'plain'` union that would grow with every provider.

## 57 decisions before writing code

We did not start coding. We started planning.

The v3 milestone produced **28 execution plans across 5 phases**, with 57 documented architectural decisions. Some were small (activation event naming). Some shaped everything.

Decision v3-D1 was the big one -- plugin distribution model:

| Approach | Pros | Cons |
|----------|------|------|
| Runtime download marketplace | Maximum flexibility, community contributions | Sandboxing nightmare, security review burden, version compat matrix |
| Bundled plugins with in-app toggle | Ship tested code, zero security surface, instant load | No community plugins, all providers first-party |
| Hybrid (bundled + verified marketplace) | Best of both | Complexity of both, premature for 2 providers |

Stability won. Bundled plugins with in-app enable/disable toggles. The API is designed external-ready (typed interfaces, JSDoc, base classes with sensible defaults), but the distribution is locked to first-party packages. We can open it later without rewriting the contracts.

Other decisions that mattered:

- **Capabilities, not feature lists.** Providers declare what they support (`supportsMcp`, `supportsUsage`, `supportedOperations: Set<'resume' | 'fork' | 'continue'>`). The UI adapts per-session. Claude shows usage panels; Codex shows them differently; a minimal provider shows nothing. No global toggles.
- **package.json manifests, code capabilities.** Plugin metadata (ID, name, type) lives in `package.json`. Everything behavioral (capabilities, activation events, extension registrations) lives in code. Declarative where static, programmatic where dynamic.
- **Single package, both sides.** One plugin package contributes backend services AND frontend components. `@omniscribe/provider-claude` contains its NestJS services and its React settings/status components together. No coordination between separate packages.

## The contract: 3 required methods

The `AiProviderPlugin` interface has a small required surface:

```typescript
interface AiProviderPlugin extends OmniscribePlugin {
  readonly aiMode: string;
  readonly capabilities: ProviderCapabilities;

  // These three are all you need for a working provider:
  detectCli(): Promise<CliDetectionResult>;
  buildLaunchCommand(context: LaunchContext): CliCommandConfig;
  parseTerminalStatus(output: string): ProviderSessionStatus | null;

  // Everything else is optional, gated by capability flags:
  parseUsage?(workingDir: string): Promise<ProviderUsageData | null>;
  readSessionHistory?(projectPath: string): Promise<ProviderSessionEntry[]>;
  buildResumeCommand?(sessionId: string, context: LaunchContext): CliCommandConfig;
  buildForkCommand?(sessionId: string, context: LaunchContext): CliCommandConfig;
  buildContinueCommand?(context: LaunchContext): CliCommandConfig;
  getMcpConfig?(sessionId: string, projectPath: string): Promise<McpConfigContribution | null>;
  getSystemPromptAdditions?(context: LaunchContext): string[];
}
```

Three methods to detect, launch, and parse. That is a minimum viable provider. The `BaseProviderPlugin` abstract class provides no-op defaults for everything optional, so a new provider plugin is roughly 50 lines of real logic to get sessions running.

The capability flags drive the UI. Claude declares full capabilities -- MCP, usage, session history, resume/fork/continue. Codex declares MCP and usage but not session history (Codex CLI does not expose session logs). The core never asks "is this Claude?" -- it asks "does this provider support usage?" and renders accordingly.

## Security: the allowlist

Plugins run in-process. The frontend talks to plugins via WebSocket events routed through `PluginGateway`. The `plugin:invoke` event lets the frontend call methods on a provider. Without guards, that is an arbitrary method invocation vector.

```typescript
// The type system keeps the allowlist in sync with the interface.
// Renaming a method on AiProviderPlugin surfaces a compile error here.
type AiProviderPluginMethods = Exclude<
  keyof AiProviderPlugin,
  keyof OmniscribePlugin | 'type' | 'capabilities' | 'aiMode' | 'activationEvents'
>;

const methods: readonly AiProviderPluginMethods[] = [
  'detectCli',
  'buildLaunchCommand',
  'parseTerminalStatus',
  'parseUsage',
  'readSessionHistory',
  'buildResumeCommand',
  'buildForkCommand',
  'buildContinueCommand',
  'getMcpConfig',
  'getSystemPromptAdditions',
] as const;

export const ALLOWED_PROVIDER_INVOKE_METHODS: ReadonlySet<string> = new Set(methods);
```

At the gateway:

```typescript
if (!ALLOWED_PROVIDER_INVOKE_METHODS.has(method)) {
  return { error: 'Method is not allowed for remote invocation' };
}
```

No `toString`, no `constructor`, no `__proto__`. The `ReadonlySet` is derived from a typed array that the compiler checks against the interface. Add a method to `AiProviderPlugin`, forget to add it to the allowlist, get a type error. Remove a method, get a type error.

Second layer: the registry rejects third-party plugins that try to register built-in AI modes.

```typescript
registerProvider(entry: RegisteredProvider, builtIn = false): void {
  const normalizedMode = entry.plugin.aiMode.trim().toLowerCase();
  if (!builtIn && VALID_AI_MODES.some(m => m === normalizedMode)) {
    this.logger.error(
      `Cannot register plugin '${entry.manifest.id}' with built-in aiMode. Registration rejected.`
    );
    return;
  }
  // ...
}
```

Only `PluginLoaderService` passes `builtIn = true`. A hypothetical malicious plugin claiming `aiMode: 'claude'` gets silently dropped.

## The extraction: Claude becomes a plugin

Phase 13 was the scary one. Take everything Claude-specific out of 6 core services and move it into `@omniscribe/provider-claude` -- without breaking a single existing workflow.

Before:
```
apps/desktop/src/modules/session/
  ├── claude-session-reader.service.ts
  ├── claude-session-tracker.service.ts
  ├── hook-manager.service.ts
  └── ... (Claude-specific logic mixed into session services)
```

After:
```
packages/plugins/provider-claude/src/
  ├── claude-provider.plugin.ts      (entry point, 245 lines)
  ├── services/
  │   ├── cli-detection.service.ts
  │   ├── cli-command.service.ts
  │   ├── session-reader.service.ts
  │   ├── session-tracker.service.ts
  │   ├── hook-manager.service.ts
  │   ├── usage-fetcher.service.ts
  │   ├── usage-parser.service.ts
  │   └── status-parser.service.ts
  └── frontend/
      ├── components/               (ClaudeAuthCard, ClaudeCliStatusCard, etc.)
      └── claude-frontend.plugin.ts
```

The core `SessionLauncherService` went from knowing about Claude to this:

```typescript
const provider = this.registryService.getProvider(aiMode);
const command = provider.buildLaunchCommand(context);
```

One line. No branching. The registry handles dispatch.

## The proof: Codex in 6 plans

Phase 15 was the validation. If the architecture actually works, adding a second provider should not require touching core.

`@omniscribe/provider-codex` took **6 plans** and plugged into the same infrastructure. The differences told us the abstraction was right:

| Feature | Claude | Codex |
|---------|--------|-------|
| CLI detection | `which claude` + auth check | `which codex` + API key check |
| Usage fetching | PTY spawn, parse `/usage` output | JSON-RPC to app-server |
| Session history | Read JSONL from `~/.claude/` | Not supported (returns `[]`) |
| Status parsing | Regex on terminal output | Regex on terminal output |
| Session operations | resume, fork, continue | resume, fork, continue |
| MCP config | Handled by core | TOML-based (deferred) |

Different CLIs, different protocols, different data formats. Same interface. Zero changes to core services.

The Codex plugin class is 189 lines. It extends `BaseProviderPlugin`, implements 3 required methods, opts into usage support, and declares that session history is not available. The core sees `supportsSessionHistory: false` and hides the history panel for Codex sessions. No if-statements.

## The numbers

| Metric | Value |
|--------|-------|
| Duration | Feb 2 -- Feb 19 (17 days, shipped; polish through Feb 22) |
| Phases | 5 (API contracts, backend infra, Claude extraction, frontend extensions, Codex validation) |
| Execution plans | 28 (23 implementation + 5 test/verification) |
| Documented decisions | 57 |
| Requirements shipped | 39 of 39 (0 dropped) |
| Commits (v3 branch) | 62 |
| Files changed | 206 (excluding lock file) |
| Lines added | ~21,000 (code + planning docs) |
| Plugin API package | 0 runtime dependencies |
| Plugin code (current) | ~15,000 lines across plugin-api, provider-claude, provider-codex, and plugin module |

## What I would do differently

**Start with two providers.** We designed the API by looking at Claude, then validated with Codex. Some Codex-specific patterns (JSON-RPC usage fetching, missing session history) forced late adjustments to the capability system. If we had spiked both providers first, the `ProviderCapabilities` interface would have been right on the first draft.

**Frontend extensions are harder than backend.** The backend plugin system is clean -- registry, dispatch, done. The frontend extension system (slot-based injection, dynamic settings navigation, runtime theme registration) took 6 plans and produced the most bugs. React component lifecycle and plugin lifecycle do not align naturally.

**Planning documents pay for themselves.** 28 plans and 57 decisions sounds like overhead. It was not. Every plan had success criteria. Every decision had a recorded rationale. When Phase 13 (the extraction) broke 12 test files, we could trace exactly which requirement each test mapped to and fix them systematically. No guessing, no archaeology.

## Lessons

1. **If you have two if-statements, you have a plugin system trying to get out.** We had 6. The refactor was overdue.
2. **Bundled plugins are a legitimate architecture.** Not everything needs a marketplace. Ship tested code, add the download system when you actually have third-party authors.
3. **Capability flags beat feature detection.** Providers declare what they support upfront. The core never tries to call a method and catches the error -- it checks the capability first.
4. **Type-safe allowlists are worth the ceremony.** The `ALLOWED_PROVIDER_INVOKE_METHODS` Set is 15 lines of type machinery. It has prevented every prototype traversal attack by construction, and it breaks at compile time if the interface changes.
5. **Plan the extraction before you start moving files.** The 5-phase structure meant we never had a half-migrated codebase. Each phase shipped a working app with its own test suite passing.

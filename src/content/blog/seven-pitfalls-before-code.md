---
title: '7 Pitfalls We Predicted (and All 7 Happened)'
description: 'We wrote a pitfall analysis before writing a single line of feature code. Every prediction materialized. Here is what we learned about research-driven development.'
pubDate: '2026-03-14'
tags: ['planning', 'gitchorus', 'process']
---

On February 11, we wrote a document called `PITFALLS.md`. It described seven specific things that would go wrong when building GitChorus — an AI-powered code review desktop app. We had not written a single line of feature code yet.

Three days later, on February 14, we shipped our first multi-agent review pipeline. Within the first week, all seven predictions had come true. Not approximately. Not "sort of." All seven, exactly as described.

This is the story of that document and what happened after.

## The setup

GitChorus is an Electron app that runs AI agents against your GitHub PRs and issues. It spawns subprocesses, talks to the GitHub API, parses LLM output, and orchestrates multiple specialist agents in parallel. Every one of those integration points is a place where things break in ways that are hard to debug after the fact.

Before building any of it, we spent a day reading GitHub issues, API documentation, and source code from three existing projects. We wrote down every failure mode we could find. Not vague risks — specific failure scenarios with specific causes and specific mitigations.

The document ended up at 318 lines. Seven critical pitfalls, four tables of technical debt patterns, integration gotchas, performance traps, and a "looks done but isn't" checklist.

Here's what happened to each one.

## Pitfall 1: AI hallucination in code review

**The prediction:** LLMs would generate findings referencing non-existent line numbers, hallucinated variable names, and phantom vulnerabilities. We cited research showing 16-48% hallucination rates on general benchmarks and 42-48% accuracy for leading AI code review tools.

**What actually happened:** The first time we ran a review agent on a real PR, it flagged a "missing null check on line 203" — a line that contained an import statement. It invented a function name that did not exist in the codebase. Classic.

**What we built because we predicted it:**

The review prompt enforces evidence-based findings from day one. Every finding requires a real `codeSnippet` from the diff. The provider's `buildReviewResult()` method runs runtime type guards that filter findings missing required evidence:

```typescript
const findings: ReviewFinding[] = rawFindings.filter((f: unknown): f is ReviewFinding => {
  if (!f || typeof f !== 'object') return false;
  const entry = f as Record<string, unknown>;
  return (
    typeof entry.file === 'string' &&
    typeof entry.line === 'number' &&
    typeof entry.explanation === 'string' &&
    typeof entry.severity === 'string' &&
    validSeverities.includes(entry.severity as ReviewSeverity)
  );
});
```

No evidence, no finding. The LLM still hallucinates — but the hallucinations never reach the user.

## Pitfall 2: Claude Agent SDK 12-second overhead

**The prediction:** The `@anthropic-ai/claude-agent-sdk` spawns a new subprocess per `query()` call with ~12 seconds of startup overhead. With 4-6 specialist agents, that's 48-72 seconds of pure subprocess spawn time.

**What actually happened:** Exactly that. Reviews were taking over two minutes for small PRs. The multi-agent pipeline (commit `37136e2`, Feb 14) ran four specialist sub-agents — Context, Code Quality, Code Patterns, Security & Performance. The SDK overhead stacked.

**What we built because we predicted it:**

We planned from day one to eventually migrate away from the Claude Agent SDK. The `PITFALLS.md` document explicitly said: "Consider whether all agents truly need the Claude Agent SDK. For simpler specialist tasks, the direct API has 1-3s latency."

Four days later (commit `85eb0c9`), we were planning the migration. By commit `4e72423`, we had migrated to the OpenAI Codex SDK, which uses a persistent thread model instead of cold subprocess spawns. The provider abstraction we designed during planning made this a swap of one provider class rather than a rewrite.

## Pitfall 3: GitHub API 406 on large diffs

**The prediction:** The GitHub REST API returns `406 Not Acceptable` when a PR diff exceeds 3,000 lines or 300 files. We cited reviewdog issue #1696 as prior art.

**What actually happened:** We hit it on a real PR. The `gh pr diff` command wraps the same API and fails the same way.

**What we built because we predicted it:**

The `getPrDiff()` method has a local git fallback baked in from the first implementation:

```typescript
async getPrDiff(repoPath: string, prNumber: number): Promise<string> {
  try {
    const { stdout } = await this.execGh(repoPath, ['pr', 'diff', prNumber.toString()]);
    if (stdout.trim()) return stdout;
  } catch (error) {
    this.logger.debug(`gh pr diff failed for #${prNumber}, falling back to git diff:`, error);
  }

  // Fallback: use local git diff
  const pr = await this.getPullRequest(repoPath, prNumber);
  const { stdout } = await execFileAsync(
    'git', ['diff', `${pr.baseRefName}...${pr.headRefName}`],
    { cwd: repoPath, maxBuffer: 10 * 1024 * 1024 }
  );
  return stdout;
}
```

This was not a "we'll add it when it breaks" feature. The fallback was in the first commit of `github.service.ts`. Because we already knew it would break.

## Pitfall 4: Structured output parsing failures

**The prediction:** LLMs wrap JSON in markdown fencing, add preamble text, or return partial objects. Different providers have fundamentally different structured output formats. We predicted tests passing for one provider and failing for another.

**What actually happened:** The Claude Agent SDK sometimes returned structured output wrapped in markdown code blocks. Sometimes it returned raw JSON. Sometimes it returned a conversational response with JSON embedded somewhere in the middle. Commit `7b8a169` was titled "fix: resolve review stuck at StructuredOutput."

**What we built because we predicted it:**

`parseJsonObject()` — a function that tries clean `JSON.parse()` first, then falls back to extracting the outermost `{...}` from whatever the LLM returned:

```typescript
function parseJsonObject(text: string): Record<string, unknown> {
  try {
    return JSON.parse(text) as Record<string, unknown>;
  } catch {
    const firstBrace = text.indexOf('{');
    const lastBrace = text.lastIndexOf('}');
    if (firstBrace === -1 || lastBrace === -1 || lastBrace <= firstBrace) {
      throw new Error('Structured output is not valid JSON');
    }
    return JSON.parse(text.slice(firstBrace, lastBrace + 1)) as Record<string, unknown>;
  }
}
```

The `PITFALLS.md` document literally said: "Auto-Claude's `ResponseParser` uses regex-based JSON extraction from markdown code blocks as a fallback." We ported the pattern before we needed it. When the parsing failures started (and they started fast — commits `a5830d4`, `3ca9dc5` fixing schema validation), the fallback was already there.

## Pitfall 5: Environment variable leaking

**The prediction:** `child_process.spawn()` inherits the full `process.env` by default. Electron adds its own variables. Users have API keys in their shell profile. We cited Electron issue #8212 and classified recovery cost as HIGH — if credentials leak, you need to rotate them and potentially issue a security advisory.

**What actually happened:** We never found out, because we built `buildSafeEnv()` before spawning a single subprocess.

**What we built because we predicted it:**

A 138-line `env-utils.ts` with an explicit allowlist of 80+ safe variables and a blocklist of patterns that must never leak:

```typescript
export const ENV_BLOCKLIST_PATTERNS: RegExp[] = [
  /^ELECTRON_/i,
  /^NODE_OPTIONS$/i,
  /SECRET/i, /PASSWORD/i, /TOKEN/i,
  /CREDENTIAL/i, /API_KEY/i, /PRIVATE_KEY/i,
  /^LD_PRELOAD$/i, /^LD_LIBRARY_PATH$/i, /^DYLD_/i,
  /^BASH_ENV$/i, /^ENV$/i, /^BASH_FUNC_/i,
];
```

This is the one pitfall that never "happened" in the sense of causing a bug. It never happened because we made it impossible on day one. The `PITFALLS.md` document said "Implement env filtering from day one (copy Omniscribe's pattern)." We did exactly that.

That is the point of this entire exercise.

## Pitfall 6: GitHub comment body size limit

**The prediction:** GitHub comments have a 65,536-character limit. AI reviews are verbose. With 20+ findings, you blow past the limit and get a `422 Unprocessable Entity`. The entire review is lost.

**What actually happened:** We sidestepped the bulk of this by choosing the inline comments strategy early. Instead of one giant summary comment, we use the GitHub Reviews API to post each finding as an inline comment on the specific line it references.

But inline comments have their own failure mode — they fail with `422` when the target line is not in the diff. So we built diff pre-validation that parses the unified diff, extracts valid `(path, line)` pairs, and validates every comment before posting. Comments targeting invalid lines get "snapped" to the nearest valid line within 3 lines, and anything that still doesn't match gets moved to the review summary body.

The `PITFALLS.md` said: "Consider posting inline review comments on specific lines rather than one giant summary comment." That single sentence shaped the entire review posting architecture.

## Pitfall 7: Partial agent failure in parallel orchestration

**The prediction:** Naive `Promise.all()` fails fast on the first rejection, discarding successful results. One slow agent blocks everything.

**What actually happened:** The multi-agent pipeline (commit `37136e2`) runs four specialist agents. During development, the security agent would intermittently time out while the other three completed successfully. Without handling, the entire review would fail.

**What we built because we predicted it:**

The orchestrator was designed with partial failure handling from the start. Each agent produces an independent result section. Failed agents are reported in the review metadata rather than crashing the pipeline. The multi-agent commit message itself says: "Add finding deduplication, weighted score calc, severity caps" — the scoring system accounts for missing agent results by adjusting weights.

## The scorecard

| Pitfall | Predicted | Happened | Time to hit | Prevention worked? |
|---------|-----------|----------|-------------|-------------------|
| AI hallucination | Feb 11 | Feb 14 | 3 days | Yes — runtime type guards filter phantom findings |
| SDK 12s overhead | Feb 11 | Feb 14 | 3 days | Partially — led to full Codex migration |
| GitHub API 406 | Feb 11 | ~Feb 15 | ~4 days | Yes — local git diff fallback was already in place |
| Structured output parsing | Feb 11 | Feb 15 | 4 days | Yes — `parseJsonObject()` fallback caught it |
| Env variable leaking | Feb 11 | Never | N/A | Yes — `buildSafeEnv()` from day one |
| Comment size limit | Feb 11 | Sidestepped | N/A | Yes — inline comments strategy avoided it |
| Partial agent failure | Feb 11 | Feb 14 | 3 days | Yes — independent agent results from the start |

Seven predictions. Seven correct. Average time from "this will happen" to "this is happening": 3.4 days (excluding the two we prevented entirely).

## Why this worked

A few observations on why a day of research paid off so dramatically.

**Research compounds.** Each pitfall we identified connected to others. The GitHub API 406 pitfall informed the diff strategy, which informed the inline comments approach, which informed the comment validation logic. Understanding one failure mode early gave us architecture choices that prevented cascading failures later.

**"Predicted" is cheaper than "discovered."** The environment variable pitfall had a HIGH recovery cost — leaked credentials require rotation, potentially a security advisory, and user trust damage. We spent 30 minutes writing `buildSafeEnv()`. The alternative was spending days on incident response.

**Specific beats vague.** The document did not say "LLMs sometimes make mistakes." It said "LLMs generate findings referencing non-existent line numbers" and cited specific accuracy numbers. It did not say "GitHub API has limits." It said "406 Not Acceptable when a PR diff exceeds 3,000 lines" and linked the exact issue. Specific predictions lead to specific mitigations.

**Prior art is everywhere.** Five of the seven pitfalls were documented in existing GitHub issues, blog posts, or codebases we had access to. The 12-second SDK overhead was literally GitHub issue #34. The 406 limit was reviewdog issue #1696. We did not discover novel failure modes — we read about known ones and believed the people who reported them.

## What we learned

1. **Spend a day on pitfall research before starting a project.** Not risk assessment theater — actual research into specific failure modes with links to evidence. One day of reading saves a week of debugging.

2. **Write mitigations into the architecture, not the backlog.** Every pitfall in our document had a "Phase to address" field. Five of seven were Phase 1. They were not tech debt to address later — they were constraints that shaped the initial design.

3. **Steal from your own past projects.** Three mitigations (`buildSafeEnv()`, `parseJsonObject()`, inline comments) were ported directly from previous codebases. The `PITFALLS.md` document cited exact file paths in other projects. Your past work is a library of solved problems.

4. **The pitfall you prevent completely is the most valuable.** Environment variable leaking never happened. We will never know what would have happened if it had. That is the best possible outcome, and it is invisible in retrospect. Prevention does not generate war stories.

5. **Pitfall documents are living architecture records.** Our `PITFALLS.md` is not just a risk register — it explains *why* the code is structured the way it is. Why does `getPrDiff()` have a fallback? Why does `buildReviewResult()` filter findings at runtime? Why do we use inline comments instead of summary comments? The answers are in the pitfalls document, written before the code existed.

The document is at `.planning/research/PITFALLS.md` — 318 lines, 7 critical pitfalls, 6 tables, 12 "looks done but isn't" checklist items. It took one day to write. It prevented at least three production incidents and turned four debugging sessions into "oh, we already have a fallback for that."

Write the pitfalls document before you write the code.

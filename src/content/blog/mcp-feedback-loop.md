---
title: 'The AI Reports Its Own State: MCP as a Feedback Loop'
description: 'Instead of parsing terminal output to figure out what an AI agent is doing, we gave it a tool to tell us. Here is how MCP creates a real-time feedback loop.'
pubDate: '2026-03-13'
tags: ['mcp', 'omniscribe', 'ai']
---

Omniscribe is a desktop app that spawns AI coding agents. You open a project, start a session, and Claude Code runs in an embedded terminal. The user types a prompt, Claude works for a while, and eventually responds.

The problem: that terminal is a black box. The app has no idea what Claude is doing. Is it reading files? Writing code? Stuck waiting for input? Done?

## Parsing terminal output is a losing game

The first instinct is to watch stdout. Claude Code prints status lines — you could regex for patterns like "Reading file..." or "Writing to..." and derive state from that.

This breaks immediately. The output format isn't a contract. It changes between versions. It's interleaved with tool results, code blocks, markdown formatting. Some status lines look like code. Some code looks like status lines. You'd be maintaining a fragile parser that breaks on every CLI update.

We needed something that works regardless of what the terminal prints.

## The insight: let the AI tell you

MCP (Model Context Protocol) gives AI agents a way to call tools. You define a tool with a name, a schema, and a handler. The AI discovers the tool and calls it when appropriate.

The key realization: there's no rule that says MCP tools have to do "real work." A tool can just be a status report. You give the AI a tool called `omniscribe_status` and tell it to call it whenever its state changes. The AI will do it — voluntarily, reliably, without parsing anything.

This inverts the problem. Instead of the app trying to figure out what the agent is doing, the agent tells the app what it's doing.

## The circular data flow

Here's the full loop:

```
Omniscribe launches session
  → writes .mcp.json to project directory
    → spawns Claude Code in that directory
      → Claude discovers .mcp.json, starts MCP server via stdio
        → Claude calls omniscribe_status("working", "Reading project files")
          → MCP server POSTs to Omniscribe's HTTP endpoint
            → Omniscribe emits event via WebSocket
              → UI updates status badge
```

Six hops, but it happens in milliseconds. And every piece is decoupled.

## The MCP server: a separate package

The MCP server lives in its own package (`apps/mcp-server`). It's a Node.js process that communicates with Claude over stdio and with Omniscribe over HTTP.

Two tools. That's it.

```typescript
const TOOL_CONSTRUCTORS: ToolConstructor[] = [
  OmniscribeStatusTool,
  OmniscribeTasksTool
];
```

**`omniscribe_status`** — reports the agent's current state:

```typescript
readonly inputSchema = {
  state: z
    .enum(SESSION_STATUS_STATES) // idle, working, planning, needs_input, finished, error
    .describe('Current agent state'),
  message: z
    .string()
    .describe('Human-readable status message'),
  needsInputPrompt: z
    .string()
    .optional()
    .describe('Question for the user when state is "needs_input"'),
};
```

**`omniscribe_tasks`** — reports a snapshot of the current task list:

```typescript
readonly inputSchema = {
  tasks: z.array(z.object({
    id: z.string(),
    subject: z.string(),
    status: z.enum(TASK_STATUSES), // pending, in_progress, completed
  })),
};
```

Each call replaces the previous snapshot. No diffing, no append — just "here's everything right now."

## The instructions matter more than the schema

The MCP server passes instructions when it registers with Claude:

```typescript
const server = new McpServer(
  { name: 'omniscribe', version: VERSION },
  {
    instructions: [
      'You MUST use these tools proactively throughout your work:',
      '',
      '1. **omniscribe_status** — Call whenever your state changes:',
      '   - "working" when you start processing a request',
      '   - "needs_input" when you need user clarification',
      '   - "finished" when you complete a task',
      '   - "error" if something goes wrong',
      '',
      '2. **omniscribe_tasks** — Call whenever your task list changes',
      '',
      'Call them frequently — at minimum at the start and end of every user request.',
    ].join('\n'),
  }
);
```

"Call them frequently" does the heavy lifting. Without this line, Claude might call the tools once or twice. With it, you get status updates throughout a multi-step task. The AI follows instructions — you just have to give them.

## The config file is the bootstrap

When Omniscribe launches a session, it writes `.mcp.json` to the working directory before spawning Claude:

```typescript
mcpServers[MCP_SERVER_NAME] = {
  type: 'stdio',
  command: 'node',
  args: [internalPath],
  env: {
    OMNISCRIBE_SESSION_ID: sessionId,
    OMNISCRIBE_PROJECT_HASH: projectHash,
    OMNISCRIBE_STATUS_URL: statusUrl,
    OMNISCRIBE_INSTANCE_ID: instanceId,
  },
};
```

Four environment variables baked into the config. When Claude starts, it reads `.mcp.json`, spawns the MCP server as a subprocess, and those env vars tell the server where to POST and which session it belongs to.

The `OMNISCRIBE_INSTANCE_ID` prevents cross-instance pollution. If you have two Omniscribe windows open, each generates a random UUID on startup. The HTTP endpoint rejects any payload whose `instanceId` doesn't match:

```typescript
if (payload.instanceId !== this.instanceId) {
  res.end(JSON.stringify({ accepted: false, reason: 'instance_mismatch' }));
  return;
}
```

## The HTTP server on the desktop side

Omniscribe runs a tiny HTTP server on localhost, port range 45100-45200. It finds the first available port, starts listening, and routes incoming POSTs:

| Route | Payload | Effect |
|-------|---------|--------|
| `POST /status` | `{ sessionId, state, message }` | Emits `session:status` event |
| `POST /tasks` | `{ sessionId, tasks[] }` | Emits `session:tasks` event |

The HTTP server validates the instance ID, checks that the session is registered, then fires an internal event. A WebSocket gateway picks up the event and broadcasts it to the frontend. The frontend updates a status badge and task list.

No polling. No file watchers. Just HTTP POST from child process to parent.

## What this unlocks

| Feature | Without MCP | With MCP |
|---------|-------------|----------|
| Status badge | Parse terminal output (fragile) | Agent reports state directly |
| "Needs input" detection | Impossible without heuristics | Agent says `needs_input` with a prompt |
| Task progress | Not available | Agent reports task list snapshots |
| Multi-step visibility | Watch for tool call patterns | Agent updates tasks as it works |
| Works across CLI versions | Breaks on format changes | Protocol is stable |

The "needs input" case is the one that sold me. When Claude hits a decision point and asks the user a question, the terminal shows a prompt — but the app has no reliable way to detect that from stdout. With MCP, Claude calls `omniscribe_status("needs_input", "...", "Should I use PostgreSQL or SQLite?")` and the UI can show a notification, highlight the session, whatever makes sense.

## The cost

Every `omniscribe_status` call costs tokens. The tool call itself, plus the response. In practice it's around 200-400 tokens per status update — negligible compared to the thousands of tokens Claude uses for actual work. And the MCP server responds with a one-line confirmation, so the response tokens are minimal.

The HTTP server on localhost is a new moving part. Port conflicts are possible (though the range is 100 ports wide). The instance ID validation adds a layer of defense, but it's still an HTTP endpoint on your machine.

Worth it? For a desktop app where sessions can run for 10+ minutes on complex tasks — absolutely. The alternative is staring at a terminal and guessing.

## Lessons

1. **MCP tools don't have to do "real work."** A tool that just reports state is perfectly valid and surprisingly useful.

2. **Instructions are the control surface.** The schema defines what the AI *can* do. The instructions define what it *will* do. "Call frequently" is worth more than a perfectly typed schema.

3. **Environment variables in `.mcp.json` are the glue.** They're how a parent process passes context to a grandchild process (Omniscribe -> Claude -> MCP server) without any direct communication channel.

4. **Instance IDs prevent ghost updates.** If a previous Omniscribe instance died without cleanup, stale MCP servers might still be running. The UUID check makes them harmless.

5. **Snapshot-based state is simpler than diffs.** `omniscribe_tasks` sends the full list every time. No "add task" / "remove task" / "update task" — just "here's everything." The server is stateless. The client just replaces what it has.

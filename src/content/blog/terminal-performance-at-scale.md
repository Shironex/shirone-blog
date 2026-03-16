---
title: 'Taming 12 Terminals: How We Stopped the UI from Freezing'
description: 'Running 12 AI coding sessions at once means 12 terminals generating output simultaneously. Here is how we kept the UI responsive.'
pubDate: '2026-03-16T14:00:00'
tags: ['electron', 'omniscribe', 'performance']
---

Omniscribe runs up to 12 AI coding sessions simultaneously. Each session gets its own terminal — xterm.js on the frontend, node-pty on the backend. When one AI agent is dumping a 500-line file diff while three others are running test suites, that's four terminals blasting output at the same time.

The naive version froze the UI within seconds.

## The firehose problem

Each `node-pty` instance fires an `onData` callback for every chunk the PTY produces. During heavy output — think `npm install` or a large git diff — a single terminal can fire dozens of events per second. Multiply by 12, and the renderer was drowning in `xterm.write()` calls. We measured roughly 250 writes per second across all terminals during peak bursts.

Every `write()` triggers xterm.js's parser, which updates the buffer, which triggers a render. At 250/sec, the browser's main thread had no breathing room for anything else — no mouse events, no tab switching, no scrolling. The app looked frozen even though every terminal was technically working.

## Backend: throttle at the source

The first layer of defense lives in `TerminalService`, the NestJS service managing all PTY processes. Instead of forwarding every `onData` event immediately, output accumulates in a per-session buffer and flushes on a 32ms timer (~30fps):

```typescript
const OUTPUT_THROTTLE_MS = 32;
const OUTPUT_BATCH_SIZE = 65_536;  // 64KB
const MAX_OUTPUT_BUFFER_SIZE = 524_288;  // 512KB

ptyProcess.onData((data: string) => {
  session.outputBuffer += data;

  if (session.outputBuffer.length > MAX_OUTPUT_BUFFER_SIZE) {
    session.outputBuffer = session.outputBuffer.slice(-MAX_OUTPUT_BUFFER_SIZE);
  }

  if (!session.flushTimer) {
    session.flushTimer = setTimeout(() => {
      this.flushOutput(sessionId);
    }, OUTPUT_THROTTLE_MS);
  }
});
```

The flush logic is chunk-aware. If the buffer exceeds 64KB, it sends the first 64KB and reschedules itself for the remainder. This prevents a single massive burst from monopolizing the socket:

```typescript
private flushOutput(sessionId: number): void {
  const session = this.sessions.get(sessionId);
  if (!session || session.paused) { session.flushTimer = null; return; }

  if (session.outputBuffer.length > OUTPUT_BATCH_SIZE) {
    const chunk = session.outputBuffer.slice(0, OUTPUT_BATCH_SIZE);
    session.outputBuffer = session.outputBuffer.slice(OUTPUT_BATCH_SIZE);
    this.eventEmitter.emit(InternalTerminalEvents.OUTPUT, { sessionId, data: chunk });
    session.flushTimer = setTimeout(() => this.flushOutput(sessionId), OUTPUT_THROTTLE_MS);
    return;
  }

  this.eventEmitter.emit(InternalTerminalEvents.OUTPUT, { sessionId, data: session.outputBuffer });
  session.outputBuffer = '';
  session.flushTimer = null;
}
```

The 512KB cap on `outputBuffer` is a safety valve. If output arrives faster than we can flush (backpressure scenario), we keep only the most recent 512KB rather than letting memory grow unbounded. Data is lost, but the alternative is the process running out of heap.

## Frontend: one write per frame

Even with backend throttling, socket events still arrive in bursts. The frontend adds a second coalescing layer using `requestAnimationFrame`:

```typescript
const MAX_HIDDEN_BUFFER_SIZE = 1_048_576;  // 1MB

const handleOutput = useCallback((data: string) => {
  if (isDisposedRef.current) return;
  writeBufferRef.current += data;

  if (!isActiveRef.current && writeBufferRef.current.length > MAX_HIDDEN_BUFFER_SIZE) {
    const trimmed = writeBufferRef.current.slice(-MAX_HIDDEN_BUFFER_SIZE);
    const firstNewline = trimmed.indexOf('\n');
    writeBufferRef.current = firstNewline > 0 ? trimmed.slice(firstNewline) : trimmed;
  }

  if (isActiveRef.current && rafIdRef.current === null) {
    rafIdRef.current = requestAnimationFrame(flushWriteBuffer);
  }
}, [isDisposedRef, isActiveRef, flushWriteBuffer]);
```

Multiple socket events between frames get concatenated into `writeBufferRef`, then written as a single `xterm.write()` call on the next animation frame. This dropped us from ~250 writes/sec to ~60 — one per frame per terminal.

The real win is hidden terminals. When a terminal tab is not visible, `isActiveRef` is false, and RAF scheduling stops entirely. Data still accumulates in the buffer (capped at 1MB), but zero CPU goes to parsing or rendering it. When the user switches back, `flushBuffer()` fires a single RAF to write everything at once.

### The newline trick

That buffer trimming deserves a closer look. When we slice to the last 1MB of output, we might cut in the middle of an ANSI escape sequence like `\x1b[38;2;255;128;0m`. Writing a partial escape to xterm.js corrupts the parser state — you get garbled colors that persist for the rest of the session. Trimming to the next newline boundary avoids this because escape sequences don't span lines.

## Backpressure: when output wins

Sometimes output genuinely overwhelms the pipe. An AI session running `cat` on a 10MB log, or a test suite with verbose logging, can produce data faster than the throttle-and-batch pipeline can drain it.

The backend supports explicit PTY pause/resume. When the frontend detects backpressure (buffer hitting capacity), it signals the backend, which calls `session.pty.pause()`. This triggers kernel-level flow control — the child process's writes to stdout will block until we resume. No data is lost, but the AI session effectively stalls until the pipe drains.

```typescript
pause(sessionId: number): void {
  const session = this.sessions.get(sessionId);
  if (!session || session.paused) return;
  session.pty.pause();
  session.paused = true;
}

resume(sessionId: number): void {
  const session = this.sessions.get(sessionId);
  if (!session || !session.paused) return;
  session.pty.resume();
  session.paused = false;

  if (session.outputBuffer.length > 0 && !session.flushTimer) {
    session.flushTimer = setTimeout(() => this.flushOutput(sessionId), OUTPUT_THROTTLE_MS);
  }
}
```

The user sees a "Buffering output..." overlay — but only after 500ms of sustained backpressure. Transient spikes (< 500ms) never show the overlay, which avoids a distracting flicker during normal operation:

```typescript
useEffect(() => {
  if (!isBackpressured) { setVisible(false); return; }
  const timer = setTimeout(() => setVisible(true), DEBOUNCE_MS);
  return () => clearTimeout(timer);
}, [isBackpressured]);
```

The overlay also has a "Cancel output" button that kills the session. Sometimes the right answer is to stop the process, not wait for it.

## Terminal initialization: patience required

With 12 terminals mounting simultaneously in a grid layout, container dimensions are not immediately available. CSS grid calculates sizes across frames, and a terminal opened with 0x0 dimensions produces garbage layout.

The init hook defers `xterm.open()` until the container has non-zero dimensions, then runs a fit-retry loop — up to 20 attempts, each scheduled via `requestAnimationFrame`:

```typescript
const performInitialFit = (retriesLeft: number) => {
  if (isDisposedRef.current || !terminal || !fitAddon) return;

  const result = safeFit(fitAddon, terminal, container);
  if (result) {
    isReadyRef.current = true;
    resizeTerminal(sessionId, result.cols, result.rows);
    connectAndJoin(sessionId);
  } else if (retriesLeft > 0) {
    initRetryTimeout = setTimeout(() => {
      requestAnimationFrame(() => performInitialFit(retriesLeft - 1));
    }, 50);
  } else {
    logger.warn('Fit retries exhausted, connecting anyway');
    isReadyRef.current = true;
    connectAndJoin(sessionId);
  }
};

requestAnimationFrame(() => performInitialFit(20));
```

If all 20 retries fail, it connects anyway and schedules deferred fits at 100ms, 250ms, 500ms, and 1000ms. This handles the case where a panel animation or DnD reorder delays the final layout. The terminal might render at a wrong size for a fraction of a second, but it self-corrects.

## Write serialization

One more subtlety: user input writes. When the user types in a terminal while an AI is also feeding commands into it, you can get interleaved writes. Each session has a promise chain that serializes writes:

```typescript
write(sessionId: number, data: string): void {
  const session = this.sessions.get(sessionId);
  if (!session) return;

  session.writeChain = session.writeChain
    .then(() => this.performWrite(session, data))
    .catch(err => this.logger.error(`[write] Failed for session ${sessionId}:`, err));
}
```

Large writes (> 1000 chars) are chunked into 100-char pieces with `setImmediate` yields between them, so a paste of 50KB of text doesn't block the event loop for the other 11 sessions.

## The numbers

| Layer | Mechanism | Key numbers |
|-------|-----------|-------------|
| Backend output | Timer-based throttle | 32ms interval (~30fps) |
| Backend output | Chunk batching | 64KB per flush |
| Backend output | Buffer cap | 512KB per terminal |
| Frontend output | RAF coalescing | ~250 writes/sec to ~60 writes/sec |
| Frontend hidden | RAF paused + buffer | 1MB cap, newline-boundary trim |
| Backpressure UI | Debounced overlay | 500ms threshold |
| Init | Fit retry loop | 20 retries via RAF + 50ms timeouts |
| Writes | Serialized queue | 100-char chunks with `setImmediate` yield |

Total memory budget per terminal in the worst case: 512KB backend buffer + 500KB scrollback + 1MB frontend hidden buffer = ~2MB. For 12 terminals, that's 24MB. Acceptable.

## What we learned

**Throttle at the source.** The temptation is to fix everything in the renderer. But if you're already sending 250 socket events/sec, no amount of frontend optimization makes that cheap. The 32ms timer on the backend cut the event count before it ever hit the IPC bridge.

**Hidden work is wasted work.** Pausing RAF for background terminals was the single biggest win. Before that change, 12 terminals at 60fps meant 720 `xterm.write()` calls per second even if the user could only see one. After: 60.

**Backpressure is a feature, not a failure.** The instinct is to buffer everything and never lose data. But unbounded buffers just convert a performance problem into a memory problem. Cap the buffer, pause the source, tell the user what's happening.

**Retry, don't assume.** Container dimensions in a grid layout are non-deterministic during mount. Waiting for "ready" events is fragile. A retry loop with exponential backoff is ugly but reliable. The 20-retry RAF loop handles every edge case we've thrown at it — panel resizes, drag-and-drop reorders, animation delays.

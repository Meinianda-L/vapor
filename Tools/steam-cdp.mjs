// Evaluates JavaScript inside Windows Steam's SharedJSContext over CEF remote debugging.
// usage: node steam-cdp.mjs '<async expression>'   (prints the JSON result)
const port = process.env.STEAM_CDP_PORT || 38917;
const targets = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
const want = process.env.STEAM_CDP_TARGET || 'SharedJSContext';
const ctx = targets.find(t => t.title === want);
if (!ctx) { console.error(want + ' not found'); process.exit(2); }
const ws = new WebSocket(ctx.webSocketDebuggerUrl);
await new Promise((ok, fail) => { ws.onopen = ok; ws.onerror = fail; });
const expression = `(async () => { ${process.argv[2]} })()`;
ws.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: { expression, awaitPromise: true, returnByValue: true } }));
const reply = await new Promise(ok => { ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id === 1) ok(m); }; });
ws.close();
if (reply.result?.exceptionDetails) { console.error(JSON.stringify(reply.result.exceptionDetails)); process.exit(1); }
console.log(JSON.stringify(reply.result?.result?.value ?? reply.result, null, 1));

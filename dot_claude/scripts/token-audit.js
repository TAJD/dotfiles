#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const os = require('os');

const TZ_OFFSET_MIN = 60;

function parseArgs(argv) {
  const a = { top: 30, out: null, since: null, until: null, utc: false, root: null };
  for (let i = 2; i < argv.length; i++) {
    const k = argv[i];
    if (k === '--since') a.since = argv[++i];
    else if (k === '--until') a.until = argv[++i];
    else if (k === '--out') a.out = argv[++i];
    else if (k === '--top') a.top = Number(argv[++i]);
    else if (k === '--root') a.root = argv[++i];
    else if (k === '--utc') a.utc = true;
    else throw new Error(`unknown arg ${k}`);
  }
  return a;
}

const args = parseArgs(process.argv);
const ROOT = args.root || path.join(os.homedir(), '.claude', 'projects');
const OUT = args.out || path.join(process.cwd(), 'token-audit-out');

function bound(dateStr, endOfDay) {
  if (!dateStr) return null;
  const [y, m, d] = dateStr.split('-').map(Number);
  const base = Date.UTC(y, m - 1, d, endOfDay ? 23 : 0, endOfDay ? 59 : 0, endOfDay ? 59 : 0, endOfDay ? 999 : 0);
  return args.utc ? base : base - TZ_OFFSET_MIN * 60000;
}
const SINCE = bound(args.since, false);
const UNTIL = bound(args.until, true);

const zeroTok = () => ({ fresh: 0, cacheCreate: 0, cacheRead: 0, output: 0, calls: 0 });
function addTok(dst, u) {
  dst.fresh += u.input_tokens || 0;
  dst.cacheCreate += u.cache_creation_input_tokens || 0;
  dst.cacheRead += u.cache_read_input_tokens || 0;
  dst.output += u.output_tokens || 0;
  dst.calls += 1;
}
const total = (t) => t.fresh + t.cacheCreate + t.cacheRead + t.output;

const fleet = zeroTok();
const byProject = new Map();
const sessions = new Map();
const byTool = new Map();
const byModel = new Map();
const bigResults = [];
const errorSamples = new Map();
const dupCalls = new Map();
const readRepeat = new Map();
let compactions = 0;
const compactSessions = new Set();
let recordsScanned = 0, filesScanned = 0, badLines = 0;
const seenRequests = new Set();

function callSignature(name, input) {
  if (!input || typeof input !== 'object') return `${name}|`;
  const pick = (k) => (input[k] === undefined ? '' : String(input[k]));
  switch (name) {
    case 'Read': return `Read|${pick('file_path')}|${pick('offset')}|${pick('limit')}`;
    case 'Bash':
    case 'PowerShell': return `${name}|${pick('command')}`;
    case 'Grep': return `Grep|${pick('pattern')}|${pick('path')}|${pick('glob')}|${pick('output_mode')}`;
    case 'Glob': return `Glob|${pick('pattern')}|${pick('path')}`;
    default: {
      let s;
      try { s = JSON.stringify(input); } catch { s = String(input); }
      return `${name}|${s.slice(0, 400)}`;
    }
  }
}

function shortInput(name, input) {
  if (!input || typeof input !== 'object') return '';
  if (input.command) return String(input.command).replace(/\s+/g, ' ').slice(0, 160);
  if (input.file_path) return String(input.file_path).slice(0, 160);
  if (input.pattern) return `pattern=${String(input.pattern).slice(0, 80)} ${input.path || input.glob || ''}`;
  if (input.prompt) return `prompt: ${String(input.prompt).replace(/\s+/g, ' ').slice(0, 140)}`;
  try { return JSON.stringify(input).slice(0, 160); } catch { return ''; }
}

function resultBytes(rec) {
  const c = rec.message && rec.message.content;
  let bytes = 0, isError = false, text = '';
  if (Array.isArray(c)) {
    for (const block of c) {
      if (block.type !== 'tool_result') continue;
      if (block.is_error) isError = true;
      const body = block.content;
      if (typeof body === 'string') { bytes += Buffer.byteLength(body); text += body; }
      else if (Array.isArray(body)) {
        for (const b of body) {
          if (typeof b === 'string') { bytes += Buffer.byteLength(b); text += b; }
          else if (b && b.type === 'text' && typeof b.text === 'string') { bytes += Buffer.byteLength(b.text); text += b.text; }
          else if (b) { const s = JSON.stringify(b); bytes += Buffer.byteLength(s); }
        }
      } else if (body) { const s = JSON.stringify(body); bytes += Buffer.byteLength(s); }
    }
  }
  return { bytes, isError, text };
}

function errorSignature(text) {
  return text
    .replace(/[A-Za-z]:\\[^\s"']+/g, '<path>')
    .replace(/\/[\w.\-\/]{6,}/g, '<path>')
    .replace(/\b[0-9a-f]{7,}\b/gi, '<hash>')
    .replace(/\b\d+\b/g, '<n>')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 180);
}

function scanFile(projectKey, file, parentSessionId) {
  let raw;
  try { raw = fs.readFileSync(file, 'utf8'); } catch { return; }
  filesScanned++;

  const toolUses = new Map();
  const recs = [];
  for (const line of raw.split('\n')) {
    if (!line) continue;
    let d;
    try { d = JSON.parse(line); } catch { badLines++; continue; }
    recs.push(d);
  }
  recordsScanned += recs.length;

  for (const d of recs) {
    if (d.type !== 'assistant' || !d.message || !Array.isArray(d.message.content)) continue;
    for (const b of d.message.content) {
      if (b.type === 'tool_use') toolUses.set(b.id, { name: b.name, input: b.input, ts: d.timestamp });
    }
  }

  for (const d of recs) {
    const ts = d.timestamp ? Date.parse(d.timestamp) : null;
    if (ts !== null && !Number.isNaN(ts)) {
      if (SINCE !== null && ts < SINCE) continue;
      if (UNTIL !== null && ts > UNTIL) continue;
    } else if (SINCE !== null || UNTIL !== null) {
      continue;
    }

    const isSub = !!parentSessionId;
    const sid = parentSessionId || d.sessionId || d.session_id || path.basename(file, '.jsonl');
    let S = sessions.get(sid);
    if (!S) {
      S = {
        sessionId: sid, project: projectKey, file,
        tok: zeroTok(), sidechainTok: zeroTok(),
        tMin: Infinity, tMax: -Infinity,
        assistantTurns: 0, userTurns: 0, toolCalls: 0, toolBytes: 0,
        errCalls: 0, errBytes: 0, dupBytes: 0, dupCalls: 0,
        compactions: 0, models: new Set(), ctx: [],
        seenSig: new Map(), costUSD: null, items: [],
      };
      sessions.set(sid, S);
    }
    if (ts !== null && !Number.isNaN(ts)) { if (ts < S.tMin) S.tMin = ts; if (ts > S.tMax) S.tMax = ts; }

    let P = byProject.get(projectKey);
    if (!P) { P = { tok: zeroTok(), sessions: new Set(), toolBytes: 0 }; byProject.set(projectKey, P); }
    P.sessions.add(sid);

    if (d.type === 'assistant' && d.message && d.message.usage) {
      const rk = d.requestId ? `${d.requestId}|${d.message.id || ''}` : null;
      if (!rk || !seenRequests.has(rk)) {
        if (rk) seenRequests.add(rk);
        const u = d.message.usage;
        addTok(fleet, u);
        addTok(P.tok, u);
        addTok(isSub || d.isSidechain ? S.sidechainTok : S.tok, u);
        const m = d.message.model || 'unknown';
        if (!byModel.has(m)) byModel.set(m, zeroTok());
        addTok(byModel.get(m), u);
        S.models.add(m);
        S.assistantTurns++;
        if (!isSub && !d.isSidechain && ts) {
          S.items.push({ kind: 'turn', t: ts });
          let keepB = 0, thinkB = 0;
          if (Array.isArray(d.message.content)) {
            for (const b of d.message.content) {
              if (b.type === 'thinking' || b.type === 'redacted_thinking') {
                thinkB += Buffer.byteLength(b.thinking || b.data || '');
              } else if (b.type === 'text') {
                keepB += Buffer.byteLength(b.text || '');
              } else if (b.type === 'tool_use') {
                try { keepB += Buffer.byteLength(JSON.stringify(b.input || {})) + Buffer.byteLength(b.name || ''); } catch { keepB += 0; }
              }
            }
          }
          S.items.push({ kind: 'add', t: ts, cat: 'output: assistant text + tool-call args (persists)', tok: keepB / 4 });
          S.thinkTok = (S.thinkTok || 0) + thinkB / 4;
          S.keepTok = (S.keepTok || 0) + keepB / 4;
        }
        const ctxSize = (u.input_tokens || 0) + (u.cache_creation_input_tokens || 0) + (u.cache_read_input_tokens || 0);
        S.ctx.push({ t: ts, ctx: ctxSize, out: u.output_tokens || 0, side: isSub || !!d.isSidechain });
      }
      if (Array.isArray(d.message.content)) {
        for (const b of d.message.content) if (b.type === 'tool_use') S.toolCalls++;
      }
    }

    if (d.type === 'user' && d.message) {
      if (d.isCompactSummary) {
        compactions++; S.compactions++; compactSessions.add(sid);
        if (!isSub && ts) {
          S.items.push({ kind: 'compact', t: ts });
          const c = d.message.content;
          const txt = typeof c === 'string' ? c : (Array.isArray(c) ? c.map((b) => b.text || '').join('') : '');
          S.items.push({ kind: 'add', t: ts + 1, cat: 'compaction summary', tok: Buffer.byteLength(txt) / 4 });
        }
      }
      const { bytes, isError, text } = resultBytes(d);
      if (bytes > 0) {
        let name = 'unknown', input = null;
        const c = d.message.content;
        if (Array.isArray(c)) {
          for (const block of c) {
            if (block.type === 'tool_result' && toolUses.has(block.tool_use_id)) {
              const tu = toolUses.get(block.tool_use_id); name = tu.name; input = tu.input; break;
            }
          }
        }
        let T = byTool.get(name);
        if (!T) { T = { calls: 0, bytes: 0, errCalls: 0, errBytes: 0 }; byTool.set(name, T); }
        T.calls++; T.bytes += bytes;
        S.toolBytes += bytes; P.toolBytes += bytes;
        if (!isSub && ts) S.items.push({ kind: 'add', t: ts, cat: `tool:${name}${isError ? ' [ERROR]' : ''}`, tok: bytes / 4 });
        if (isError) {
          T.errCalls++; T.errBytes += bytes; S.errCalls++; S.errBytes += bytes;
          const sig = errorSignature(text);
          let E = errorSamples.get(sig);
          if (!E) { E = { count: 0, bytes: 0, sessions: new Set(), tool: name, sample: text.slice(0, 200) }; errorSamples.set(sig, E); }
          E.count++; E.bytes += bytes; E.sessions.add(sid);
        }

        bigResults.push({ bytes, tool: name, session: sid, project: projectKey, what: shortInput(name, input), isError });
        if (bigResults.length > 4000) {
          bigResults.sort((a, b) => b.bytes - a.bytes);
          bigResults.length = 500;
        }

        const sig = callSignature(name, input);
        if (S.seenSig.has(sig)) {
          S.dupCalls++; S.dupBytes += bytes;
          let D = dupCalls.get(sig);
          if (!D) { D = { n: 0, bytes: 0, sessions: new Set(), tool: name, what: shortInput(name, input) }; dupCalls.set(sig, D); }
          D.n++; D.bytes += bytes; D.sessions.add(sid);
        } else {
          S.seenSig.set(sig, bytes);
        }
        if (name === 'Read' && input && input.file_path) {
          const k = `${sid}|${input.file_path}`;
          const R = readRepeat.get(k);
          if (R) { R.n++; R.bytes += bytes; }
          else readRepeat.set(k, { n: 1, bytes, file: input.file_path, session: sid, project: projectKey });
        }
      } else if (!Array.isArray(d.message.content) || d.message.content.some((b) => b.type !== 'tool_result')) {
        S.userTurns++;
      }
    }

    if (d.type === 'attachment' && d.attachment && !isSub && ts) {
      const a = d.attachment;
      const body = String(a.stdout || a.content || '');
      const b = Buffer.byteLength(body);
      if (b > 0) {
        const label = a.hookName || a.hookEvent || a.type || 'attachment';
        S.items.push({ kind: 'add', t: ts, cat: `hook/attachment:${a.type === 'skill_listing' ? 'skill_listing' : label}`, tok: b / 4 });
      }
    }

    if (d.type === 'summary' && typeof d.totalCostUSD === 'number') S.costUSD = d.totalCostUSD;
  }
}

const projectKeys = fs.readdirSync(ROOT).filter((k) => {
  try { return fs.statSync(path.join(ROOT, k)).isDirectory(); } catch { return false; }
});
let subagentFiles = 0;
for (const k of projectKeys) {
  const dir = path.join(ROOT, k);
  for (const f of fs.readdirSync(dir)) {
    const p = path.join(dir, f);
    if (f.endsWith('.jsonl')) { scanFile(k, p); continue; }
    let st;
    try { st = fs.statSync(p); } catch { continue; }
    if (!st.isDirectory()) continue;
    const subDir = path.join(p, 'subagents');
    if (!fs.existsSync(subDir)) continue;
    for (const sf of fs.readdirSync(subDir)) {
      if (sf.endsWith('.jsonl')) { scanFile(k, path.join(subDir, sf), f); subagentFiles++; }
    }
  }
}

for (const [sid, S] of sessions) if (S.tok.calls === 0 && S.sidechainTok.calls === 0 && S.toolBytes === 0) sessions.delete(sid);

bigResults.sort((a, b) => b.bytes - a.bytes);
bigResults.length = Math.min(bigResults.length, 300);

fs.mkdirSync(OUT, { recursive: true });
const fmt = (n) => n.toLocaleString('en-US');
const mb = (b) => (b / 1048576).toFixed(1) + ' MB';
const pct = (a, b) => (b ? ((a / b) * 100).toFixed(1) + '%' : '0%');
const L = [];
const say = (s = '') => L.push(s);

const winLabel = `${args.since || 'all'} .. ${args.until || 'all'}${args.utc ? ' (UTC)' : ' (local UTC+1)'}`;
say(`# Token audit - window ${winLabel}`);
say(`files=${filesScanned} records=${fmt(recordsScanned)} badLines=${badLines} sessions=${sessions.size} projects=${byProject.size}`);
say('');
say('## 1. Fleet totals (deduped by requestId)');
const FT = total(fleet);
say(`api calls        ${fmt(fleet.calls)}`);
say(`cache read       ${fmt(fleet.cacheRead)}  (${pct(fleet.cacheRead, FT)})`);
say(`cache creation   ${fmt(fleet.cacheCreate)}  (${pct(fleet.cacheCreate, FT)})`);
say(`fresh input      ${fmt(fleet.fresh)}  (${pct(fleet.fresh, FT)})`);
say(`output           ${fmt(fleet.output)}  (${pct(fleet.output, FT)})`);
say(`TOTAL            ${fmt(FT)}`);
say('');
say('## 2. By model');
for (const [m, t] of [...byModel].sort((a, b) => total(b[1]) - total(a[1]))) {
  say(`${m.padEnd(28)} total=${fmt(total(t))}  read=${fmt(t.cacheRead)} create=${fmt(t.cacheCreate)} fresh=${fmt(t.fresh)} out=${fmt(t.output)} calls=${fmt(t.calls)}`);
}
say('');
say(`## 3. Top ${args.top} projects by total tokens`);
for (const [k, P] of [...byProject].sort((a, b) => total(b[1].tok) - total(a[1].tok)).slice(0, args.top)) {
  say(`${fmt(total(P.tok)).padStart(14)}  read=${pct(P.tok.cacheRead, total(P.tok)).padStart(6)} out=${fmt(P.tok.output).padStart(9)}  sess=${String(P.sessions.size).padStart(3)}  toolOut=${mb(P.toolBytes).padStart(9)}  ${k}`);
}
say('');
const sessArr = [...sessions.values()].sort((a, b) => total(b.tok) + total(b.sidechainTok) - (total(a.tok) + total(a.sidechainTok)));
say(`## 4. Top ${args.top} sessions by total tokens`);
for (const S of sessArr.slice(0, args.top)) {
  const t = total(S.tok) + total(S.sidechainTok);
  const dur = S.tMax > S.tMin ? ((S.tMax - S.tMin) / 3600000).toFixed(1) + 'h' : '-';
  const day = S.tMin === Infinity ? '?' : new Date(S.tMin).toISOString().slice(0, 10);
  say(`${fmt(t).padStart(12)}  main=${fmt(total(S.tok)).padStart(11)} sub=${fmt(total(S.sidechainTok)).padStart(11)} turns=${String(S.assistantTurns).padStart(4)} tools=${String(S.toolCalls).padStart(4)} toolOut=${mb(S.toolBytes).padStart(8)} dup=${mb(S.dupBytes).padStart(8)} err=${String(S.errCalls).padStart(3)} cmp=${S.compactions} ${dur} ${day} ${S.project}/${S.sessionId.slice(0, 8)}`);
}
say('');
say('## 5. Tool result volume (ranked by bytes returned into context)');
const toolArr = [...byTool].sort((a, b) => b[1].bytes - a[1].bytes);
const toolTotalBytes = toolArr.reduce((s, [, t]) => s + t.bytes, 0);
say(`total tool result bytes ${mb(toolTotalBytes)}  (~${fmt(Math.round(toolTotalBytes / 4))} tokens at 4 B/tok)`);
for (const [name, T] of toolArr.slice(0, args.top)) {
  say(`${name.padEnd(34)} ${mb(T.bytes).padStart(10)} ${pct(T.bytes, toolTotalBytes).padStart(6)}  calls=${fmt(T.calls).padStart(7)}  avg=${fmt(Math.round(T.bytes / T.calls)).padStart(7)}B  err=${fmt(T.errCalls)}/${mb(T.errBytes)}`);
}
say('');
say(`## 6. Largest individual tool results (top ${args.top})`);
for (const r of bigResults.slice(0, args.top)) {
  say(`${mb(r.bytes).padStart(9)}  ${r.tool.padEnd(14)} ${r.isError ? 'ERR ' : '    '}${r.project.slice(0, 40).padEnd(40)} ${r.what}`);
}
say('');
say(`## 7. Redundancy - identical repeated calls in one session (top ${args.top} by wasted bytes)`);
const dupArr = [...dupCalls.values()].sort((a, b) => b.bytes - a.bytes);
const dupTotal = dupArr.reduce((s, d) => s + d.bytes, 0);
say(`total repeat-call bytes ${mb(dupTotal)} (${pct(dupTotal, toolTotalBytes)} of all tool output) across ${fmt(dupArr.reduce((s, d) => s + d.n, 0))} repeat calls`);
for (const d of dupArr.slice(0, args.top)) {
  say(`${mb(d.bytes).padStart(9)}  x${String(d.n).padStart(4)}  ${String(d.sessions.size).padStart(3)}sess  ${d.tool.padEnd(12)} ${d.what}`);
}
say('');
say('## 7b. Same file Read more than once in one session');
const rr = [...readRepeat.values()].filter((r) => r.n > 1).sort((a, b) => b.bytes - a.bytes);
const rrWaste = rr.reduce((s, r) => s + (r.bytes * (r.n - 1)) / r.n, 0);
say(`${fmt(rr.length)} (session,file) pairs re-read; ~${mb(rrWaste)} of re-read bytes`);
for (const r of rr.slice(0, args.top)) {
  say(`${mb(r.bytes).padStart(9)}  x${String(r.n).padStart(3)}  ${r.file}`);
}
say('');
say(`## 8. Failure waste - errored tool results (top ${args.top} signatures)`);
const errArr = [...errorSamples.values()].sort((a, b) => b.bytes - a.bytes);
const errBytesTotal = toolArr.reduce((s, [, t]) => s + t.errBytes, 0);
say(`total errored tool result bytes ${mb(errBytesTotal)} (${pct(errBytesTotal, toolTotalBytes)} of all tool output)`);
for (const e of errArr.slice(0, args.top)) {
  say(`${mb(e.bytes).padStart(9)}  x${String(e.count).padStart(4)}  ${String(e.sessions.size).padStart(3)}sess  ${e.tool.padEnd(12)} ${e.sample.replace(/\s+/g, ' ').slice(0, 120)}`);
}
say('');
say('## 9. Context growth / compaction');
say(`sessions that compacted: ${compactSessions.size} (${compactions} compaction events)`);
const withCtx = sessArr.filter((S) => S.ctx.length >= 20);
say(`sessions with >=20 assistant turns: ${withCtx.length}`);
const ctxRank = withCtx.map((S) => {
  const main = S.ctx.filter((c) => !c.side);
  const arr = main.length ? main : S.ctx;
  const mean = arr.reduce((s, c) => s + c.ctx, 0) / arr.length;
  const peak = Math.max(...arr.map((c) => c.ctx));
  return { S, mean, peak, n: arr.length };
}).sort((a, b) => b.mean * b.n - a.mean * a.n);
for (const r of ctxRank.slice(0, args.top)) {
  say(`meanCtx=${fmt(Math.round(r.mean)).padStart(8)} peak=${fmt(r.peak).padStart(8)} turns=${String(r.n).padStart(4)} cmp=${r.S.compactions}  ${r.S.project}/${r.S.sessionId.slice(0, 8)}`);
}

say('');
say('## 10. Fixed-prefix overhead (system prompt + CLAUDE.md + tool defs + skills + hooks)');
say('Proxy: smallest context seen on a main-chain turn in the session = the prefix that is');
say('re-sent on every subsequent turn. floor = minCtx * mainTurns.');
let floorSum = 0, mainReadSum = 0;
const floorRows = [];
for (const S of sessArr) {
  const main = S.ctx.filter((c) => !c.side);
  if (main.length < 5) continue;
  const minCtx = Math.min(...main.map((c) => c.ctx));
  const sumCtx = main.reduce((s, c) => s + c.ctx, 0);
  floorSum += minCtx * main.length;
  mainReadSum += sumCtx;
  floorRows.push({ S, minCtx, turns: main.length, floor: minCtx * main.length, sumCtx });
}
say(`sessions considered: ${floorRows.length}`);
say(`sum of per-turn context (main chain): ${fmt(mainReadSum)}`);
say(`fixed-prefix floor:                   ${fmt(floorSum)}  (${pct(floorSum, mainReadSum)} of main-chain context volume)`);
floorRows.sort((a, b) => b.floor - a.floor);
for (const r of floorRows.slice(0, args.top)) {
  say(`minCtx=${fmt(r.minCtx).padStart(8)} turns=${String(r.turns).padStart(5)} floor=${fmt(r.floor).padStart(12)} ${pct(r.floor, r.sumCtx).padStart(6)} of session  ${r.S.project}/${r.S.sessionId.slice(0, 8)}`);
}
say('');
say('## 11. Subagent share');
const subTotal = sessArr.reduce((s, S) => s + total(S.sidechainTok), 0);
const mainTotal = sessArr.reduce((s, S) => s + total(S.tok), 0);
say(`subagent transcript files: ${subagentFiles}`);
say(`main-chain tokens ${fmt(mainTotal)}  subagent tokens ${fmt(subTotal)} (${pct(subTotal, mainTotal + subTotal)})`);
const withSub = sessArr.filter((S) => total(S.sidechainTok) > 0).length;
say(`sessions using subagents: ${withSub} of ${sessions.size}`);

say('');
say('## 12. Amplified cost by source');
say('A block of B tokens entering context at turn t of a compaction segment with M later');
say('turns is re-sent M times, so it is paid B*(M+1). Sizes are bytes/4. Categories:');
say('hook:<name> = hook output injected into context; tool:<name> = tool result; output =');
say('assistant text+thinking+tool-call args (billed once as output, then re-read as input).');
const amp = new Map();
function bump(cat, tokens, times, count) {
  let A = amp.get(cat);
  if (!A) { A = { added: 0, paid: 0, n: 0 }; amp.set(cat, A); }
  A.added += tokens; A.paid += tokens * times; A.n += count;
}
let ampTotalPaid = 0;
for (const S of sessions.values()) {
  const items = S.items;
  if (!items || !items.length) continue;
  items.sort((a, b) => a.t - b.t);
  const turnTimes = [];
  const segStarts = [];
  for (const it of items) {
    if (it.kind === 'turn') turnTimes.push(it.t);
    if (it.kind === 'compact') segStarts.push(it.t);
  }
  if (!turnTimes.length) continue;
  const segEndAfter = (t) => {
    const next = segStarts.find((s) => s > t);
    return next === undefined ? Infinity : next;
  };
  for (const it of items) {
    if (it.kind === 'turn' || it.kind === 'compact') continue;
    const limit = segEndAfter(it.t);
    let later = 0;
    for (const tt of turnTimes) if (tt > it.t && tt < limit) later++;
    const times = later + 1;
    bump(it.cat, it.tok, times, 1);
    ampTotalPaid += it.tok * times;
  }
}
const ampArr = [...amp].sort((a, b) => b[1].paid - a[1].paid);
const thinkAll = [...sessions.values()].reduce((s, S) => s + (S.thinkTok || 0), 0);
say(`thinking tokens generated but NOT re-read on later turns: ~${fmt(Math.round(thinkAll))} (billed as output only)`);
say(`total amplified cost of conversation-body items: ${fmt(Math.round(ampTotalPaid))} tokens`);
say(`(compare: fixed-prefix floor ${fmt(floorSum)}; measured cache read ${fmt(fleet.cacheRead)})`);
for (const [cat, A] of ampArr.slice(0, args.top * 2)) {
  say(`${fmt(Math.round(A.paid)).padStart(13)}  ${pct(A.paid, ampTotalPaid).padStart(6)}  added=${fmt(Math.round(A.added)).padStart(10)} n=${fmt(A.n).padStart(6)} avgAmp=${(A.paid / (A.added || 1)).toFixed(0).padStart(4)}x  ${cat}`);
}

say('');
say('## 13. Fitted per-source token cost and amplified cost');
say('Every consecutive pair of main-chain turns gives an equation: the observed context');
say('delta equals the summed real token cost of the events in between, plus a constant');
say('per-turn overhead (system-reminders, tool-result framing, user text). Fitting all such');
say('equations at once by non-negative multiplicative update gives cal = real tokens per');
say('modelled token for each category. No tokenizer is assumed.');
const rows = [];
const catIndex = new Map();
const CONST = '__per-turn overhead (system-reminders, framing)';
catIndex.set(CONST, 0);
const catNames = [CONST];
const evByCat = new Map();
for (const S of sessions.values()) {
  const items = S.items;
  if (!items || !items.length) continue;
  items.sort((a, b) => a.t - b.t);
  const turns = S.ctx.filter((c) => !c.side && c.t).map((c) => ({ t: c.t, ctx: c.ctx })).sort((a, b) => a.t - b.t);
  if (turns.length < 3) continue;
  const segStarts = items.filter((i) => i.kind === 'compact').map((i) => i.t);
  const adds = items.filter((i) => i.kind === 'add' && i.tok > 0);
  const segEndAfter = (t) => { const n = segStarts.find((s) => s > t); return n === undefined ? Infinity : n; };
  for (const ev of adds) {
    if (!catIndex.has(ev.cat)) { catIndex.set(ev.cat, catNames.length); catNames.push(ev.cat); }
    const limit = segEndAfter(ev.t);
    let later = 0;
    for (const t of turns) if (t.t > ev.t && t.t < limit) later++;
    let E = evByCat.get(ev.cat);
    if (!E) { E = { added: 0, weighted: 0, n: 0 }; evByCat.set(ev.cat, E); }
    E.added += ev.tok; E.weighted += ev.tok * (later + 1); E.n++;
  }
  let ai = 0;
  for (let i = 0; i + 1 < turns.length; i++) {
    const a = turns[i].t, b = turns[i + 1].t;
    if (segStarts.some((s) => s > a && s <= b)) continue;
    const obs = turns[i + 1].ctx - turns[i].ctx;
    if (obs <= 0 || obs > 400000) continue;
    while (ai < adds.length && adds[ai].t < a) ai++;
    const m = new Map([[0, 1]]);
    for (let j = ai; j < adds.length && adds[j].t < b; j++) {
      const ci = catIndex.get(adds[j].cat);
      m.set(ci, (m.get(ci) || 0) + adds[j].tok);
    }
    rows.push({ obs, m });
  }
}
const cal = new Float64Array(catNames.length).fill(1);
for (let iter = 0; iter < 300; iter++) {
  const num = new Float64Array(catNames.length);
  const den = new Float64Array(catNames.length);
  for (const r of rows) {
    let pred = 0;
    for (const [ci, v] of r.m) pred += cal[ci] * v;
    if (pred <= 0) continue;
    const ratio = r.obs / pred;
    for (const [ci, v] of r.m) { num[ci] += v * ratio; den[ci] += v; }
  }
  for (let c = 0; c < cal.length; c++) if (den[c] > 0) cal[c] *= num[c] / den[c];
}
let ss = 0, st = 0;
for (const r of rows) {
  let pred = 0;
  for (const [ci, v] of r.m) pred += cal[ci] * v;
  ss += Math.abs(r.obs - pred); st += r.obs;
}
say(`equations fitted: ${fmt(rows.length)}   mean |residual| / observed = ${(ss / st * 100).toFixed(1)}%`);
say(`fitted per-turn constant overhead: ${Math.round(cal[0])} tokens/turn`);
say('');
const empRows = [...evByCat].map(([c, E]) => ({
  cat: c, cal: cal[catIndex.get(c)],
  added: E.added * cal[catIndex.get(c)],
  paid: E.weighted * cal[catIndex.get(c)], n: E.n,
})).sort((a, b) => b.paid - a.paid);
const bodyTotal = empRows.reduce((s, r) => s + r.paid, 0);
say(`fixed-prefix floor (observed minCtx x turns, unfitted): ${fmt(floorSum)}  ${pct(floorSum, fleet.cacheRead)} of fleet cache read`);
say(`fitted amplified cost of conversation-body items:        ${fmt(Math.round(bodyTotal))}  ${pct(bodyTotal, fleet.cacheRead)}`);
say(`measured fleet cache read:                               ${fmt(fleet.cacheRead)}`);
say(`accounted: ${pct(floorSum + bodyTotal, fleet.cacheRead)}`);
say('');
say(`${'source'.padEnd(50)} ${'amplified'.padStart(13)} ${'share'.padStart(7)} ${'added'.padStart(11)} ${'n'.padStart(6)} ${'cal'.padStart(6)}`);
for (const r of empRows.slice(0, args.top * 2)) {
  say(`${r.cat.slice(0, 50).padEnd(50)} ${fmt(Math.round(r.paid)).padStart(13)} ${pct(r.paid, fleet.cacheRead).padStart(7)} ${fmt(Math.round(r.added)).padStart(11)} ${fmt(r.n).padStart(6)} ${r.cal.toFixed(2).padStart(6)}`);
}

const report = L.join('\n');
fs.writeFileSync(path.join(OUT, 'report.txt'), report + '\n');
fs.writeFileSync(path.join(OUT, 'summary.json'), JSON.stringify({
  window: winLabel, filesScanned, recordsScanned, sessions: sessions.size,
  fleet, byModel: Object.fromEntries(byModel),
  byTool: Object.fromEntries(byTool),
  byProject: Object.fromEntries([...byProject].map(([k, v]) => [k, { tok: v.tok, sessions: v.sessions.size, toolBytes: v.toolBytes }])),
  bigResults: bigResults.slice(0, 300),
  dupCalls: dupArr.slice(0, 300).map((d) => ({ n: d.n, bytes: d.bytes, tool: d.tool, what: d.what, sessions: d.sessions.size })),
  errors: errArr.slice(0, 200).map((e) => ({ count: e.count, bytes: e.bytes, tool: e.tool, sample: e.sample, sessions: e.sessions.size })),
  compactions, compactSessions: compactSessions.size,
  sessionsDetail: sessArr.slice(0, 200).map((S) => ({
    sessionId: S.sessionId, project: S.project, tok: S.tok, sidechainTok: S.sidechainTok,
    tMin: S.tMin === Infinity ? null : new Date(S.tMin).toISOString(),
    tMax: S.tMax === -Infinity ? null : new Date(S.tMax).toISOString(),
    assistantTurns: S.assistantTurns, toolCalls: S.toolCalls, toolBytes: S.toolBytes,
    dupBytes: S.dupBytes, errCalls: S.errCalls, errBytes: S.errBytes,
    compactions: S.compactions, models: [...S.models], costUSD: S.costUSD,
    ctx: S.ctx.filter((c) => !c.side).map((c) => c.ctx),
  })),
}, null, 1));

console.log(report);
console.error(`\n[wrote ${path.join(OUT, 'report.txt')} and summary.json]`);

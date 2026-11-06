const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const install = vm.runInNewContext(fs.readFileSync(__dirname + '/adapter.js', 'utf8'));
async function make() {
  let now = 100000, next = 0, interval, scheduled = [], listeners = [], status;
  let config = { schema: 1, enabled: true, targetMs: 500, leaseUntilMs: 108000 };
  const nativeCalls = [];
  const model = { namespace: 'async:lyric', reducers: {
    updateLyric: (s, a) => ({ ...s, ...a.payload.lyric, resourceTrackId: a.payload.resourceTrackId }),
    setDefaultLyric: s => ({ ...s, resourceTrackId: '', scrollable: false })
  }, effects: { setNativeLyric: () => (function* () {})() } };
  let root = { playing: { onlineResourceId: 'A', resourceTrackId: 'A', resourceName: 'Test A' },
    'async:lyric': { resourceTrackId: 'A', scrollable: true, currentUsedLyric: 'lrc', offset: 0,
      lyricLines: [{ time: 10, lyric: 'first' }, { time: undefined, lyric: 'metadata' }] } };
  const dispatch = action => {
    const name = action.type.split('/').pop();
    const reducer = model.reducers[name];
    if (reducer) root['async:lyric'] = reducer(root['async:lyric'], action);
    listeners.forEach(l => l());
  };
  const native = {
    Storage: { readFile: async () => JSON.stringify(config), writeFile: async value => { status = JSON.parse(value.content); } },
    LyricConfigType: { offset: 'offset' },
    AudioPlayer: { setLyricConfig: p => { nativeCalls.push(p.data.offset); return Promise.resolve(); } }
  };
  const tool = { getStore: () => root, getDispatch: () => dispatch,
    app: { _store: { subscribe: fn => { listeners.push(fn); return () => { listeners = listeners.filter(x => x !== fn); }; } } } };
  const env = { now: () => now, setTimeout: fn => { scheduled.push(fn); return ++next; }, clearTimeout: () => { scheduled = []; },
    setInterval: fn => { interval = fn; return 1; }, clearInterval: () => {} };
  install(model, native, tool, { config: '/config', status: '/status' }, env);
  const cleanup = model.subscriptions.lyricOffsetMenuBar();
  const settle = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };
  const flush = async () => { const tasks = scheduled; scheduled = []; tasks.forEach(f => f()); await settle(); };
  const ready = async () => { const generator = model.effects.setNativeLyric({}, {}); while (!generator.next().done) {} await flush(); };
  await settle();
  return { model, root, nativeCalls, dispatch, ready, flush, settle, cleanup,
    poll: async () => { await interval(); await settle(); }, status: () => status,
    configure: values => Object.assign(config, values), time: value => { now = value; },
    lyric: () => root['async:lyric'] };
}
(async () => {
  const h = await make();
  assert.equal(h.nativeCalls.length, 0, 'must wait for lyric-native completion');
  await h.ready();
  assert.deepEqual(h.nativeCalls, [500]);
  assert.equal(h.lyric().offset, 0.5);
  assert.equal(h.lyric().lyricLines[0].time, 9.5);
  assert.equal(h.lyric().lyricLines[1].time, undefined, 'metadata times stay untouched');
  await h.flush(); await h.poll();
  assert.equal(h.nativeCalls.length, 1, 'repeat polls cannot accumulate offset');
  h.configure({ targetMs: -500 }); await h.poll();
  assert.equal(h.lyric().offset, -0.5);
  assert.equal(h.lyric().lyricLines[0].time, 10.5);
  h.configure({ enabled: false, targetMs: 1000 }); await h.poll();
  assert.equal(h.lyric().offset, -0.5, 'disabled preserves existing offset');
  h.configure({ enabled: true }); h.time(109000); await h.poll();
  assert.equal(h.lyric().offset, -0.5, 'expired heartbeat cannot apply');
  h.time(100000); h.configure({ leaseUntilMs: 108000 }); await h.poll();
  assert.equal(h.lyric().offset, 1);
  h.root.playing.onlineResourceId = 'B'; h.root.playing.resourceTrackId = 'B';
  h.configure({ targetMs: 500 }); await h.poll();
  assert.equal(h.lyric().offset, 1, 'late A lyric cannot be applied to B');
  h.dispatch({ type: 'async:lyric/updateLyric', payload: { resourceTrackId: 'B',
    lyric: { scrollable: true, currentUsedLyric: 'yrc', offset: -1, lyricLines: [{ time: 11 }] } } });
  await h.flush(); assert.equal(h.lyric().offset, -1, 'new lyric waits for native load');
  await h.ready(); assert.equal(h.lyric().offset, 0.5);
  assert.equal(h.lyric().lyricLines[0].time, 9.5);
  h.configure({ targetMs: 10001 }); await h.poll();
  assert.equal(h.lyric().offset, 0.5, 'invalid config fails closed');
  assert.equal(h.status().enabled, false);
  h.cleanup();
  console.log('PASS: absolute offsets, idempotency, late lyrics, yrc model, disable, heartbeat, invalid config, metadata.');
})().catch(e => { console.error(e); process.exitCode = 1; });

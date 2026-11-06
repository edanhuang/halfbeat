const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const create = vm.runInNewContext(fs.readFileSync(__dirname + '/bridge.js', 'utf8'));
async function fixture(legacy = false) {
  let now = 100000, interval, scheduled = [], listeners = [], status, fail = false, deferNative;
  const config = { schema: 1, enabled: true, targetMs: 500, leaseUntilMs: 108000 };
  const nativeCalls = [];
  let root = { playing: { onlineResourceId: 'A', resourceTrackId: 'A', resourceName: 'Test A' },
    'async:lyric': { resourceTrackId: 'A', scrollable: true, currentUsedLyric: 'lrc', offset: 0,
      lyricLines: [{ time: 10, lyric: 'first' }] } };
  if (legacy) delete root["async:lyric"].resourceTrackId;
  const dispatch = action => {
    if (action.type === 'async:lyric/updateOffset') {
      const s = root['async:lyric'], delta = .5 * action.payload.gain;
      root['async:lyric'] = { ...s, offset: s.offset + delta, lyricLines: s.lyricLines.map(line => ({ ...line, time: line.time - delta })) };
    }
    listeners.forEach(l => l());
  };
  const native = {
    Storage: { readFile: async () => JSON.stringify(config), writeFile: async value => { status = JSON.parse(value.content); } },
    LyricConfigType: { offset: 'offset', lyric: 'lyric' },
    AudioPlayer: { setLyricConfig: function (p) {
      assert.equal(this, native.AudioPlayer, 'preserve native receiver');
      nativeCalls.push(p);
      if (fail) return Promise.reject(new Error('native failed'));
      if (deferNative) return deferNative;
      return Promise.resolve();
    } }
  };
  const original = native.AudioPlayer.setLyricConfig;
  const tool = { getStore: () => root, getDispatch: () => dispatch,
    app: { _store: { subscribe: fn => { listeners.push(fn); return () => { listeners = listeners.filter(x => x !== fn); }; } } } };
  const env = { now: () => now, setTimeout: fn => { scheduled.push(fn); return scheduled.length; }, clearTimeout: () => { scheduled = []; },
    setInterval: fn => { interval = fn; return 1; }, clearInterval: () => {} };
  const bridge = create(native, tool, { config: '/config', status: '/status' }, env);
  const settle = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); };
  await settle();
  return { root, native, nativeCalls, bridge, original, dispatch,
    flush: async () => { const tasks = scheduled; scheduled = []; tasks.forEach(f => f()); await settle(); }, settle,
    scheduledTimers: () => scheduled.length,
    poll: async () => { await interval(); await settle(); }, status: () => status,
    configure: values => Object.assign(config, values), time: value => { now = value; },
    failure: value => { fail = value; }, pending: value => { deferNative = value; },
    lyric: () => root['async:lyric'] };
}
(async () => {
  const h = await fixture();
  assert.equal(h.lyric().offset, .5); assert.equal(h.lyric().lyricLines[0].time, 9.5);
  assert.equal(h.status().state, 'aligned');
  await h.poll(); await h.flush(); assert.equal(h.nativeCalls.length, 1, 'idempotency');
  h.configure({ targetMs: -500 }); await h.poll();
  assert.equal(h.lyric().offset, -.5); assert.equal(h.lyric().lyricLines[0].time, 10.5);
  h.configure({ enabled: false, targetMs: 1000 }); await h.poll(); assert.equal(h.lyric().offset, -.5);
  h.configure({ enabled: true }); h.time(109000); await h.poll(); assert.equal(h.lyric().offset, -.5);
  h.time(100000); h.failure(true); await h.poll();
  assert.equal(h.lyric().offset, -.5, 'native failure cannot claim target in model');
  assert.equal(h.status().state, 'error');
  h.failure(false); h.time(101100); await h.poll(); assert.equal(h.lyric().offset, 1, 'retry applies target');
  h.root.playing.onlineResourceId = 'B'; h.root.playing.resourceTrackId = 'B';
  h.configure({ targetMs: 500 }); await h.poll(); assert.equal(h.lyric().offset, 1, 'old-song guard');
  h.root['async:lyric'] = { resourceTrackId: 'B', scrollable: true, currentUsedLyric: 'yrc', offset: -1, lyricLines: [{ time: 11 }] };
  let finish;
  h.pending(new Promise(resolve => { finish = resolve; }));
  const vendorCall = h.native.AudioPlayer.setLyricConfig({ type: 'lyric', data: {} });
  await h.poll(); assert.equal(h.lyric().offset, -1, 'wait for vendor native loading');
  h.pending(undefined); finish(); await vendorCall; await h.settle(); await h.flush();
  assert.equal(h.lyric().offset, .5); assert.equal(h.lyric().lyricLines[0].time, 9.5);
  const count = h.nativeCalls.length;
  await h.native.AudioPlayer.setLyricConfig({ type: 'offset', data: { offset: 0 } });
  await h.settle(); await h.flush();
  assert.equal(h.nativeCalls.length, count + 2, 'native reload at same model offset is reasserted');
  assert.equal(h.lyric().offset, .5, 'reassertion cannot shift frontend again');
  h.configure({ targetMs: 10001 }); await h.poll(); assert.equal(h.status().enabled, false);
  h.configure({ targetMs: 500 }); await h.poll(); assert.equal(h.status().state, 'aligned', 'configuration error clears after recovery');
  h.bridge.stop(); assert.equal(h.native.AudioPlayer.setLyricConfig, h.original, 'restore native method on disconnect');
  const race = await fixture();
  let resolveOwn;
  race.configure({ targetMs: 1000 });
  race.pending(new Promise(resolve => { resolveOwn = resolve; }));
  const own = race.poll(); await race.settle();
  race.pending(undefined);
  await race.native.AudioPlayer.setLyricConfig({ type: 'offset', data: { offset: 0 } });
  await race.settle(); resolveOwn(); await own; await race.flush(); await race.poll();
  assert.equal(race.lyric().offset, 1);
  assert.equal(race.nativeCalls.at(-1).data.offset, 1000, 'completed vendor call during own await requires correction');
  race.bridge.stop();
  // 页面被隐藏时浏览器会把页面计时器节流到分钟级：只允许 store 通知（微任务）驱动，也必须完成对齐。
  const hidden = await fixture();
  hidden.configure({ targetMs: -500 }); await hidden.poll();
  assert.equal(hidden.lyric().offset, -.5);
  hidden.root.playing.onlineResourceId = 'C'; hidden.root.playing.resourceTrackId = 'C';
  hidden.root['async:lyric'] = { resourceTrackId: 'C', isLoading: true, scrollable: false,
    currentUsedLyric: 'none', offset: 0, lyricLines: [] };
  hidden.dispatch({ type: 'song/switch' });
  await hidden.settle();
  assert.equal(hidden.status().state, 'waiting', 'hidden page must wait for the lyric, not skip the switch');
  hidden.root['async:lyric'] = { resourceTrackId: 'C', scrollable: true, currentUsedLyric: 'lrc', offset: 0,
    lyricLines: [{ time: 10, lyric: 'first' }] };
  hidden.dispatch({ type: 'lyric/ready' });
  await hidden.settle();
  assert.equal(hidden.lyric().offset, -.5, 'store notification alone must align while page timers are frozen');
  assert.equal(hidden.status().state, 'aligned');
  assert.equal(hidden.scheduledTimers(), 0, 'the event path must not depend on throttled page timers');
  // 完全没有 store 通知时，菜单栏每个心跳调用的 pump 也必须能对齐。
  hidden.root.playing.onlineResourceId = 'D'; hidden.root.playing.resourceTrackId = 'D';
  hidden.root['async:lyric'] = { resourceTrackId: 'D', scrollable: true, currentUsedLyric: 'lrc', offset: 0,
    lyricLines: [{ time: 12, lyric: 'second' }] };
  assert.equal(await hidden.bridge.pump(), 'aligned', 'app-driven pump must align without any store notification');
  assert.equal(hidden.lyric().offset, -.5);
  hidden.bridge.stop();
  const legacy = await fixture(true);
  assert.equal(legacy.lyric().offset, .5, 'legacy current lyrics align');
  legacy.root.playing.onlineResourceId = 'B'; legacy.root.playing.resourceTrackId = 'B';
  legacy.configure({ targetMs: 1000 });
  await legacy.poll();
  assert.equal(legacy.lyric().offset, .5, 'legacy old lyrics cannot follow a track change');
  legacy.root['async:lyric'] = { isLoading: false, scrollable: true, currentUsedLyric: 'lrc',
    offset: 0, lyricLines: [{ time: 20 }] };
  await legacy.poll();
  assert.equal(legacy.lyric().offset, 0, 'legacy new state waits for native lyrics');
  await legacy.native.AudioPlayer.setLyricConfig({ type: 'lyric', data: {} });
  await legacy.settle();
  assert.equal(legacy.lyric().offset, 1, 'legacy native lyric completion binds song');
  assert.equal(legacy.lyric().lyricLines[0].time, 19);
  await legacy.poll();
  assert.equal(legacy.lyric().offset, 1, 'legacy idempotency');
  let finishLegacy;
  legacy.root.playing.onlineResourceId = 'C'; legacy.root.playing.resourceTrackId = 'C';
  legacy.root['async:lyric'] = { isLoading: false, scrollable: true, currentUsedLyric: 'lrc',
    offset: 0, lyricLines: [{ time: 30 }] };
  legacy.pending(new Promise(resolve => { finishLegacy = resolve; }));
  const oldLoad = legacy.native.AudioPlayer.setLyricConfig({ type: 'lyric', data: {} });
  legacy.root.playing.onlineResourceId = 'D'; legacy.root.playing.resourceTrackId = 'D';
  await legacy.poll();
  legacy.pending(undefined); finishLegacy(); await oldLoad; await legacy.settle();
  assert.equal(legacy.lyric().offset, 0, 'legacy late native completion cannot bind to a new song');
  legacy.bridge.stop();
  console.log('PASS: absolute targets, idempotency, disable, lease expiry, native failure/retry, late song, yrc state, pending reload, native reassertion, invalid config, cleanup, frozen-timer event path, app-driven pump, legacy song binding and late completion.');
})().catch(e => { console.error(e); process.exitCode = 1; });

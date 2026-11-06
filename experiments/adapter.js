// Installed only into the supported lyric-model module. No network or audio access.
(function installLyricOffset(model, native, tool, paths, environment) {
  "use strict";
  const env = environment || { now: Date.now, setTimeout, clearTimeout, setInterval, clearInterval };
  const originalNative = model.effects.setNativeLyric;
  const originalUpdate = model.reducers.updateLyric;
  const originalClear = model.reducers.setDefaultLyric;
  let config = null, readySong = "", busy = false, reading = false, timer = null;
  let disposed = false, error = "", changes = 0, lastAppliedAt = 0;
  let generation = 0, pendingNative = 0, nativeDirty = false;
  const songOf = state => String(state && state.resourceTrackId || "");
  const get = () => tool.getStore();
  const active = () => config && config.enabled === true && config.leaseUntilMs > env.now();
  const validConfig = value => value && value.schema === 1 && typeof value.enabled === "boolean"
    && Number.isInteger(value.targetMs) && Math.abs(value.targetMs) <= 10000
    && Number.isFinite(value.leaseUntilMs) && value.leaseUntilMs <= env.now() + 60000;
  function snapshot() {
    const root = get(), lyric = root[model.namespace] || {}, playing = root.playing || {};
    const song = songOf(lyric);
    const playingSong = String(playing.onlineResourceId || playing.resourceTrackId || "");
    return { lyric, song, playingSong, name: playing.resourceName || "" };
  }
  function stateOf(s) {
    if (!active()) return "disabled";
    if (error) return "error";
    if (!s.song || !s.playingSong || s.song !== s.playingSong || readySong !== s.song) return "waiting";
    if (!s.lyric.scrollable || s.lyric.currentUsedLyric === "none") return "no-lyrics";
    if (!Number.isFinite(s.lyric.offset)) return "invalid-offset";
    return !nativeDirty && pendingNative === 0 && Math.abs(s.lyric.offset * 1000 - config.targetMs) < 0.01 ? "aligned" : "waiting";
  }
  async function publish() {
    if (disposed) return;
    try {
      const s = snapshot();
      await native.Storage.writeFile({ path: paths.status, isAbsolute: true, alone: true,
        content: JSON.stringify({ schema: 1, bridgeVersion: "1.0.0", updatedAtMs: env.now(),
          state: stateOf(s), enabled: !!active(), songId: s.song, playingSongId: s.playingSong,
          songName: s.name, currentMs: Number.isFinite(s.lyric.offset) ? Math.round(s.lyric.offset * 1000) : null,
          targetMs: config ? config.targetMs : null, changes, lastAppliedAtMs: lastAppliedAt, error }) });
    } catch (_) { /* Status failure must never interrupt playback. */ }
  }
  model.reducers.menuBarAbsoluteOffset = (state, action) => {
    const p = action.payload;
    if (songOf(state) !== p.song || state.offset !== p.expectedOffset || !state.scrollable) return state;
    const delta = p.targetMs / 1000 - state.offset;
    return Object.assign({}, state, { offset: p.targetMs / 1000,
      lyricLines: state.lyricLines.map(line => Object.assign({}, line,
        { time: Number.isFinite(line.time) ? line.time - delta : line.time })) });
  };
  model.reducers.updateLyric = (state, action) => { generation++; readySong = ""; return originalUpdate(state, action); };
  model.reducers.setDefaultLyric = (state, action) => { generation++; readySong = ""; return originalClear(state, action); };
  function schedule() {
    if (!disposed && timer === null) timer = env.setTimeout(() => {
      timer = null;
      reconcile().catch(e => { error = String(e); });
    }, 60);
  }
  async function reconcile() {
    if (busy || disposed || !active() || pendingNative > 0) return;
    const s = snapshot();
    if (!s.song || s.song !== s.playingSong || readySong !== s.song || !s.lyric.scrollable
      || s.lyric.currentUsedLyric === "none" || !Number.isFinite(s.lyric.offset)) return;
    if (!nativeDirty && Math.abs(s.lyric.offset * 1000 - config.targetMs) < 0.01) return;
    busy = true;
    const target = config.targetMs, version = generation;
    try {
      // Execute in one JS turn: no file/network await between checking song ID and applying.
      await native.AudioPlayer.setLyricConfig({ type: native.LyricConfigType.offset, data: { offset: target } });
      const current = snapshot();
      if (!disposed && active() && generation === version && current.song === s.song
        && current.playingSong === s.song && current.lyric.offset === s.lyric.offset && config.targetMs === target) {
        if (Math.abs(s.lyric.offset * 1000 - target) >= 0.01) {
          tool.getDispatch()({ type: model.namespace + "/menuBarAbsoluteOffset",
            payload: { song: s.song, expectedOffset: s.lyric.offset, targetMs: target } });
        }
        nativeDirty = pendingNative > 0;
        changes += 1; lastAppliedAt = env.now(); error = "";
      } else { nativeDirty = true; schedule(); }
    } catch (e) { nativeDirty = true; error = String(e); }
    finally { busy = false; await publish(); }
  }
  model.effects.setNativeLyric = function (action, helpers) {
    return (function* () {
      const initialSong = songOf(get()[model.namespace]), version = generation;
      pendingNative++; nativeDirty = true;
      try {
        yield* originalNative(action, helpers);
        if (generation === version && songOf(get()[model.namespace]) === initialSong) readySong = initialSong;
      } finally {
        pendingNative--; nativeDirty = true; schedule();
      }
    })();
  };
  async function poll() {
    if (reading || disposed) return;
    reading = true;
    try {
      const raw = await native.Storage.readFile({ path: paths.config, isAbsolute: true, alone: true });
      const parsed = JSON.parse(raw);
      if (!validConfig(parsed)) throw new Error("Invalid LyricOffset configuration");
      config = parsed;
      // Do not erase a native application error merely because config reading succeeded.
      await reconcile();
    } catch (e) { config = null; error = String(e); }
    finally { reading = false; await publish(); }
  }
  const previousSubscriptions = model.subscriptions || {};
  model.subscriptions = Object.assign({}, previousSubscriptions, {
    lyricOffsetMenuBar() {
      const unsubscribe = tool.app._store.subscribe(schedule);
      const interval = env.setInterval(poll, 1000);
      poll();
      return () => {
        disposed = true; unsubscribe(); env.clearInterval(interval);
        if (timer !== null) env.clearTimeout(timer);
      };
    }
  });
  return model;
})

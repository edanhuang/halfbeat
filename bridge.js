// 在已适配的网易云运行时内对齐歌词绝对偏移；只接管歌词配置和页面时间，保留原有音频播放流程。
// 不写回歌曲歌词缓存；停用后保留当前偏移，后续歌词重新加载时由原流程恢复其数据。
// 版本号与 RuntimeBridge.bridgeVersion 保持一致，菜单栏靠它判断是否需要替换已注入的实例。
(function createLyricOffsetBridge(native, tool, paths, environment) {
  "use strict";
  const env = environment || { now: () => Date.now(),
    setTimeout: (fn, ms) => globalThis.setTimeout(fn, ms), clearTimeout: id => globalThis.clearTimeout(id),
    setInterval: (fn, ms) => globalThis.setInterval(fn, ms), clearInterval: id => globalThis.clearInterval(id) };
  const namespace = "async:lyric";
  const originalSet = native.AudioPlayer.setLyricConfig;
  let config = null, busy = false, reading = false, disposed = false;
  let nativeDirty = true, pendingNative = 0, changes = 0, lastAppliedAt = 0, error = "", configError = "";
  let nativeGeneration = 0;
  let retryAfter = 0, failures = 0;
  let configReadAt = 0, pumpQueued = false;
  // 退出或崩溃后心跳失效即停止接管，不能仅凭磁盘上残留的 enabled=true 继续调整。
  const active = () => config && config.enabled === true && config.leaseUntilMs > env.now();
  function snapshot() {
    const root = tool.getStore(), lyric = root[namespace] || {}, playing = root.playing || {};
    return { lyric, song: String(lyric.resourceTrackId || ""),
      playingSong: String(playing.onlineResourceId || playing.resourceTrackId || ""),
      name: playing.resourceName || "" };
  }
  function canApply(s) {
    // 切歌与歌词加载异步完成，只处理当前播放歌曲已加载的可滚动歌词，跳过旧歌、纯音乐和无效偏移。
    return active() && s.song && s.song === s.playingSong && !s.lyric.isLoading
      && s.lyric.scrollable && s.lyric.currentUsedLyric !== "none" && Number.isFinite(s.lyric.offset);
  }
  // 只读自检：确认我们依赖的模块与状态形状还在。版本号只写进诊断，不参与是否接管的判断。
  function clientVersion() {
    const agent = typeof navigator !== "undefined" ? navigator.userAgent || "" : "";
    const match = /NeteaseMusicDesktop\/([\d.]+)/.exec(agent);
    return match ? match[1] : "";
  }
  function probe() {
    const checks = { store: false, subscribe: false, storage: false, setLyricConfig: false,
      lyricConfigType: false, lyricState: false, playing: false };
    try {
      const root = tool.getStore(), lyric = root && root[namespace], playing = root && root.playing;
      checks.store = typeof tool.getStore === "function" && typeof tool.getDispatch === "function";
      checks.subscribe = !!(tool.app && tool.app._store && typeof tool.app._store.subscribe === "function");
      checks.storage = !!(native.Storage && typeof native.Storage.readFile === "function"
        && typeof native.Storage.writeFile === "function");
      checks.setLyricConfig = !!(native.AudioPlayer && typeof native.AudioPlayer.setLyricConfig === "function");
      checks.lyricConfigType = !!(native.LyricConfigType && native.LyricConfigType.offset != null
        && native.LyricConfigType.lyric != null);
      checks.lyricState = !!lyric && typeof lyric.offset === "number" && "resourceTrackId" in lyric
        && "isLoading" in lyric && "scrollable" in lyric;
      checks.playing = !!playing && ("onlineResourceId" in playing || "resourceTrackId" in playing);
    } catch (e) {
      return { verdict: "incompatible", checks, version: "", error: String(e) };
    }
    const ok = Object.keys(checks).every(key => checks[key]);
    return { verdict: ok ? "ok" : "incompatible", checks, version: clientVersion() };
  }
  function statusOf(s) {
    if (!active()) return "disabled";
    if (error || configError) return "error";
    if (!s.song || s.song !== s.playingSong || s.lyric.isLoading) return "waiting";
    if (!s.lyric.scrollable || s.lyric.currentUsedLyric === "none") return "no-lyrics";
    if (!Number.isFinite(s.lyric.offset)) return "invalid-offset";
    return !nativeDirty && pendingNative === 0 && Math.abs(s.lyric.offset * 1000 - config.targetMs) < .01 ? "aligned" : "waiting";
  }
  async function publish() {
    if (disposed) return;
    try {
      const s = snapshot();
      await native.Storage.writeFile({ path: paths.status, isAbsolute: true, alone: true,
        content: JSON.stringify({ schema: 1, bridgeVersion: "2.1.0", updatedAtMs: env.now(),
          state: statusOf(s), enabled: !!active(), songId: s.song, playingSongId: s.playingSong,
          songName: s.name, currentMs: Number.isFinite(s.lyric.offset) ? Math.round(s.lyric.offset * 1000) : null,
          targetMs: config ? config.targetMs : null, changes, lastAppliedAtMs: lastAppliedAt, error: configError || error,
          probe: probe() }) });
    } catch (_) { /* Playback must not depend on status reporting. */ }
  }
  function acceptConfig(parsed) {
    if (!parsed || parsed.schema !== 1 || typeof parsed.enabled !== "boolean" || !Number.isInteger(parsed.targetMs)
      || Math.abs(parsed.targetMs) > 10000 || !Number.isFinite(parsed.leaseUntilMs)
      || parsed.leaseUntilMs > env.now() + 60000) throw new Error("Invalid LyricOffset configuration");
    config = parsed; configError = ""; configReadAt = env.now();
  }
  // 配置与 8 秒租约原本只靠 1 秒轮询续期，而页面被隐藏时该轮询会被浏览器节流到分钟级，
  // 因此事件路径必须自己按需重读，否则会拿着过期租约判定 active() 而整段不接管。
  async function loadConfig() {
    try {
      acceptConfig(JSON.parse(await native.Storage.readFile({ path: paths.config, isAbsolute: true, alone: true })));
    } catch (e) { config = null; configError = String(e); }
  }
  async function loadConfigIfStale(maxAgeMs) {
    if (env.now() - configReadAt > maxAgeMs) await loadConfig();
  }
  // store 通知和原生歌词加载完成都可能发生在页面被隐藏、页面计时器被节流的时候：
  // 用微任务合并同一轮通知后直接检查，不再经过会被节流的 setTimeout。
  function schedule() {
    if (disposed || pumpQueued) return;
    pumpQueued = true;
    Promise.resolve().then(async () => {
      pumpQueued = false;
      if (disposed) return;
      await loadConfigIfStale(500);
      await reconcile();
      await publish();
    }).catch(e => { error = String(e); });
  }
  async function reconcile() {
    if (busy || disposed || !active() || pendingNative > 0 || env.now() < retryAfter) return;
    const s = snapshot();
    if (!canApply(s)) return;
    const target = config.targetMs, generation = nativeGeneration;
    if (!nativeDirty && Math.abs(s.lyric.offset * 1000 - target) < .01) return;
    busy = true;
    try {
      // 原生接口使用毫秒，页面使用秒。先确认原生调用完成，再更新页面，失败时不得伪装成已对齐。
      await originalSet.call(native.AudioPlayer, { type: native.LyricConfigType.offset, data: { offset: target } });
      const current = snapshot();
      // 等待期间可能切歌、重载歌词或修改目标；版本号还能识别已开始又已结束的原生调用，防止漏掉重置。
      if (!disposed && canApply(current) && current.song === s.song && current.lyric === s.lyric
        && pendingNative === 0 && nativeGeneration === generation && config.targetMs === target) {
        // 复用原有每单位 0.5 秒的页面调整动作，只补齐差值，避免轮询或重复播放时累加偏移。
        const gain = (target / 1000 - s.lyric.offset) / .5;
        if (Math.abs(gain) > .000001) tool.getDispatch()({ type: namespace + "/updateOffset", payload: { gain } });
        nativeDirty = false; changes++; lastAppliedAt = env.now(); error = "";
        failures = 0; retryAfter = 0;
      } else { nativeDirty = true; schedule(); }
    } catch (e) {
      nativeDirty = true; error = String(e);
      // 保留页面原值并限速重试；原生失败不能阻断音乐播放，也不能触发高频调用。
      failures++; retryAfter = env.now() + Math.min(1000 * Math.pow(2, failures - 1), 15000);
    } finally { busy = false; await publish(); }
  }
  function observedSet(...args) {
    const type = args[0] && args[0].type;
    if (type !== native.LyricConfigType.lyric && type !== native.LyricConfigType.offset)
      return originalSet.apply(this, args);
    // 网易云自己的歌词加载或手动微调可能覆盖原生偏移；等待其完成后重新对齐，不打断原调用。
    nativeGeneration++; pendingNative++; nativeDirty = true;
    let result;
    try { result = originalSet.apply(this, args); }
    catch (e) { pendingNative--; nativeDirty = true; schedule(); throw e; }
    // 保持原方法接收者、返回值和异常语义，避免影响网易云后续歌词流程。
    Promise.resolve(result).then(() => {
      pendingNative--; nativeDirty = true; schedule();
    }, () => { pendingNative--; nativeDirty = true; schedule(); });
    return result;
  }
  async function poll() {
    if (disposed || reading) return;
    reading = true;
    try { await loadConfig(); await reconcile(); }
    finally { reading = false; await publish(); }
  }
  const interval = env.setInterval(poll, 1000);
  let unsubscribe;
  try { unsubscribe = tool.app._store.subscribe(schedule); native.AudioPlayer.setLyricConfig = observedSet; }
  catch (e) { env.clearInterval(interval); if (unsubscribe) unsubscribe(); throw e; }
  poll();
  return { version: "2.1.0",
    // 由菜单栏经本机调试通道驱动：页面计时器被浏览器冻结时，仍由 App 的心跳拉起一次检查。
    async pump() {
      if (disposed) return "disposed";
      await loadConfig(); await reconcile(); await publish();
      return statusOf(snapshot());
    },
    stop() {
      disposed = true; unsubscribe(); env.clearInterval(interval);
      // 仅撤销本实例仍持有的方法包装，不能覆盖在它之后安装的其他运行时适配。
      if (native.AudioPlayer.setLyricConfig === observedSet) native.AudioPlayer.setLyricConfig = originalSet;
    } };
})

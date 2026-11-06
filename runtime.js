// Only inspect modules already loaded by the player; never execute unknown factories.
(function resolvePlayerRuntime(require) {
  const tools = new Set(), natives = new Set();
  for (const id of Object.keys(require.c || {})) {
    const value = require.c[id].exports;
    const candidates = [value];
    if (value && (typeof value === 'object' || typeof value === 'function')) {
      for (const key of Object.keys(value)) {
        try { candidates.push(value[key]); } catch (_) { /* Ignore unavailable exports. */ }
      }
    }
    for (const item of candidates) {
      if (!item) continue;
      if (typeof item.getStore === 'function' && typeof item.getDispatch === 'function') tools.add(item);
      if (item.Storage && typeof item.Storage.readFile === 'function' && typeof item.Storage.writeFile === 'function'
        && item.AudioPlayer && typeof item.AudioPlayer.setLyricConfig === 'function'
        && item.LyricConfigType && item.LyricConfigType.offset != null && item.LyricConfigType.lyric != null) natives.add(item);
    }
  }
  if (tools.size !== 1 || natives.size !== 1) throw new Error('Unsupported player runtime: ambiguous or missing modules');
  const tool = [...tools][0], native = [...natives][0];
  if (!tool.inited || !tool.app || !tool.app._store || typeof tool.app._store.subscribe !== 'function')
    throw new Error('Player initializing');
  const root = tool.getStore(), state = root && root['async:lyric'];
  if (!state) throw new Error('Player initializing');
  if (!Number.isFinite(state.offset) || typeof state.isLoading !== 'boolean' || typeof state.scrollable !== 'boolean'
    || !Array.isArray(state.lyricLines) || !root.playing) throw new Error('Unsupported lyric state');
  return { tool, native };
})

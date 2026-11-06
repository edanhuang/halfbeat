const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const resolve = vm.runInNewContext(fs.readFileSync(__dirname + '/runtime.js', 'utf8'));
function fixture(id) {
  const tool = { inited: true, app: { _store: { subscribe() {} } }, getDispatch() {},
    getStore: () => ({ playing: {}, 'async:lyric': { offset: 0, isLoading: false, scrollable: true, lyricLines: [] } }) };
  const native = { Storage: { readFile() {}, writeFile() {} }, AudioPlayer: { setLyricConfig() {} },
    LyricConfigType: { offset: 'offset', lyric: 'lyric' } };
  const require = () => { throw new Error('must not execute modules'); };
  require.c = { [id]: { exports: { a: tool } }, 4: { exports: native }, 99: { exports: { a: tool } } };
  return { require, tool, native };
}
for (const id of [8, 11, 42]) {
  const h = fixture(id), result = resolve(h.require);
  assert.equal(result.tool, h.tool); assert.equal(result.native, h.native);
  h.tool.inited = false;
  assert.throws(() => resolve(h.require), /Player initializing/);
}
const h = fixture(11);
h.require.c[100] = { exports: { ...h.tool } };
assert.throws(() => resolve(h.require), /ambiguous/);
console.log('PASS: module renumbering, duplicate re-exports, initializing, ambiguity; no unknown factory execution.');

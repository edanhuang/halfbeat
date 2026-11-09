#!/bin/zsh
set -eu
cd "${0:A:h:h}"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/halfbeat-name-tests.XXXXXX")
TEST_APP="$TEST_ROOT/Halfbeat.app"
# 只运行替换了入口的临时测试包：不启动真实 App，不接管网易云，也不改系统或用户语言偏好。
ditto "$PWD/dist/Halfbeat.app" "$TEST_APP"
xcrun swiftc AppIdentity.swift tests/BundleNameTests.swift -o "$TEST_ROOT/BundleNameTests"
cp "$TEST_ROOT/BundleNameTests" "$TEST_APP/Contents/MacOS/Halfbeat"
codesign --force --sign - "$TEST_APP"
"$TEST_APP/Contents/MacOS/Halfbeat" "$TEST_APP" Halfbeat -AppleLanguages '(en-CN, zh-Hans-CN)'
"$TEST_APP/Contents/MacOS/Halfbeat" "$TEST_APP" 歌词对齐 -AppleLanguages '(zh-Hans-CN, en-CN)'
"$TEST_APP/Contents/MacOS/Halfbeat" "$TEST_APP" Halfbeat -AppleLanguages '(fr-FR)'
python3 - "$TEST_ROOT" <<'PY'
import pathlib, shutil, sys
root = pathlib.Path(sys.argv[1])
if not root.name.startswith('halfbeat-name-tests.'):
    raise SystemExit('Unexpected temporary test path')
shutil.rmtree(root)
PY

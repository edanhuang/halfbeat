#!/usr/bin/env python3
"""Version-checked, backed-up patch of the user's web cache, never the signed app."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent
STATE = Path.home() / 'Library/Application Support/LyricOffsetMenubar'
ARCHIVE = Path.home() / 'Library/Application Support/com.netease.163music/Documents/webfiles.zip'
PACKAGE = ARCHIVE.parent / 'storage/Package/package.pack'
ENTRY = 'webfiles/hybrid/200.chunk.fb61360.js'
MANIFEST = STATE / 'patch-manifest.json'
MARK = '__lyricOffsetMenuBarV1'
SUPPORTED_MODULE_SHA256 = '7941f1fcf390f75c7430b4a4305f05bf9c81d36085737efd43912deb5dbe50ab'

def find_entry(archive):
    matches = [name for name in archive.namelist() if name.startswith('webfiles/hybrid/200.chunk.') and name.endswith('.js')]
    if len(matches) != 1: raise RuntimeError('无法定位受支持的歌词模块')
    return matches[0]

def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()

def atomic_json(path, value):
    fd, name = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as out:
            json.dump(value, out, ensure_ascii=False, indent=2)
        os.replace(name, path)
    finally:
        if os.path.exists(name): os.unlink(name)

def patched_source(source, adapter, paths):
    if MARK in source: raise RuntimeError('该资源已安装适配，请先恢复后再安装')
    if hashlib.sha256(source.split('//# sourceMappingURL=')[0].encode()).hexdigest() != SUPPORTED_MODULE_SHA256:
        raise RuntimeError('该版本的歌词模块尚未适配，未做任何修改')
    anchor = '}.call(this,r(184))'
    required = ['changeLyricOffset(e,t)', 'setNativeLyric(e,t)', 'subscriptions:{}', 'const m="async:lyric"']
    if source.count(anchor) != 1 or any(x not in source for x in required):
        raise RuntimeError('网易云资源结构不受支持，未做任何修改')
    addition = (';const ' + MARK + '=t.default;t.default=async()=>('
        + adapter.strip() + ')(await ' + MARK + '(),i,r(8).a,' + json.dumps(paths, ensure_ascii=False) + ');')
    return source.replace(anchor, addition + anchor)

def inspect():
    data = {'archive': str(ARCHIVE), 'installed': False}
    if ARCHIVE.exists():
        with zipfile.ZipFile(ARCHIVE) as z:
            data['installed'] = MARK in z.read(find_entry(z)).decode()
    if MANIFEST.exists(): data['manifest'] = json.loads(MANIFEST.read_text())
    print(json.dumps(data, ensure_ascii=False, indent=2))

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('operation', choices=['install', 'restore', 'status'])
    args = parser.parse_args()
    if args.operation == 'status': return inspect()
    if subprocess.run(['pgrep', '-x', 'NeteaseMusic'], stdout=subprocess.DEVNULL).returncode == 0:
        raise RuntimeError('请先退出网易云音乐，再安装或恢复适配')
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(STATE, 0o700)
    if args.operation == 'restore':
        manifest = json.loads(MANIFEST.read_text())
        if digest(ARCHIVE) != manifest['patchedSha256']:
            raise RuntimeError('当前资源已变化（可能客户端已更新），拒绝覆盖；原备份仍保留')
        backup = Path(manifest['backup'])
        if digest(backup) != manifest['originalSha256']: raise RuntimeError('原始备份校验失败')
        if 'packageBackup' in manifest:
            if digest(PACKAGE) != manifest['packagePatchedSha256']:
                raise RuntimeError('当前缓存包已更新，拒绝覆盖；原备份仍保留')
            if digest(Path(manifest['packageBackup'])) != manifest['packageOriginalSha256']:
                raise RuntimeError('原始缓存包备份校验失败')
            replace_copy(Path(manifest['packageBackup']), PACKAGE)
        replace_copy(backup, ARCHIVE)
        manifest['restored'] = True
        atomic_json(MANIFEST, manifest)
        print('已恢复原始网易云资源；歌曲已有偏移保持不变。')
        return
    before = digest(ARCHIVE)
    package_bytes = PACKAGE.read_bytes()
    archive_bytes = ARCHIVE.read_bytes()
    # This client rebuilds webfiles.zip from its local package at every launch.
    # Only accept the observed package layout. Never edit the signed application.
    if package_bytes[:4] != b'0003' or package_bytes[100:] != archive_bytes:
        raise RuntimeError('缓存包格式或资源内容不匹配，未做任何修改')
    adapter = (ROOT / 'adapter.js').read_text()
    with zipfile.ZipFile(ARCHIVE) as z:
        entry_name = find_entry(z)
        source = z.read(entry_name).decode()
        if MARK in source:
            if MANIFEST.exists() and digest(ARCHIVE) == json.loads(MANIFEST.read_text())['patchedSha256']:
                print('适配已安装，无需重复安装。'); return
            raise RuntimeError('检测到来源不明的已有适配，未覆盖')
        patched = patched_source(source, adapter, {'config': str(STATE / 'config.json'), 'status': str(STATE / 'status.json')})
        backup = STATE / ('webfiles-original-' + before[:16] + '.zip')
        if backup.exists():
            if digest(backup) != before: raise RuntimeError('已有备份校验失败')
        else:
            # Exclusive creation so an existing backup can never be overwritten.
            with backup.open('xb') as out, ARCHIVE.open('rb') as original:
                import shutil
                shutil.copyfileobj(original, out)
            os.chmod(backup, 0o600)
        fd, name = tempfile.mkstemp(prefix='.lyricoffset-', suffix='.zip', dir=ARCHIVE.parent)
        os.close(fd)
        temp = Path(name)
        try:
            with zipfile.ZipFile(temp, 'w') as out:
                for entry in z.infolist():
                    out.writestr(entry, patched.encode() if entry.filename == entry_name else z.read(entry.filename))
            with zipfile.ZipFile(temp) as check:
                if check.testzip() is not None: raise RuntimeError('新资源压缩包校验失败')
            after = digest(temp)
            package_before = digest(PACKAGE)
            package_backup = STATE / ('package-original-' + package_before[:16] + '.pack')
            if not package_backup.exists():
                with package_backup.open('xb') as out: out.write(package_bytes)
                os.chmod(package_backup, 0o600)
            elif digest(package_backup) != package_before: raise RuntimeError('原始缓存包备份校验失败')
            new_package = package_bytes[:100] + temp.read_bytes()
            package_after = hashlib.sha256(new_package).hexdigest()
            atomic_json(MANIFEST, {'schema': 1, 'entry': entry_name, 'backup': str(backup),
                'originalSha256': before, 'patchedSha256': after, 'restored': False,
                'packageBackup': str(package_backup), 'packageOriginalSha256': package_before,
                'packagePatchedSha256': package_after})
            fd2, name2 = tempfile.mkstemp(dir=PACKAGE.parent)
            try:
                with os.fdopen(fd2, 'wb') as out: out.write(new_package)
                os.chmod(name2, PACKAGE.stat().st_mode & 0o777)
                os.replace(name2, PACKAGE)
            finally:
                if os.path.exists(name2): os.unlink(name2)
            os.chmod(temp, ARCHIVE.stat().st_mode & 0o777)
            os.replace(temp, ARCHIVE)
        finally:
            temp.unlink(missing_ok=True)
    print('适配已安装，原始资源已校验备份；重新打开网易云音乐后生效。')

def replace_copy(source, destination):
    import shutil
    fd, name = tempfile.mkstemp(dir=destination.parent)
    os.close(fd)
    try:
        shutil.copyfile(source, name)
        os.chmod(name, destination.stat().st_mode & 0o777)
        os.replace(name, destination)
    finally:
        if os.path.exists(name): os.unlink(name)

if __name__ == '__main__':
    try: main()
    except Exception as e:
        print(str(e), file=__import__('sys').stderr)
        raise SystemExit(1)

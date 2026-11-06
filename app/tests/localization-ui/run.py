"""Run localization checks through LaunchServices in a normal macOS desktop session."""
from pathlib import Path
import json, os, plistlib, subprocess, sys, time, uuid

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'checks/i18n'
RESULT = OUT / 'validation.json'

def desktop():
    env = dict(os.environ, HARBOR_TEST_PREFERENCES_DOMAIN='local.harbor.localization-test.' + uuid.uuid4().hex,
               GHOSTTY_RESOURCES_DIR=str(ROOT / 'vendor/ghostty/zig-out/share/ghostty'))
    env.pop('HARBOR_LANGUAGE', None)
    unit = str(OUT / 'unit/localization-test')
    tests = [('unit', [unit], {}), ('set', [unit, '--set-chinese'], {}),
             ('persist', [unit, '--check-persisted'], {}), ('reset', [unit, '--reset'], {})]
    for name, language, expected in [('zh', 'zh-Hans', 'zh-Hans'), ('en', 'en-US', 'en'), ('other', 'ja-JP', 'en')]:
        tests.append(('system-' + name, [unit, '-AppleLanguages', '(' + language + ')', '--expect-language', expected], {}))
    for language in ['en', 'zh-Hans']:
        tests.append(('ui-' + language, [str(OUT / 'native/native-test')],
                      {'HARBOR_LANGUAGE': language, 'HARBOR_I18N_OUTPUT': str(OUT / ('ui-' + language))}))
        tests.append(('automation-' + language, [str(ROOT / 'checks/automation-native/native-test')],
                      {'HARBOR_LANGUAGE': language}))
        tests.append(('selftest-' + language, [str(ROOT / 'dist/Harbor.app/Contents/MacOS/Harbor'), '--self-test'],
                      {'HARBOR_LANGUAGE': language}))
    results = {}
    try:
        for name, args, overrides in tests:
            log_path = OUT / ('final-' + name + '.log')
            with log_path.open('w') as log:
                try:
                    code = subprocess.run(args, cwd=ROOT, env=dict(env, **overrides), stdout=log,
                                          stderr=subprocess.STDOUT, timeout=60).returncode
                except subprocess.TimeoutExpired:
                    code = 124
            results[name] = {'exit': code, 'log': str(log_path.relative_to(ROOT))}
            RESULT.write_text(json.dumps({'complete': False, 'tests': results}, indent=2) + '\n')
    finally:
        subprocess.run([unit, '--reset'], env=env, stdout=subprocess.DEVNULL, timeout=10)
    RESULT.write_text(json.dumps({'complete': True, 'tests': results}, indent=2) + '\n')
    return int(any(v['exit'] for v in results.values()))

def launch():
    OUT.mkdir(parents=True, exist_ok=True)
    RESULT.unlink(missing_ok=True)
    bundle = OUT / 'Localization Checks.app'
    macos = bundle / 'Contents/MacOS'
    macos.mkdir(parents=True, exist_ok=True)
    # shlex protects repository paths containing whitespace or shell metacharacters.
    import shlex
    executable = macos / 'run'
    executable.write_text('#!/bin/sh\nexec /usr/bin/python3 ' + shlex.quote(str(Path(__file__).resolve())) + ' --desktop\n')
    executable.chmod(0o755)
    with (bundle / 'Contents/Info.plist').open('wb') as stream:
        plistlib.dump(dict(CFBundleExecutable='run', CFBundleIdentifier='local.harbor.localization-checks',
                          CFBundleName='Localization Checks', CFBundlePackageType='APPL',
                          CFBundleDevelopmentRegion='en', CFBundleLocalizations=['en', 'zh-Hans']), stream)
    subprocess.run(['open', '-n', str(bundle)], check=True)
    deadline = time.monotonic() + 240
    while time.monotonic() < deadline:
        try:
            result = json.loads(RESULT.read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            result = {}
        if result.get('complete'):
            print(json.dumps(result, indent=2))
            return int(any(v['exit'] for v in result['tests'].values()))
        time.sleep(0.5)
    raise SystemExit('Desktop checks timed out; inspect checks/i18n/final-*.log')

if __name__ == '__main__':
    sys.exit(desktop() if '--desktop' in sys.argv else launch())

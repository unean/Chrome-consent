#!/usr/bin/env python3
"""Transactional installer for the ChromeConsent authorization branch."""
import argparse
import copy
import json
import os
import pathlib
import plistlib
import pwd
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import fcntl
import contextlib

SUPPORT = pathlib.Path('/Library/Application Support/ChromeConsent')
APP = pathlib.Path('/Applications/Chrome Consent.app')
PLUGIN = pathlib.Path('/Library/Security/SecurityAgentPlugins/ChromeConsentAuthorizationPlugin.bundle')
RIGHT = 'local.chromeconsent.unlock'
PARENT = 'system.login.screensaver'
SKIP_COMPARE = {'created', 'modified', 'version', 'identifier', 'requirement'}
CALLER_PID = None


def command(args, data=None):
    p = subprocess.run(args, input=data, capture_output=True, timeout=30)
    if p.returncode:
        raise RuntimeError(p.stderr.decode(errors='replace').strip() or 'Command failed: ' + ' '.join(args))
    return p.stdout


def read_rule(name):
    return plistlib.loads(command(['/usr/bin/security', 'authorizationdb', 'read', name]))


def semantic(rule):
    return {key: value for key, value in rule.items() if key not in SKIP_COMPARE}


def add_branch(rule):
    result = copy.deepcopy(rule)
    if result.get('class') != 'rule' or result.get('k-of-n') != 1:
        raise ValueError('Unsupported screensaver rule; no changes made.')
    branches = result.get('rule')
    if not isinstance(branches, list) or not branches or not all(isinstance(x, str) for x in branches):
        raise ValueError('Unsupported screensaver branches.')
    if RIGHT not in branches:
        result['rule'] = [RIGHT] + branches
    return result


def remove_branch(rule):
    if RIGHT not in rule.get('rule', []):
        return copy.deepcopy(rule)
    result = copy.deepcopy(rule)
    if result.get('class') != 'rule' or result.get('k-of-n') != 1:
        raise ValueError('Screensaver rule was restructured. Refusing destructive restoration.')
    result['rule'] = [x for x in result['rule'] if x != RIGHT]
    if not result['rule']:
        raise ValueError('No fallback branch remains. Refusing removal.')
    return result


def write_rule(name, value):
    command(['/usr/bin/security', 'authorizationdb', 'write', name], plistlib.dumps(value))
    observed = read_rule(name)
    for key, expected in semantic(value).items():
        if observed.get(key) != expected:
            raise RuntimeError('Authorization rule verification failed: ' + name + ' / ' + key)


def atomic_plist(path, value):
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix='.state-')
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(plistlib.dumps(value)); stream.flush(); os.fsync(stream.fileno())
        os.chmod(tmp, 0o644); os.chown(tmp, 0, 0)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)


def ensure_idle_unlocked():
    root = plistlib.loads(command(['/usr/sbin/ioreg', '-n', 'Root', '-d', '1', '-a']))
    if isinstance(root, list): root = root[0]
    if root.get('IOConsoleLocked') is not False:
        raise RuntimeError('Installation changes require an unlocked desktop.')
    processes = command(['/bin/ps', '-axo', 'pid=,command=']).decode(errors='replace').splitlines()
    binary = str(APP / 'Contents/MacOS/ChromeConsent')
    for line in processes:
        fields = line.strip().split(None, 1)
        if len(fields) != 2 or not fields[0].isdigit(): continue
        pid, process = int(fields[0]), fields[1]
        if process == binary or process.startswith(binary + ' '):
            if '--permission-probe' in process: continue
            if pid == CALLER_PID and not any(x in process for x in ['--guardian ', '--watchdog ']): continue
            raise RuntimeError('Chrome Consent is still running. Wait for it to exit before changing installation.')


@contextlib.contextmanager
def transaction_lock():
    path = pathlib.Path('/Library/Application Support/.ChromeConsent.install.lock')
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or st.st_mode & 0o022:
            raise ValueError('Invalid installer lock ownership.')
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(fd)


def trusted_metadata(path, directory=False):
    st = path.lstat()
    valid_type = stat.S_ISDIR(st.st_mode) if directory else stat.S_ISREG(st.st_mode)
    if not valid_type or st.st_uid != 0 or st.st_mode & 0o022:
        raise ValueError('System components have invalid ownership or type: ' + str(path))


def upgrade(source, uid, dry_run):
    source = source.resolve(strict=True)
    new_hash = verify_bundle(source)
    trusted_metadata(SUPPORT, directory=True)
    trusted_metadata(PLUGIN, directory=True)
    paths = [SUPPORT / name for name in ['config.plist', 'installed.plist', 'installer.py', 'screensaver-before.plist']]
    for path in paths: trusted_metadata(path)
    original = {path.name: path.read_bytes() for path in paths}
    cfg = plistlib.loads(original['config.plist'])
    installed = plistlib.loads(original['installed.plist'])
    previous_app = existing_application()
    if not previous_app or cfg.get('appCDHash') != previous_app['cdhash'] or installed.get('appCDHash') != previous_app['cdhash']:
        raise ValueError('Installed application does not match its component configuration.')
    if not cfg.get('enabled') or cfg.get('ownerUID') != uid or installed.get('ownerUID') != uid:
        raise ValueError('System components require recovery or belong to another user.')
    current = read_rule(PARENT)
    add_branch(current)
    remove_branch(current)
    own_rule = read_rule(RIGHT) if RIGHT in current['rule'] else {}
    if own_rule.get('class') != 'evaluate-mechanisms' or own_rule.get('mechanisms') != ['ChromeConsentAuthorizationPlugin:allow']:
        raise ValueError('Installed authorization configuration is incomplete.')
    if dry_run:
        print(json.dumps({'operation': 'update', 'source': str(source), 'application': str(APP),
                          'previousCDHash': previous_app['cdhash'], 'appCDHash': new_hash,
                          'preservesOtherBranches': True, 'preservesUserData': True}, indent=2)); return
    if os.geteuid() != 0: raise PermissionError('Administrator authorization is required.')
    ensure_idle_unlocked()
    stage = pathlib.Path(tempfile.mkdtemp(prefix='update-', dir=SUPPORT))
    old_app = old_plugin = None
    new_app = new_plugin = disabled = False
    try:
        staged = stage / 'Chrome Consent.app'
        shutil.copytree(source, staged, symlinks=True); owned_tree(staged)
        if verify_bundle(staged) != new_hash: raise RuntimeError('Staged application identity changed.')
        staged_plugin = stage / 'plugin.bundle'
        shutil.copytree(staged / 'Contents/Resources/ChromeConsentAuthorizationPlugin.bundle', staged_plugin)
        owned_tree(staged_plugin)
        command(['/usr/bin/codesign', '--verify', '--strict', str(staged_plugin)])
        for name, data in original.items():
            (stage / name).write_bytes(data); os.chmod(stage / name, 0o600)
        if existing_application() != previous_app or semantic(read_rule(PARENT)) != semantic(current):
            raise RuntimeError('Installation state changed during update.')
        if any((SUPPORT / name).read_bytes() != data for name, data in original.items()):
            raise RuntimeError('Component configuration changed during update.')
        ensure_idle_unlocked()
        disabled_cfg = dict(cfg, enabled=False)
        disabled = True; atomic_plist(SUPPORT / 'config.plist', disabled_cfg)
        os.rename(APP, stage / 'previous-app.app'); old_app = stage / 'previous-app.app'
        os.rename(PLUGIN, stage / 'previous-plugin.bundle'); old_plugin = stage / 'previous-plugin.bundle'
        os.rename(staged, APP); new_app = True
        os.rename(staged_plugin, PLUGIN); new_plugin = True
        shutil.copy2(APP / 'Contents/Resources/installer.py', SUPPORT / 'installer.py')
        os.chown(SUPPORT / 'installer.py', 0, 0); os.chmod(SUPPORT / 'installer.py', 0o644)
        if verify_bundle(APP) != new_hash: raise RuntimeError('Updated application failed verification.')
        atomic_plist(SUPPORT / 'installed.plist', dict(installed, appCDHash=new_hash, installed=True))
        atomic_plist(SUPPORT / 'config.plist', dict(cfg, appCDHash=new_hash, enabled=True))
    except Exception as error:
        try:
            if disabled:
                atomic_plist(SUPPORT / 'config.plist', dict(cfg, enabled=False))
                if new_plugin: shutil.rmtree(PLUGIN)
                if new_app: shutil.rmtree(APP)
                if old_plugin: os.rename(old_plugin, PLUGIN)
                if old_app: os.rename(old_app, APP)
                shutil.copy2(stage / 'installer.py', SUPPORT / 'installer.py')
                os.chown(SUPPORT / 'installer.py', 0, 0); os.chmod(SUPPORT / 'installer.py', 0o644)
                atomic_plist(SUPPORT / 'installed.plist', installed)
                atomic_plist(SUPPORT / 'config.plist', cfg)
            shutil.rmtree(stage)
        except Exception as rollback_error:
            raise RuntimeError(f'{error}; rollback incomplete: {rollback_error}. Recovery data retained at {stage}.') from error
        raise RuntimeError(f'{error}; update rolled back. Previous application and components restored.') from error
    try: shutil.rmtree(stage)
    except OSError as error: print('Updated; backup cleanup deferred: ' + str(error), file=sys.stderr)
    print('Updated application and components. User settings and authorization branches preserved.')


def owned_tree(path):
    for root, dirs, files in os.walk(path, followlinks=False):
        for entry in [pathlib.Path(root)] + [pathlib.Path(root) / f for f in files + dirs]:
            if entry.is_symlink():
                raise ValueError('Symlinks are not permitted in this package: ' + str(entry))
            st = entry.stat()
            if not stat.S_ISREG(st.st_mode) and not stat.S_ISDIR(st.st_mode):
                raise ValueError('Special files are not permitted: ' + str(entry))
            os.chown(entry, 0, 0)
            os.chmod(entry, 0o755 if entry.is_dir() or st.st_mode & 0o111 else 0o644)


def verify_bundle(path):
    command(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(path)])
    p = subprocess.run(['/usr/bin/codesign', '-dvvvv', str(path)], capture_output=True, timeout=10)
    match = re.search(rb'^CDHash=([0-9a-f]{40})$', p.stderr, re.M)
    if not match: raise RuntimeError('Unable to read signed application CDHash')
    info = plistlib.loads((path / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'local.chromeconsent.app':
        raise ValueError('Unexpected application identifier')
    return match.group(1).decode()


def existing_application():
    if APP.is_symlink():
        raise ValueError('The application destination must not be a symlink.')
    if not APP.exists():
        return None
    if not APP.is_dir():
        raise ValueError('The application destination is not an application bundle.')
    st = APP.stat()
    return {'device': st.st_dev, 'inode': st.st_ino, 'cdhash': verify_bundle(APP)}


def install(source, uid, dry_run):
    source = source.resolve(strict=True)
    app_hash = verify_bundle(source)
    current = read_rule(PARENT)
    target = add_branch(current)
    account = pwd.getpwuid(uid)
    if uid < 501: raise ValueError('A non-system console account is required.')
    if PLUGIN.exists() or PLUGIN.is_symlink() or SUPPORT.exists() or SUPPORT.is_symlink():
        if not (SUPPORT / 'installed.plist').is_file():
            raise ValueError('System components require recovery before updating.')
        return upgrade(source, uid, dry_run)
    previous_app = existing_application()
    exists = subprocess.run(['/usr/bin/security', 'authorizationdb', 'read', RIGHT], capture_output=True, timeout=10)
    if exists.returncode == 0 or RIGHT in current.get('rule', []):
        raise ValueError('Authorization branch already exists; no changes made.')
    plan = {'operation': 'install', 'ownerUID': uid, 'application': str(APP), 'plugin': str(PLUGIN),
            'support': str(SUPPORT), 'appCDHash': app_hash,
            'source': str(source), 'sourceIsDestination': source == APP.resolve(),
            'applicationAction': 'replace-unmanaged-copy' if previous_app else 'copy-new',
            'restorePreviousAppOnFailure': previous_app is not None,
            'existingBranches': current['rule'], 'newBranches': target['rule']}
    if dry_run:
        print(json.dumps(plan, ensure_ascii=False, indent=2)); return
    if os.geteuid() != 0: raise PermissionError('Administrator authorization is required.')
    ensure_idle_unlocked()
    stage = backup_app = None
    created_support = False
    copied_app = copied_plugin = parent_changed = right_created = False
    try:
        SUPPORT.mkdir(mode=0o755); created_support = True
        os.chown(SUPPORT, 0, 0)
        atomic_plist(SUPPORT / 'screensaver-before.plist', current)
        shutil.copy2(source / 'Contents/Resources/installer.py', SUPPORT / 'installer.py')
        os.chown(SUPPORT / 'installer.py', 0, 0)
        stage = pathlib.Path(tempfile.mkdtemp(prefix='stage-', dir=SUPPORT))
        staged_app = stage / 'Chrome Consent.app'
        shutil.copytree(source, staged_app, symlinks=True)
        owned_tree(staged_app)
        if verify_bundle(staged_app) != app_hash:
            raise RuntimeError('Staged application identity changed')
        staged_plugin = staged_app / 'Contents/Resources/ChromeConsentAuthorizationPlugin.bundle'
        command(['/usr/bin/codesign', '--verify', '--strict', str(staged_plugin)])
        APP.parent.mkdir(exist_ok=True)
        if existing_application() != previous_app:
            raise RuntimeError('Application destination changed during install; refusing to overwrite it.')
        if previous_app:
            # Keep the original bundle and metadata intact until the transaction commits.
            backup = stage / 'previous-app.app'
            os.rename(APP, backup); backup_app = backup
        os.rename(staged_app, APP); copied_app = True
        if PLUGIN.exists() or PLUGIN.is_symlink():
            raise RuntimeError('Plugin destination appeared during install; refusing to overwrite it.')
        copied_plugin = True
        shutil.copytree(APP / 'Contents/Resources/ChromeConsentAuthorizationPlugin.bundle', PLUGIN)
        owned_tree(PLUGIN)
        runtime = SUPPORT / 'Runtime'
        runtime.mkdir(mode=0o755); os.chown(runtime, 0, 0)
        user_runtime = runtime / str(uid)
        user_runtime.mkdir(mode=0o711); os.chown(user_runtime, uid, account.pw_gid)
        cfg = {'enabled': False, 'ownerUID': uid, 'appCDHash': app_hash, 'version': 1}
        atomic_plist(SUPPORT / 'config.plist', cfg)
        recovery = APP / 'Contents/Resources/installer.py'
        shutil.copy2(recovery, SUPPORT / 'installer.py'); os.chown(SUPPORT / 'installer.py', 0, 0)
        own_rule = {'class': 'evaluate-mechanisms', 'mechanisms': ['ChromeConsentAuthorizationPlugin:allow'],
                    'shared': False, 'tries': 1, 'comment': 'Short-lived, one-use ChromeConsent session authorization.'}
        right_created = True
        write_rule(RIGHT, own_rule)
        # Re-read immediately before editing to preserve concurrent administrators' changes.
        if semantic(read_rule(PARENT)) != semantic(current):
            raise RuntimeError('Screensaver authorization changed during install; refusing to overwrite it.')
        cfg['enabled'] = True; atomic_plist(SUPPORT / 'config.plist', cfg)
        parent_changed = True
        write_rule(PARENT, target)
        atomic_plist(SUPPORT / 'installed.plist', {'appCDHash': app_hash, 'ownerUID': uid, 'installed': True})
    except Exception as error:
        try:
            cfg_path = SUPPORT / 'config.plist'
            if created_support and cfg_path.exists():
                cfg = plistlib.loads(cfg_path.read_bytes()); cfg['enabled'] = False; atomic_plist(cfg_path, cfg)
            if parent_changed:
                write_rule(PARENT, remove_branch(read_rule(PARENT)))
            if right_created:
                removed = subprocess.run(['/usr/bin/security', 'authorizationdb', 'remove', RIGHT], capture_output=True, timeout=10)
                if removed.returncode:
                    raise RuntimeError('Could not remove the new authorization branch.')
            if copied_plugin and PLUGIN.exists(): shutil.rmtree(PLUGIN)
            if copied_app: shutil.rmtree(APP)
            if backup_app is not None:
                if APP.exists() or APP.is_symlink():
                    raise RuntimeError('Destination is occupied; original application retained in recovery directory.')
                os.rename(backup_app, APP)
            if created_support: shutil.rmtree(SUPPORT)
        except Exception as rollback_error:
            raise RuntimeError(f'{error}; rollback incomplete: {rollback_error}. Recovery data retained at {SUPPORT}.') from error
        raise RuntimeError(f'{error}; installation changes rolled back. Any previous application was preserved.') from error
    # Cleanup is after commit; a cleanup failure must not remove a working installation.
    try:
        shutil.rmtree(stage)
    except OSError as error:
        print('Installed; temporary backup cleanup deferred: ' + str(error), file=sys.stderr)
    print('Installed application and components. Reopen /Applications/Chrome Consent.app to complete setup.')


def uninstall(dry_run):
    if any(path.is_symlink() for path in [APP, PLUGIN, SUPPORT]):
        raise ValueError('System component destinations must not be symlinks.')
    current = read_rule(PARENT)
    target = remove_branch(current)
    if dry_run:
        print(json.dumps({'operation': 'uninstall', 'existingBranches': current.get('rule'),
                          'newBranches': target.get('rule'), 'preservesOtherBranches': True}, ensure_ascii=False, indent=2)); return
    if os.geteuid() != 0: raise PermissionError('Administrator authorization is required.')
    ensure_idle_unlocked()
    if APP.exists(): verify_bundle(APP)
    current = read_rule(PARENT)
    target = remove_branch(current)
    cfg_path = SUPPORT / 'config.plist'
    if cfg_path.exists():
        trusted_metadata(SUPPORT, directory=True)
        trusted_metadata(cfg_path)
        cfg = plistlib.loads(cfg_path.read_bytes()); cfg['enabled'] = False; atomic_plist(cfg_path, cfg)
    # Detach the rule before removing the code it names.
    write_rule(PARENT, target)
    removal = subprocess.run(['/usr/bin/security', 'authorizationdb', 'remove', RIGHT], capture_output=True, timeout=10)
    if removal.returncode and RIGHT in current.get('rule', []):
        raise RuntimeError('Unable to remove component authorization rule. Components retained for recovery.')
    if PLUGIN.exists(): shutil.rmtree(PLUGIN)
    if APP.exists(): shutil.rmtree(APP)
    if SUPPORT.exists(): shutil.rmtree(SUPPORT)
    print('Uninstalled. Only the ChromeConsent branch and installed components were removed; other rules and user logs were preserved.')


def main():
    global CALLER_PID
    parser = argparse.ArgumentParser()
    parser.add_argument('operation', choices=['install', 'uninstall'])
    parser.add_argument('--source', type=pathlib.Path)
    parser.add_argument('--uid', type=int, default=os.getuid())
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--caller-pid', type=int)
    args = parser.parse_args()
    CALLER_PID = args.caller_pid
    if args.operation == 'install' and not args.source: parser.error('--source is required')
    if not args.dry_run and os.geteuid() != 0: raise PermissionError('Administrator authorization is required.')
    with contextlib.nullcontext() if args.dry_run else transaction_lock():
        if args.operation == 'install': install(args.source, args.uid, args.dry_run)
        else: uninstall(args.dry_run)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('ChromeConsent: ' + str(error), file=sys.stderr)
        sys.exit(1)

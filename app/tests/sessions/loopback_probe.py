"""Disposable multi-hop OpenSSH fixture; no existing keys or system services changed."""
import json, os, pathlib, pwd, socket, subprocess, tempfile, time, sys
result = {'passed':False, 'scope':'loopback only; ephemeral test keys'}
with tempfile.TemporaryDirectory(prefix='harbor-p1-sshd-') as root:
    root=pathlib.Path(root); children=[]; logs=[]
    try:
        for name in ['host_key','client_key']:
            subprocess.run(['/usr/bin/ssh-keygen','-q','-t','ed25519','-N','','-f',str(root/name)],check=True)
        (root/'authorized_keys').write_bytes((root/'client_key.pub').read_bytes()); (root/'authorized_keys').chmod(0o600)
        ports=[]
        for i in range(3):
            with socket.socket() as sock: sock.bind(('127.0.0.1',0)); ports.append(sock.getsockname()[1])
        for i,port in enumerate(ports):
            config=root/f'sshd{i}.conf'
            config.write_text(f'''Port {port}
ListenAddress 127.0.0.1
HostKey {root}/host_key
PidFile {root}/pid{i}
AuthorizedKeysFile {root}/authorized_keys
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
AllowTcpForwarding yes
Subsystem sftp internal-sftp
''')
            log=open(root/f'sshd{i}.log','wb'); logs.append(log)
            children.append(subprocess.Popen(['/usr/sbin/sshd','-D','-e','-f',str(config)],stdout=log,stderr=log))
        time.sleep(0.3)
        if any(p.poll() is not None for p in children):
            raise RuntimeError('local sshd cannot start: '+'; '.join((root/f'sshd{i}.log').read_text()[-500:] for i in range(3)))
        pub=(root/'host_key.pub').read_text().split()
        (root/'known_hosts').write_text(''.join(f'[127.0.0.1]:{p} {pub[0]} {pub[1]}\n' for p in ports))
        config=root/'client.conf'
        config.write_text(f'''Host hop1
 HostName 127.0.0.1
 Port {ports[0]}
Host hop2
 HostName 127.0.0.1
 Port {ports[1]}
Host *
 User {pwd.getpwuid(os.getuid()).pw_name}
 IdentityFile {root}/client_key
 IdentitiesOnly yes
 IdentityAgent none
 UserKnownHostsFile {root}/known_hosts
 StrictHostKeyChecking yes
 BatchMode yes
 ConnectTimeout 5
''')
        args=['/usr/bin/ssh','-F',str(config),'-J','hop1,hop2','-p',str(ports[2]),'127.0.0.1','printf HARBOR_MULTIHOP_OK']
        p=subprocess.run(args,capture_output=True,timeout=20)
        result.update(passed=p.returncode==0 and p.stdout==b'HARBOR_MULTIHOP_OK',returncode=p.returncode,stderr=p.stderr.decode(errors='replace')[-1500:])
        if result['passed'] and len(sys.argv)>1:
            env=dict(os.environ,HARBOR_ROUTE_CONFIG=str(config),HARBOR_ROUTE_ROOT=str(root),HARBOR_ROUTE_PORT=str(ports[2]),HARBOR_ROUTE_USER=pwd.getpwuid(os.getuid()).pw_name,GHOSTTY_RESOURCES_DIR=str(pathlib.Path('vendor/ghostty/zig-out/share/ghostty').resolve()))
            native=subprocess.run([sys.argv[1]],env=env,capture_output=True,timeout=45)
            pathlib.Path('checks/p1-loopback-native.log').write_bytes(native.stdout+native.stderr)
            result['native_returncode']=native.returncode
            result['native_passed']=native.returncode==0 and b'failures=0' in native.stdout
            result['passed']=result['passed'] and result['native_passed']
    except Exception as e: result['blocker']=str(e)
    finally:
        for p in children:
            if p.poll() is None: p.terminate()
        for p in children:
            try:p.wait(timeout=3)
            except subprocess.TimeoutExpired:p.kill();p.wait()
        for log in logs: log.close()
pathlib.Path('checks/p1-loopback-probe.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2))

sys.exit(0 if result['passed'] else 1)

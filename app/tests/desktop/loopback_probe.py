"""Isolated P2 forwarding fixture. Uses ephemeral keys and loopback listeners only."""
import http.server, json, os, pathlib, pwd, socket, subprocess, sys, tempfile, threading, time
result = {'passed': False, 'scope': 'RDP/VNC handoff callbacks simulated; real HTTP through disposable loopback SSH forwarding'}
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body=b'HARBOR_P2_FORWARD_OK'; self.send_response(200); self.end_headers(); self.wfile.write(body)
    def log_message(self, *args): pass
def freeport():
    with socket.socket() as s: s.bind(('127.0.0.1',0)); return s.getsockname()[1]
with tempfile.TemporaryDirectory(prefix='harbor-desktop-') as name:
    root=pathlib.Path(name); daemon=None
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    try:
        for key in ['host','client']:
            subprocess.run(['/usr/bin/ssh-keygen','-q','-t','ed25519','-N','','-f',str(root/key)],check=True)
        (root/'authorized_keys').write_bytes((root/'client.pub').read_bytes())
        sshport=freeport(); config=root/'sshd.conf'
        config.write_text(f'''Port {sshport}
ListenAddress 127.0.0.1
HostKey {root}/host
PidFile {root}/pid
AuthorizedKeysFile {root}/authorized_keys
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
AllowTcpForwarding yes
GatewayPorts no
''')
        pub=(root/'host.pub').read_text().split()
        (root/'known_hosts').write_text(f'[127.0.0.1]:{sshport} {pub[0]} {pub[1]}\n')
        client=root/'client.conf'
        client.write_text(f'''Host *
 IdentityFile {root}/client
 IdentitiesOnly yes
 IdentityAgent none
 UserKnownHostsFile {root}/known_hosts
 StrictHostKeyChecking yes
 BatchMode yes
 ConnectTimeout 5
''')
        with open(root/'sshd.log','wb') as log:
            daemon=subprocess.Popen(['/usr/sbin/sshd','-D','-e','-f',str(config)],stdout=log,stderr=log)
            time.sleep(.3)
            if daemon.poll() is not None: raise RuntimeError((root/'sshd.log').read_text())
            env=dict(os.environ,HARBOR_P2_CONFIG=str(client),HARBOR_P2_KEY=str(root/'client'),HARBOR_P2_PORT=str(sshport),HARBOR_P2_USER=pwd.getpwuid(os.getuid()).pw_name,HARBOR_P2_HTTP=str(server.server_port),HARBOR_P2_LISTEN=','.join(str(freeport()) for _ in range(4)),GHOSTTY_RESOURCES_DIR=str(pathlib.Path('vendor/ghostty/zig-out/share/ghostty').resolve()))
            p=subprocess.run([sys.argv[1]],env=env,capture_output=True,timeout=90)
            pathlib.Path('checks/p3-desktop-tests.log').write_bytes(p.stdout+p.stderr)
            result.update(returncode=p.returncode,passed=p.returncode==0 and b'failures=0' in p.stdout)
    except Exception as error: result['blocker']=str(error)
    finally:
        server.shutdown(); server.server_close()
        if daemon:
            daemon.terminate()
            try: daemon.wait(timeout=3)
            except subprocess.TimeoutExpired: daemon.kill(); daemon.wait()
pathlib.Path('checks/p3-desktop-loopback.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2)); sys.exit(0 if result['passed'] else 1)

"""Real loopback RFB fixtures and FreeRDP sample server; no remote credentials."""
import pty
import os, pathlib, socket, struct, subprocess, threading, queue, time, tempfile, json, select
ROOT=pathlib.Path(__file__).resolve().parents[3]
HELPER=pathlib.Path(os.environ.get('HARBOR_DESKTOP_HELPER',ROOT/'vendor/desktop-engine/harbor-desktop-engine'))
env=dict(os.environ,DYLD_LIBRARY_PATH=str(ROOT/'vendor/freerdp-install/lib'))
checks=[]
def check(v,label):
    checks.append({'name':label,'passed':bool(v)})
    print(('PASS ' if v else 'FAIL ')+label,flush=True)
    assert v,label
def exact(f,n):
    b=b''
    while len(b)<n:
        x=f.recv(n-len(b)) if isinstance(f,socket.socket) else f.read(n-len(b))
        if not x: raise EOFError()
        b+=x
    return b
class Client:
    def __init__(self,kind,port,password='fixture'):
        self.p=subprocess.Popen([str(HELPER)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=({k:v for k,v in os.environ.items() if not k.startswith("DYLD_")} if "HARBOR_DESKTOP_HELPER" in os.environ else env))
        self.q=queue.Queue()
        def reader():
            try:
                while True:
                    h=exact(self.p.stdout,5);n=struct.unpack('!I',h[1:])[0];self.q.put((h[:1],exact(self.p.stdout,n)))
            except Exception as e:self.q.put((b'X',str(e).encode()))
        threading.Thread(target=reader,daemon=True).start()
        b=struct.pack('!III',port,800,600)
        for s in [kind,'127.0.0.1','fixture',password,'']:
            v=s.encode();b+=struct.pack('!I',len(v))+v
        self.send(b'I',b)
    def send(self,t,b=b''):self.p.stdin.write(t+struct.pack('!I',len(b))+b);self.p.stdin.flush()
    def wait(self,t,timeout=15):
        until=time.monotonic()+timeout
        while time.monotonic()<until:
            item=self.q.get(timeout=max(.01,until-time.monotonic()))
            if item[0] in [t,b'E',b'X']:return item
        raise TimeoutError()
    def close(self):
        if self.p.poll() is None:
            try:self.send(b'Q')
            except BrokenPipeError:pass
            try:self.p.wait(timeout=3)
            except subprocess.TimeoutExpired:self.p.terminate();self.p.wait(timeout=3)
        self.p.stdin.close();self.p.stdout.close();diagnostic=self.p.stderr.read();self.p.stderr.close();print('HELPER EXIT',self.p.returncode,diagnostic.decode(errors="replace")[-4000:],flush=True)
def vnc_case(minor=8,auth=1,bad=False,reject=False):
    listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen();port=listener.getsockname()[1];events=queue.Queue();errors=[]
    def server():
        try:
            with listener.accept()[0] as s:
                s.settimeout(10);s.sendall(f'RFB 003.00{minor}\n'.encode());assert exact(s,12)==f'RFB 003.00{minor}\n'.encode()
                if minor==3:s.sendall(struct.pack('!I',auth))
                else:s.sendall(bytes([1,auth]));assert exact(s,1)==bytes([auth])
                if auth==2:
                    challenge=bytes(range(16));s.sendall(challenge);response=exact(s,16)
                    def reverse(v):return int(f'{v:08b}'[::-1],2)
                    key=bytes(reverse(x) for x in b'fixture\0').hex()
                    expected=subprocess.check_output(['/opt/homebrew/opt/openssl@3/bin/openssl','enc','-des-ecb','-provider','legacy','-K',key,'-nopad'],input=challenge)
                    assert response==expected
                if auth==2 or minor==8:s.sendall(struct.pack('!I',1 if reject else 0))
                if reject:return
                assert exact(s,1)==b'\x01';s.sendall(struct.pack('!HH',4,3)+bytes([32,24,0,1,0,255,0,255,0,255,0,8,16,0,0,0])+struct.pack('!I',7)+b'Fixture')
                assert len(exact(s,20))==20;h=exact(s,4);assert h[0]==2;exact(s,struct.unpack('!H',h[2:])[0]*4);exact(s,10)
                rect=struct.pack('!HHHHi',5 if bad else 0,0,4,3,0)
                s.sendall(b'\x00\x00\x00\x01'+rect+bytes([20,40,60,0])*12)
                if bad:return
                exact(s,10)
                # Overlapping copy + resize + raw frame in a single update.
                s.sendall(b'\x00\x00\x00\x03'+struct.pack('!HHHHi',1,1,3,2,1)+struct.pack('!HH',0,0)+struct.pack('!HHHHi',0,0,2,2,-223)+struct.pack('!HHHHi',0,0,2,2,0)+bytes([90,80,70,0])*4)
                exact(s,10)
                for _ in range(2):
                    kind=exact(s,1);events.put(kind+exact(s,7 if kind==b'\x04' else 5))
        except Exception as e:errors.append(repr(e))
        finally:listener.close()
    thread=threading.Thread(target=server);thread.start();c=Client('VNC',port)
    try:
        if bad or reject:check(c.wait(b'E')[0]==b'E','VNC rejects '+('out-of-bounds rectangle' if bad else 'wrong password'))
        else:
            t,b=c.wait(b'F');check(t==b'F' and b[:8]==struct.pack('!II',4,3) and b[8:]==bytes([20,40,60,255])*12,f'RFB 3.{minor} authentication {auth} and exact RGBA frame')
            t,b=c.wait(b'F');check(t==b'F' and b[:8]==struct.pack('!II',2,2) and b[8:]==bytes([90,80,70,255])*4,'CopyRect and DesktopSize accepted')
            c.send(b'V',b'\x01'+struct.pack('!I',0xff0d));c.send(b'P',b'\x01'+struct.pack('!HH',1,1))
            check(events.get(timeout=5)==b'\x04\x01\0\0'+struct.pack('!I',0xff0d),'VNC keyboard delivered')
            check(events.get(timeout=5)==b'\x05\x01'+struct.pack('!HH',1,1),'VNC pointer delivered')
    finally:c.close();thread.join(12)
    check(not errors,'VNC fixture lifecycle '+str(errors))
def rdp_case(trust):
    with tempfile.TemporaryDirectory(prefix='harbor-rdp-') as name:
        d=pathlib.Path(name);cert=d/'cert.pem';key=d/'key.pem'
        subprocess.run(['/opt/homebrew/opt/openssl@3/bin/openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1','-subj','/CN=Harbor Fixture','-keyout',str(key),'-out',str(cert)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen();port=listener.getsockname()[1]
        log=open(d/'server.log','wb');master,slave=pty.openpty()
        def capture():
            try:
                while True:
                    data=os.read(master,65536)
                    if not data:break
                    log.write(data);log.flush()
            except OSError:pass
        capture_thread=threading.Thread(target=capture,daemon=True);capture_thread.start()
        server=subprocess.Popen([str(ROOT/'vendor/freerdp-build/server/Sample/sfreerdp-server'),'--local-only',f'--port={port}',f'--cert={cert}',f'--key={key}'],cwd=ROOT/'vendor/freerdp-build/server/Sample',env=dict(env,WLOG_LEVEL='DEBUG',TMPDIR=name),stdout=slave,stderr=slave)
        os.close(slave)
        path=d/f'tfreerdp-server.{port}'
        deadline=time.monotonic()+8
        while not path.exists() and time.monotonic()<deadline:time.sleep(.05)
        if not path.exists():server.terminate();server.wait();log.close();raise RuntimeError((d/'server.log').read_text())
        bridge=[]
        def forward():
            try:
                a=listener.accept()[0];b=socket.socket(socket.AF_UNIX);b.connect(str(path));bridge.extend([a,b])
                while True:
                    ready=select.select([a,b],[],[],10)[0]
                    if not ready:break
                    for src in ready:
                        data=src.recv(65536)
                        if not data:return
                        (b if src is a else a).sendall(data)
            except OSError:pass
            finally:
                for s in bridge:s.close()
        thread=threading.Thread(target=forward,daemon=True);thread.start();c=Client('RDP',port)
        try:
            t,b=c.wait(b'C');check(t==b'C' and b'Fingerprint:' in b,'RDP self-signed certificate requires decision')
            c.send(b'T',bytes([int(trust)]))
            if not trust:check(c.wait(b'E')[0]==b'E','RDP certificate rejection prevents connection')
            else:
                t,b=c.wait(b'F',25);print('RDP FRAME',t,len(b),b[:200] if t!=b'F' else b[:8],flush=True);check(t==b'F' and len(b)==800*600*4+8,'RDP real sample server renders negotiated desktop')
                c.send(b'K',b'\x01'+struct.pack('!I',0x1e));c.send(b'K',b'\x00'+struct.pack('!I',0x1e));c.send(b'U',b'\x01'+struct.pack('!I',0x4e2d))
                for _ in range(100):
                    c.send(b'K',b'\x01'+struct.pack('!I',0x20));c.send(b'K',b'\x00'+struct.pack('!I',0x20))
                c.send(b'M',struct.pack('!HHHH',0x0800,12,23,0));time.sleep(.3)
        finally:
            c.close();server.terminate();server.wait(timeout=5);listener.close();capture_thread.join(2);os.close(master);log.close();thread.join(2);(ROOT/'checks'/f'embedded-rdp-{trust}.log').write_text((d/'server.log').read_text())
        output=(d/'server.log').read_text();(ROOT/'checks'/f'embedded-rdp-{trust}.log').write_text(output)
        if trust:
            check('Client sent a keyboard event' in output and 'pos:12,23' in output,'RDP keyboard and mouse reach protocol server')
            check(output.count('Client sent a keyboard event')>=202,'RDP burst input drains without accumulating event latency')
if __name__=='__main__':
    try:
        for minor,auth in [(3,1),(7,1),(8,1),(8,2)]:vnc_case(minor,auth)
        vnc_case(auth=2,reject=True);vnc_case(bad=True)
        rdp_case(False);rdp_case(True)
    finally:
        (ROOT/'checks/embedded-protocol.json').write_text(json.dumps({'checks':checks,'passed':all(c['passed'] for c in checks)},indent=2))

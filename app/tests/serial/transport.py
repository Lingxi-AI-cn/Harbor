"""Exercise the real packaged bridge through macOS PTYs, without physical devices."""
import base64, errno, fcntl, json, os, pathlib, pty, select, signal, subprocess, sys, termios, time
binary=str(pathlib.Path(sys.argv[1] if len(sys.argv)>1 else 'dist/Harbor.app/Contents/MacOS/Harbor').resolve())
checks=[]
def check(ok,name):
    checks.append({'name':name,'passed':bool(ok)}); print(('PASS: ' if ok else 'FAIL: ')+name,flush=True)
def read_until(fd, token, seconds=4):
    data=b''; deadline=time.monotonic()+seconds
    while token not in data and time.monotonic()<deadline:
        if select.select([fd],[],[],.1)[0]:
            try: chunk=os.read(fd,65536)
            except OSError as e:
                if e.errno==errno.EIO: break
                raise
            if not chunk: break
            data+=chunk
    return data
class Fixture:
    def __init__(self,**values):
        self.master,self.slave=pty.openpty(); self.path=os.ttyname(self.slave)
        self.before=termios.tcgetattr(self.slave)
        self.settings=dict(device=self.path,baud=115200,dataBits=8,parity='None',stopBits=1,flow='None',lineEnding='CR',localEcho=False)
        self.settings.update(values)
        self.p=subprocess.Popen([binary,'--serial-bridge',base64.b64encode(json.dumps(self.settings).encode()).decode()],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        self.ready=read_until(self.p.stdout.fileno(),b'Close this tab to disconnect.]\r\n')
    def stop(self):
        if self.p.poll() is None:self.p.terminate()
        self.p.wait(timeout=3)
    def close(self):
        self.stop()
        for x in [self.master,self.slave]:
            if x>=0:os.close(x)
        for pipe in [self.p.stdin,self.p.stdout,self.p.stderr]:pipe.close()
try:
    f=Fixture()
    try:
        check(b'Serial open:' in f.ready,'real serial bridge opens a PTY')
        actual=termios.tcgetattr(f.slave)
        check(actual[4]==termios.B115200 and actual[5]==termios.B115200,'configured baud applied to driver')
        check(not(actual[3]&termios.ECHO) and not(actual[3]&termios.ICANON),'device configured as raw without echo')
        tx=b'abc\x00\x03\x1b[A'+ '中文'.encode()+b'\r'
        f.p.stdin.write(tx);f.p.stdin.flush()
        check(read_until(f.master,tx)==tx,'input including NUL Ctrl-C arrows UTF-8 and CR reaches device unchanged')
        rx=b'\x1b[31mdevice:'+ '中文'.encode()+b'\x00\r\n'
        os.write(f.master,rx)
        check(read_until(f.p.stdout.fileno(),rx)==rx,'device bytes and escape sequences reach terminal unchanged')
        check(f.p.poll() is None,'Ctrl-C is sent to device and does not terminate bridge')
        other=subprocess.run([binary,'--serial-bridge',base64.b64encode(json.dumps(f.settings).encode()).decode()],input=b'',capture_output=True,timeout=3)
        check(other.returncode!=0 and (b'already in use' in other.stderr or b'busy' in other.stderr.lower()),'second bridge cannot claim an owned device')
        f.stop()
        check(f.p.returncode==0,'SIGTERM exits bridge cleanly')
        after=termios.tcgetattr(f.slave)
        # PENDIN is transient kernel state when restoring canonical mode.
        after[3] &= ~termios.PENDIN; before=list(f.before); before[3] &= ~termios.PENDIN
        check(after==before,'closing restores original serial termios')
        fd=os.open(f.path,os.O_RDWR|os.O_NOCTTY|os.O_NONBLOCK);os.close(fd)
        check(True,'port can be reopened after close')
    finally:f.close()
    for ending,expected in [('LF',b'one\ntwo\n'),('CRLF',b'one\r\ntwo\n')]:
        f=Fixture(lineEnding=ending)
        try:
            f.p.stdin.write(b'one\rtwo\n');f.p.stdin.flush()
            check(read_until(f.master,expected)==expected,ending+' maps CR input and preserves existing LF')
        finally:f.close()
    f=Fixture(localEcho=True)
    try:
        f.p.stdin.write(b'echo test');f.p.stdin.flush()
        check(read_until(f.master,b'echo test')==b'echo test' and read_until(f.p.stdout.fileno(),b'echo test')==b'echo test','optional local echo displays exactly the transmitted input')
    finally:f.close()
    f=Fixture()
    try:
        # Repeated binary blocks exercise queue partial writes/backpressure.
        payload=(bytes(range(256))*128)
        f.p.stdin.write(payload);f.p.stdin.flush()
        check(read_until(f.master,payload,6)==payload,'32 KiB binary transmit has no truncation or reordering')
        f.p.stdin.close();f.p.wait(timeout=3)
        check(f.p.returncode==0,'input EOF releases the device')
    finally:f.close()
    f=Fixture()
    try:
        os.close(f.master);f.master=-1
        f.p.wait(timeout=4)
        check(f.p.returncode!=0 and b'disconnected' in f.p.stderr.read(),'device unplug ends session with an explicit disconnect reason')
    finally:f.close()
    for changes in [dict(device='/tmp/file'),dict(baud=0),dict(dataBits=9),dict(parity='invalid'),dict(flow='invalid'),dict(stopBits=3),dict(lineEnding='invalid')]:
        cfg=dict(device='/dev/cu.nonexistent-harbor-test',baud=115200,dataBits=8,parity='None',stopBits=1,flow='None',lineEnding='CR',localEcho=False);cfg.update(changes)
        p=subprocess.run([binary,'--serial-bridge',base64.b64encode(json.dumps(cfg).encode()).decode()],input=b'',capture_output=True,timeout=3)
        check(p.returncode!=0 and b'Invalid serial' in p.stderr,'invalid '+next(iter(changes))+' rejected before open')
    cfg=dict(device='/dev/cu.nonexistent-harbor-test',baud=115200,dataBits=8,parity='None',stopBits=1,flow='None',lineEnding='CR',localEcho=False)
    p=subprocess.run([binary,'--serial-bridge',base64.b64encode(json.dumps(cfg).encode()).decode()],input=b'',capture_output=True,timeout=3)
    check(p.returncode!=0 and b'Cannot open' in p.stderr,'missing device reports failure without fallback')
except Exception as error:
    check(False,'test exception: '+str(error))
result={'scope':'real macOS PTY byte IO and driver configuration; no physical UART acceptance','checks':checks,'passed':all(c['passed'] for c in checks)}
pathlib.Path('checks/p3-serial-transport.json').write_text(json.dumps(result,indent=2)+'\n')
print('RESULT assertions=%s failures=%s'%(len(checks),sum(not c['passed'] for c in checks)))
sys.exit(0 if result['passed'] else 1)

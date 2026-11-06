"""A bounded, disposable loopback framebuffer for native UI verification."""
import socket,struct,threading,subprocess,os,pathlib,time,json,sys
root=pathlib.Path(__file__).resolve().parents[3]
server=socket.socket();server.bind(('127.0.0.1',0));server.listen();server.settimeout(.5)
events=[];stopping=False
W,H=800,600
pixels=bytearray()
for y in range(H):
    for x in range(W):
        if x<400 and y<300:c=(230,70,70,0)
        elif x>=400 and y<300:c=(60,180,100,0)
        elif x<400:c=(60,120,230,0)
        else:c=(240,190,50,0)
        if x%100<2 or y%100<2:c=(245,245,245,0)
        pixels.extend(c)
def exact(s,n):
    data=b''
    while len(data)<n:
        b=s.recv(n-len(data))
        if not b:raise EOFError
        data+=b
    return data
def handle(s):
    try:
        s.settimeout(120);s.sendall(b'RFB 003.008\n');exact(s,12);s.sendall(b'\x01\x01');exact(s,1);s.sendall(b'\0\0\0\0');exact(s,1)
        s.sendall(struct.pack('!HH',W,H)+bytes([32,24,0,1,0,255,0,255,0,255,0,8,16,0,0,0])+struct.pack('!I',7)+b'Fixture')
        exact(s,20);h=exact(s,4);exact(s,struct.unpack('!H',h[2:])[0]*4);first=True
        while True:
            t=exact(s,1)[0]
            if t==3:
                exact(s,9)
                if first:s.sendall(b'\0\0\0\1'+struct.pack('!HHHHi',0,0,W,H,0)+pixels);first=False
                # Hold incremental requests until another change; no busy polling.
            elif t==4:
                b=exact(s,7);events.append({'key':struct.unpack('!I',b[3:])[0],'down':b[0]})
            elif t==5:
                b=exact(s,5);events.append({'buttons':b[0],'x':struct.unpack('!H',b[1:3])[0],'y':struct.unpack('!H',b[3:])[0]})
            else:raise ValueError(t)
            (root/'checks/embedded-ui-events.json').write_text(json.dumps(events,indent=2))
    except (EOFError,OSError):pass
    finally:s.close()
def serve():
    while not stopping:
        try:s,_=server.accept();threading.Thread(target=handle,args=(s,),daemon=True).start()
        except socket.timeout:pass
        except OSError:break
threading.Thread(target=serve,daemon=True).start()
env=dict(os.environ,HARBOR_EMBEDDED_PORT=str(server.getsockname()[1]),GHOSTTY_RESOURCES_DIR=str(root/'vendor/ghostty/zig-out/share/ghostty'))
try:
    with open(root/'checks/embedded-native.log','wb') as log:
        p=subprocess.run([sys.argv[1]],cwd=root,env=env,stdout=log,stderr=log,timeout=300)
finally:stopping=True;server.close()
print('native return',p.returncode);sys.exit(p.returncode)

"""Exercise release-notice gates against a copy, never mutate the real bundle."""
from pathlib import Path
import shutil,subprocess,tempfile
root=Path(__file__).resolve().parents[3]
with tempfile.TemporaryDirectory(prefix='harbor-notice-tests-') as temp:
    bundle=Path(temp)/'Harbor.app';shutil.copytree(root/'dist/Harbor.app',bundle)
    def verify(ok):
        p=subprocess.run(['python3',str(root/'scripts/verify-linked-notices.py'),str(bundle)],capture_output=True,text=True)
        assert (p.returncode==0)==ok,p.stdout+p.stderr
    verify(True)
    notice=bundle/'Contents/Resources/ThirdPartyNotices/Desktop/libusb-COPYING.txt';data=notice.read_bytes();notice.unlink();verify(False);notice.write_bytes(data)
    extra=bundle/'Contents/Frameworks/unreviewed.dylib';extra.write_bytes(b'unreviewed');verify(False);extra.unlink()
    binary=bundle/'Contents/MacOS/Harbor'
    with binary.open('ab') as f:f.write(b'changed')
    verify(False)
print('PASS: valid bundle accepted; missing libusb notice, unknown library and stale executable rejected')

"""Convert the checked-in high-resolution artwork to a macOS ICNS using system tools."""
from pathlib import Path
import subprocess
import struct
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source = root / 'app/Resources/AppIcon/Harbor.png'
destination = Path(sys.argv[1]).resolve()
destination.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='harbor-icon-') as temp:
    iconset = Path(temp) / 'Harbor.iconset'
    iconset.mkdir()
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            suffix = '@2x' if scale == 2 else ''
            output = iconset / f'icon_{size}x{size}{suffix}.png'
            subprocess.run(['sips', '-z', str(size * scale), str(size * scale),
                            str(source), '--out', str(output)], check=True,
                           stdout=subprocess.DEVNULL)
    # Modern ICNS entries contain PNG data; explicit types retain Retina mappings.
    types = {(16, 1): b'icp4', (16, 2): b'ic11', (32, 1): b'icp5',
             (32, 2): b'ic12', (128, 1): b'ic07', (128, 2): b'ic13',
             (256, 1): b'ic08', (256, 2): b'ic14', (512, 1): b'ic09',
             (512, 2): b'ic10'}
    entries = []
    for (size, scale), kind in types.items():
        suffix = '@2x' if scale == 2 else ''
        data = (iconset / f'icon_{size}x{size}{suffix}.png').read_bytes()
        entries.append(kind + struct.pack('>I', len(data) + 8) + data)
    payload = b''.join(entries)
    destination.write_bytes(b'icns' + struct.pack('>I', len(payload) + 8) + payload)
print(destination)

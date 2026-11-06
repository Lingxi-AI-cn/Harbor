import json, os, select, sys, termios, time, tty
path = sys.argv[1]
old = termios.tcgetattr(0)
try:
    tty.setraw(0)
    os.write(1, b'\x1b[?2004h\x1b[?1000h\x1b[?1006hINPUT_READY\r\n')
    data = bytearray()
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        if select.select([0], [], [], 0.1)[0]:
            data.extend(os.read(0, 65536))
    with open(path, 'w') as f:
        json.dump({'hex': data.hex(), 'bytes': len(data)}, f)
finally:
    termios.tcsetattr(0, termios.TCSANOW, old)
    os.write(1, b'\x1b[?2004l\x1b[?1000l\x1b[?1006lINPUT_DONE\r\n')

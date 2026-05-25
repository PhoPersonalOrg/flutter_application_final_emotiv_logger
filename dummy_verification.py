import struct

# Create a 1x1 binary PNG
png_header = b'\x89PNG\r\n\x1a\n'
ihdr = struct.pack('!I4sIIBB0s', 13, b'IHDR', 1, 1, 8, 2, b'')
idat = struct.pack('!I4s12s', 12, b'IDAT', b'\x78\x9c\x63\x00\x01\x00\x00\x05\x00\x01\x0d\x0a')
iend = struct.pack('!I4s0s', 0, b'IEND', b'')

with open('dummy_screenshot.png', 'wb') as f:
    f.write(png_header)
    f.write(ihdr)
    f.write(idat)
    f.write(iend)

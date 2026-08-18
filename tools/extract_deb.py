"""Pull MiniBea.dylib out of a .deb without dpkg (ar + tar, both stdlib-able)."""
import io, lzma, os, struct, sys, tarfile

deb = sys.argv[1]
outdir = sys.argv[2]
os.makedirs(outdir, exist_ok=True)

data = open(deb, 'rb').read()
assert data[:8] == b'!<arch>\n', 'not an ar archive'

pos = 8
members = {}
while pos < len(data):
    header = data[pos:pos + 60]
    if len(header) < 60:
        break
    name = header[0:16].decode().strip()
    size = int(header[48:58].decode().strip())
    body = data[pos + 60:pos + 60 + size]
    members[name.rstrip('/')] = body
    pos += 60 + size + (size % 2)

print('ar members:', list(members))

payload = next(v for k, v in members.items() if k.startswith('data.tar'))
name = next(k for k in members if k.startswith('data.tar'))
if name.endswith('.xz'):
    payload = lzma.decompress(payload)
    mode = 'r:'
elif name.endswith('.gz'):
    mode = 'r:gz'
elif name.endswith('.lzma'):
    payload = lzma.decompress(payload)
    mode = 'r:'
else:
    mode = 'r:'

tf = tarfile.open(fileobj=io.BytesIO(payload), mode=mode)
for m in tf.getmembers():
    if m.name.endswith('.dylib'):
        print('found', m.name, m.size)
        out = os.path.join(outdir, os.path.basename(m.name))
        with open(out, 'wb') as f:
            f.write(tf.extractfile(m).read())
        print('wrote', out)

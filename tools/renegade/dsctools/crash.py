import sys, re
from symb import *
f = sys.argv[1]
name = sys.argv[2]
want = int(sys.argv[3]) if len(sys.argv) > 3 else 0
lines = open(f, errors='replace').read().split('\n')
idx = [i for i, l in enumerate(lines) if re.match(r'^CRASH %s\w*\[\d+\] sig' % name, l)]
i = idx[want]
l = lines[i]
m = re.search(r'slide (0x[0-9a-f]+) mh (0x[0-9a-f]+)', l)
slide = int(m.group(1), 16); mh = int(m.group(2), 16)
print(l)
pc = int(re.search(r' pc (0x[0-9a-f]+)', lines[i+1]).group(1), 16)
lr = int(re.search(r' lr (0x[0-9a-f]+)', lines[i+1]).group(1), 16)
bt = [int(x, 16) for x in lines[i+2].split()[3:]]
def desc(a):
    if a == 0: return '0'
    u = a - slide
    if 0x180000000 <= u < 0x300000000:
        try: return 'CACHE ' + hex(u) + ' ' + sym(u)
        except Exception as e: return 'CACHE ' + hex(u)
    return 'MAIN %s+%#x' % (name, a - mh)
print('pc  ', desc(pc)); print('lr  ', desc(lr))
for k, a in enumerate(bt): print('bt%d ' % k, desc(a))

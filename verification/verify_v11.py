# Model v11 for output row R=0 using the LOAD-PIPELINE offset that v9 actually exhibits:
#   buffer[ch][slot][p] = ifmap[ch][row(slot)][p-1]   (p=1..98 after widening to 99)
#   v11 read: element (ch,dr,dc) -> buffer[ch][slot=(base_slot+dr)%5][3C+dc+1]
#   For R=0: base_slot=0, slot=dr holds row dr.  -> value = ifmap[ch][dr][3C+dc]
#   filter = filter[cnt75-1] = filter[decode(k-1)] (straight load via pipeline)
# This is exactly standard conv for R=0; check idx 0..31 (incl. the col=31 that v9 failed).
def load(fn):
    with open(fn,'rb') as f: return f.read()
img=load('image_0.bin'); fil=load('filter_2.bin'); gold=load('golden_2.bin')
def s8(b): return b-256 if b>=128 else b
def gld(idx): return gold[2*idx]|(gold[2*idx+1]<<8) if (gold[0]|(gold[1]<<8))==10439 else (gold[2*idx]<<8)|gold[2*idx+1]

# Build R=0 buffer with the offset (widened to p=0..98)
# buffer[ch][slot=row][p] for p in 1..98 = ifmap[ch][row][p-1]
def buf(ch, slot, p):           # slot==row for R=0
    assert 1 <= p <= 98, f"p out of read range {p}"
    return s8(img[ch*9604 + slot*98 + (p-1)])

def dec(pos):
    ch=pos//25; r=pos%25; return ch, r//5, r%5

R=0
ok=0; bad=[]
for C in range(32):
    acc=0
    for k in range(1,76):
        ch,dr,dc = dec(k-1)            # cur_mac_(ch,dr,dc) at element k
        slot = (0 + dr) % 5            # base_slot=0 for R=0
        col  = 3*C + dc + 1            # mac_target_col (the +1)
        acc += buf(ch, slot, col) * s8(fil[k-1])   # filter_buf[cnt75-1]=filter[k-1]
    acc &= 0xFFFF
    exp = gld(R*32+C)
    if acc==exp: ok+=1
    else: bad.append((R*32+C, C, acc, exp))

print(f"v11 model R=0: {ok}/32 match")
print("idx 31 (col=31, the one v9 failed):",
      "PASS" if (R*32+31) not in [b[0] for b in bad] else "FAIL")
if bad: print("mismatches:", bad)

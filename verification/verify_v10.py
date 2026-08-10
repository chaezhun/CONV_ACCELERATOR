# Faithfully model Convolver_v10.v's EXACT per-element computation and compare to golden_2.
# v10 element loop (per output pixel (R,C)):
#   for cnt75 in 1..75:
#     pos = cnt75-1                      # cur_mac_(ch,dr,dc) = decode(pos), advance dc->dr->ch
#     ch = pos//25; dr=(pos%25)//5; dc=pos%5
#     mac_target_ch  = ch
#     mac_target_slot= (base_slot+dr)%5  -> holds ifmap row 3R+dr   (row mapping unchanged from v8, proven by f0/1 pass)
#     mac_target_col = 3*C + dc          (STANDARD: no +1)
#     ifmap value    = ifmap[ch][3R+dr][3C+dc]
#     filter value   = filter_buf[cnt75-1] = filter[cnt75-1] = filter[pos]   (STRAIGHT load)
#     acc += ifmap*filter
#   out = acc & 0xFFFF
# This directly checks the (ch,dr,dc) pairing v10 uses, not just abstract std conv.

def load(fn):
    with open(fn,'rb') as f: return f.read()
img  = load('image_0.bin'); fil = load('filter_2.bin'); gold = load('golden_2.bin')
def s8(b): return b-256 if b>=128 else b
LE = (gold[0] | (gold[1]<<8)) == 10439
def gld(idx):
    return (gold[2*idx]|(gold[2*idx+1]<<8)) if LE else ((gold[2*idx]<<8)|gold[2*idx+1])

def ifmap(ch,row,col):
    idx = ch*9604 + row*98 + col
    assert 0 <= idx < 28812, f"OOB ifmap idx {idx} (ch{ch} row{row} col{col})"
    return s8(img[idx])
def filt(pos):              # filter_buf[pos] = filter[pos] (straight)
    return s8(fil[pos])

def v10_pixel(R, C):
    acc = 0
    max_col = 0; max_row = 0
    for cnt75 in range(1, 76):
        pos = cnt75 - 1
        ch = pos // 25; rem = pos % 25; dr = rem // 5; dc = rem % 5
        row = 3*R + dr
        col = 3*C + dc
        max_col = max(max_col, col); max_row = max(max_row, row)
        acc += ifmap(ch, row, col) * filt(pos)
    return acc & 0xFFFF, max_row, max_col

ok = 0; bad = []
worst_row = 0; worst_col = 0
for R in range(32):
    for C in range(32):
        got, mr, mc = v10_pixel(R, C)
        worst_row = max(worst_row, mr); worst_col = max(worst_col, mc)
        exp = gld(R*32 + C)
        if got == exp: ok += 1
        else: bad.append((R*32+C, R, C, got, exp))

print(f"v10 model match: {ok}/1024")
print(f"max row index used: {worst_row} (must be <=97), max col index: {worst_col} (must be <=97)")
# explicit col=31 (boundary) check
print("col=31 outputs (idx 31,63,...):")
allok31 = True
for R in range(32):
    idx = R*32 + 31
    got,_,_ = v10_pixel(R, 31)
    exp = gld(idx)
    if got != exp:
        allok31 = False
        print(f"  X idx {idx} R={R}: got {got} exp {exp}")
print("  all col=31 PASS" if allok31 else "  col=31 has mismatches")
if bad:
    print("first mismatches:", bad[:5])

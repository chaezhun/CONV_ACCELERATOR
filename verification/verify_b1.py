# Verify B1 channel-serial + feature-RAM accumulation == golden.
# Per output (R,C): for ch in 0,1,2: ch_sum = sum_{dr,dc} ifmap[ch][3R+dr][3C+dc]*filter[ch*25+dr*5+dc]
#   partial = (partial + ch_sum) & 0xFFFF   # feature RAM is 16-bit, accumulates across passes
# Check final == golden. (Confirms modular accumulation is correct.)
def load(fn):
    with open(fn,'rb') as f: return f.read()
img=load('image_0.bin'); fil=load('filter_2.bin'); gold=load('golden_2.bin')
def s8(b): return b-256 if b>=128 else b
def gld(idx): return gold[2*idx]|(gold[2*idx+1]<<8) if (gold[0]|(gold[1]<<8))==10439 else (gold[2*idx]<<8)|gold[2*idx+1]
def ifmap(ch,row,col): return s8(img[ch*9604+row*98+col])
def filt(i): return s8(fil[i])

ok=0; bad=[]
for R in range(32):
    for C in range(32):
        partial = 0                       # feature RAM value, 16-bit
        for ch in range(3):               # 3 passes
            ch_sum = 0
            for dr in range(5):
                for dc in range(5):
                    ch_sum += ifmap(ch, 3*R+dr, 3*C+dc) * filt(ch*25 + dr*5 + dc)
            ch_sum &= 0xFFFF              # MAC accumulator 16-bit
            partial = (partial + ch_sum) & 0xFFFF   # feature RAM RMW
        exp = gld(R*32+C)
        if partial == exp: ok += 1
        else: bad.append((R*32+C, partial, exp))

print(f"B1 channel-serial model: {ok}/1024 match")
if bad: print("mismatches:", bad[:5])

# cycle estimate
ifmap_reads = 3*9604          # each channel's ifmap once (with row reuse)
# (rough; actual load count depends on rolling reuse, ~= 28812)
feat_reads  = 2*1024          # passes 1,2 read partials
feat_writes = 3*1024
macs        = 3*25*1024
est = ifmap_reads*11 + feat_reads*11 + feat_writes*1 + macs*1
print(f"rough cycle estimate ~ {est} (gate 450000)")

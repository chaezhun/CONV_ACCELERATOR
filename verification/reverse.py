# Reverse-engineer golden_2 addressing rule.
# ifmap 3x98x98 signed byte, filter 3x5x5 signed, ofmap 32x32 x2byte.

def load(fn):
    with open(fn, 'rb') as f:
        return f.read()

img  = load('image_0.bin')   # 28812
fil  = load('filter_2.bin')  # 75
gold = load('golden_2.bin')  # 2048

print("sizes:", len(img), len(fil), len(gold))

def s8(b):
    return b - 256 if b >= 128 else b

# golden endianness check via idx0 (log said golden[0]=10439)
g_le0 = gold[0] | (gold[1] << 8)
g_be0 = (gold[0] << 8) | gold[1]
print("idx0  LE:", g_le0, " BE:", g_be0, " (expect 10439)")
LE = (g_le0 == 10439)
def gld(idx):
    if LE:
        return gold[2*idx] | (gold[2*idx+1] << 8)
    return (gold[2*idx] << 8) | gold[2*idx+1]

def filt(ch, r, c):
    return s8(fil[ch*25 + r*5 + c])

# ifmap by 1D linear index (col may exceed 97 -> flows to next row/ch naturally)
def ifmap_lin(idx):
    if 0 <= idx < 28812:
        return s8(img[idx])
    return None  # out of image

# Hypotheses for one output (R,C). Returns (sum & 0xFFFF) or None if OOB encountered.
def conv(R, C, offset, oob):
    # offset: column offset added (0 = standard, 1 = +1 idiosyncratic)
    # oob: how to treat index >= 28812 : 'zero' or 'skip' or 'none'
    s = 0
    for ch in range(3):
        for dr in range(5):
            for dc in range(5):
                idx = ch*9604 + (R*3+dr)*98 + (C*3+dc+offset)
                v = ifmap_lin(idx)
                if v is None:
                    if oob == 'zero':
                        v = 0
                    elif oob == 'none':
                        return None
                    else:
                        v = 0
                s += v * filt(ch, dr, dc)
    return s & 0xFFFF

def test(offset, oob):
    ok = 0; first_bad = None; bad = 0
    for R in range(32):
        for C in range(32):
            idx = R*32 + C
            got = conv(R, C, offset, oob)
            exp = gld(idx)
            if got == exp:
                ok += 1
            else:
                bad += 1
                if first_bad is None:
                    first_bad = (idx, R, C, got, exp)
    print(f"offset={offset} oob={oob}: match {ok}/1024, first_bad={first_bad}")

print("\n--- standard (offset 0) ---")
test(0, 'zero')
print("\n--- +1 idiosyncratic (offset 1) ---")
test(1, 'zero')

# Detailed look at col=31 outputs for the +1 hypothesis
print("\n--- col=31 detail (offset 1, oob zero) ---")
for R in range(8):
    idx = R*32 + 31
    got = conv(R, 31, 1, 'zero')
    exp = gld(idx)
    print(f"  idx {idx:4d} (R={R:2d},C=31): got {got:6d} exp {exp:6d} {'OK' if got==exp else 'X diff='+str((got-exp))}")

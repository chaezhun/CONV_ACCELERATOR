# Diagnose: compute output (0,0) under several formulas, compare to golden[0]=10439
# and to v10-RTL's actual result 10116.
def load(fn):
    with open(fn,'rb') as f: return f.read()
img=load('image_0.bin'); fil=load('filter_2.bin'); gold=load('golden_2.bin')
def s8(b): return b-256 if b>=128 else b
def ifmap(ch,row,col): return s8(img[ch*9604+row*98+col])
def filt(i): return s8(fil[i])
g0 = gold[0]|(gold[1]<<8)
print("golden[0] (LE,BE):", g0, (gold[0]<<8)|gold[1])  # BE=10439

def dec(pos):
    ch=pos//25; r=pos%25; return ch, r//5, r%5

R=C=0
# 1) standard conv
s=0
for pos in range(75):
    ch,dr,dc=dec(pos); s+=ifmap(ch,3*R+dr,3*C+dc)*filt(pos)
print("standard           :", s & 0xFFFF)

# 2) v8 formula: element k=1..75: ifmap col=3C+dc(k-1)+1, filter index = k (k<75) else 0
s=0
for k in range(1,76):
    ch,dr,dc=dec(k-1)
    fi = k if k<75 else 0
    s+=ifmap(ch,3*R+dr,3*C+dc+1)*filt(fi)
print("v8 (col+1,filt[k]) :", s & 0xFFFF)

# 3) v10 model: element k: ifmap col=3C+dc(k-1), filter index = k-1
s=0
for k in range(1,76):
    ch,dr,dc=dec(k-1)
    s+=ifmap(ch,3*R+dr,3*C+dc)*filt(k-1)
print("v10 model(col,f[k-1]):", s & 0xFFFF)

# 4) variants to try to hit 10116 (RTL v10 actual)
# 4a: col=3C+dc, filter index = k (NOT k-1) -> ifmap std pos but filter shifted +1
s=0
for k in range(1,76):
    ch,dr,dc=dec(k-1); fi=k if k<75 else 0
    s+=ifmap(ch,3*R+dr,3*C+dc)*filt(fi)
print("4a col, filt[k]    :", s & 0xFFFF)

# 4b: col=3C+dc+1, filter index = k-1
s=0
for k in range(1,76):
    ch,dr,dc=dec(k-1)
    s+=ifmap(ch,3*R+dr,3*C+dc+1)*filt(k-1)
print("4b col+1, filt[k-1]:", s & 0xFFFF)

print("\n(target: golden 10439 ; v10-RTL gave 10116)")

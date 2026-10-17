import numpy as np;
def f(a: any) -> any { x: any = np.where(a, False, a >= 1); return x; }
with entry { print(f(np.zeros(3))); }

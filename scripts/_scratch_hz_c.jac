import numpy as np;
def f(a: any) -> any { x: any = np.degrees(a); return x; }
with entry { print(f(np.zeros(3))); }

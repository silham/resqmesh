import re;
import numpy as np;
import from resqmesh.graph.commitments { close as close_commitment }

obj A {
    has x: float, y: float, z: list[str] = [];
}

obj B {
    has items: list[int],
        cache: dict[str, int] = {},
        idx: dict[int, int] = {};

    def postinit {
        self.idx = {i: i for i in self.items};
    }
}

def f(a: int, *, b: int = 2) -> int { return a + b; }

with entry {
    a = A(1.0, 2.0, ["e"]);
    print(a.x, a.y, a.z);
    b1 = B(items=[1, 2]);
    b2 = B(items=[3]);
    b1.cache["k"] = 1;
    print(b2.cache, b1.idx);
    m: any = re.compile(r"forbid_pair:\s*(?P<v1>\S+?)\s*>\s*(?P<c1>\S+)|(?i:no)\s+(?P<v2>\S+)\s+(?i:to)\s+(?P<c2>\S+)");
    print(m.fullmatch("No V to C").group("v2"));
    d: any = np.arange(12).reshape(3, 4);
    print(d[1, np.array([0, 2])]);
    print(f(1, b=3));
    for (u, v, k) in [(1, 2, 3)] { print(u, v, k); }
    print(close_commitment);
}

"""Micro-benchmarks for m0-core hot paths.

Covers hashing (FNV-1a, xxHash32, wyhash64), SIMD batch hashing,
JSON escape, and hex formatting.

Usage:  pixi run bench-core
"""

from std.benchmark import Bench, Bencher, BenchId, BenchConfig
from src.hashing import fnv1a, xxhash32, wyhash64_string, fnv1a_batch, xxhash32_batch, format_hash32, format_hash64
from src.json_escape import escape_json_string


# --- Test data generators ---

fn _short_string() -> String:
    return String("hello_mojo")

fn _medium_string() -> String:
    var s = String("")
    for _ in range(10):
        s += "abcdefghij"  # 100 chars
    return s^

fn _long_string() -> String:
    var s = String("")
    for _ in range(100):
        s += "abcdefghij"  # 1000 chars
    return s^

fn _escape_heavy_string() -> String:
    var s = String("")
    for _ in range(50):
        s += 'key:"val"\tnew\n'  # lots of escapes
    return s^

fn _long_clean_string() -> String:
    var s = String("")
    for _ in range(1000):
        s += "abcdefghij"  # 10KB clean ASCII
    return s^

fn _batch_strings() -> List[String]:
    var strings = List[String]()
    for i in range(100):
        strings.append(String("effect.dom.query.") + String(i))
    return strings^


fn main() raises:
    var bench = Bench(BenchConfig())

    # --- FNV-1a ---
    var short = _short_string()
    var medium = _medium_string()
    var long = _long_string()

    @parameter
    fn bench_fnv1a_short(mut b: Bencher) raises:
        @parameter
        fn kernel():
            _ = fnv1a(short)
        b.iter[kernel]()

    @parameter
    fn bench_fnv1a_medium(mut b: Bencher) raises:
        @parameter
        fn kernel():
            _ = fnv1a(medium)
        b.iter[kernel]()

    @parameter
    fn bench_fnv1a_long(mut b: Bencher) raises:
        @parameter
        fn kernel():
            _ = fnv1a(long)
        b.iter[kernel]()

    # --- xxHash32 ---

    @parameter
    fn bench_xxhash32_short(mut b: Bencher) raises:
        @parameter
        fn kernel():
            _ = xxhash32(short)
        b.iter[kernel]()

    @parameter
    fn bench_xxhash32_medium(mut b: Bencher) raises:
        @parameter
        fn kernel():
            _ = xxhash32(medium)
        b.iter[kernel]()

    @parameter
    fn bench_xxhash32_long(mut b: Bencher) raises:
        @parameter
        fn kernel():
            _ = xxhash32(long)
        b.iter[kernel]()

    # --- wyhash64 ---

    @parameter
    fn bench_wyhash64_short(mut b: Bencher) raises:
        @parameter
        fn kernel():
            _ = wyhash64_string(short)
        b.iter[kernel]()

    @parameter
    fn bench_wyhash64_medium(mut b: Bencher) raises:
        @parameter
        fn kernel():
            _ = wyhash64_string(medium)
        b.iter[kernel]()

    @parameter
    fn bench_wyhash64_long(mut b: Bencher) raises:
        @parameter
        fn kernel():
            _ = wyhash64_string(long)
        b.iter[kernel]()

    # --- Batch hashing (SIMD) ---
    var batch = _batch_strings()

    @parameter
    fn bench_fnv1a_batch_100(mut b: Bencher) raises:
        @parameter
        fn kernel():
            _ = fnv1a_batch(batch)
        b.iter[kernel]()

    @parameter
    fn bench_xxhash32_batch_100(mut b: Bencher) raises:
        @parameter
        fn kernel():
            _ = xxhash32_batch(batch)
        b.iter[kernel]()

    # --- Hex formatting ---

    @parameter
    fn bench_format_hash32(mut b: Bencher) raises:
        @parameter
        fn kernel():
            _ = format_hash32(UInt32(0xDEADBEEF))
        b.iter[kernel]()

    @parameter
    fn bench_format_hash64(mut b: Bencher) raises:
        @parameter
        fn kernel():
            _ = format_hash64(UInt64(0xDEADBEEFCAFEBABE))
        b.iter[kernel]()

    # --- JSON escape ---
    var clean = _long_clean_string()
    var heavy = _escape_heavy_string()

    @parameter
    fn bench_json_escape_clean(mut b: Bencher) raises:
        @parameter
        fn kernel():
            _ = escape_json_string(short)
        b.iter[kernel]()

    @parameter
    fn bench_json_escape_heavy(mut b: Bencher) raises:
        @parameter
        fn kernel():
            _ = escape_json_string(heavy)
        b.iter[kernel]()

    @parameter
    fn bench_json_escape_long(mut b: Bencher) raises:
        @parameter
        fn kernel():
            _ = escape_json_string(clean)
        b.iter[kernel]()

    # --- Run all ---
    print("=== m0-core benchmarks ===\n")

    bench.bench_function[bench_fnv1a_short](BenchId("fnv1a/10B"))
    bench.bench_function[bench_fnv1a_medium](BenchId("fnv1a/100B"))
    bench.bench_function[bench_fnv1a_long](BenchId("fnv1a/1KB"))
    bench.bench_function[bench_xxhash32_short](BenchId("xxhash32/10B"))
    bench.bench_function[bench_xxhash32_medium](BenchId("xxhash32/100B"))
    bench.bench_function[bench_xxhash32_long](BenchId("xxhash32/1KB"))
    bench.bench_function[bench_wyhash64_short](BenchId("wyhash64/10B"))
    bench.bench_function[bench_wyhash64_medium](BenchId("wyhash64/100B"))
    bench.bench_function[bench_wyhash64_long](BenchId("wyhash64/1KB"))
    bench.bench_function[bench_fnv1a_batch_100](BenchId("fnv1a_batch/100x"))
    bench.bench_function[bench_xxhash32_batch_100](BenchId("xxhash32_batch/100x"))
    bench.bench_function[bench_format_hash32](BenchId("format_hash32"))
    bench.bench_function[bench_format_hash64](BenchId("format_hash64"))
    bench.bench_function[bench_json_escape_clean](BenchId("json_escape/10B_clean"))
    bench.bench_function[bench_json_escape_heavy](BenchId("json_escape/700B_heavy"))
    bench.bench_function[bench_json_escape_long](BenchId("json_escape/10KB_clean"))

    bench.dump_report()

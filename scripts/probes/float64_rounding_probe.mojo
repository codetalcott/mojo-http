"""Whether this toolchain's `Float64` parsing and printing round correctly.

Mojo 1.1's do not (docs/ROADMAP.md, Known issues): a shortest-form
decimal can parse to the double one unit in the last place from the one
it names, and a double between about 2e16 and 6e19 can print as text that
names its neighbour. This runs known misses of both kinds and exits 1
while any still misses, 0 when none does, and 2 when a control fails,
which means the probe itself cannot judge. The misses came from sweeping
60,000 random doubles' shortest forms and 73,656 doubles across every
exponent against CPython's correctly rounded `float()` and `repr()`.

The parser is judged by the bits each decimal names. The printer is
judged by libc's `strtod`, which rounds correctly on macOS and glibc,
reading back what Mojo printed, so a change of notation is not a miss. A
clean exit after a toolchain bump is the cue to sweep again before
retiring the issue, not proof on its own: these are a handful of cases.

Not a CI gate:

    uv run mojo run scripts/probes/float64_rounding_probe.mojo
"""

from std.ffi import external_call
from std.sys import exit


def _strtod(text: String) -> Float64:
    """Read `text` with libc's correctly rounded `strtod`."""
    var c = text
    var value = external_call["strtod", Float64](c.as_c_string_span().ptr(), 0)
    _ = c
    return value


def _parse_misses(cases: List[Tuple[String, UInt64]]) raises -> Int:
    """Count the decimals `Float64()` reads as a double other than the one named."""
    var misses = 0
    for pair in cases:
        var got = rebind[UInt64](Float64(pair[0]).to_bits())
        if got != pair[1]:
            misses += 1
            print("  parse:", pair[0], "->", hex(got), "where it names", hex(pair[1]))
    return misses


def _print_misses(cases: List[UInt64]) -> Int:
    """Count the doubles `String()` prints as text that names another double."""
    var misses = 0
    for bits in cases:
        var text = String(Float64(from_bits=bits))
        var back = rebind[UInt64](_strtod(text).to_bits())
        if back != bits:
            misses += 1
            print("  print:", hex(bits), "->", text, "which names", hex(back))
    return misses


def main() raises:
    # Controls every toolchain gets right: if one misses, the harness is wrong.
    var parse_controls: List[Tuple[String, UInt64]] = [
        (String("0.5"), UInt64(0x3FE0000000000000)),
        (String("1e22"), UInt64(0x4480F0CF064DD592)),
        (String("-2.5e-3"), UInt64(0xBF647AE147AE147B)),
    ]
    var print_controls: List[UInt64] = [
        UInt64(0x3FB999999999999A),  # 0.1
        UInt64(0x4340000000000000),  # 2**53
        UInt64(0x7FEFFFFFFFFFFFFF),  # the largest finite double
    ]
    print("controls:")
    if _parse_misses(parse_controls) + _print_misses(print_controls) > 0:
        print("a control missed: this probe cannot judge the toolchain")
        exit(2)
    print("  all pass")

    # Known misses on Mojo 1.1.0, each one unit in the last place.
    var parse_cases: List[Tuple[String, UInt64]] = [
        (String("1.270555243478764e-297"), UInt64(0x024A970DECED412F)),
        (String("1.703276648469858e-76"), UInt64(0x3033B8FC0FFBD30E)),
        (String("2.3914322253667574e+17"), UInt64(0x438A8CDBF36DED0D)),
        (String("-1.1401575076331948e+19"), UInt64(0xC3E3C75103F616D1)),
        (String("1.3819002211802669e+20"), UInt64(0x441DF71653D1216B)),
        (String("-8.032385101749752e+276"), UInt64(0xF96D000226A4C532)),
    ]
    var print_cases: List[UInt64] = [
        UInt64(0x435235A2D54B2365),  # 2.0502092240948628e+16
        UInt64(0x435C66EB97B82B4F),  # 3.1977845586701628e+16
        UInt64(0x43669BB4F6FE8F61),  # 5.0909208223447816e+16
        UInt64(0x4379B6F068D70DE9),  # 1.1580828936155099e+17
        UInt64(0x43F5F164C4A48B61),  # 2.5298491838731522e+19
    ]
    print("known misses:")
    var misses = _parse_misses(parse_cases) + _print_misses(print_cases)
    var total = len(parse_cases) + len(print_cases)
    if misses > 0:
        print(misses, "of", total, "known cases still miss: the defect is present")
        exit(1)
    print(
        "0 of", total, "known cases miss: sweep again before retiring the issue"
    )

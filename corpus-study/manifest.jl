"""
Corpus manifest for the Julia-asr corpus study. Unlike BEAM-asr's
30-file domain sample (Erlang/OTP is far too large to scan
exhaustively) or cpython-asr's 27-project sample, Julia's own standard
distribution is small enough to cover *exhaustively*: this is not a
hand-picked subset chosen for domain representativeness, it's all of
Base plus a broad, representative slice of the stdlib modules that ship
with every Julia install - avoiding "why these files" selection-bias
scrutiny entirely.

Each entry is `(dir, domain_tag, resolve_mod)` - `resolve_mod` is the
Julia expression (as a string, `eval`'d once) that produces the Module
Pass 2 should resolve candidate accumulator types in. Base files
resolve directly in `Base`; each stdlib module must be `using`'d first,
since (unlike Base) it isn't loaded into a fresh Julia session by
default.
"""

const BASE_DIR = "C:/Users/frank/AppData/Local/Programs/Julia-1.10.0/share/julia/base"
const STDLIB_DIR = "C:/Users/frank/AppData/Local/Programs/Julia-1.10.0/share/julia/stdlib/v1.10"

const STDLIB_MODULES = [
    ("LinearAlgebra", "numeric-linalg"),
    ("Statistics", "numeric-stats"),
    ("SparseArrays", "numeric-sparse"),
    ("Dates", "datetime"),
    ("Random", "random"),
    ("Printf", "formatting"),
    ("Sockets", "networking"),
    ("Serialization", "serialization"),
    ("Unicode", "text"),
    ("Logging", "diagnostics"),
    ("REPL", "tooling-repl"),
    ("Test", "testing-framework"),
]

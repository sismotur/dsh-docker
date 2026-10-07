## JPL-inspired coding standards

Follow these guidelines, not blindly — use judgment for trivial tasks.

1. Restrict to simple control flow. No `goto`, `setjmp()`, `longjmp()`.
2. Declare all variables at the top of a function. No mixing declarations and code.
3. Minimum two runtime checks per function (pre- and post-conditions: validate pointers, array bounds, return values).
4. Use a standard naming convention for variables and functions.
5. Use preprocessor for constants only. Never `#define` for macros. Use `const` variables. Avoid function-like macros.
6. No dynamic memory allocation after initialization. Allocate all memory at startup. `malloc()`/`free()` can fail, fragment, leak, or corrupt heap.
7. No recursion. Unbounded recursion causes stack overflow.
8. Limit function length to 100 lines.
9. Minimum 80% code coverage with unit testing.
10. Compile with all warnings enabled. Treat warnings as errors.

# Compatibility and validation limits

## Rewrite status

The Rust policy tests and original-implementation characterization tests cover section predicates, identity coding, movement restrictions, classic visibility transitions, and native event construction. They do not establish end-to-end feature parity.

Before the legacy-removal cleanup, native runtime validation at `0dcda2f5d6411e5c772a3af134bc4679de8080b8` failed during synthetic item movement. macOS 15 did not reach the expected final position. macOS 26 timed out. These are unresolved application defects, not passing or disabled tests. Consult PR #1 and the Native macOS workflow for subsequent results.

## Private macOS behavior

The rewrite retains private WindowServer calls, synthetic menu-bar events, and status-item hosting integration. OS changes can invalidate these mechanisms. Successful compilation, a Rust test, or a hide/show fixture alone does not prove that third-party items can be moved or clicked safely on that OS.

Tests that require Accessibility permission report whether it is available. A run that skips live input validation must not be described as proving movement or click delivery. Tests under a debugger can have different permission behavior from the ordinary process.

Multi-display layouts, notched displays, fullscreen Spaces, sleep/wake, third-party item popups, permissions changing during a session, and recovery after an interrupted move still require their own validation. Do not infer their results from a small CI fixture.

## Configuration and attribution

Settings may import recognized keys from the original `com.jordanbaird.Ice` preferences domain. Those identifiers are deliberate migration inputs, not references to deleted source files. The original application remains available at the pinned Git commit for regression testing and rollback.

The old theme and appearance system is not part of the replacement. LICENSE and NOTICE remain required distribution files.

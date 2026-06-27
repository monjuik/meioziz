# Meioziz

Tiny privacy-first event stats for indie apps. Zig + SQLite. No user tracking.

## What's in this name?

This app is very tiny, the events are tiny – as amoeba. Meiosis is a their reproduction.

## How to use

`zig build run`

## How to test

`zig build test`

## How to build

1. in main.zig use `smp_allocator` instead of `DebugAllocator`
2. `zig build -Doptimize=ReleaseSafe`

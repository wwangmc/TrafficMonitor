# Third-party code

Sources/TMRebind.c and Sources/fishhook.h are derived from https://github.com/facebook/fishhook (main retrieved 2026-10-27). Original source blob fb41e8eccca3c247f647b7a8770da3b910ee88fd; header blob 0d8e36a990cf2820a861e9c3f64e29b8d0b09260. BSD license preserved in both source files and fishhook.txt. Local changes prefix exported rebinding functions with tm_ and exclude TrafficMonitor.dylib itself from rebinding. Only indirect imported symbol pointers are covered; no guarantee for authenticated/chained fixups or direct syscalls.

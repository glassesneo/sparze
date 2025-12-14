# System Functions

**Location**: `src/system/system.zig`

**Responsibility**: System function execution with compile-time parameter injection. CANNOT directly accept `World` as parameter.

**Return Types**:
- `void` - No errors
- `!void` - Can propagate errors (World.runSystem will `try`)

**Parameter Injection**:
1. Query Filters: `SingleQuery(T)`, `SingleTag(T)`, `Query(...)`, `TagQuery(...)`, `Group(...)`
2. `Resource(T)` / `ResourceMut(T)` - Global singleton access
3. `EventWriter(E)` / `EventReader(E)` - Frame-delayed event communication
4. `Commands` - `anytype` parameter receives `Commands(World)` for deferred operations
5. `Allocator` - `std.mem.Allocator`

**Commands Timing**:
| Operation | Timing | Reason |
|-----------|--------|--------|
| `createEntity()` | Immediate | Need ID for subsequent commands |
| Resource ops | Immediate | Global state access |
| Component ops | Deferred | Safe during iteration |
| `destroyEntity()` | Deferred | Safe during iteration |

**CRITICAL Pattern**: ALWAYS use Commands during iteration, NEVER mutate World directly (invalidates iterators).

**CommandBuffer Safety**:
- Entity liveness validated during flush (at `endFrame()`)
- Zombie entity prevention: Component ops skipped if entity destroyed
- Version checking handles entity recycling

**Frame Lifecycle**:
```
beginFrame() → swap event buffers, clear write buffer
runSystem(...)  → queue Commands, write events, read previous frame's events
endFrame() → flush CommandBuffer (execute deferred ops)
```

**Resource Safety**: MUST initialize resources at startup (`initResources()`). Uninitialized access panics in Debug/ReleaseSafe.

**Detailed Documentation**: @docs/SYSTEM_PATTERNS.md - full examples, Commands API reference, patterns, frame lifecycle, pitfalls

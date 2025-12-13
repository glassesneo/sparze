# Storage

**Location**: `src/storage/`

**Responsibility**: Component and event storage with automatic type-based selection.

**Storage Selection**:
- Zero-sized components → `TagStorage` (bitset + reverse indices)
- Non-zero components → `SparseSet(T)` (sparse array + dense packed arrays)
- Events → `EventStorage(E)` (double-buffered queues)

**SparseSet - Critical Behaviors**:
- Pagination: 4096 entities/page, 16 pages max (65,536 entities total)
- Group layout: First `group_size` elements reserved for group entities
- `remove()` does NOT validate entity has component
- `get/getPtr/getPtrMut()` return null if the entity doesn't have the component (caller must handle absence)
- Memory: ~512 KB sparse max (on-demand pages), dense linear with entity count

**TagStorage - Memory Efficiency**:
- Structure: Paged bitset (512 bytes) + reverse indices (16 KB) per page
- ~98% memory reduction vs. non-paged for sparse distributions
- Best for markers: Enemy, Dead, Selected, Active, Disabled

**EventStorage - Frame Delay**:
- 1-frame latency by design (write Frame N, read Frame N+1)
- `beginFrame()` swaps buffers, `endFrame()` flushes commands

**CRITICAL**: Pre-allocate with `reserve()` before bulk operations for performance.

**Detailed Documentation**: @docs/STORAGE_INTERNALS.md - internal structures, pagination, group mechanics, memory calculations

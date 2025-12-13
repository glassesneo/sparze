# Entity System

**Location**: `src/entity/entity.zig`

**Responsibility**: 32-bit entity lifecycle management with version-based recycling.

**Structure**: Entity = packed struct(u32) with two u16 fields:
- `index` (lower 16 bits): dense slot index 0-65,534
- `version` (upper 16 bits): generation guard for stale handle detection

**API**:
- `Entity.init(index, version)` - Create entity from components
- `Entity.toInt()` - Convert to u32 for serialization
- `Entity.fromInt(u32)` - Create from u32 for deserialization
- `getIndex(entity)` / `getVersion(entity)` - Extract fields

**Key Behaviors**:
- Free list recycling: Destroyed entity index recycled with incremented version
- Old entity IDs become invalid after destruction (version mismatch)
- Version wraparound after 65,535 recycles at same index (rare)
- Fixed memory footprint: 65,535 entities × u32 ≈ 256 KB (capacity ≈65,535)

**CRITICAL Constraint**: `destroy()` does NOT validate entity is alive - caller (World/CommandBuffer) must ensure validity.

**Integration**: World wraps EntityRegistry, component storages indexed by entity, version checking prevents use-after-free.

**Detailed Documentation**: @docs/ENTITY_LIFECYCLE.md - creation/destruction flows, recycling mechanism, safety guarantees

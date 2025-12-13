# Entity System

**Location**: `src/entity/entity.zig`

**Responsibility**: 32-bit entity lifecycle management with version-based recycling.

**Structure**: Entity = 32-bit ID (lower 16 bits: index 0-65,534, upper 16 bits: version)

**Key Behaviors**:
- Free list recycling: Destroyed entity index recycled with incremented version
- Old entity IDs become invalid after destruction (version mismatch)
- Version wraparound after 65,535 recycles at same index (rare)
- Fixed memory footprint: 65,535 entities × u32 ≈ 256 KB (capacity ≈65,535)

**CRITICAL Constraint**: `destroy()` does NOT validate entity is alive - caller (World/CommandBuffer) must ensure validity.

**Integration**: World wraps EntityRegistry, component storages indexed by entity, version checking prevents use-after-free.

**Detailed Documentation**: @docs/ENTITY_LIFECYCLE.md - creation/destruction flows, recycling mechanism, safety guarantees

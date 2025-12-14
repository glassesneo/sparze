# Query Filters

**Location**: `src/query/filter.zig`

**Responsibility**: Compile-time type-safe entity iteration via parameter injection.

**Filter Types**:
| Filter | Setup | Modifiers | Access | Performance |
|--------|-------|-----------|--------|-------------|
| `SingleQuery(T)` | No | No | Direct array | Fastest |
| `SingleTag(T)` | No | No | Direct array | Fastest |
| `Query(struct {...})` | No | Optional, Exclude | Sparse lookup + filter | Good |
| `TagQuery(struct {...})` | No | Optional, Exclude | Bitset lookup | Good |
| `Group(struct {...})` | Compile-time | Free | Direct (owned), sparse (free) | Fastest |

**Entity Liveness Validation**:
- **Debug/ReleaseSafe**: Automatic validation (`isAlive()` check) prevents iteration over destroyed entities
- **ReleaseFast**: Validation compiled out (zero overhead)

**Group Types**:
- **Full-owning**: `struct { A, B }` - All components owned, organized, direct array access
- **Partial-owning**: `struct { A, Free(B) }` - Some owned (organized), some free (sparse lookup), allows component sharing

**Filter Modifiers**:
- `?T` (Optional): Match entities with or without component, access via `getOptional()`
- `Exclude(T)`: Filter out entities with component
- `Free(T)` (Group only): Mark component as free (not owned), required but not organized

**Special Iterators**:
- `combinations()`: Unique pairs (i < j) for collision detection
- `crossProduct(&other)`: N×M pairs for asymmetric interactions

**CRITICAL**: Groups are defined at compile-time in World signature. Ownership conflicts detected at compile-time via `World.validateGroups()`.

**Best Practices**: Use Group for hot paths, Query for flexibility, SingleQuery for single components.

**Detailed Documentation**: @docs/QUERY_PATTERNS.md - decision flowchart, performance comparison, patterns, component sharing

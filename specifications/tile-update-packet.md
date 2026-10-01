# Tile update packet v1

`drain_tile_updates` returns a compact little-endian binary packet. It is a
control-plane notification: tile pixels remain in separate `read_tile` calls
and are never embedded in this packet.

## Header (8 bytes)

| Offset | Type | Meaning |
|---:|---|---|
| 0 | `u16` | Packet version, currently `1` |
| 2 | `u16` | Flags; bit `0` means the visible cache must be fully redrawn |
| 4 | `u32` | Number of records |

## Record (32 bytes)

| Offset | Type | Meaning |
|---:|---|---|
| 0 | `u64` | Document revision that dirtied the tile |
| 8 | `u128` | Stable layer ID |
| 24 | `i32` | Tile X coordinate |
| 28 | `i32` | Tile Y coordinate |

Records are sorted and deduplicated by `(revision, layer, x, y)`. A layer-tree
or compositing change sets the full-redraw flag; consumers must not assume that
the record list alone describes the affected pixels in that case. Unchanged
tiles may be promoted to the newest revision in the Flutter cache until they
are replaced by a later record.

//! Deterministic sparse 256x256 premultiplied BGRA raster tiles.
#![allow(missing_docs)]
#![allow(
    clippy::missing_errors_doc,
    clippy::missing_panics_doc,
    clippy::must_use_candidate,
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    clippy::cast_precision_loss
)]

use ink_model::Rgba8;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;

/// Fixed tile edge required by the v1 renderer.
pub const TILE_SIZE: u32 = 256;
const PIXELS_PER_TILE: usize = (TILE_SIZE * TILE_SIZE) as usize;

/// Tile coordinate in document space.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
pub struct TileCoord {
    pub x: i32,
    pub y: i32,
}

/// Premultiplied BGRA tile bytes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Tile {
    // Layer history snapshots clone Tile values frequently. Sharing immutable
    // pixel buffers keeps those snapshots cheap; mutation detaches on write.
    bytes: Arc<Vec<u8>>,
}

impl Default for Tile {
    fn default() -> Self {
        Self {
            bytes: Arc::new(vec![0; PIXELS_PER_TILE * 4]),
        }
    }
}

impl Tile {
    /// Construct a tile from a complete BGRA8888 payload.
    pub fn from_bytes(bytes: Vec<u8>) -> Result<Self, RasterError> {
        if bytes.len() != PIXELS_PER_TILE * 4 {
            return Err(RasterError::InvalidTileLength);
        }
        Ok(Self {
            bytes: Arc::new(bytes),
        })
    }

    /// Return bytes in on-screen BGRA order.
    #[must_use]
    pub fn bytes(&self) -> &[u8] {
        &self.bytes
    }

    /// Stable FNV-1a hash used by cross-architecture replay tests.
    #[must_use]
    pub fn stable_hash(&self) -> u64 {
        self.bytes.iter().fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
            (hash ^ u64::from(*byte)).wrapping_mul(0x0100_0000_01b3)
        })
    }

    /// Blend one premultiplied source pixel using integer source-over.
    pub fn blend_pixel(&mut self, x: u32, y: u32, source: Rgba8, opacity: u16) {
        if x >= TILE_SIZE || y >= TILE_SIZE {
            return;
        }
        let bytes = Arc::make_mut(&mut self.bytes);
        let offset = ((y * TILE_SIZE + x) * 4) as usize;
        let alpha = (u32::from(source.a) * u32::from(opacity) + 32_767) / 65_535;
        let inv = 255 - alpha;
        // Convert straight RGBA input to premultiplied BGRA before blending.
        let sb = (u32::from(source.b) * alpha + 127) / 255;
        let sg = (u32::from(source.g) * alpha + 127) / 255;
        let sr = (u32::from(source.r) * alpha + 127) / 255;
        for (index, value) in [(0, sb), (1, sg), (2, sr)] {
            bytes[offset + index] = value
                .saturating_add((u32::from(bytes[offset + index]) * inv + 127) / 255)
                .min(255) as u8;
        }
        bytes[offset + 3] = alpha
            .saturating_add((u32::from(bytes[offset + 3]) * inv + 127) / 255)
            .min(255) as u8;
    }

    /// Erase one pixel while preserving deterministic tile storage.
    pub fn erase_pixel(&mut self, x: u32, y: u32) {
        if x >= TILE_SIZE || y >= TILE_SIZE {
            return;
        }
        let bytes = Arc::make_mut(&mut self.bytes);
        let offset = ((y * TILE_SIZE + x) * 4) as usize;
        bytes[offset..offset + 4].fill(0);
    }

    /// Read one pixel as straight-alpha RGBA for bounded pickup/smudge tools.
    #[must_use]
    pub fn pixel_rgba(&self, x: u32, y: u32) -> Rgba8 {
        if x >= TILE_SIZE || y >= TILE_SIZE {
            return Rgba8::default();
        }
        let offset = ((y * TILE_SIZE + x) * 4) as usize;
        let alpha = self.bytes[offset + 3];
        if alpha == 0 {
            return Rgba8::default();
        }
        let unpremultiply = |value: u8| (u32::from(value) * 255 / u32::from(alpha)).min(255) as u8;
        Rgba8 {
            r: unpremultiply(self.bytes[offset + 2]),
            g: unpremultiply(self.bytes[offset + 1]),
            b: unpremultiply(self.bytes[offset]),
            a: alpha,
        }
    }
}

/// Raster payload validation errors.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RasterError {
    InvalidTileLength,
    InvalidTransform,
}

/// Sparse document raster with dirty tracking and copy-on-write tile snapshots.
#[derive(Clone, Debug, Default)]
pub struct TileStore {
    // History snapshots share the sparse index and detach it on first write.
    // Tile pixel buffers have their own copy-on-write Arc inside `Tile`.
    tiles: Arc<HashMap<TileCoord, Tile>>,
    dirty: Arc<HashSet<TileCoord>>,
}

impl TileStore {
    /// Iterate allocated tile coordinates without cloning tile pixel storage.
    pub fn coordinates(&self) -> impl Iterator<Item = TileCoord> + '_ {
        self.tiles.keys().copied()
    }

    /// Clone only the requested tile handles into an immutable sparse
    /// snapshot. Pixel storage stays shared until either store mutates it,
    /// when that store detaches its copy. Callers use this to release document
    /// locks before running expensive compositing work over those pixels.
    #[must_use]
    pub fn snapshot_tiles(&self, coordinates: &[TileCoord]) -> Self {
        let mut snapshot = Self::default();
        for coordinate in coordinates {
            if let Some(tile) = self.tiles.get(coordinate) {
                Arc::make_mut(&mut snapshot.tiles).insert(*coordinate, tile.clone());
            }
        }
        // Some layer-tree decisions depend on whether a mask has any tiles
        // anywhere in the document, even when this requested coordinate is
        // transparent. Preserve that global allocated/non-allocated bit with
        // a transparent sentinel at the first requested coordinate.
        if snapshot.tiles.is_empty()
            && !self.tiles.is_empty()
            && let Some(coordinate) = coordinates.first()
        {
            Arc::make_mut(&mut snapshot.tiles).insert(*coordinate, Tile::default());
        }
        snapshot
    }

    /// Read a tile, returning a transparent tile for untouched coordinates.
    #[must_use]
    pub fn read(&self, coord: TileCoord) -> Tile {
        self.tiles.get(&coord).cloned().unwrap_or_default()
    }

    /// Read one document pixel without allocating a tile in the sparse store.
    #[must_use]
    pub fn sample_pixel(&self, x: u32, y: u32) -> Rgba8 {
        let coord = TileCoord {
            x: i32::try_from(x / TILE_SIZE).unwrap_or(i32::MAX),
            y: i32::try_from(y / TILE_SIZE).unwrap_or(i32::MAX),
        };
        self.tiles.get(&coord).map_or_else(Rgba8::default, |tile| {
            tile.pixel_rgba(x % TILE_SIZE, y % TILE_SIZE)
        })
    }

    /// Blend a pixel and mark the containing tile dirty.
    pub fn blend_pixel(&mut self, x: u32, y: u32, source: Rgba8, opacity: u16) -> TileCoord {
        let coord = TileCoord {
            x: i32::try_from(x / TILE_SIZE).unwrap_or(i32::MAX),
            y: i32::try_from(y / TILE_SIZE).unwrap_or(i32::MAX),
        };
        let tile = Arc::make_mut(&mut self.tiles).entry(coord).or_default();
        tile.blend_pixel(x % TILE_SIZE, y % TILE_SIZE, source, opacity);
        Arc::make_mut(&mut self.dirty).insert(coord);
        coord
    }

    /// Erase a pixel and mark its containing tile dirty.
    pub fn erase_pixel(&mut self, x: u32, y: u32) -> TileCoord {
        let coord = TileCoord {
            x: i32::try_from(x / TILE_SIZE).unwrap_or(i32::MAX),
            y: i32::try_from(y / TILE_SIZE).unwrap_or(i32::MAX),
        };
        if let Some(tile) = Arc::make_mut(&mut self.tiles).get_mut(&coord) {
            tile.erase_pixel(x % TILE_SIZE, y % TILE_SIZE);
            Arc::make_mut(&mut self.dirty).insert(coord);
        }
        coord
    }

    /// Replace one pixel with a straight-alpha RGBA value and mark the tile
    /// dirty. This is used by undoable bucket/gradient operations that must
    /// not accumulate source-over opacity on every visited pixel.
    pub fn set_pixel(&mut self, x: u32, y: u32, source: Rgba8) -> TileCoord {
        let coord = TileCoord {
            x: i32::try_from(x / TILE_SIZE).unwrap_or(i32::MAX),
            y: i32::try_from(y / TILE_SIZE).unwrap_or(i32::MAX),
        };
        let tile = Arc::make_mut(&mut self.tiles).entry(coord).or_default();
        let bytes = Arc::make_mut(&mut tile.bytes);
        let offset = (((y % TILE_SIZE) * TILE_SIZE + (x % TILE_SIZE)) * 4) as usize;
        let alpha = source.a;
        bytes[offset] = (u16::from(source.b) * u16::from(alpha) / 255) as u8;
        bytes[offset + 1] = (u16::from(source.g) * u16::from(alpha) / 255) as u8;
        bytes[offset + 2] = (u16::from(source.r) * u16::from(alpha) / 255) as u8;
        bytes[offset + 3] = alpha;
        Arc::make_mut(&mut self.dirty).insert(coord);
        coord
    }

    /// Return and clear all dirty coordinates in stable order.
    pub fn take_dirty(&mut self) -> Vec<TileCoord> {
        let mut result: Vec<_> = Arc::make_mut(&mut self.dirty).drain().collect();
        result.sort_unstable_by_key(|coord| (coord.y, coord.x));
        result
    }

    /// Capture tiles before a command mutates them.
    #[must_use]
    pub fn snapshot(&self, coords: impl IntoIterator<Item = TileCoord>) -> Vec<(TileCoord, Tile)> {
        coords
            .into_iter()
            .map(|coord| (coord, self.read(coord)))
            .collect()
    }

    /// Restore a prior snapshot and mark the affected region dirty.
    pub fn restore(&mut self, snapshot: impl IntoIterator<Item = (TileCoord, Tile)>) {
        for (coord, tile) in snapshot {
            Arc::make_mut(&mut self.tiles).insert(coord, tile);
            Arc::make_mut(&mut self.dirty).insert(coord);
        }
    }

    /// Number of allocated tiles.
    #[must_use]
    pub fn allocated_tiles(&self) -> usize {
        self.tiles.len()
    }

    /// Return a conservative estimate of serialized tile payload storage
    /// without copying pixel buffers. Shared history snapshots are counted
    /// independently so existing history limits remain conservative.
    #[must_use]
    pub fn estimated_payload_bytes(&self) -> usize {
        self.tiles
            .iter()
            .fold(0usize, |total, (_coordinate, tile)| {
                total
                    .saturating_add(std::mem::size_of::<TileCoord>())
                    .saturating_add(std::mem::size_of::<Vec<u8>>())
                    .saturating_add(tile.bytes.len())
            })
    }

    /// Count unique retained pixel-buffer bytes across current and history stores.
    ///
    /// Shared copy-on-write allocations are counted once. This excludes sparse
    /// indices, allocator overhead, and process RSS; use it for history payload
    /// measurements rather than the conservative document admission budget.
    #[must_use]
    pub fn retained_pixel_bytes(stores: &[Self]) -> usize {
        let mut buffers = std::collections::HashSet::new();
        stores
            .iter()
            .flat_map(|store| store.tiles.values())
            .fold(0usize, |total, tile| {
                if buffers.insert(Arc::as_ptr(&tile.bytes)) {
                    total.saturating_add(tile.bytes.len())
                } else {
                    total
                }
            })
    }

    /// Return allocated coordinates in stable order without copying pixels.
    #[must_use]
    pub fn allocated_coordinates(&self) -> Vec<TileCoord> {
        let mut coordinates: Vec<_> = self.tiles.keys().copied().collect();
        coordinates.sort_unstable_by_key(|coordinate| (coordinate.y, coordinate.x));
        coordinates
    }

    /// Remove all allocated tiles and pending dirty markers.
    pub fn clear(&mut self) {
        Arc::make_mut(&mut self.tiles).clear();
        Arc::make_mut(&mut self.dirty).clear();
    }

    /// Copy all allocated tile payloads in stable coordinate order.
    #[must_use]
    pub fn tiles(&self) -> Vec<(TileCoord, Vec<u8>)> {
        let mut tiles: Vec<_> = self
            .tiles
            .iter()
            .map(|(coordinate, tile)| (*coordinate, tile.bytes.as_ref().clone()))
            .collect();
        tiles.sort_unstable_by_key(|(coordinate, _)| (coordinate.y, coordinate.x));
        tiles
    }

    /// Apply a finite affine transform to all non-transparent pixels while
    /// keeping the raster sparse and bounded to the document canvas.
    ///
    /// This intentionally uses deterministic nearest-neighbour forward
    /// mapping for the Phase 2 editing path. Higher quality resampling can be
    /// added later without changing the command or file format.
    #[allow(clippy::too_many_arguments)]
    pub fn transform_affine(
        &mut self,
        width_px: u32,
        height_px: u32,
        a: f32,
        b: f32,
        c: f32,
        d: f32,
        tx: f32,
        ty: f32,
    ) -> Result<Vec<TileCoord>, RasterError> {
        let values = [a, b, c, d, tx, ty];
        if width_px == 0
            || height_px == 0
            || values.iter().any(|value| !value.is_finite())
            || values.iter().any(|value| value.abs() > 1_000_000.0)
            || (a * d - b * c).abs() < 1.0e-6
        {
            return Err(RasterError::InvalidTransform);
        }
        Ok(
            self.transform_with_mapper(width_px, height_px, |source_x, source_y| {
                (
                    a * source_x + c * source_y + tx,
                    b * source_x + d * source_y + ty,
                )
            }),
        )
    }

    /// Apply a bounded bilinear perspective transform from the full canvas
    /// rectangle into a target quadrilateral. Mapping is deterministic
    /// nearest-neighbour forward sampling, matching affine transforms.
    pub fn transform_perspective(
        &mut self,
        width_px: u32,
        height_px: u32,
        target: [(f32, f32); 4],
    ) -> Result<Vec<TileCoord>, RasterError> {
        if width_px == 0 || height_px == 0 {
            return Err(RasterError::InvalidTransform);
        }
        if target.iter().any(|(x, y)| !x.is_finite() || !y.is_finite())
            || target
                .iter()
                .any(|(x, y)| x.abs() > 4_000_000.0 || y.abs() > 4_000_000.0)
        {
            return Err(RasterError::InvalidTransform);
        }
        let area = target
            .iter()
            .zip(target.iter().cycle().skip(1))
            .take(4)
            .map(|(left, right)| left.0 * right.1 - right.0 * left.1)
            .sum::<f32>()
            .abs();
        if area < 1.0e-3 {
            return Err(RasterError::InvalidTransform);
        }
        let width = (width_px.saturating_sub(1)).max(1) as f32;
        let height = (height_px.saturating_sub(1)).max(1) as f32;
        Ok(
            self.transform_with_mapper(width_px, height_px, move |source_x, source_y| {
                let u = (source_x / width).clamp(0.0, 1.0);
                let v = (source_y / height).clamp(0.0, 1.0);
                let lerp = |left: (f32, f32), right: (f32, f32), amount: f32| {
                    (
                        left.0 + (right.0 - left.0) * amount,
                        left.1 + (right.1 - left.1) * amount,
                    )
                };
                let top = lerp(target[0], target[1], u);
                let bottom = lerp(target[3], target[2], u);
                lerp(top, bottom, v)
            }),
        )
    }

    /// Apply a bounded regular bilinear mesh transform. Mesh control points
    /// are row-major destination coordinates and must contain exactly
    /// `columns * rows` entries.
    pub fn transform_mesh(
        &mut self,
        width_px: u32,
        height_px: u32,
        columns: u16,
        rows: u16,
        points: &[(f32, f32)],
    ) -> Result<Vec<TileCoord>, RasterError> {
        if !(2..=32).contains(&columns)
            || !(2..=32).contains(&rows)
            || points.len() != usize::from(columns) * usize::from(rows)
            || points.iter().any(|(x, y)| {
                !x.is_finite() || !y.is_finite() || x.abs() > 4_000_000.0 || y.abs() > 4_000_000.0
            })
            || width_px == 0
            || height_px == 0
        {
            return Err(RasterError::InvalidTransform);
        }
        let source_width = (width_px.saturating_sub(1)).max(1) as f32;
        let source_height = (height_px.saturating_sub(1)).max(1) as f32;
        let columns_usize = usize::from(columns);
        let rows_usize = usize::from(rows);
        Ok(
            self.transform_with_mapper(width_px, height_px, |source_x, source_y| {
                let u = (source_x / source_width).clamp(0.0, 1.0);
                let v = (source_y / source_height).clamp(0.0, 1.0);
                let grid_x = u * f32::from(columns - 1);
                let grid_y = v * f32::from(rows - 1);
                let left = grid_x.floor() as usize;
                let top = grid_y.floor() as usize;
                let right = (left + 1).min(columns_usize - 1);
                let bottom = (top + 1).min(rows_usize - 1);
                let fx = grid_x - left as f32;
                let fy = grid_y - top as f32;
                let at = |column: usize, row: usize| points[row * columns_usize + column];
                let lerp = |start: (f32, f32), end: (f32, f32), amount: f32| {
                    (
                        start.0 + (end.0 - start.0) * amount,
                        start.1 + (end.1 - start.1) * amount,
                    )
                };
                let upper = lerp(at(left, top), at(right, top), fx);
                let lower = lerp(at(left, bottom), at(right, bottom), fx);
                lerp(upper, lower, fy)
            }),
        )
    }

    /// Apply a bounded local liquify deformation. Mode `0` pushes pixels,
    /// `1` expands, `2` contracts, and `3` applies a twirl.
    #[allow(clippy::too_many_arguments)]
    pub fn transform_liquify(
        &mut self,
        width_px: u32,
        height_px: u32,
        center_x: f32,
        center_y: f32,
        radius: f32,
        strength: f32,
        mode: u8,
        direction_x: f32,
        direction_y: f32,
    ) -> Result<Vec<TileCoord>, RasterError> {
        let values = [
            center_x,
            center_y,
            radius,
            strength,
            direction_x,
            direction_y,
        ];
        if width_px == 0
            || height_px == 0
            || radius <= 0.0
            || radius > 4_000_000.0
            || !values.iter().all(|value| value.is_finite())
            || !matches!(mode, 0..=3)
        {
            return Err(RasterError::InvalidTransform);
        }
        Ok(
            self.transform_with_mapper(width_px, height_px, move |source_x, source_y| {
                let dx = source_x - center_x;
                let dy = source_y - center_y;
                let distance = dx.hypot(dy);
                if distance >= radius {
                    return (source_x, source_y);
                }
                let falloff = (1.0 - distance / radius).powi(2) * strength.clamp(-1.0, 1.0);
                match mode {
                    0 => (
                        source_x + direction_x * falloff,
                        source_y + direction_y * falloff,
                    ),
                    1 => (
                        center_x + dx * (1.0 + falloff),
                        center_y + dy * (1.0 + falloff),
                    ),
                    2 => (
                        center_x + dx * (1.0 - falloff),
                        center_y + dy * (1.0 - falloff),
                    ),
                    _ => {
                        let angle = falloff * std::f32::consts::PI;
                        let (sin, cos) = angle.sin_cos();
                        (
                            center_x + dx * cos - dy * sin,
                            center_y + dx * sin + dy * cos,
                        )
                    }
                }
            }),
        )
    }

    fn transform_with_mapper(
        &mut self,
        width_px: u32,
        height_px: u32,
        mapper: impl Fn(f32, f32) -> (f32, f32),
    ) -> Vec<TileCoord> {
        let width = i64::from(width_px);
        let height = i64::from(height_px);
        let old_tiles = std::mem::take(Arc::make_mut(&mut self.tiles));
        let mut transformed = HashMap::new();
        let mut dirty = std::mem::take(Arc::make_mut(&mut self.dirty));
        dirty.extend(old_tiles.keys().copied());
        for (coordinate, tile) in old_tiles {
            for local_y in 0..TILE_SIZE {
                let source_y = i64::from(coordinate.y) * i64::from(TILE_SIZE) + i64::from(local_y);
                if source_y < 0 || source_y >= height {
                    continue;
                }
                for local_x in 0..TILE_SIZE {
                    let source_x =
                        i64::from(coordinate.x) * i64::from(TILE_SIZE) + i64::from(local_x);
                    if source_x < 0 || source_x >= width {
                        continue;
                    }
                    let source_offset = ((local_y * TILE_SIZE + local_x) * 4) as usize;
                    let source_alpha = tile.bytes[source_offset + 3];
                    if source_alpha == 0 {
                        continue;
                    }
                    let (mapped_x, mapped_y) = mapper(source_x as f32, source_y as f32);
                    let dest_x = mapped_x.round();
                    let dest_y = mapped_y.round();
                    if !dest_x.is_finite()
                        || !dest_y.is_finite()
                        || dest_x < 0.0
                        || dest_y < 0.0
                        || dest_x >= width_px as f32
                        || dest_y >= height_px as f32
                    {
                        continue;
                    }
                    let dest_x = dest_x as u32;
                    let dest_y = dest_y as u32;
                    let dest_coord = TileCoord {
                        x: i32::try_from(dest_x / TILE_SIZE).unwrap_or(i32::MAX),
                        y: i32::try_from(dest_y / TILE_SIZE).unwrap_or(i32::MAX),
                    };
                    let dest_tile = transformed.entry(dest_coord).or_insert_with(Tile::default);
                    let dest_offset =
                        (((dest_y % TILE_SIZE) * TILE_SIZE + (dest_x % TILE_SIZE)) * 4) as usize;
                    // Forward mapping can converge several source pixels on
                    // one destination pixel. Keep the first deterministic
                    // sample rather than repeatedly blending premultiplied
                    // bytes and changing opacity.
                    if dest_tile.bytes[dest_offset + 3] == 0 {
                        Arc::make_mut(&mut dest_tile.bytes)[dest_offset..dest_offset + 4]
                            .copy_from_slice(&tile.bytes[source_offset..source_offset + 4]);
                    }
                }
            }
        }
        dirty.extend(transformed.keys().copied());
        self.tiles = Arc::new(transformed);
        self.dirty = Arc::new(dirty);
        let mut dirty_coordinates: Vec<_> = self.dirty.iter().copied().collect();
        dirty_coordinates.sort_unstable_by_key(|coordinate| (coordinate.y, coordinate.x));
        dirty_coordinates
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn blend_is_deterministic_and_dirty() {
        let mut store = TileStore::default();
        let coord = store.blend_pixel(
            1,
            2,
            Rgba8 {
                r: 255,
                g: 0,
                b: 0,
                a: 255,
            },
            u16::MAX,
        );
        assert_eq!(coord, TileCoord { x: 0, y: 0 });
        let tile = store.read(coord);
        let offset = ((2 * TILE_SIZE + 1) * 4) as usize;
        assert_eq!(&tile.bytes()[offset..offset + 4], &[0, 0, 255, 255]);
        assert_eq!(store.take_dirty(), vec![coord]);
    }
    #[test]
    fn untouched_tiles_are_sparse() {
        assert_eq!(TileStore::default().allocated_tiles(), 0);
    }

    #[test]
    fn cloned_stores_share_tiles_until_mutation_then_remain_isolated() {
        let mut store = TileStore::default();
        store.set_pixel(
            3,
            4,
            Rgba8 {
                r: 255,
                g: 0,
                b: 0,
                a: 255,
            },
        );
        let snapshot = store.clone();

        store.set_pixel(
            3,
            4,
            Rgba8 {
                r: 0,
                g: 0,
                b: 255,
                a: 255,
            },
        );

        assert_eq!(store.sample_pixel(3, 4).b, 255);
        assert_eq!(snapshot.sample_pixel(3, 4).r, 255);
    }

    #[test]
    fn history_clone_shares_sparse_maps_and_detaches_only_mutated_data() {
        let mut original = TileStore::default();
        original.set_pixel(
            2,
            3,
            Rgba8 {
                r: 255,
                g: 0,
                b: 0,
                a: 255,
            },
        );
        original.set_pixel(
            TILE_SIZE + 2,
            3,
            Rgba8 {
                r: 0,
                g: 255,
                b: 0,
                a: 255,
            },
        );

        let mut snapshot = original.clone();
        assert!(Arc::ptr_eq(&original.tiles, &snapshot.tiles));
        assert!(Arc::ptr_eq(&original.dirty, &snapshot.dirty));
        assert!(Arc::ptr_eq(
            &original.tiles[&TileCoord { x: 1, y: 0 }].bytes,
            &snapshot.tiles[&TileCoord { x: 1, y: 0 }].bytes,
        ));

        snapshot.set_pixel(
            2,
            3,
            Rgba8 {
                r: 0,
                g: 0,
                b: 255,
                a: 255,
            },
        );

        assert!(!Arc::ptr_eq(&original.tiles, &snapshot.tiles));
        assert!(!Arc::ptr_eq(&original.dirty, &snapshot.dirty));
        assert_eq!(original.sample_pixel(2, 3).r, 255);
        assert_eq!(snapshot.sample_pixel(2, 3).b, 255);
        assert!(Arc::ptr_eq(
            &original.tiles[&TileCoord { x: 1, y: 0 }].bytes,
            &snapshot.tiles[&TileCoord { x: 1, y: 0 }].bytes,
        ));
        assert_eq!(original.take_dirty().len(), 2);
        assert_eq!(snapshot.take_dirty().len(), 2);
    }

    #[test]
    fn retained_payload_counts_shared_buffers_once_and_releases_evicted_history() {
        let mut current = TileStore::default();
        current.set_pixel(
            0,
            0,
            Rgba8 {
                r: 255,
                g: 0,
                b: 0,
                a: 255,
            },
        );
        let previous = current.clone();
        assert_eq!(
            TileStore::retained_pixel_bytes(&[previous.clone(), current.clone()]),
            256 * 256 * 4
        );
        current.erase_pixel(0, 0);
        assert_eq!(
            TileStore::retained_pixel_bytes(&[previous, current.clone()]),
            2 * 256 * 256 * 4
        );
        assert_eq!(TileStore::retained_pixel_bytes(&[current]), 256 * 256 * 4);
        assert_eq!(TileStore::retained_pixel_bytes(&[]), 0);
    }

    #[test]
    fn identical_recorded_pixels_have_identical_hashes() {
        let mut first = TileStore::default();
        let mut second = TileStore::default();
        for x in [2, 8, 16, 24] {
            first.blend_pixel(
                x,
                4,
                Rgba8 {
                    r: 12,
                    g: 34,
                    b: 56,
                    a: 255,
                },
                u16::MAX,
            );
            second.blend_pixel(
                x,
                4,
                Rgba8 {
                    r: 12,
                    g: 34,
                    b: 56,
                    a: 255,
                },
                u16::MAX,
            );
        }
        assert_eq!(
            first.read(TileCoord { x: 0, y: 0 }).stable_hash(),
            second.read(TileCoord { x: 0, y: 0 }).stable_hash()
        );
    }

    #[test]
    fn erase_clears_pixel_and_marks_tile_dirty() {
        let mut store = TileStore::default();
        let coord = store.blend_pixel(
            3,
            4,
            Rgba8 {
                r: 255,
                g: 0,
                b: 0,
                a: 255,
            },
            u16::MAX,
        );
        store.take_dirty();
        assert_eq!(store.erase_pixel(3, 4), coord);
        let tile = store.read(coord);
        let offset = ((4 * TILE_SIZE + 3) * 4) as usize;
        assert_eq!(&tile.bytes()[offset..offset + 4], &[0, 0, 0, 0]);
        assert_eq!(store.take_dirty(), vec![coord]);
    }

    #[test]
    fn erasing_untouched_area_keeps_tiles_sparse() {
        let mut store = TileStore::default();
        assert_eq!(store.erase_pixel(300, 300), TileCoord { x: 1, y: 1 });
        assert_eq!(store.allocated_tiles(), 0);
        assert!(store.take_dirty().is_empty());
    }

    #[test]
    fn affine_transform_moves_allocated_pixels_deterministically() {
        let mut store = TileStore::default();
        store.blend_pixel(
            4,
            5,
            Rgba8 {
                r: 255,
                g: 0,
                b: 0,
                a: 255,
            },
            u16::MAX,
        );
        store
            .transform_affine(64, 64, 1.0, 0.0, 0.0, 1.0, 10.0, 7.0)
            .expect("valid transform");
        assert_eq!(store.sample_pixel(14, 12).r, 255);
        assert_eq!(store.sample_pixel(4, 5).a, 0);
    }

    #[test]
    fn affine_transform_rejects_non_invertible_or_non_finite_matrices() {
        let mut store = TileStore::default();
        assert_eq!(
            store.transform_affine(64, 64, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0),
            Err(RasterError::InvalidTransform)
        );
        assert_eq!(
            store.transform_affine(64, 64, f32::NAN, 0.0, 0.0, 1.0, 0.0, 0.0),
            Err(RasterError::InvalidTransform)
        );
    }

    #[test]
    fn perspective_transform_maps_canvas_corners_deterministically() {
        let mut store = TileStore::default();
        store.blend_pixel(
            0,
            0,
            Rgba8 {
                r: 255,
                g: 0,
                b: 0,
                a: 255,
            },
            u16::MAX,
        );
        store
            .transform_perspective(32, 32, [(4.0, 5.0), (28.0, 5.0), (27.0, 27.0), (5.0, 27.0)])
            .expect("valid perspective");
        assert_eq!(store.sample_pixel(4, 5).r, 255);
        assert_eq!(store.sample_pixel(0, 0).a, 0);
    }

    #[test]
    fn mesh_transform_rejects_unbounded_grids_and_maps_identity_grid() {
        let mut store = TileStore::default();
        store.blend_pixel(
            2,
            3,
            Rgba8 {
                r: 9,
                g: 8,
                b: 7,
                a: 255,
            },
            u16::MAX,
        );
        store
            .transform_mesh(
                16,
                16,
                2,
                2,
                &[(0.0, 0.0), (15.0, 0.0), (0.0, 15.0), (15.0, 15.0)],
            )
            .expect("identity mesh");
        assert_eq!(store.sample_pixel(2, 3).r, 9);
        assert_eq!(
            store.transform_mesh(16, 16, 1, 2, &[(0.0, 0.0), (1.0, 1.0)]),
            Err(RasterError::InvalidTransform)
        );
    }

    #[test]
    fn liquify_transform_is_bounded_and_changes_pixels_inside_radius() {
        let mut store = TileStore::default();
        store.blend_pixel(
            8,
            8,
            Rgba8 {
                r: 200,
                g: 100,
                b: 50,
                a: 255,
            },
            u16::MAX,
        );
        store
            .transform_liquify(32, 32, 8.0, 8.0, 12.0, 0.5, 0, 2.0, 0.0)
            .expect("valid liquify");
        assert_eq!(store.sample_pixel(8, 8).a, 0);
        assert_eq!(
            store.transform_liquify(32, 32, 8.0, 8.0, -1.0, 0.5, 0, 1.0, 0.0),
            Err(RasterError::InvalidTransform)
        );
    }
}

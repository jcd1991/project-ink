use super::{
    BTreeMap, BrushDab, BrushPaint, BrushPreset, BrushResource, Dab, EngineError, GrainStamp,
    LayerState, MAX_POST_EFFECT_PIXELS, PostEffect, Rgba8, SelectionMask, TILE_SIZE, TileCoord,
    TileStore, ToolBehavior, VectorStroke, WatercolorEdgeStyle,
};

#[allow(clippy::too_many_arguments)]
pub(super) fn render_dabs(
    tiles: &mut TileStore,
    dabs: &[Dab],
    preset: BrushPreset,
    selection: Option<&SelectionMask>,
    eraser: bool,
    preview_mask: bool,
    alpha_lock: bool,
    width_px: u32,
    height_px: u32,
) -> Vec<TileCoord> {
    let mut dirty = Vec::new();
    for dab in dabs.iter().copied() {
        let pressure = dab.pressure.clamp(0.0, 1.0);
        let radius = legacy_dab_radius(preset, pressure);
        let opacity_pressure = legacy_dab_opacity(preset, pressure);
        let min_x = ((dab.x - radius - 0.5).floor() as i64).max(0);
        let min_y = ((dab.y - radius - 0.5).floor() as i64).max(0);
        let max_x =
            ((dab.x + radius + 0.5).ceil() as i64).min(i64::from(width_px).saturating_sub(1));
        let max_y =
            ((dab.y + radius + 0.5).ceil() as i64).min(i64::from(height_px).saturating_sub(1));
        if min_x > max_x || min_y > max_y {
            continue;
        }
        for y in min_y..=max_y {
            for x in min_x..=max_x {
                let distance = (x as f32 - dab.x).hypot(y as f32 - dab.y);
                let coverage = (radius + 0.5 - distance).clamp(0.0, 1.0);
                if coverage > 0.0
                    && selection.is_none_or(|mask| mask.get(x as u32, y as u32) > 0)
                    && (!alpha_lock || tiles.sample_pixel(x as u32, y as u32).a != 0)
                {
                    let opacity =
                        (coverage * opacity_pressure * preset.opacity * f32::from(u16::MAX))
                            .clamp(0.0, f32::from(u16::MAX)) as u16;
                    let coord = if eraser && !preview_mask {
                        tiles.erase_pixel(x as u32, y as u32)
                    } else {
                        let color = if eraser {
                            ink_model::Rgba8 {
                                r: 255,
                                g: 255,
                                b: 255,
                                a: 255,
                            }
                        } else {
                            preset.color
                        };
                        tiles.blend_pixel(x as u32, y as u32, color, opacity)
                    };
                    if !dirty.contains(&coord) {
                        dirty.push(coord);
                    }
                }
            }
        }
    }
    dirty
}

pub(super) fn legacy_dab_radius(preset: BrushPreset, pressure: f32) -> f32 {
    let pressure = pressure.clamp(0.0, 1.0);
    let diameter_scale = if preset.kind == ink_brush::BrushKind::TechnicalPen {
        // A narrow low-pressure start and a strong curved rise make changes
        // visible across the Pencil's working range, not only at maximum force.
        0.2 + 2.8 * pressure.powf(1.5)
    } else {
        1.0
    };
    (preset.diameter_px * diameter_scale * 0.5).max(0.5)
}

pub(super) fn legacy_dab_opacity(preset: BrushPreset, pressure: f32) -> f32 {
    let pressure = pressure.clamp(0.0, 1.0);
    let pressure_opacity = if preset.kind == ink_brush::BrushKind::TechnicalPen {
        // Technical pens vary width with pressure, but remain opaque. Using
        // Pencil force for opacity made light Pencil strokes translucent and
        // visually strand-like compared with finger input.
        1.0
    } else {
        pressure
    };
    (pressure_opacity * preset.opacity).clamp(0.0, 1.0)
}

#[allow(clippy::too_many_arguments)]
#[allow(clippy::too_many_lines)]
pub(super) fn render_brush_dabs(
    tiles: &mut TileStore,
    dabs: &[BrushDab],
    resources: &BTreeMap<[u8; 32], BrushResource>,
    selection: Option<&SelectionMask>,
    eraser: bool,
    preview_mask: bool,
    alpha_lock: bool,
    width_px: u32,
    height_px: u32,
) -> Vec<TileCoord> {
    let mut dirty = Vec::new();
    for dab in dabs.iter().copied() {
        let radius_x = dab.radius_x.max(0.25);
        let radius_y = dab.radius_y.max(0.25);
        let cx = dab.x.round() as i64;
        let cy = dab.y.round() as i64;
        let min_x = (cx - radius_x.ceil() as i64).max(0);
        let min_y = (cy - radius_y.ceil() as i64).max(0);
        let max_x = (cx + radius_x.ceil() as i64).min(i64::from(width_px).saturating_sub(1));
        let max_y = (cy + radius_y.ceil() as i64).min(i64::from(height_px).saturating_sub(1));
        if min_x > max_x || min_y > max_y {
            continue;
        }
        let normalized_angle = dab.angle;
        let (sin, cos) = normalized_angle.sin_cos();
        let center_sample = tiles.sample_pixel(cx.max(0) as u32, cy.max(0) as u32);
        let sampled = match dab.paint {
            BrushPaint::ColorPickup {
                pickup,
                deposit,
                dilution,
                blur,
            } => {
                let source = if blur > 0.01 {
                    average_samples(tiles, cx.max(0) as u32, cy.max(0) as u32)
                } else {
                    center_sample
                };
                let picked = mix_color(dab.color, source, (pickup * dilution).clamp(0.0, 1.0));
                let deposit = deposit.clamp(0.0, 1.0);
                mix_color(source, picked, deposit)
            }
            BrushPaint::DigitalWatercolor {
                dilution, pickup, ..
            } => mix_color(
                dab.color,
                center_sample,
                (dilution * pickup).clamp(0.0, 1.0),
            ),
            _ if matches!(dab.tool, ToolBehavior::Smudge | ToolBehavior::Blur) => {
                if dab.tool == ToolBehavior::Blur {
                    average_samples(tiles, cx.max(0) as u32, cy.max(0) as u32)
                } else {
                    center_sample
                }
            }
            _ => dab.color,
        };
        for y in min_y..=max_y {
            for x in min_x..=max_x {
                let raw_x = (x as f32 - dab.x) / radius_x;
                let raw_y = (y as f32 - dab.y) / radius_y;
                let normalized_x = raw_x * cos + raw_y * sin;
                let normalized_y = -raw_x * sin + raw_y * cos;
                let distance = normalized_x * normalized_x + normalized_y * normalized_y;
                if distance > 1.0 {
                    continue;
                }
                if selection.is_some_and(|mask| mask.get(x as u32, y as u32) == 0) {
                    continue;
                }
                if alpha_lock && tiles.sample_pixel(x as u32, y as u32).a == 0 {
                    continue;
                }
                let edge = (1.0 - distance).clamp(0.0, 1.0);
                let grain = dab.grain.map_or(1.0, |value| {
                    let (gx, gy) = if value.canvas_space {
                        (x as f32, y as f32)
                    } else {
                        (
                            f32::midpoint(normalized_x, 1.0) * radius_x * 2.0,
                            f32::midpoint(normalized_y, 1.0) * radius_y * 2.0,
                        )
                    };
                    grain_multiplier(value, gx, gy, resources.get(&value.resource_hash))
                });
                let tip = dab
                    .tip_resource_hash
                    .and_then(|hash| resources.get(&hash))
                    .map_or(1.0, |resource| {
                        sample_resource_alpha(resource, normalized_x, normalized_y)
                    });
                let paint_factor = match dab.paint {
                    BrushPaint::Glaze => 0.82,
                    BrushPaint::Marker => 0.92,
                    BrushPaint::DigitalWatercolor {
                        edge_pooling,
                        paper_resist,
                        granulation,
                        ..
                    } => {
                        let pooling = 1.0 + (1.0 - edge) * edge_pooling.clamp(0.0, 1.0);
                        let resist = 1.0 - paper_resist.clamp(0.0, 1.0) * 0.2;
                        pooling * resist * (0.85 + granulation.clamp(0.0, 1.0) * 0.15)
                    }
                    BrushPaint::ColorPickup { .. } => 0.9,
                    BrushPaint::Solid => 1.0,
                };
                let opacity = (dab.opacity
                    * dab.flow
                    * edge
                    * grain
                    * tip
                    * paint_factor
                    * f32::from(u16::MAX))
                .clamp(0.0, f32::from(u16::MAX)) as u16;
                let coord = if (eraser || dab.tool == ToolBehavior::Erase) && !preview_mask {
                    tiles.erase_pixel(x as u32, y as u32)
                } else {
                    tiles.blend_pixel(x as u32, y as u32, sampled, opacity)
                };
                if !dirty.contains(&coord) {
                    dirty.push(coord);
                }
            }
        }
    }
    dirty
}

/// Restrict predicted alpha-locked dabs to pixels that already contain
/// content on the committed layer. Preview tiles are separate from the
/// document, so this pass keeps them visually consistent without journaling
/// or mutating the committed raster.
pub(super) fn mask_preview_to_alpha(
    preview: &mut TileStore,
    source: &TileStore,
    width_px: u32,
    height_px: u32,
) {
    let coordinates = preview.allocated_coordinates();
    for coordinate in coordinates {
        for local_y in 0..TILE_SIZE {
            let y = coordinate
                .y
                .saturating_mul(TILE_SIZE as i32)
                .saturating_add(local_y as i32);
            if y < 0 || y >= height_px as i32 {
                continue;
            }
            for local_x in 0..TILE_SIZE {
                let x = coordinate
                    .x
                    .saturating_mul(TILE_SIZE as i32)
                    .saturating_add(local_x as i32);
                if x < 0 || x >= width_px as i32 {
                    continue;
                }
                if preview.sample_pixel(x as u32, y as u32).a != 0
                    && source.sample_pixel(x as u32, y as u32).a == 0
                {
                    preview.erase_pixel(x as u32, y as u32);
                }
            }
        }
    }
}

fn mix_color(left: ink_model::Rgba8, right: ink_model::Rgba8, amount: f32) -> ink_model::Rgba8 {
    let amount = amount.clamp(0.0, 1.0);
    let mix = |a: u8, b: u8| {
        (f32::from(a) + (f32::from(b) - f32::from(a)) * amount)
            .round()
            .clamp(0.0, 255.0) as u8
    };
    ink_model::Rgba8 {
        r: mix(left.r, right.r),
        g: mix(left.g, right.g),
        b: mix(left.b, right.b),
        a: mix(left.a, right.a),
    }
}

#[derive(Clone, Copy)]
struct PostEffectBounds {
    min_x: u32,
    min_y: u32,
    max_x: u32,
    max_y: u32,
}

impl PostEffectBounds {
    fn width(self) -> usize {
        self.max_x.saturating_sub(self.min_x) as usize + 1
    }

    fn height(self) -> usize {
        self.max_y.saturating_sub(self.min_y) as usize + 1
    }

    fn contains(self, x: i64, y: i64) -> bool {
        x >= i64::from(self.min_x)
            && x <= i64::from(self.max_x)
            && y >= i64::from(self.min_y)
            && y <= i64::from(self.max_y)
    }

    fn index(self, x: u32, y: u32) -> usize {
        (y.saturating_sub(self.min_y) as usize)
            .saturating_mul(self.width())
            .saturating_add(x.saturating_sub(self.min_x) as usize)
    }
}

fn post_effect_bounds(
    samples: &[ink_input::PointerSample],
    padding: u32,
    halo: u32,
    width_px: u32,
    height_px: u32,
) -> Option<PostEffectBounds> {
    let first = samples.first()?;
    let (mut min_x, mut max_x) = (first.canvas_x, first.canvas_x);
    let (mut min_y, mut max_y) = (first.canvas_y, first.canvas_y);
    for sample in samples.iter().skip(1) {
        min_x = min_x.min(sample.canvas_x);
        max_x = max_x.max(sample.canvas_x);
        min_y = min_y.min(sample.canvas_y);
        max_y = max_y.max(sample.canvas_y);
    }
    let pad = padding.saturating_add(halo) as f32;
    let min_x = (min_x.floor().max(0.0) - pad).max(0.0) as u32;
    let min_y = (min_y.floor().max(0.0) - pad).max(0.0) as u32;
    let max_x = (max_x.ceil() + pad)
        .min(width_px.saturating_sub(1) as f32)
        .max(0.0) as u32;
    let max_y = (max_y.ceil() + pad)
        .min(height_px.saturating_sub(1) as f32)
        .max(0.0) as u32;
    (min_x <= max_x && min_y <= max_y).then_some(PostEffectBounds {
        min_x,
        min_y,
        max_x,
        max_y,
    })
}

fn post_region_sample(
    current: &[Rgba8],
    bounds: PostEffectBounds,
    tiles: &TileStore,
    x: i64,
    y: i64,
) -> Rgba8 {
    if bounds.contains(x, y) {
        return current[bounds.index(x as u32, y as u32)];
    }
    if x < 0 || y < 0 {
        Rgba8::default()
    } else {
        tiles.sample_pixel(x as u32, y as u32)
    }
}

fn post_average_neighbors(
    current: &[Rgba8],
    bounds: PostEffectBounds,
    tiles: &TileStore,
    x: u32,
    y: u32,
    radius: u32,
) -> Rgba8 {
    let radius = i64::from(radius.max(1));
    let x = i64::from(x);
    let y = i64::from(y);
    let samples = [
        post_region_sample(current, bounds, tiles, x - radius, y),
        post_region_sample(current, bounds, tiles, x + radius, y),
        post_region_sample(current, bounds, tiles, x, y - radius),
        post_region_sample(current, bounds, tiles, x, y + radius),
    ];
    let mut sums = [0_u32; 4];
    for sample in samples {
        sums[0] += u32::from(sample.r);
        sums[1] += u32::from(sample.g);
        sums[2] += u32::from(sample.b);
        sums[3] += u32::from(sample.a);
    }
    Rgba8 {
        r: (sums[0] / 4) as u8,
        g: (sums[1] / 4) as u8,
        b: (sums[2] / 4) as u8,
        a: (sums[3] / 4) as u8,
    }
}

fn post_scale_color(color: Rgba8, factor: f32) -> Rgba8 {
    let scale = |value: u8| (f32::from(value) * factor).round().clamp(0.0, 255.0) as u8;
    Rgba8 {
        r: scale(color.r),
        g: scale(color.g),
        b: scale(color.b),
        a: color.a,
    }
}

fn post_saturate(color: Rgba8, amount: f32) -> Rgba8 {
    let amount = (1.0 + amount).clamp(0.0, 2.0);
    let gray = 0.299 * f32::from(color.r) + 0.587 * f32::from(color.g) + 0.114 * f32::from(color.b);
    let channel = |value: u8| {
        (gray + (f32::from(value) - gray) * amount)
            .round()
            .clamp(0.0, 255.0) as u8
    };
    Rgba8 {
        r: channel(color.r),
        g: channel(color.g),
        b: channel(color.b),
        a: color.a,
    }
}

fn post_hue_shift(color: Rgba8, amount: f32) -> Rgba8 {
    let amount = amount.clamp(-1.0, 1.0);
    if amount.abs() <= f32::EPSILON {
        return color;
    }
    let rotate = |a: u8, b: u8, t: f32| {
        (f32::from(a) + (f32::from(b) - f32::from(a)) * t)
            .round()
            .clamp(0.0, 255.0) as u8
    };
    if amount > 0.0 {
        Rgba8 {
            r: rotate(color.r, color.g, amount),
            g: rotate(color.g, color.b, amount),
            b: rotate(color.b, color.r, amount),
            a: color.a,
        }
    } else {
        let amount = -amount;
        Rgba8 {
            r: rotate(color.r, color.b, amount),
            g: rotate(color.g, color.r, amount),
            b: rotate(color.b, color.g, amount),
            a: color.a,
        }
    }
}

fn post_noise(hash: &[u8; 32], x: u32, y: u32, scale: f32) -> f32 {
    let qx = (x as f32 * scale.clamp(0.01, 64.0)).floor() as u64;
    let qy = (y as f32 * scale.clamp(0.01, 64.0)).floor() as u64;
    let mut state = u64::from_le_bytes(hash[..8].try_into().unwrap_or([0; 8]));
    state ^= qx.wrapping_mul(0x9e37_79b9_7f4a_7c15);
    state ^= qy.wrapping_mul(0xbf58_476d_1ce4_e5b9);
    state ^= state >> 30;
    state = state.wrapping_mul(0xbf58_476d_1ce4_e5b9);
    state ^= state >> 27;
    (state as f32 / u64::MAX as f32).clamp(0.0, 1.0)
}

/// Apply declarative post effects to the current stroke's bounded dirty
/// region. Every stage reads from an immutable region snapshot, making output
/// independent of tile iteration order and keeping the operation undoable as
/// one stroke transaction.
#[allow(clippy::too_many_lines)]
pub(super) fn apply_post_effects(
    tiles: &mut TileStore,
    effects: &[PostEffect],
    samples: &[ink_input::PointerSample],
    padding: u32,
    selection: Option<&SelectionMask>,
    width_px: u32,
    height_px: u32,
) -> Result<Vec<TileCoord>, EngineError> {
    let halo = effects.iter().map(PostEffect::halo_px).max().unwrap_or(0);
    let Some(bounds) = post_effect_bounds(samples, padding, halo, width_px, height_px) else {
        return Ok(Vec::new());
    };
    let area = bounds.width().saturating_mul(bounds.height());
    if area > MAX_POST_EFFECT_PIXELS {
        return Err(EngineError::InvalidCommand(
            "post-effect dirty region exceeds the safety limit".into(),
        ));
    }
    let mut current = Vec::with_capacity(area);
    for y in bounds.min_y..=bounds.max_y {
        for x in bounds.min_x..=bounds.max_x {
            current.push(tiles.sample_pixel(x, y));
        }
    }
    let original = current.clone();
    let (start, end) =
        samples
            .first()
            .zip(samples.last())
            .map_or(((0.0, 0.0), (1.0, 0.0)), |(first, last)| {
                (
                    (first.canvas_x, first.canvas_y),
                    (last.canvas_x, last.canvas_y),
                )
            });
    let direction = (end.0 - start.0, end.1 - start.1);
    let direction_length = direction.0.hypot(direction.1).max(1.0);
    for effect in effects {
        let mut next = current.clone();
        for y in bounds.min_y..=bounds.max_y {
            for x in bounds.min_x..=bounds.max_x {
                if selection.is_some_and(|mask| mask.get(x, y) == 0) {
                    continue;
                }
                let index = bounds.index(x, y);
                let center = current[index];
                let updated = match effect {
                    PostEffect::DigitalWatercolorEdge {
                        radius_px,
                        strength,
                        darkness,
                        blur,
                        saturation,
                        hue_shift,
                        style,
                        ..
                    } => {
                        let neighbor =
                            post_average_neighbors(&current, bounds, tiles, x, y, *radius_px);
                        let edge = (f32::from(center.a) - f32::from(neighbor.a)).abs() / 255.0;
                        let vivid =
                            f32::from(u8::from(matches!(style, WatercolorEdgeStyle::Vivid)));
                        let factor = (edge * *strength * (1.0 + vivid * 0.25)).clamp(0.0, 1.0);
                        let softened = mix_color(center, neighbor, factor * *blur);
                        let darkened = post_scale_color(softened, 1.0 - *darkness * factor);
                        post_hue_shift(
                            post_saturate(darkened, *saturation * factor),
                            *hue_shift * factor,
                        )
                    }
                    PostEffect::EdgeSoftness { radius_px, amount } => {
                        let neighbor =
                            post_average_neighbors(&current, bounds, tiles, x, y, *radius_px);
                        if *amount >= 0.0 {
                            mix_color(center, neighbor, *amount)
                        } else {
                            let sharpen = -*amount;
                            let channel = |value: u8, average: u8| {
                                (f32::from(value)
                                    + (f32::from(value) - f32::from(average)) * sharpen)
                                    .round()
                                    .clamp(0.0, 255.0) as u8
                            };
                            Rgba8 {
                                r: channel(center.r, neighbor.r),
                                g: channel(center.g, neighbor.g),
                                b: channel(center.b, neighbor.b),
                                a: center.a,
                            }
                        }
                    }
                    PostEffect::StampOutline {
                        radius_px,
                        opacity,
                        color,
                    } => {
                        let neighbor =
                            post_average_neighbors(&current, bounds, tiles, x, y, *radius_px);
                        if center.a > 0 && neighbor.a == 0 {
                            mix_color(center, *color, *opacity)
                        } else {
                            center
                        }
                    }
                    PostEffect::TrailingFade {
                        distance_px,
                        amount,
                    } => {
                        let projection = ((x as f32 - start.0) * direction.0
                            + (y as f32 - start.1) * direction.1)
                            / direction_length;
                        let endpoint =
                            (direction_length - projection).clamp(0.0, *distance_px as f32);
                        let fade = (*amount * (1.0 - endpoint / (*distance_px as f32).max(1.0)))
                            .clamp(0.0, 1.0);
                        Rgba8 {
                            r: center.r,
                            g: center.g,
                            b: center.b,
                            a: (f32::from(center.a) * (1.0 - fade)).round() as u8,
                        }
                    }
                    PostEffect::TexturePass {
                        resource_hash,
                        scale,
                        depth,
                    } => {
                        let noise = post_noise(resource_hash, x, y, *scale);
                        post_scale_color(center, 1.0 + (noise - 0.5) * 2.0 * *depth)
                    }
                };
                next[index] = updated;
            }
        }
        current = next;
    }
    let mut dirty = Vec::new();
    for y in bounds.min_y..=bounds.max_y {
        for x in bounds.min_x..=bounds.max_x {
            let index = bounds.index(x, y);
            if current[index] != original[index] {
                let coordinate = tiles.set_pixel(x, y, current[index]);
                if !dirty.contains(&coordinate) {
                    dirty.push(coordinate);
                }
            }
        }
    }
    dirty.sort_unstable_by_key(|coordinate| (coordinate.y, coordinate.x));
    Ok(dirty)
}

fn average_samples(tiles: &TileStore, x: u32, y: u32) -> ink_model::Rgba8 {
    let mut sums = [0_u32; 4];
    let mut count = 0_u32;
    for (dx, dy) in [(0_i32, 0_i32), (-1, 0), (1, 0), (0, -1), (0, 1)] {
        let px = i64::from(x) + i64::from(dx);
        let py = i64::from(y) + i64::from(dy);
        if px < 0 || py < 0 {
            continue;
        }
        let sample = tiles.sample_pixel(px as u32, py as u32);
        sums[0] = sums[0].saturating_add(u32::from(sample.r));
        sums[1] = sums[1].saturating_add(u32::from(sample.g));
        sums[2] = sums[2].saturating_add(u32::from(sample.b));
        sums[3] = sums[3].saturating_add(u32::from(sample.a));
        count = count.saturating_add(1);
    }
    let divisor = count.max(1);
    ink_model::Rgba8 {
        r: (sums[0] / divisor) as u8,
        g: (sums[1] / divisor) as u8,
        b: (sums[2] / divisor) as u8,
        a: (sums[3] / divisor) as u8,
    }
}

/// Rasterize editable centerline ink into the same sparse tile store used by
/// the canvas. The vector record remains authoritative; this deterministic
/// cache makes vector layers visible in Flutter and all export formats.
pub(super) fn rasterize_vector_stroke(
    tiles: &mut TileStore,
    stroke: &VectorStroke,
    width_px: u32,
    height_px: u32,
) -> Vec<TileCoord> {
    let mut dirty = Vec::new();
    let mut paint_point = |x: f32, y: f32, pressure: f32| {
        if x < 0.0 || y < 0.0 || x >= width_px as f32 || y >= height_px as f32 {
            return;
        }
        let radius = (0.75 + pressure.clamp(0.0, 1.0) * 2.75).max(0.5);
        let cx = x.round() as i64;
        let cy = y.round() as i64;
        let min_x = (cx - radius.ceil() as i64).max(0);
        let min_y = (cy - radius.ceil() as i64).max(0);
        let max_x = (cx + radius.ceil() as i64).min(i64::from(width_px) - 1);
        let max_y = (cy + radius.ceil() as i64).min(i64::from(height_px) - 1);
        for py in min_y..=max_y {
            for px in min_x..=max_x {
                let distance = ((px as f32 - x).powi(2) + (py as f32 - y).powi(2)).sqrt();
                if distance > radius {
                    continue;
                }
                let opacity = ((1.0 - distance / radius).clamp(0.0, 1.0)
                    * (0.45 + pressure.clamp(0.0, 1.0) * 0.55)
                    * f32::from(u16::MAX)) as u16;
                let coordinate = tiles.blend_pixel(
                    px as u32,
                    py as u32,
                    ink_model::Rgba8 {
                        r: 24,
                        g: 24,
                        b: 28,
                        a: 255,
                    },
                    opacity,
                );
                if !dirty.contains(&coordinate) {
                    dirty.push(coordinate);
                }
            }
        }
    };
    for pair in stroke.points.windows(2) {
        let from = pair[0];
        let to = pair[1];
        let distance = (to.x - from.x).hypot(to.y - from.y);
        let steps = distance.ceil().max(1.0) as usize;
        for step in 0..=steps {
            let amount = step as f32 / steps as f32;
            let x = from.x + (to.x - from.x) * amount;
            let y = from.y + (to.y - from.y) * amount;
            let pressure = from.pressure + (to.pressure - from.pressure) * amount;
            paint_point(x, y, pressure);
        }
    }
    if stroke.points.len() == 1 {
        let point = stroke.points[0];
        paint_point(point.x, point.y, point.pressure);
    }
    dirty
}

pub(super) fn rebuild_vector_layer(
    layer: &mut LayerState,
    width_px: u32,
    height_px: u32,
) -> Vec<TileCoord> {
    layer.tiles.clear();
    let mut dirty = Vec::new();
    for (_, stroke) in &layer.vectors {
        dirty.extend(rasterize_vector_stroke(
            &mut layer.tiles,
            stroke,
            width_px,
            height_px,
        ));
    }
    dirty.sort_unstable_by_key(|coordinate| (coordinate.y, coordinate.x));
    dirty.dedup();
    dirty
}

fn sample_resource_alpha(resource: &BrushResource, x: f32, y: f32) -> f32 {
    if resource.width == 0 || resource.height == 0 || resource.rgba8.len() < 4 {
        return 1.0;
    }
    let u = f32::midpoint(x, 1.0).clamp(0.0, 1.0);
    let v = f32::midpoint(y, 1.0).clamp(0.0, 1.0);
    let px = (u * (resource.width.saturating_sub(1)) as f32).round() as usize;
    let py = (v * (resource.height.saturating_sub(1)) as f32).round() as usize;
    let offset = py
        .saturating_mul(resource.width as usize)
        .saturating_add(px)
        .saturating_mul(4);
    resource
        .rgba8
        .get(offset + 3)
        .map_or(1.0, |alpha| f32::from(*alpha) / 255.0)
}

/// Deterministic bounded grain modulation. The native v2 resource pipeline
/// supplies content hashes; until decoded image resources are installed, the
/// hash still gives every preset a stable, seam-free procedural texture.
fn grain_multiplier(grain: GrainStamp, x: f32, y: f32, resource: Option<&BrushResource>) -> f32 {
    let scale = grain.scale.clamp(0.01, 64.0);
    let noise = resource
        .filter(|value| value.kind == "grain" && value.width > 0 && value.height > 0)
        .and_then(|value| {
            let rgba_len = value.width as usize * value.height as usize * 4;
            if value.rgba8.len() < rgba_len {
                return None;
            }
            let px = ((x * scale).floor() as i64).rem_euclid(i64::from(value.width)) as usize;
            let py = ((y * scale).floor() as i64).rem_euclid(i64::from(value.height)) as usize;
            let offset = (py * value.width as usize + px) * 4;
            Some(
                (f32::from(value.rgba8[offset]) * 0.2126
                    + f32::from(value.rgba8[offset + 1]) * 0.7152
                    + f32::from(value.rgba8[offset + 2]) * 0.0722)
                    / 255.0,
            )
        })
        .unwrap_or_else(|| {
            let qx = (x * scale).floor() as i64;
            let qy = (y * scale).floor() as i64;
            let mut state =
                u64::from_le_bytes(grain.resource_hash[..8].try_into().unwrap_or([0; 8]));
            state ^= (qx as u64).wrapping_mul(0x9e37_79b9_7f4a_7c15);
            state ^= (qy as u64).wrapping_mul(0xbf58_476d_1ce4_e5b9);
            state ^= state >> 30;
            state = state.wrapping_mul(0xbf58_476d_1ce4_e5b9);
            state ^= state >> 27;
            (state as f32 / u64::MAX as f32).clamp(0.0, 1.0)
        });
    let contrast = (1.0 + (noise - 0.5) * 2.0 * grain.contrast.clamp(-1.0, 1.0)).clamp(0.0, 2.0);
    (1.0 - grain.depth.clamp(0.0, 1.0) + grain.depth.clamp(0.0, 1.0) * contrast).clamp(0.0, 2.0)
}

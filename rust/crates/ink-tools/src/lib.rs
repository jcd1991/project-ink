//! Deterministic, platform-independent illustration tools used by Phase 2.
#![allow(missing_docs)]
#![allow(
    clippy::missing_errors_doc,
    clippy::missing_panics_doc,
    clippy::must_use_candidate,
    clippy::cast_possible_truncation,
    clippy::cast_precision_loss,
    clippy::cast_sign_loss
)]

use ink_model::Rgba8;
pub use ink_model::{VectorPoint, VectorStroke};
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::f32::consts::TAU;

const MAX_MASK_PIXELS: usize = 128 * 1024 * 1024;

/// A byte-valued selection mask. Zero is unselected and 255 is fully selected.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct SelectionMask {
    pub width: u32,
    pub height: u32,
    pub values: Vec<u8>,
}

impl SelectionMask {
    pub fn new(width: u32, height: u32) -> Result<Self, ToolError> {
        let pixels = pixel_count(width, height)?;
        Ok(Self {
            width,
            height,
            values: vec![0; pixels],
        })
    }

    pub fn full(width: u32, height: u32) -> Result<Self, ToolError> {
        let mut mask = Self::new(width, height)?;
        mask.values.fill(255);
        Ok(mask)
    }

    /// Expand selection coverage by a bounded square radius using separable
    /// max filters. The operation is O(width × height), not O(radius²).
    pub fn grow(&mut self, radius: u32) -> Result<(), ToolError> {
        self.morphology(radius, true)
    }

    /// Contract selection coverage by a bounded square radius using
    /// separable min filters. Pixels outside the document are unselected.
    pub fn shrink(&mut self, radius: u32) -> Result<(), ToolError> {
        self.morphology(radius, false)
    }

    fn morphology(&mut self, radius: u32, grow: bool) -> Result<(), ToolError> {
        if radius == 0 || radius > 256 {
            return Err(ToolError::InvalidDimensions);
        }
        let width = usize::try_from(self.width).map_err(|_| ToolError::InvalidDimensions)?;
        let height = usize::try_from(self.height).map_err(|_| ToolError::InvalidDimensions)?;
        if width == 0 || height == 0 || self.values.len() != width.saturating_mul(height) {
            return Err(ToolError::InvalidDimensions);
        }
        let radius = usize::try_from(radius).map_err(|_| ToolError::InvalidDimensions)?;
        let horizontal = morphology_axis(&self.values, width, height, radius, true, grow);
        self.values = morphology_axis(&horizontal, width, height, radius, false, grow);
        Ok(())
    }

    pub fn rectangle(
        width: u32,
        height: u32,
        x0: i32,
        y0: i32,
        x1: i32,
        y1: i32,
    ) -> Result<Self, ToolError> {
        let mut mask = Self::new(width, height)?;
        let left = x0.min(x1).max(0) as u32;
        let right = x0.max(x1).min(i32::try_from(width).unwrap_or(i32::MAX)) as u32;
        let top = y0.min(y1).max(0) as u32;
        let bottom = y0.max(y1).min(i32::try_from(height).unwrap_or(i32::MAX)) as u32;
        for y in top..bottom {
            let start = usize::try_from(y * width + left).unwrap_or(0);
            let end = usize::try_from(y * width + right).unwrap_or(start);
            mask.values[start..end].fill(255);
        }
        Ok(mask)
    }

    pub fn ellipse(
        width: u32,
        height: u32,
        cx: f32,
        cy: f32,
        rx: f32,
        ry: f32,
    ) -> Result<Self, ToolError> {
        let mut mask = Self::new(width, height)?;
        if !cx.is_finite()
            || !cy.is_finite()
            || !rx.is_finite()
            || !ry.is_finite()
            || rx <= 0.0
            || ry <= 0.0
        {
            return Ok(mask);
        }
        let left = (cx - rx).floor().max(0.0) as u32;
        let right = (cx + rx).ceil().min(width as f32) as u32;
        let top = (cy - ry).floor().max(0.0) as u32;
        let bottom = (cy + ry).ceil().min(height as f32) as u32;
        for y in top..bottom {
            for x in left..right {
                let dx = (x as f32 + 0.5 - cx) / rx;
                let dy = (y as f32 + 0.5 - cy) / ry;
                if dx * dx + dy * dy <= 1.0 {
                    mask.set(x, y, 255);
                }
            }
        }
        Ok(mask)
    }

    /// Rasterize a closed polygon with an even-odd point-in-polygon test.
    pub fn lasso(width: u32, height: u32, points: &[(f32, f32)]) -> Result<Self, ToolError> {
        let mut mask = Self::new(width, height)?;
        if points.len() < 3 {
            return Ok(mask);
        }
        for y in 0..height {
            for x in 0..width {
                if point_in_polygon(x as f32 + 0.5, y as f32 + 0.5, points) {
                    mask.set(x, y, 255);
                }
            }
        }
        Ok(mask)
    }

    #[must_use]
    pub fn get(&self, x: u32, y: u32) -> u8 {
        if x >= self.width || y >= self.height {
            return 0;
        }
        self.values[usize::try_from(y * self.width + x).unwrap_or(0)]
    }

    pub fn set(&mut self, x: u32, y: u32, value: u8) {
        if x < self.width && y < self.height {
            let index = usize::try_from(y * self.width + x).unwrap_or(0);
            self.values[index] = value;
        }
    }

    pub fn invert(&mut self) {
        for value in &mut self.values {
            *value = 255 - *value;
        }
    }

    /// Select pixels whose alpha is at least `minimum_alpha`.
    pub fn from_opacity(
        pixels: &[Rgba8],
        width: u32,
        height: u32,
        minimum_alpha: u8,
    ) -> Result<Self, ToolError> {
        let expected = pixel_count(width, height)?;
        if pixels.len() != expected {
            return Err(ToolError::InvalidPixelLength);
        }
        let mut mask = Self::new(width, height)?;
        for (index, pixel) in pixels.iter().enumerate() {
            mask.values[index] = if pixel.a >= minimum_alpha { 255 } else { 0 };
        }
        Ok(mask)
    }

    /// Soften an edge by replacing each selected value with a bounded local
    /// neighborhood average. Repeating the operation creates a larger feather.
    pub fn feather(&mut self, radius: u32) {
        if radius == 0 {
            return;
        }
        let source = self.values.clone();
        let radius = i32::try_from(radius.min(32)).unwrap_or(32);
        for y in 0..self.height {
            for x in 0..self.width {
                let mut total = 0_u32;
                let mut count = 0_u32;
                for dy in -radius..=radius {
                    for dx in -radius..=radius {
                        let nx = i32::try_from(x).unwrap_or(i32::MAX).saturating_add(dx);
                        let ny = i32::try_from(y).unwrap_or(i32::MAX).saturating_add(dy);
                        if let (Ok(nx), Ok(ny)) = (u32::try_from(nx), u32::try_from(ny))
                            && nx < self.width
                            && ny < self.height
                        {
                            total += u32::from(
                                source[usize::try_from(ny * self.width + nx).unwrap_or(0)],
                            );
                            count += 1;
                        }
                    }
                }
                self.set(x, y, u8::try_from(total / count.max(1)).unwrap_or(u8::MAX));
            }
        }
    }

    /// Intersect this mask with another same-sized mask.
    pub fn intersect(&mut self, other: &Self) -> Result<(), ToolError> {
        if self.width != other.width || self.height != other.height {
            return Err(ToolError::InvalidDimensions);
        }
        for (left, right) in self.values.iter_mut().zip(&other.values) {
            *left = ((u16::from(*left) * u16::from(*right)) / 255) as u8;
        }
        Ok(())
    }

    /// Union this mask with another same-sized mask.
    pub fn union(&mut self, other: &Self) -> Result<(), ToolError> {
        if self.width != other.width || self.height != other.height {
            return Err(ToolError::InvalidDimensions);
        }
        for (left, right) in self.values.iter_mut().zip(&other.values) {
            *left = (*left).max(*right);
        }
        Ok(())
    }

    /// Expand a mask using a square neighborhood. This is deterministic and avoids
    /// platform-specific morphology implementations.
    pub fn expand(&mut self, radius: u32) {
        if radius == 0 {
            return;
        }
        let source = self.values.clone();
        for y in 0..self.height {
            for x in 0..self.width {
                let mut value = 0;
                for dy in -(i32::try_from(radius).unwrap_or(i32::MAX))
                    ..=i32::try_from(radius).unwrap_or(i32::MAX)
                {
                    for dx in -(i32::try_from(radius).unwrap_or(i32::MAX))
                        ..=i32::try_from(radius).unwrap_or(i32::MAX)
                    {
                        let nx = i32::try_from(x).unwrap_or(i32::MAX).saturating_add(dx);
                        let ny = i32::try_from(y).unwrap_or(i32::MAX).saturating_add(dy);
                        if nx >= 0
                            && ny >= 0
                            && u32::try_from(nx).is_ok_and(|nx| nx < self.width)
                            && u32::try_from(ny).is_ok_and(|ny| ny < self.height)
                        {
                            let index = usize::try_from(
                                u32::try_from(ny).unwrap_or(0) * self.width
                                    + u32::try_from(nx).unwrap_or(0),
                            )
                            .unwrap_or(0);
                            value = value.max(source[index]);
                        }
                    }
                }
                self.set(x, y, value);
            }
        }
    }

    /// Select pixels within an RGBA Euclidean tolerance of a reference color.
    pub fn from_color_range(
        pixels: &[Rgba8],
        width: u32,
        height: u32,
        target: Rgba8,
        tolerance: u16,
    ) -> Result<Self, ToolError> {
        let expected = pixel_count(width, height)?;
        if pixels.len() != expected {
            return Err(ToolError::InvalidPixelLength);
        }
        let mut mask = Self::new(width, height)?;
        let limit = u32::from(tolerance) * u32::from(tolerance);
        for (index, pixel) in pixels.iter().enumerate() {
            let distance = [
                pixel.r.abs_diff(target.r),
                pixel.g.abs_diff(target.g),
                pixel.b.abs_diff(target.b),
                pixel.a.abs_diff(target.a),
            ]
            .into_iter()
            .map(u32::from)
            .map(|value| value * value)
            .sum::<u32>();
            if distance <= limit {
                mask.values[index] = 255;
            }
        }
        Ok(mask)
    }

    /// Flood-fill a contiguous color region. `gap` permits traversing at most
    /// that many consecutive out-of-tolerance pixels to close a narrow line-art
    /// gap. The traversed bridge is included in the fill, but the result is not
    /// expanded after traversal, so nearby unrelated pixels are not painted as
    /// a side effect of gap closing.
    pub fn flood_fill(
        pixels: &[Rgba8],
        width: u32,
        height: u32,
        start_x: u32,
        start_y: u32,
        tolerance: u16,
        gap: u32,
    ) -> Result<Self, ToolError> {
        let expected = pixel_count(width, height)?;
        if pixels.len() != expected {
            return Err(ToolError::InvalidPixelLength);
        }
        let mut mask = Self::new(width, height)?;
        if start_x >= width || start_y >= height {
            return Ok(mask);
        }
        let start = pixels[usize::try_from(start_y * width + start_x).unwrap_or(0)];
        let limit = u32::from(tolerance) * u32::from(tolerance);
        let max_gap = gap.min(4) as u8;
        let mut queue = VecDeque::from([(start_x, start_y, 0_u8)]);
        // A pixel can be reached through a shorter bridge later, so retain the
        // smallest barrier distance seen rather than a simple boolean.
        let mut visited = vec![u8::MAX; expected];
        while let Some((x, y, barrier_steps)) = queue.pop_front() {
            let index = usize::try_from(y * width + x).unwrap_or(0);
            if barrier_steps >= visited[index] {
                continue;
            }
            visited[index] = barrier_steps;
            let pixel = pixels[index];
            let distance = [
                pixel.r.abs_diff(start.r),
                pixel.g.abs_diff(start.g),
                pixel.b.abs_diff(start.b),
                pixel.a.abs_diff(start.a),
            ]
            .into_iter()
            .map(u32::from)
            .map(|value| value * value)
            .sum::<u32>();
            let inside = distance <= limit;
            if !inside && barrier_steps >= max_gap {
                continue;
            }
            mask.values[index] = 255;
            let next_barrier_steps = if inside { 0 } else { barrier_steps + 1 };
            for (nx, ny) in [
                (x.wrapping_sub(1), y),
                (x.saturating_add(1), y),
                (x, y.wrapping_sub(1)),
                (x, y.saturating_add(1)),
            ] {
                if nx < width
                    && ny < height
                    && next_barrier_steps < visited[usize::try_from(ny * width + nx).unwrap_or(0)]
                {
                    queue.push_back((nx, ny, next_barrier_steps));
                }
            }
        }
        Ok(mask)
    }

    /// Paint a linear gradient through a mask. Unselected pixels retain the
    /// supplied base image, making this suitable for Paint Inside and
    /// selection-constrained fills.
    pub fn gradient_fill(
        &self,
        base: &[Rgba8],
        start: (f32, f32),
        end: (f32, f32),
        from: Rgba8,
        to: Rgba8,
    ) -> Result<Vec<Rgba8>, ToolError> {
        let expected = pixel_count(self.width, self.height)?;
        if base.len() != expected {
            return Err(ToolError::InvalidPixelLength);
        }
        let dx = end.0 - start.0;
        let dy = end.1 - start.1;
        let length_sq = (dx * dx + dy * dy).max(f32::EPSILON);
        let mut result = base.to_vec();
        for y in 0..self.height {
            for x in 0..self.width {
                let index = usize::try_from(y * self.width + x).unwrap_or(0);
                let t = (((x as f32 - start.0) * dx + (y as f32 - start.1) * dy) / length_sq)
                    .clamp(0.0, 1.0);
                let color = lerp_color(from, to, t);
                let mask = u16::from(self.values[index]);
                let inverse = u16::from(u8::MAX) - mask;
                result[index] = Rgba8 {
                    r: ((u16::from(base[index].r) * inverse + u16::from(color.r) * mask) / 255)
                        as u8,
                    g: ((u16::from(base[index].g) * inverse + u16::from(color.g) * mask) / 255)
                        as u8,
                    b: ((u16::from(base[index].b) * inverse + u16::from(color.b) * mask) / 255)
                        as u8,
                    a: ((u16::from(base[index].a) * inverse + u16::from(color.a) * mask) / 255)
                        as u8,
                };
            }
        }
        Ok(result)
    }
}

fn morphology_axis(
    source: &[u8],
    width: usize,
    height: usize,
    radius: usize,
    horizontal: bool,
    grow: bool,
) -> Vec<u8> {
    let mut output = vec![0; source.len()];
    let line_count = if horizontal { height } else { width };
    let line_len = if horizontal { width } else { height };
    for line in 0..line_count {
        let mut candidates = VecDeque::<usize>::new();
        let mut next = 0usize;
        for center in 0..line_len {
            let right = center.saturating_add(radius).min(line_len - 1);
            while next <= right {
                let index = if horizontal {
                    line * width + next
                } else {
                    next * width + line
                };
                let value = source[index];
                while let Some(&last) = candidates.back() {
                    let last_index = if horizontal {
                        line * width + last
                    } else {
                        last * width + line
                    };
                    let last_value = source[last_index];
                    if (grow && last_value <= value) || (!grow && last_value >= value) {
                        candidates.pop_back();
                    } else {
                        break;
                    }
                }
                candidates.push_back(next);
                next = next.saturating_add(1);
            }
            let left = center.saturating_sub(radius);
            while candidates
                .front()
                .is_some_and(|candidate| *candidate < left)
            {
                candidates.pop_front();
            }
            let boundary = !grow && (center < radius || center.saturating_add(radius) >= line_len);
            let value = if boundary {
                0
            } else {
                let sample = *candidates.front().unwrap_or(&center);
                let index = if horizontal {
                    line * width + sample
                } else {
                    sample * width + line
                };
                source[index]
            };
            let destination = if horizontal {
                line * width + center
            } else {
                center * width + line
            };
            output[destination] = value;
        }
    }
    output
}

/// Affine transform used by move/scale/rotate/perspective tool frontends.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Affine2D {
    pub a: f32,
    pub b: f32,
    pub c: f32,
    pub d: f32,
    pub tx: f32,
    pub ty: f32,
}

impl Affine2D {
    #[must_use]
    pub const fn identity() -> Self {
        Self {
            a: 1.0,
            b: 0.0,
            c: 0.0,
            d: 1.0,
            tx: 0.0,
            ty: 0.0,
        }
    }
    #[must_use]
    pub const fn translate(tx: f32, ty: f32) -> Self {
        Self {
            tx,
            ty,
            ..Self::identity()
        }
    }
    #[must_use]
    pub fn scale(sx: f32, sy: f32) -> Self {
        Self {
            a: sx,
            d: sy,
            ..Self::identity()
        }
    }
    #[must_use]
    pub fn rotate(radians: f32) -> Self {
        let (sin, cos) = radians.sin_cos();
        Self {
            a: cos,
            b: sin,
            c: -sin,
            d: cos,
            ..Self::identity()
        }
    }
    #[must_use]
    pub fn apply(self, point: (f32, f32)) -> (f32, f32) {
        (
            self.a * point.0 + self.c * point.1 + self.tx,
            self.b * point.0 + self.d * point.1 + self.ty,
        )
    }
    #[must_use]
    pub fn then(self, next: Self) -> Self {
        Self {
            a: next.a * self.a + next.c * self.b,
            b: next.b * self.a + next.d * self.b,
            c: next.a * self.c + next.c * self.d,
            d: next.b * self.c + next.d * self.d,
            tx: next.a * self.tx + next.c * self.ty + next.tx,
            ty: next.b * self.tx + next.d * self.ty + next.ty,
        }
    }
    #[must_use]
    pub fn snap_translation(self, grid: f32) -> Self {
        if grid.is_finite() && grid > 0.0 {
            Self {
                tx: (self.tx / grid).round() * grid,
                ty: (self.ty / grid).round() * grid,
                ..self
            }
        } else {
            self
        }
    }
}

impl ink_model::VectorAffineTransform for Affine2D {
    fn apply_vector_point(self, point: (f32, f32)) -> (f32, f32) {
        self.apply(point)
    }
}

/// A bounded bilinear perspective transform for a selected quadrilateral.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct PerspectiveTransform {
    pub source: [(f32, f32); 4],
    pub target: [(f32, f32); 4],
}

impl PerspectiveTransform {
    #[must_use]
    pub fn apply(self, point: (f32, f32)) -> (f32, f32) {
        let source_width = (self.source[1].0 - self.source[0].0)
            .abs()
            .max(f32::EPSILON);
        let source_height = (self.source[3].1 - self.source[0].1)
            .abs()
            .max(f32::EPSILON);
        let u = ((point.0 - self.source[0].0) / source_width).clamp(-2.0, 3.0);
        let v = ((point.1 - self.source[0].1) / source_height).clamp(-2.0, 3.0);
        let top = lerp_point(self.target[0], self.target[1], u);
        let bottom = lerp_point(self.target[3], self.target[2], u);
        lerp_point(top, bottom, v)
    }
}

/// A regular mesh deformation with bounded control-point count.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct MeshTransform {
    pub columns: u16,
    pub rows: u16,
    pub points: Vec<(f32, f32)>,
}

impl MeshTransform {
    pub fn new(columns: u16, rows: u16, points: Vec<(f32, f32)>) -> Result<Self, ToolError> {
        if !(2..=32).contains(&columns) || !(2..=32).contains(&rows) {
            return Err(ToolError::InvalidDimensions);
        }
        let expected = usize::from(columns) * usize::from(rows);
        if points.len() != expected {
            return Err(ToolError::InvalidDimensions);
        }
        if points.iter().any(|(x, y)| !x.is_finite() || !y.is_finite()) {
            return Err(ToolError::InvalidDimensions);
        }
        Ok(Self {
            columns,
            rows,
            points,
        })
    }

    #[must_use]
    pub fn apply(self, point: (f32, f32), bounds: (f32, f32, f32, f32)) -> (f32, f32) {
        let u = ((point.0 - bounds.0) / (bounds.2 - bounds.0).max(f32::EPSILON)).clamp(0.0, 1.0);
        let v = ((point.1 - bounds.1) / (bounds.3 - bounds.1).max(f32::EPSILON)).clamp(0.0, 1.0);
        let x = u * f32::from(self.columns - 1);
        let y = v * f32::from(self.rows - 1);
        let left = x.floor() as usize;
        let top = y.floor() as usize;
        let right = (left + 1).min(usize::from(self.columns - 1));
        let bottom = (top + 1).min(usize::from(self.rows - 1));
        let fx = x - left as f32;
        let fy = y - top as f32;
        let at = |column: usize, row: usize| self.points[row * usize::from(self.columns) + column];
        let upper = lerp_point(at(left, top), at(right, top), fx);
        let lower = lerp_point(at(left, bottom), at(right, bottom), fx);
        lerp_point(upper, lower, fy)
    }
}

/// Bounded local liquify deformation used for non-destructive previews.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub enum LiquifyMode {
    Push,
    Expand,
    Contract,
    Twirl,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct LiquifyBrush {
    pub center: (f32, f32),
    pub radius: f32,
    pub strength: f32,
    pub mode: LiquifyMode,
}

impl LiquifyBrush {
    #[must_use]
    pub fn apply(self, point: (f32, f32), direction: (f32, f32)) -> (f32, f32) {
        let dx = point.0 - self.center.0;
        let dy = point.1 - self.center.1;
        let distance = dx.hypot(dy);
        if !self.radius.is_finite() || self.radius <= 0.0 || distance >= self.radius {
            return point;
        }
        let falloff = (1.0 - distance / self.radius).powi(2) * self.strength.clamp(-1.0, 1.0);
        match self.mode {
            LiquifyMode::Push => (
                point.0 + direction.0 * falloff,
                point.1 + direction.1 * falloff,
            ),
            LiquifyMode::Expand => (
                self.center.0 + dx * (1.0 + falloff),
                self.center.1 + dy * (1.0 + falloff),
            ),
            LiquifyMode::Contract => (
                self.center.0 + dx * (1.0 - falloff),
                self.center.1 + dy * (1.0 - falloff),
            ),
            LiquifyMode::Twirl => {
                let angle = falloff * std::f32::consts::PI;
                let (sin, cos) = angle.sin_cos();
                (
                    self.center.0 + dx * cos - dy * sin,
                    self.center.1 + dx * sin + dy * cos,
                )
            }
        }
    }
}

fn lerp_point(left: (f32, f32), right: (f32, f32), amount: f32) -> (f32, f32) {
    (
        left.0 + (right.0 - left.0) * amount,
        left.1 + (right.1 - left.1) * amount,
    )
}

/// Operations that preserve the sampled legacy stroke representation.
pub trait VectorStrokeOperations {
    #[must_use]
    fn simplify(&self, tolerance: f32) -> Self
    where
        Self: Sized;
    fn width_at(&self, index: usize, min_width: f32, max_width: f32) -> f32;
    fn transform(&mut self, transform: Affine2D);
    fn connect(&self, other: &Self, tolerance: f32) -> Option<Self>
    where
        Self: Sized;
    fn erase_segment(&self, center: (f32, f32), radius: f32) -> Vec<Self>
    where
        Self: Sized;
}

impl VectorStrokeOperations for VectorStroke {
    fn simplify(&self, tolerance: f32) -> Self {
        if self.points.len() < 3 || !tolerance.is_finite() || tolerance <= 0.0 {
            return self.clone();
        }
        let mut output = Vec::with_capacity(self.points.len());
        rdp(&self.points, tolerance * tolerance, &mut output);
        Self {
            points: output,
            closed: self.closed,
        }
    }

    fn width_at(&self, index: usize, min_width: f32, max_width: f32) -> f32 {
        let pressure = self
            .points
            .get(index)
            .map_or(0.0, |point| point.pressure.clamp(0.0, 1.0));
        min_width + (max_width - min_width) * pressure
    }

    fn transform(&mut self, transform: Affine2D) {
        for point in &mut self.points {
            (point.x, point.y) = transform.apply((point.x, point.y));
        }
    }

    /// Join two strokes when their endpoints are within the requested gap.
    fn connect(&self, other: &Self, tolerance: f32) -> Option<Self> {
        let first = self.points.last()?;
        let last = other.points.first()?;
        if (first.x - last.x).hypot(first.y - last.y) > tolerance.max(0.0) {
            return None;
        }
        let mut points = self.points.clone();
        points.extend_from_slice(&other.points[1..]);
        Some(Self {
            points,
            closed: self.closed || other.closed,
        })
    }

    /// Erase a circular segment from vector ink and return the surviving
    /// pieces. Each piece remains editable centerline data.
    fn erase_segment(&self, center: (f32, f32), radius: f32) -> Vec<Self> {
        // Invalid geometry should never turn into an accidental destructive
        // erase. Keep the original stroke intact and let the caller decide
        // how to report malformed input.
        if !center.0.is_finite()
            || !center.1.is_finite()
            || !radius.is_finite()
            || self
                .points
                .iter()
                .any(|point| !point.x.is_finite() || !point.y.is_finite())
        {
            return vec![self.clone()];
        }

        if self.points.len() < 2 {
            let Some(point) = self.points.first() else {
                return Vec::new();
            };
            let dx = point.x - center.0;
            let dy = point.y - center.1;
            return if dx * dx + dy * dy > radius.max(0.0).powi(2) {
                vec![self.clone()]
            } else {
                Vec::new()
            };
        }

        let radius = radius.max(0.0);
        let radius_sq = radius * radius;
        let mut pieces = Vec::new();
        let mut current = Vec::new();

        let mut erased_any = false;
        let segment_count = if self.closed {
            self.points.len()
        } else {
            self.points.len() - 1
        };

        for segment_index in 0..segment_count {
            let start = self.points[segment_index];
            let end = self.points[(segment_index + 1) % self.points.len()];
            let roots = segment_circle_intersections(start, end, center, radius);
            let mut cuts = Vec::with_capacity(roots.len() + 2);
            cuts.push(0.0);
            cuts.extend(roots);
            cuts.push(1.0);

            for window in cuts.windows(2) {
                let start_t = window[0];
                let end_t = window[1];
                if end_t - start_t <= f32::EPSILON {
                    continue;
                }
                let midpoint_t = f32::midpoint(start_t, end_t);
                let midpoint = interpolate_vector_point(start, end, midpoint_t);
                let offset_x = midpoint.x - center.0;
                let offset_y = midpoint.y - center.1;
                let midpoint_outside = offset_x * offset_x + offset_y * offset_y > radius_sq;

                if !midpoint_outside {
                    flush_vector_piece(&mut pieces, &mut current);
                    erased_any = true;
                    continue;
                }

                let start_point = interpolate_vector_point(start, end, start_t);
                let end_point = interpolate_vector_point(start, end, end_t);
                let start_is_original_inside =
                    start_t <= f32::EPSILON && point_inside_circle(start, center, radius_sq);
                let end_is_original_inside =
                    end_t >= 1.0 - f32::EPSILON && point_inside_circle(end, center, radius_sq);

                if start_is_original_inside {
                    flush_vector_piece(&mut pieces, &mut current);
                    erased_any = true;
                } else {
                    append_vector_point(&mut current, start_point);
                }

                if end_is_original_inside {
                    flush_vector_piece(&mut pieces, &mut current);
                    erased_any = true;
                } else {
                    append_vector_point(&mut current, end_point);
                }
            }
        }

        flush_vector_piece(&mut pieces, &mut current);
        if !erased_any {
            // Preserve the closed flag when the eraser only touches the
            // stroke tangentially or misses it entirely.
            return vec![self.clone()];
        }
        pieces
    }
}

fn point_inside_circle(point: VectorPoint, center: (f32, f32), radius_sq: f32) -> bool {
    let dx = point.x - center.0;
    let dy = point.y - center.1;
    dx * dx + dy * dy <= radius_sq
}

fn interpolate_vector_point(start: VectorPoint, end: VectorPoint, amount: f32) -> VectorPoint {
    let amount = amount.clamp(0.0, 1.0);
    VectorPoint {
        x: start.x + (end.x - start.x) * amount,
        y: start.y + (end.y - start.y) * amount,
        pressure: start.pressure + (end.pressure - start.pressure) * amount,
        tilt: start.tilt + (end.tilt - start.tilt) * amount,
    }
}

fn append_vector_point(points: &mut Vec<VectorPoint>, point: VectorPoint) {
    if points.last().is_none_or(|last| *last != point) {
        points.push(point);
    }
}

fn flush_vector_piece(pieces: &mut Vec<VectorStroke>, current: &mut Vec<VectorPoint>) {
    if current.len() >= 2 {
        pieces.push(VectorStroke {
            points: std::mem::take(current),
            closed: false,
        });
    } else {
        current.clear();
    }
}

/// Return the (strictly interior) parameter values where a segment intersects
/// a circle. The result is sorted and deduplicated so callers can partition a
/// segment into deterministic inside/outside intervals.
fn segment_circle_intersections(
    start: VectorPoint,
    end: VectorPoint,
    center: (f32, f32),
    radius: f32,
) -> Vec<f32> {
    let dx = f64::from(end.x - start.x);
    let dy = f64::from(end.y - start.y);
    let fx = f64::from(start.x - center.0);
    let fy = f64::from(start.y - center.1);
    let a = dx * dx + dy * dy;
    if a <= f64::EPSILON {
        return Vec::new();
    }
    let radius = f64::from(radius);
    let b = 2.0 * (fx * dx + fy * dy);
    let c = fx * fx + fy * fy - radius * radius;
    let discriminant = b * b - 4.0 * a * c;
    if discriminant <= 0.0 {
        return Vec::new();
    }

    let root = discriminant.sqrt();
    let denominator = 2.0 * a;
    let mut roots = [
        ((-b - root) / denominator) as f32,
        ((-b + root) / denominator) as f32,
    ];
    roots.sort_by(f32::total_cmp);
    roots
        .into_iter()
        .filter(|value| value.is_finite() && *value > f32::EPSILON && *value < 1.0 - f32::EPSILON)
        .fold(Vec::with_capacity(2), |mut values, value| {
            if values
                .last()
                .is_none_or(|previous| (value - *previous).abs() > 1e-6)
            {
                values.push(value);
            }
            values
        })
}

/// Rulers expose only geometric snapping; rendering remains a UI concern.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum Ruler {
    Straight {
        origin: (f32, f32),
        angle: f32,
    },
    Parallel {
        origin: (f32, f32),
        angle: f32,
    },
    Symmetry {
        axis: (f32, f32, f32, f32),
    },
    Radial {
        center: (f32, f32),
        spokes: u16,
    },
    Perspective {
        horizon: (f32, f32),
        vanishing: Vec<(f32, f32)>,
    },
}

/// Bounded local time-lapse recording built from committed stroke history.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct TimeLapseSample {
    pub x: f32,
    pub y: f32,
    pub pressure: u16,
    pub tilt: (f32, f32),
    pub azimuth: f32,
    pub twist: f32,
    pub timestamp_ns: u64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct TimeLapseStroke {
    pub revision: u64,
    pub layer: u128,
    pub brush: u128,
    /// Source preset revision used to evaluate this stroke; zero denotes a legacy brush.
    #[serde(default)]
    pub brush_revision: u32,
    /// Brush evaluator semantics captured at stroke start; zero denotes a legacy brush.
    #[serde(default)]
    pub brush_semantics: u32,
    /// Whether the captured path used pulled-string conditioning.
    #[serde(default)]
    pub pulled_string: bool,
    /// Pulled-string distance in document pixels, or zero for legacy paths.
    #[serde(default)]
    pub stabilizer_distance_px: f32,
    /// Whether the captured stroke emitted its bounded terminal catch-up sample.
    #[serde(default)]
    pub catch_up_on_end: bool,
    pub samples: Vec<TimeLapseSample>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct TimeLapseRecording {
    pub format_version: u32,
    pub strokes: Vec<TimeLapseStroke>,
}

impl TimeLapseRecording {
    pub const FORMAT_VERSION: u32 = 2;
    pub const MAX_STROKES: usize = 100_000;
    pub const MAX_SAMPLES: usize = 2_000_000;

    #[must_use]
    pub fn new() -> Self {
        Self {
            format_version: Self::FORMAT_VERSION,
            strokes: Vec::new(),
        }
    }

    pub fn push(&mut self, stroke: TimeLapseStroke) -> Result<(), ToolError> {
        if self.format_version != Self::FORMAT_VERSION {
            return Err(ToolError::UnsupportedFormat);
        }
        let samples = self
            .strokes
            .iter()
            .map(|value| value.samples.len())
            .sum::<usize>();
        if self.strokes.len() >= Self::MAX_STROKES
            || samples.saturating_add(stroke.samples.len()) > Self::MAX_SAMPLES
        {
            return Err(ToolError::InvalidDimensions);
        }
        if stroke
            .samples
            .iter()
            .any(|sample| !sample.x.is_finite() || !sample.y.is_finite())
        {
            return Err(ToolError::InvalidDimensions);
        }
        let stabilizer_valid = stroke.stabilizer_distance_px.is_finite()
            && (0.0..=100.0).contains(&stroke.stabilizer_distance_px);
        let brush_metadata_valid = match stroke.brush_semantics {
            0 | 2000 => {
                !stroke.pulled_string
                    && stroke.stabilizer_distance_px.to_bits() == 0.0_f32.to_bits()
                    && !stroke.catch_up_on_end
            }
            2001 => stroke.brush_revision > 0 && stroke.pulled_string,
            2002 => {
                stroke.brush_revision > 0
                    && (stroke.pulled_string
                        || (stroke.stabilizer_distance_px.to_bits() == 0.0_f32.to_bits()
                            && !stroke.catch_up_on_end))
            }
            _ => false,
        };
        if !stabilizer_valid || !brush_metadata_valid {
            return Err(ToolError::InvalidStrokeMetadata);
        }
        self.strokes.push(stroke);
        Ok(())
    }

    pub fn to_json(&self) -> Result<Vec<u8>, serde_json::Error> {
        serde_json::to_vec(self)
    }
}

impl Ruler {
    #[must_use]
    pub fn snap(&self, point: (f32, f32)) -> (f32, f32) {
        match self {
            Self::Straight { origin, angle } | Self::Parallel { origin, angle } => {
                project_line(point, *origin, *angle)
            }
            Self::Symmetry { axis } => project_line(point, (axis.0, axis.1), axis.3.atan2(axis.2)),
            Self::Radial { center, spokes } => {
                if *spokes == 0 {
                    return *center;
                }
                let dx = point.0 - center.0;
                let dy = point.1 - center.1;
                let radius = dx.hypot(dy);
                let step = TAU / f32::from(*spokes);
                let angle = dy.atan2(dx);
                let snapped = (angle / step).round() * step;
                (
                    center.0 + radius * snapped.cos(),
                    center.1 + radius * snapped.sin(),
                )
            }
            Self::Perspective { horizon, vanishing } => vanishing
                .iter()
                .copied()
                .min_by(|a, b| {
                    distance_to_line(point, *horizon, *a)
                        .total_cmp(&distance_to_line(point, *horizon, *b))
                })
                .map_or(point, |vanishing| {
                    project_segment(point, *horizon, vanishing)
                }),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ToolError {
    InvalidDimensions,
    InvalidPixelLength,
    InvalidStrokeMetadata,
    UnsupportedFormat,
}

impl std::fmt::Display for ToolError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::InvalidDimensions => "tool dimensions are invalid",
            Self::InvalidPixelLength => "pixel buffer does not match tool dimensions",
            Self::InvalidStrokeMetadata => "time-lapse stroke metadata is invalid",
            Self::UnsupportedFormat => "time-lapse format version is unsupported",
        })
    }
}
impl std::error::Error for ToolError {}

fn pixel_count(width: u32, height: u32) -> Result<usize, ToolError> {
    let pixels = usize::try_from(width)
        .ok()
        .and_then(|w| usize::try_from(height).ok().and_then(|h| w.checked_mul(h)))
        .ok_or(ToolError::InvalidDimensions)?;
    if pixels == 0 || pixels > MAX_MASK_PIXELS {
        return Err(ToolError::InvalidDimensions);
    }
    Ok(pixels)
}

fn point_in_polygon(x: f32, y: f32, points: &[(f32, f32)]) -> bool {
    let mut inside = false;
    let mut previous = points[points.len() - 1];
    for &current in points {
        if ((current.1 > y) != (previous.1 > y))
            && x < (previous.0 - current.0) * (y - current.1)
                / (previous.1 - current.1).max(f32::MIN_POSITIVE)
                + current.0
        {
            inside = !inside;
        }
        previous = current;
    }
    inside
}

fn lerp_color(from: Rgba8, to: Rgba8, amount: f32) -> Rgba8 {
    let mix = |left: u8, right: u8| {
        (f32::from(left) + (f32::from(right) - f32::from(left)) * amount)
            .round()
            .clamp(0.0, 255.0) as u8
    };
    Rgba8 {
        r: mix(from.r, to.r),
        g: mix(from.g, to.g),
        b: mix(from.b, to.b),
        a: mix(from.a, to.a),
    }
}

fn rdp(points: &[VectorPoint], tolerance_sq: f32, output: &mut Vec<VectorPoint>) {
    if points.len() <= 2 {
        output.extend_from_slice(points);
        return;
    }
    let first = points[0];
    let last = points[points.len() - 1];
    let mut farthest = 0.0;
    let mut index = 0;
    for (candidate_index, point) in points.iter().enumerate().take(points.len() - 1).skip(1) {
        let distance =
            distance_to_segment((point.x, point.y), (first.x, first.y), (last.x, last.y));
        if distance > farthest {
            farthest = distance;
            index = candidate_index;
        }
    }
    if farthest > tolerance_sq {
        rdp(&points[..=index], tolerance_sq, output);
        output.pop();
        rdp(&points[index..], tolerance_sq, output);
    } else {
        output.push(first);
        output.push(last);
    }
}

fn distance_to_segment(point: (f32, f32), start: (f32, f32), end: (f32, f32)) -> f32 {
    let dx = end.0 - start.0;
    let dy = end.1 - start.1;
    let length_sq = dx * dx + dy * dy;
    let t = if length_sq > 0.0 {
        ((point.0 - start.0) * dx + (point.1 - start.1) * dy) / length_sq
    } else {
        0.0
    }
    .clamp(0.0, 1.0);
    let x = start.0 + t * dx;
    let y = start.1 + t * dy;
    let ex = point.0 - x;
    let ey = point.1 - y;
    ex * ex + ey * ey
}

fn project_line(point: (f32, f32), origin: (f32, f32), angle: f32) -> (f32, f32) {
    let direction = (angle.cos(), angle.sin());
    let distance = (point.0 - origin.0) * direction.0 + (point.1 - origin.1) * direction.1;
    (
        origin.0 + distance * direction.0,
        origin.1 + distance * direction.1,
    )
}
fn project_segment(point: (f32, f32), start: (f32, f32), end: (f32, f32)) -> (f32, f32) {
    let dx = end.0 - start.0;
    let dy = end.1 - start.1;
    let length = dx.hypot(dy).max(f32::MIN_POSITIVE);
    let direction = (dx / length, dy / length);
    let distance = (point.0 - start.0) * direction.0 + (point.1 - start.1) * direction.1;
    (
        start.0 + distance * direction.0,
        start.1 + distance * direction.1,
    )
}
fn distance_to_line(point: (f32, f32), start: (f32, f32), end: (f32, f32)) -> f32 {
    distance_to_segment(point, start, end)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn masks_cover_basic_selection_operations() {
        let mut mask = SelectionMask::rectangle(8, 8, 2, 2, 5, 5).expect("mask");
        assert_eq!(mask.get(2, 2), 255);
        assert_eq!(mask.get(5, 5), 0);
        mask.expand(1);
        assert_eq!(mask.get(1, 2), 255);
        mask.invert();
        assert_eq!(mask.get(2, 2), 0);
    }

    #[test]
    fn flood_fill_stays_inside_boundary() {
        let mut pixels = vec![
            Rgba8 {
                r: 255,
                g: 255,
                b: 255,
                a: 255
            };
            25
        ];
        for y in 0..5 {
            pixels[y * 5 + 2] = Rgba8 {
                r: 0,
                g: 0,
                b: 0,
                a: 255,
            };
        }
        let mask = SelectionMask::flood_fill(&pixels, 5, 5, 0, 0, 0, 0).expect("fill");
        assert_eq!(mask.get(1, 1), 255);
        assert_eq!(mask.get(3, 1), 0);
        assert_eq!(mask.get(2, 1), 0);
    }

    #[test]
    fn flood_fill_gap_closing_is_bounded_to_consecutive_barrier_pixels() {
        let mut pixels = vec![
            Rgba8 {
                r: 255,
                g: 255,
                b: 255,
                a: 255,
            };
            7
        ];
        // Two dark barrier pixels separate the white source from a distinct
        // red region. A one-pixel gap allowance may cross the first barrier,
        // but must not leap through the second one.
        pixels[1] = Rgba8 {
            r: 0,
            g: 0,
            b: 0,
            a: 255,
        };
        pixels[2] = pixels[1];
        for pixel in &mut pixels[3..] {
            *pixel = Rgba8 {
                r: 255,
                g: 0,
                b: 0,
                a: 255,
            };
        }
        let mask = SelectionMask::flood_fill(&pixels, 7, 1, 0, 0, 0, 1).expect("fill");
        assert_eq!(mask.get(0, 0), 255);
        assert_eq!(mask.get(1, 0), 255);
        assert_eq!(mask.get(2, 0), 0);
        assert_eq!(mask.get(3, 0), 0);
    }

    #[test]
    fn transform_and_vector_simplification_are_deterministic() {
        let transform = Affine2D::translate(2.0, 3.0).then(Affine2D::scale(2.0, 2.0));
        assert_eq!(transform.apply((1.0, 1.0)), (6.0, 8.0));
        let stroke = VectorStroke {
            closed: false,
            points: vec![
                VectorPoint {
                    x: 0.0,
                    y: 0.0,
                    pressure: 1.0,
                    tilt: 0.0,
                },
                VectorPoint {
                    x: 0.5,
                    y: 0.01,
                    pressure: 0.5,
                    tilt: 0.0,
                },
                VectorPoint {
                    x: 1.0,
                    y: 0.0,
                    pressure: 0.25,
                    tilt: 0.0,
                },
            ],
        };
        assert_eq!(stroke.simplify(0.1).points.len(), 2);
    }

    #[test]
    fn rulers_snap_to_expected_geometry() {
        let ruler = Ruler::Straight {
            origin: (0.0, 0.0),
            angle: 0.0,
        };
        assert_eq!(ruler.snap((2.0, 3.0)), (2.0, 0.0));
        let radial = Ruler::Radial {
            center: (0.0, 0.0),
            spokes: 4,
        };
        let snapped = radial.snap((1.0, 0.2));
        assert!((snapped.1).abs() < 0.001);
    }

    #[test]
    fn selection_gradient_and_transform_tools_are_bounded() {
        let mut mask = SelectionMask::full(4, 4).expect("mask");
        mask.feather(1);
        let base = vec![Rgba8::default(); 16];
        let gradient = mask
            .gradient_fill(
                &base,
                (0.0, 0.0),
                (3.0, 0.0),
                Rgba8 {
                    r: 0,
                    g: 0,
                    b: 0,
                    a: 255,
                },
                Rgba8 {
                    r: 255,
                    g: 0,
                    b: 0,
                    a: 255,
                },
            )
            .expect("gradient");
        assert_eq!(gradient.len(), 16);
        let mesh = MeshTransform::new(2, 2, vec![(0.0, 0.0), (4.0, 0.0), (0.0, 4.0), (4.0, 4.0)])
            .expect("mesh");
        assert_eq!(mesh.apply((2.0, 2.0), (0.0, 0.0, 4.0, 4.0)), (2.0, 2.0));
        let liquify = LiquifyBrush {
            center: (0.0, 0.0),
            radius: 10.0,
            strength: 0.5,
            mode: LiquifyMode::Push,
        };
        assert_ne!(liquify.apply((1.0, 0.0), (1.0, 0.0)), (1.0, 0.0));
    }

    #[test]
    fn selection_growth_shrink_and_invert_are_bounded_and_deterministic() {
        let mut one_pixel = SelectionMask::rectangle(5, 5, 2, 2, 3, 3).expect("selection");
        one_pixel.grow(1).expect("grow");
        assert_eq!(
            one_pixel
                .values
                .iter()
                .map(|value| u32::from(*value))
                .sum::<u32>(),
            9 * u32::from(u8::MAX)
        );
        assert_eq!(one_pixel.get(1, 2), 255);
        assert_eq!(one_pixel.get(0, 0), 0);

        let mut full = SelectionMask::full(5, 5).expect("full selection");
        full.shrink(1).expect("shrink");
        assert_eq!(full.get(0, 0), 0);
        assert_eq!(full.get(1, 1), 255);
        assert_eq!(
            full.values
                .iter()
                .map(|value| u32::from(*value))
                .sum::<u32>(),
            9 * u32::from(u8::MAX)
        );
        full.invert();
        assert_eq!(full.get(1, 1), 0);
        assert_eq!(full.get(0, 0), 255);
        assert!(full.grow(257).is_err());
    }

    #[test]
    fn vector_connect_erase_and_timelapse_are_deterministic() {
        let stroke = VectorStroke {
            closed: false,
            points: vec![
                VectorPoint {
                    x: 0.0,
                    y: 0.0,
                    pressure: 1.0,
                    tilt: 0.0,
                },
                VectorPoint {
                    x: 1.0,
                    y: 0.0,
                    pressure: 1.0,
                    tilt: 0.0,
                },
                VectorPoint {
                    x: 2.0,
                    y: 0.0,
                    pressure: 1.0,
                    tilt: 0.0,
                },
            ],
        };
        let next = VectorStroke {
            closed: false,
            points: vec![
                VectorPoint {
                    x: 2.0,
                    y: 0.0,
                    pressure: 1.0,
                    tilt: 0.0,
                },
                VectorPoint {
                    x: 3.0,
                    y: 0.0,
                    pressure: 1.0,
                    tilt: 0.0,
                },
            ],
        };
        let joined = stroke.connect(&next, 0.0).expect("join");
        assert_eq!(joined.points.len(), 4);
        assert_eq!(stroke.erase_segment((1.0, 0.0), 0.1).len(), 2);
        let mut recording = TimeLapseRecording::new();
        recording
            .push(TimeLapseStroke {
                revision: 1,
                layer: 1,
                brush: 2,
                brush_revision: 3,
                brush_semantics: 2001,
                pulled_string: true,
                stabilizer_distance_px: 12.5,
                catch_up_on_end: true,
                samples: vec![TimeLapseSample {
                    x: 0.0,
                    y: 0.0,
                    pressure: 65535,
                    tilt: (0.0, 0.0),
                    azimuth: 0.0,
                    twist: 0.0,
                    timestamp_ns: 1,
                }],
            })
            .expect("record");
        let bytes = recording.to_json().expect("json");
        assert!(!bytes.is_empty());
        let decoded: TimeLapseRecording = serde_json::from_slice(&bytes).expect("decode v2");
        assert_eq!(decoded.format_version, 2);
        assert_eq!(decoded.strokes[0].brush_revision, 3);
        assert_eq!(decoded.strokes[0].brush_semantics, 2001);
        assert!(decoded.strokes[0].pulled_string);
        assert_eq!(
            decoded.strokes[0].stabilizer_distance_px.to_bits(),
            12.5_f32.to_bits()
        );
        assert!(decoded.strokes[0].catch_up_on_end);
    }

    #[test]
    fn time_lapse_v1_strokes_default_new_brush_metadata() {
        let legacy =
            r#"{"format_version":1,"strokes":[{"revision":1,"layer":1,"brush":2,"samples":[]}]}"#;
        let decoded: TimeLapseRecording = serde_json::from_str(legacy).expect("decode v1");
        assert_eq!(decoded.format_version, 1);
        assert_eq!(decoded.strokes[0].brush_revision, 0);
        assert_eq!(decoded.strokes[0].brush_semantics, 0);
        assert!(!decoded.strokes[0].pulled_string);
        assert_eq!(
            decoded.strokes[0].stabilizer_distance_px.to_bits(),
            0.0_f32.to_bits()
        );
        assert!(!decoded.strokes[0].catch_up_on_end);
    }

    #[test]
    fn time_lapse_rejects_unsupported_or_inconsistent_stroke_metadata() {
        let mut recording = TimeLapseRecording::new();
        let mut stroke = TimeLapseStroke {
            revision: 1,
            layer: 1,
            brush: 2,
            brush_revision: 1,
            brush_semantics: 2001,
            pulled_string: true,
            stabilizer_distance_px: 10.0,
            catch_up_on_end: true,
            samples: Vec::new(),
        };
        stroke.brush_semantics = 9999;
        assert_eq!(
            recording.push(stroke.clone()),
            Err(ToolError::InvalidStrokeMetadata)
        );

        stroke.brush_semantics = 2001;
        stroke.stabilizer_distance_px = f32::NAN;
        assert_eq!(
            recording.push(stroke),
            Err(ToolError::InvalidStrokeMetadata)
        );

        recording.format_version = 1;
        assert_eq!(
            recording.push(TimeLapseStroke {
                revision: 1,
                layer: 1,
                brush: 2,
                brush_revision: 0,
                brush_semantics: 0,
                pulled_string: false,
                stabilizer_distance_px: 0.0,
                catch_up_on_end: false,
                samples: Vec::new(),
            }),
            Err(ToolError::UnsupportedFormat)
        );
    }

    #[test]
    fn vector_intersection_erase_interpolates_and_preserves_misses() {
        let crossing = VectorStroke {
            closed: false,
            points: vec![
                VectorPoint {
                    x: 0.0,
                    y: 0.0,
                    pressure: 0.0,
                    tilt: 0.0,
                },
                VectorPoint {
                    x: 10.0,
                    y: 0.0,
                    pressure: 1.0,
                    tilt: 1.0,
                },
            ],
        };
        let erased = crossing.erase_segment((5.0, 0.0), 1.0);
        assert_eq!(erased.len(), 2);
        assert!((erased[0].points.last().expect("left endpoint").x - 4.0).abs() < 1e-5);
        assert!((erased[1].points.first().expect("right endpoint").x - 6.0).abs() < 1e-5);
        assert!((erased[0].points.last().expect("left pressure").pressure - 0.4).abs() < 1e-5);
        assert!((erased[1].points.first().expect("right tilt").tilt - 0.6).abs() < 1e-5);

        let miss = crossing.erase_segment((5.0, 2.0), 1.0);
        assert_eq!(miss, vec![crossing]);

        let closed = VectorStroke {
            closed: true,
            points: vec![
                VectorPoint {
                    x: 0.0,
                    y: 0.0,
                    pressure: 1.0,
                    tilt: 0.0,
                },
                VectorPoint {
                    x: 1.0,
                    y: 0.0,
                    pressure: 1.0,
                    tilt: 0.0,
                },
                VectorPoint {
                    x: 1.0,
                    y: 1.0,
                    pressure: 1.0,
                    tilt: 0.0,
                },
            ],
        };
        assert_eq!(closed.erase_segment((8.0, 8.0), 1.0), vec![closed]);
    }
}

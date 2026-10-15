//! Bounded vector geometry services for Project Ink.
//!
//! This crate contains deterministic geometry only. Document mutation,
//! selection state, persistence, and transactions remain owned by the engine.
#![forbid(unsafe_code)]

use ink_model::{
    AnchorKind, BezierAnchor, BezierPath, BezierSubpath, FillRule, Rgba8, StrokeCap, StrokeJoin,
    VectorStroke, VectorStyle,
};
pub use kurbo::{Point, Rect};

mod hit_test;
mod raster;
mod repeat;
mod smart_guides;
mod source_contour;
mod source_fit;
mod source_recognize;

pub use hit_test::{hit_test_bezier_path, hit_test_legacy_stroke};
pub use raster::{RasterPixel, rasterize_bezier_path};
pub use repeat::{MAX_REPEAT_OBJECTS, mirror_path, repeat_grid, repeat_radial};
pub use smart_guides::{GuideFeatures, SmartGuideMatch, SmartGuideResult, snap_smart_guides};

/// Maximum region size accepted by monochrome raster tracing.
pub const MAX_TRACE_PIXELS: usize = 4_194_304;
/// Maximum anchors emitted by a single trace operation.
pub const MAX_TRACE_ANCHORS: usize = 2_048;
/// Maximum point-to-segment evaluations performed while fitting trace contours.
pub const MAX_TRACE_FIT_CHECKS: usize = 4_194_304;

/// Bounded settings for black-and-white raster tracing.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TraceOptions {
    /// Pixels below this composited luminance are foreground.
    pub threshold: u8,
    /// Components with fewer pixels are discarded; zero keeps every component.
    pub min_component_pixels: usize,
    /// Maximum contour simplification deviation in document pixels.
    pub fit_tolerance_px: f64,
}

impl Default for TraceOptions {
    fn default() -> Self {
        Self {
            threshold: 128,
            min_component_pixels: 8,
            fit_tolerance_px: 0.75,
        }
    }
}

/// Trace a row-major straight-alpha RGBA image into black filled contours.
///
/// The input dimensions and byte count are checked before any mask allocation.
/// Transparent source pixels are treated as background and luminance uses the
/// documented integer sRGB approximation.
///
/// # Errors
/// Returns `InvalidInput` for invalid dimensions/settings and `TooComplex`
/// when checked sizes or generated geometry exceed the supported budget.
pub fn trace_black_white(
    width: u32,
    height: u32,
    rgba: &[u8],
    options: TraceOptions,
) -> Result<Vec<BezierPath>, VectorError> {
    let width_usize = usize::try_from(width).map_err(|_| VectorError::InvalidInput)?;
    let height_usize = usize::try_from(height).map_err(|_| VectorError::InvalidInput)?;
    let pixels = width_usize
        .checked_mul(height_usize)
        .ok_or(VectorError::TooComplex)?;
    let bytes = pixels.checked_mul(4).ok_or(VectorError::TooComplex)?;
    if width_usize == 0
        || height_usize == 0
        || width_usize > 4096
        || height_usize > 4096
        || pixels > MAX_TRACE_PIXELS
        || bytes != rgba.len()
        || options.min_component_pixels > 256
        || !options.fit_tolerance_px.is_finite()
        || !(0.25..=4.0).contains(&options.fit_tolerance_px)
    {
        return Err(VectorError::InvalidInput);
    }
    let mask = trace_foreground_mask(pixels, rgba, options.threshold)?;
    let components = source_contour::trace_mask_bounded(&mask, width_usize, height_usize)
        .ok_or(VectorError::TooComplex)?;
    let mut output = Vec::new();
    output
        .try_reserve(components.len())
        .map_err(|_| VectorError::TooComplex)?;
    let mut anchors_total = 0usize;
    for component in components
        .into_iter()
        .filter(|c| c.pixels >= options.min_component_pixels.max(1))
    {
        let Some(subpaths) =
            component_to_subpaths(component, options.fit_tolerance_px, &mut anchors_total)?
        else {
            continue;
        };
        output.push(BezierPath {
            subpaths,
            style: VectorStyle {
                fill: Some(Rgba8 {
                    r: 0,
                    g: 0,
                    b: 0,
                    a: 255,
                }),
                stroke: None,
                stroke_width: 0.0,
                cap: StrokeCap::Butt,
                join: StrokeJoin::Miter,
                miter_limit: 4.0,
                fill_rule: FillRule::NonZero,
            },
        });
    }
    Ok(output)
}

fn trace_foreground_mask(
    pixels: usize,
    rgba: &[u8],
    threshold: u8,
) -> Result<Vec<bool>, VectorError> {
    let mut mask = Vec::new();
    mask.try_reserve_exact(pixels)
        .map_err(|_| VectorError::TooComplex)?;
    let (pixel_bytes, remainder) = rgba.as_chunks::<4>();
    if !remainder.is_empty() {
        return Err(VectorError::InvalidInput);
    }
    for &[red, green, blue, alpha] in pixel_bytes {
        let luminance =
            (54 * u32::from(red) + 183 * u32::from(green) + 19 * u32::from(blue) + 128) >> 8;
        let composited =
            (luminance * u32::from(alpha) + 255 * (255 - u32::from(alpha)) + 127) / 255;
        mask.push(alpha != 0 && composited < u32::from(threshold));
    }
    Ok(mask)
}

fn component_to_subpaths(
    component: source_contour::Component,
    tolerance: f64,
    anchors_total: &mut usize,
) -> Result<Option<Vec<BezierSubpath>>, VectorError> {
    let contour_count = component
        .holes
        .len()
        .checked_add(1)
        .ok_or(VectorError::TooComplex)?;
    let mut contours = Vec::new();
    contours
        .try_reserve_exact(contour_count)
        .map_err(|_| VectorError::TooComplex)?;
    contours.push(component.outer);
    contours.extend(component.holes);
    let mut subpaths = Vec::new();
    subpaths
        .try_reserve_exact(contours.len())
        .map_err(|_| VectorError::TooComplex)?;
    for contour in contours {
        let mut points = Vec::new();
        points
            .try_reserve_exact(contour.pts.len())
            .map_err(|_| VectorError::TooComplex)?;
        points.extend(
            contour
                .pts
                .iter()
                .map(|(x, y)| (f64::from(*x), f64::from(*y))),
        );
        let fitted = simplify_closed(&points, tolerance).ok_or(VectorError::TooComplex)?;
        if fitted.len() < 3 {
            continue;
        }
        *anchors_total = anchors_total
            .checked_add(fitted.len())
            .ok_or(VectorError::TooComplex)?;
        if *anchors_total > MAX_TRACE_ANCHORS {
            return Err(VectorError::TooComplex);
        }
        let mut anchors = Vec::new();
        anchors
            .try_reserve_exact(fitted.len())
            .map_err(|_| VectorError::TooComplex)?;
        anchors.extend(fitted.into_iter().map(anchor));
        subpaths.push(BezierSubpath {
            anchors,
            closed: true,
        });
    }
    Ok((!subpaths.is_empty()).then_some(subpaths))
}

fn simplify_closed(points: &[(f64, f64)], tolerance: f64) -> Option<Vec<(f64, f64)>> {
    if points.len() < 4 {
        let mut output = Vec::new();
        output.try_reserve_exact(points.len()).ok()?;
        output.extend_from_slice(points);
        return Some(output);
    }
    let mut open = Vec::new();
    open.try_reserve_exact(points.len()).ok()?;
    open.extend_from_slice(points);
    if open.first() == open.last() {
        open.pop();
    }
    let Some(first) = open.first().copied() else {
        return Some(Vec::new());
    };
    let (split, _) = open
        .iter()
        .enumerate()
        .max_by(|(_, a), (_, b)| point_distance(first, **a).total_cmp(&point_distance(first, **b)))
        .unwrap_or((0, &first));
    let ring_len = open.len().checked_add(1)?;
    let mut ring = Vec::new();
    ring.try_reserve_exact(ring_len).ok()?;
    ring.extend(open.iter().cycle().skip(split).take(ring_len).copied());
    let fit = fit_polyline(&ring, tolerance)?;
    let count = fit.len().saturating_sub(1);
    if count < 3 {
        if open.len() > MAX_TRACE_ANCHORS {
            return None;
        }
        Some(open)
    } else {
        let mut output = Vec::new();
        output.try_reserve_exact(count).ok()?;
        output.extend(fit.into_iter().take(count));
        Some(output)
    }
}

fn fit_polyline(points: &[(f64, f64)], tolerance: f64) -> Option<Vec<(f64, f64)>> {
    if points.len() < 3 {
        let mut output = Vec::new();
        output.try_reserve_exact(points.len()).ok()?;
        output.extend_from_slice(points);
        return Some(output);
    }
    let mut keep = Vec::new();
    keep.try_reserve_exact(points.len()).ok()?;
    keep.resize(points.len(), false);
    keep[0] = true;
    keep[points.len() - 1] = true;
    let mut pending = Vec::new();
    pending.try_reserve(1).ok()?;
    pending.push((0usize, points.len() - 1));
    let mut evaluations = 0usize;
    while let Some((a, b)) = pending.pop() {
        evaluations = evaluations.checked_add(b.saturating_sub(a).saturating_sub(1))?;
        if evaluations > MAX_TRACE_FIT_CHECKS {
            return None;
        }
        let Some((idx, distance)) = (a + 1..b)
            .map(|i| (i, point_line_distance(points[i], points[a], points[b])))
            .max_by(|a, b| a.1.total_cmp(&b.1))
        else {
            continue;
        };
        if distance > tolerance {
            keep[idx] = true;
            if idx > a + 1 {
                pending.try_reserve(1).ok()?;
                pending.push((a, idx));
            }
            if b > idx + 1 {
                pending.try_reserve(1).ok()?;
                pending.push((idx, b));
            }
        }
    }
    let kept = keep.iter().filter(|keep| **keep).count();
    if kept > MAX_TRACE_ANCHORS.saturating_add(1) {
        return None;
    }
    let mut output = Vec::new();
    output.try_reserve_exact(kept).ok()?;
    output.extend(
        points
            .iter()
            .zip(keep)
            .filter_map(|(point, keep)| keep.then_some(*point)),
    );
    Some(output)
}

fn point_distance(a: (f64, f64), b: (f64, f64)) -> f64 {
    (a.0 - b.0).hypot(a.1 - b.1)
}

/// Maximum sampled points accepted by recognition.
pub const MAX_RECOGNITION_POINTS: usize = 8_192;

/// Errors returned by bounded vector algorithms.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum VectorError {
    /// Input contains invalid coordinates or parameters.
    InvalidInput,
    /// Input or generated output exceeds the bounded algorithm budget.
    TooComplex,
}

/// Result of recognizing a completed legacy stroke.
#[derive(Clone, Debug, PartialEq)]
pub struct Recognition {
    /// Replacement path to show in preview or commit.
    pub path: BezierPath,
    /// Stable result kind for UI labels and acceptance fixtures.
    pub kind: RecognizedKind,
}

/// The supported shape classifications.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RecognizedKind {
    /// Open straight line.
    Line,
    /// Closed four-sided shape.
    Rectangle,
    /// Closed four-cubic ellipse.
    Ellipse,
    /// Closed three-sided shape.
    Triangle,
}

/// Optional geometric constraint available for recognized previews.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ShapeConstraint {
    /// Equalize the two dimensions of a recognized rectangle.
    Square,
    /// Equalize the radii of a recognized ellipse.
    Circle,
}

/// Constrain a recognized rectangle or ellipse while preserving its center,
/// orientation, style, and source-independent geometry.
///
/// # Errors
/// Returns `InvalidInput` when the path is not a supported recognized shape
/// or its geometry is degenerate.
pub fn constrain_recognized_shape(
    path: &BezierPath,
    constraint: ShapeConstraint,
) -> Result<BezierPath, VectorError> {
    let Some(subpath) = path.subpaths.first() else {
        return Err(VectorError::InvalidInput);
    };
    if path.subpaths.len() != 1 || !subpath.closed {
        return Err(VectorError::InvalidInput);
    }
    let mut result = path.clone();
    let anchors = &mut result.subpaths[0].anchors;
    let expected_anchor_kind = match constraint {
        ShapeConstraint::Square => AnchorKind::Corner,
        ShapeConstraint::Circle => AnchorKind::Smooth,
    };
    if anchors.len() != 4
        || anchors
            .iter()
            .any(|anchor| anchor.kind != expected_anchor_kind)
    {
        return Err(VectorError::InvalidInput);
    }
    match constraint {
        ShapeConstraint::Square => constrain_square(anchors)?,
        ShapeConstraint::Circle => constrain_circle(anchors)?,
    }
    if result
        .subpaths
        .iter()
        .flat_map(|subpath| &subpath.anchors)
        .any(|anchor| {
            !anchor.x.is_finite()
                || !anchor.y.is_finite()
                || anchor
                    .incoming
                    .iter()
                    .chain(&anchor.outgoing)
                    .any(|v| !v.is_finite())
        })
    {
        return Err(VectorError::InvalidInput);
    }
    Ok(result)
}

fn constrain_square(anchors: &mut [BezierAnchor]) -> Result<(), VectorError> {
    let p0 = (anchors[0].x, anchors[0].y);
    let p1 = (anchors[1].x, anchors[1].y);
    let p2 = (anchors[2].x, anchors[2].y);
    let p3 = (anchors[3].x, anchors[3].y);
    let u = unit_vector((p1.0 - p0.0, p1.1 - p0.1))?;
    let v = unit_vector((p3.0 - p0.0, p3.1 - p0.1))?;
    let side = point_distance(p0, p1).max(point_distance(p0, p3));
    let center = (f64::midpoint(p0.0, p2.0), f64::midpoint(p0.1, p2.1));
    for (anchor, (u_sign, v_sign)) in
        anchors
            .iter_mut()
            .zip([(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)])
    {
        let point = (
            center.0 + side * 0.5 * (u_sign * u.0 + v_sign * v.0),
            center.1 + side * 0.5 * (u_sign * u.1 + v_sign * v.1),
        );
        *anchor = crate::anchor(point);
    }
    Ok(())
}

fn constrain_circle(anchors: &mut [BezierAnchor]) -> Result<(), VectorError> {
    let points = [
        (anchors[0].x, anchors[0].y),
        (anchors[1].x, anchors[1].y),
        (anchors[2].x, anchors[2].y),
        (anchors[3].x, anchors[3].y),
    ];
    let center = (
        f64::midpoint(points[0].0, points[2].0),
        f64::midpoint(points[0].1, points[2].1),
    );
    let u = unit_vector((points[0].0 - center.0, points[0].1 - center.1))?;
    let v = unit_vector((points[1].0 - center.0, points[1].1 - center.1))?;
    let radius = point_distance(center, points[0]).max(point_distance(center, points[1]));
    let k = 0.552_284_749_830_793_6 * radius;
    let positions = [
        add_scaled(center, u, radius),
        add_scaled(center, v, radius),
        add_scaled(center, u, -radius),
        add_scaled(center, v, -radius),
    ];
    let handles = [
        (
            add_scaled(positions[0], v, -k),
            add_scaled(positions[0], v, k),
        ),
        (
            add_scaled(positions[1], u, k),
            add_scaled(positions[1], u, -k),
        ),
        (
            add_scaled(positions[2], v, k),
            add_scaled(positions[2], v, -k),
        ),
        (
            add_scaled(positions[3], u, -k),
            add_scaled(positions[3], u, k),
        ),
    ];
    for ((anchor, position), (incoming, outgoing)) in anchors.iter_mut().zip(positions).zip(handles)
    {
        anchor.x = position.0;
        anchor.y = position.1;
        anchor.incoming = [incoming.0, incoming.1];
        anchor.outgoing = [outgoing.0, outgoing.1];
    }
    Ok(())
}

fn unit_vector(vector: (f64, f64)) -> Result<(f64, f64), VectorError> {
    let length = vector.0.hypot(vector.1);
    if !length.is_finite() || length <= f64::EPSILON {
        return Err(VectorError::InvalidInput);
    }
    Ok((vector.0 / length, vector.1 / length))
}

fn add_scaled(point: (f64, f64), vector: (f64, f64), scale: f64) -> (f64, f64) {
    (point.0 + vector.0 * scale, point.1 + vector.1 * scale)
}

/// Which absolute Bézier handle is being moved.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HandleKind {
    /// Handle approaching the anchor from the preceding segment.
    Incoming,
    /// Handle leaving the anchor toward the following segment.
    Outgoing,
}

/// Uniform affine transform supported by the first Bézier editing version.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct VectorTransform {
    /// Translation in document pixels.
    pub translate: (f64, f64),
    /// Rotation in degrees around the document origin.
    pub rotation_degrees: f64,
    /// Positive uniform scale; reflections are not supported.
    pub scale: f64,
}

/// Convert model anchors into a Kurbo path without changing document units.
///
/// # Errors
/// Returns `InvalidInput` if any subpath has no anchors.
pub fn to_kurbo(path: &BezierPath) -> Result<kurbo::BezPath, VectorError> {
    use kurbo::{BezPath, PathEl, Point};
    let mut output = BezPath::new();
    for subpath in &path.subpaths {
        let Some(first) = subpath.anchors.first() else {
            return Err(VectorError::InvalidInput);
        };
        output.push(PathEl::MoveTo(Point::new(first.x, first.y)));
        let count = subpath.anchors.len().saturating_sub(1) + usize::from(subpath.closed);
        for i in 0..count {
            let a = &subpath.anchors[i];
            let b = &subpath.anchors[(i + 1) % subpath.anchors.len()];
            output.push(PathEl::CurveTo(
                Point::new(a.outgoing[0], a.outgoing[1]),
                Point::new(b.incoming[0], b.incoming[1]),
                Point::new(b.x, b.y),
            ));
        }
        if subpath.closed {
            output.push(PathEl::ClosePath);
        }
    }
    Ok(output)
}

/// Recognize a line, rectangle, ellipse, or triangle from a legacy stroke.
///
/// A no-match result leaves mutation to the caller; this function never erases
/// strokes or interprets scribbles as commands.
///
/// # Errors
/// Returns `InvalidInput` for undersized, oversized, or non-finite strokes.
pub fn recognize(stroke: &VectorStroke) -> Result<Option<Recognition>, VectorError> {
    let points = &stroke.points;
    if points.len() > MAX_RECOGNITION_POINTS {
        return Err(VectorError::InvalidInput);
    }
    // A one-sample vector stroke is valid legacy ink (for example, a tap),
    // but it cannot describe one of the supported geometric shapes.
    if points.len() < 2 {
        return Ok(None);
    }
    if points.iter().any(|p| {
        !p.x.is_finite() || !p.y.is_finite() || !p.pressure.is_finite() || !p.tilt.is_finite()
    }) {
        return Err(VectorError::InvalidInput);
    }
    let input: Vec<Point> = points
        .iter()
        .map(|p| Point::new(f64::from(p.x), f64::from(p.y)))
        .collect();
    let Some(recognized) = source_recognize::recognize(&input) else {
        return Ok(None);
    };
    let pressure = mean_pressure(points);
    let (kind, path) = match recognized {
        source_recognize::Recognized::Line { a, b } => (
            RecognizedKind::Line,
            open_line((a.x, a.y), (b.x, b.y), pressure),
        ),
        source_recognize::Recognized::Rectangle { rect, rotation } => (
            RecognizedKind::Rectangle,
            rotated_rectangle(rect, rotation, pressure),
        ),
        source_recognize::Recognized::Ellipse { rect, rotation } => (
            RecognizedKind::Ellipse,
            rotated_ellipse(rect, rotation, pressure),
        ),
        source_recognize::Recognized::Polygon {
            center,
            radius,
            sides: 3,
            rotation,
        } => (
            RecognizedKind::Triangle,
            regular_polygon(center, radius, 3, rotation, pressure),
        ),
        source_recognize::Recognized::Polygon { .. }
        | source_recognize::Recognized::Scribble(_) => return Ok(None),
    };
    Ok(Some(Recognition { path, kind }))
}

/// Build a previewable path object while retaining the exact source samples.
///
/// # Errors
/// Returns the input errors reported by [`recognize`].
pub fn recognize_object(
    stroke: &VectorStroke,
) -> Result<Option<ink_model::VectorObject>, VectorError> {
    let Some(candidate) = recognize(stroke)? else {
        return Ok(None);
    };
    Ok(Some(ink_model::VectorObject::BezierPath {
        path: candidate.path,
        source: Some(ink_model::VectorSourceArchive {
            legacy: stroke.clone(),
        }),
    }))
}

/// Fit an open stroke to a chain of cubic Bézier segments using the pinned
/// least-squares fitter and a document-pixel error tolerance.
///
/// # Errors
/// Returns `InvalidInput` for malformed samples or a tolerance outside
/// `0.25..=8.0`, and `TooComplex` if the resulting path exceeds its anchor
/// limit or the fit cannot meet its tolerance within bounded iteration.
pub fn fit_curve(stroke: &VectorStroke, tolerance_px: f64) -> Result<BezierPath, VectorError> {
    if stroke.points.len() < 2
        || stroke.points.len() > MAX_RECOGNITION_POINTS
        || stroke.closed
        || !tolerance_px.is_finite()
        || !(0.25..=8.0).contains(&tolerance_px)
        || stroke.points.iter().any(|p| {
            !p.x.is_finite() || !p.y.is_finite() || !p.pressure.is_finite() || !p.tilt.is_finite()
        })
    {
        return Err(VectorError::InvalidInput);
    }
    let mut points = Vec::new();
    points
        .try_reserve_exact(stroke.points.len())
        .map_err(|_| VectorError::TooComplex)?;
    points.extend(
        stroke
            .points
            .iter()
            .map(|point| Point::new(f64::from(point.x), f64::from(point.y))),
    );
    let first = points[0];
    if points.last().is_none() {
        return Err(VectorError::InvalidInput);
    }
    let corner_indices = preserved_corner_indices(&points)?;
    let mut cubics = Vec::new();
    let mut corner_ends = Vec::new();
    for pair in corner_indices.windows(2) {
        let chunk = &points[pair[0]..=pair[1]];
        let start_tangent = vector_between(chunk[0], chunk[1]);
        let end_tangent = vector_between(chunk[chunk.len() - 2], chunk[chunk.len() - 1]);
        let fitted = source_fit::fit_cubics(chunk, start_tangent, end_tangent, tolerance_px)
            .filter(|curves| !curves.is_empty())
            .ok_or(VectorError::TooComplex)?;
        if cubics.len().saturating_add(fitted.len()) >= ink_model::MAX_BEZIER_ANCHORS {
            return Err(VectorError::TooComplex);
        }
        cubics
            .try_reserve(fitted.len())
            .map_err(|_| VectorError::TooComplex)?;
        corner_ends
            .try_reserve(fitted.len())
            .map_err(|_| VectorError::TooComplex)?;
        let fitted_len = fitted.len();
        for (index, cubic) in fitted.into_iter().enumerate() {
            cubics.push(cubic);
            corner_ends.push(index + 1 == fitted_len && pair[1] + 1 < points.len());
        }
    }
    if cubics.is_empty() {
        return Err(VectorError::InvalidInput);
    }
    let mut anchors = Vec::new();
    anchors
        .try_reserve_exact(cubics.len() + 1)
        .map_err(|_| VectorError::TooComplex)?;
    anchors.push(BezierAnchor {
        x: first.x,
        y: first.y,
        incoming: [first.x, first.y],
        outgoing: [first.x, first.y],
        kind: AnchorKind::Corner,
    });
    for (index, cubic) in cubics.iter().enumerate() {
        let start = anchors.last_mut().ok_or(VectorError::InvalidInput)?;
        start.outgoing = [cubic.p1.x, cubic.p1.y];
        if index > 0 && !corner_ends[index - 1] {
            start.kind = AnchorKind::Smooth;
        }
        anchors.push(BezierAnchor {
            x: cubic.p3.x,
            y: cubic.p3.y,
            incoming: [cubic.p2.x, cubic.p2.y],
            outgoing: [cubic.p3.x, cubic.p3.y],
            kind: if corner_ends[index] || index + 1 == cubics.len() {
                AnchorKind::Corner
            } else {
                AnchorKind::Smooth
            },
        });
    }
    Ok(make_path(
        BezierSubpath {
            anchors,
            closed: false,
        },
        mean_pressure(&stroke.points),
    ))
}

/// Convert a sampled stroke to a fitted path while retaining the exact source.
///
/// # Errors
/// Returns the input, tolerance, or complexity errors from [`fit_curve`].
pub fn fit_curve_object(
    stroke: &VectorStroke,
    tolerance_px: f64,
) -> Result<ink_model::VectorObject, VectorError> {
    let path = fit_curve(stroke, tolerance_px)?;
    Ok(ink_model::VectorObject::BezierPath {
        path,
        source: Some(ink_model::VectorSourceArchive {
            legacy: stroke.clone(),
        }),
    })
}

fn vector_between(from: Point, to: Point) -> kurbo::Vec2 {
    let delta = to - from;
    let length = delta.hypot();
    if length <= f64::EPSILON {
        kurbo::Vec2::new(1.0, 0.0)
    } else {
        delta / length
    }
}

fn preserved_corner_indices(points: &[Point]) -> Result<Vec<usize>, VectorError> {
    let mut corners = Vec::new();
    corners
        .try_reserve_exact(points.len())
        .map_err(|_| VectorError::TooComplex)?;
    corners.push(0);
    let mut previous_corner = 0;
    for index in 1..points.len().saturating_sub(1) {
        if index.saturating_sub(previous_corner) < 2 {
            continue;
        }
        let incoming = points[index] - points[index - 1];
        let outgoing = points[index + 1] - points[index];
        let lengths = incoming.hypot() * outgoing.hypot();
        if lengths <= f64::EPSILON {
            continue;
        }
        if incoming.dot(outgoing) / lengths < 0.5 {
            corners.push(index);
            previous_corner = index;
        }
    }
    corners.push(points.len() - 1);
    Ok(corners)
}

/// Translate one anchor and both absolute handles.
///
/// # Errors
/// Returns `InvalidInput` for a non-finite delta or a missing anchor.
pub fn move_anchor(
    path: &BezierPath,
    subpath: usize,
    anchor_index: usize,
    delta: (f64, f64),
) -> Result<BezierPath, VectorError> {
    if !delta.0.is_finite() || !delta.1.is_finite() {
        return Err(VectorError::InvalidInput);
    }
    let mut result = path.clone();
    let point = result
        .subpaths
        .get_mut(subpath)
        .and_then(|s| s.anchors.get_mut(anchor_index))
        .ok_or(VectorError::InvalidInput)?;
    point.x += delta.0;
    point.y += delta.1;
    point.incoming[0] += delta.0;
    point.incoming[1] += delta.1;
    point.outgoing[0] += delta.0;
    point.outgoing[1] += delta.1;
    if [
        point.x,
        point.y,
        point.incoming[0],
        point.incoming[1],
        point.outgoing[0],
        point.outgoing[1],
    ]
    .iter()
    .any(|value| !value.is_finite())
    {
        return Err(VectorError::InvalidInput);
    }
    Ok(result)
}

/// Apply translation, rotation and positive uniform scaling to path geometry.
/// Stroke width scales with the path; source archives are not part of this
/// function and remain unchanged.
///
/// # Errors
/// Returns `InvalidInput` for non-finite parameters, non-positive scale, or
/// transformed coordinates/styles outside finite numeric range.
pub fn transform_path(
    path: &BezierPath,
    transform: VectorTransform,
) -> Result<BezierPath, VectorError> {
    if !transform.translate.0.is_finite()
        || !transform.translate.1.is_finite()
        || !transform.rotation_degrees.is_finite()
        || !transform.scale.is_finite()
        || transform.scale <= 0.0
    {
        return Err(VectorError::InvalidInput);
    }
    let (sin, cos) = transform.rotation_degrees.to_radians().sin_cos();
    let mut result = path.clone();
    for subpath in &mut result.subpaths {
        for anchor in &mut subpath.anchors {
            let mut point = [anchor.x, anchor.y];
            transform_coordinates(&mut point, transform, sin, cos);
            (anchor.x, anchor.y) = (point[0], point[1]);
            transform_coordinates(&mut anchor.incoming, transform, sin, cos);
            transform_coordinates(&mut anchor.outgoing, transform, sin, cos);
        }
    }
    result.style.stroke_width *= transform.scale;
    if !result.style.stroke_width.is_finite()
        || result
            .subpaths
            .iter()
            .flat_map(|s| &s.anchors)
            .any(|anchor| {
                [
                    anchor.x,
                    anchor.y,
                    anchor.incoming[0],
                    anchor.incoming[1],
                    anchor.outgoing[0],
                    anchor.outgoing[1],
                ]
                .iter()
                .any(|coordinate| !coordinate.is_finite())
            })
    {
        return Err(VectorError::InvalidInput);
    }
    Ok(result)
}

fn transform_coordinates(point: &mut [f64; 2], transform: VectorTransform, sin: f64, cos: f64) {
    let x = point[0] * transform.scale;
    let y = point[1] * transform.scale;
    point[0] = cos * x - sin * y + transform.translate.0;
    point[1] = sin * x + cos * y + transform.translate.1;
}

/// Move one absolute handle, preserving smooth-anchor collinearity and the
/// opposite handle's length.
///
/// # Errors
/// Returns `InvalidInput` for a non-finite position, a missing anchor, or a
/// zero-length direction on a smooth anchor.
pub fn move_handle(
    path: &BezierPath,
    subpath: usize,
    anchor_index: usize,
    handle: HandleKind,
    position: (f64, f64),
) -> Result<BezierPath, VectorError> {
    if !position.0.is_finite() || !position.1.is_finite() {
        return Err(VectorError::InvalidInput);
    }
    let mut result = path.clone();
    let anchor = result
        .subpaths
        .get_mut(subpath)
        .and_then(|value| value.anchors.get_mut(anchor_index))
        .ok_or(VectorError::InvalidInput)?;
    match handle {
        HandleKind::Incoming => anchor.incoming = [position.0, position.1],
        HandleKind::Outgoing => anchor.outgoing = [position.0, position.1],
    }
    if anchor.kind == AnchorKind::Smooth {
        let (moving, fixed) = match handle {
            HandleKind::Incoming => (anchor.incoming, &mut anchor.outgoing),
            HandleKind::Outgoing => (anchor.outgoing, &mut anchor.incoming),
        };
        let dx = moving[0] - anchor.x;
        let dy = moving[1] - anchor.y;
        let length = dx.hypot(dy);
        if length <= f64::EPSILON {
            return Err(VectorError::InvalidInput);
        }
        let fixed_length = (fixed[0] - anchor.x).hypot(fixed[1] - anchor.y);
        let direction = if handle == HandleKind::Incoming {
            1.0
        } else {
            -1.0
        };
        *fixed = [
            anchor.x + direction * dx / length * fixed_length,
            anchor.y + direction * dy / length * fixed_length,
        ];
    }
    Ok(result)
}

/// Split a cubic segment with de Casteljau and insert one smooth anchor.
///
/// # Errors
/// Returns `InvalidInput` for an invalid parameter or segment and `TooComplex`
/// when the path has reached the anchor limit.
pub fn split_segment(
    path: &BezierPath,
    subpath_index: usize,
    segment_index: usize,
    t: f64,
) -> Result<BezierPath, VectorError> {
    if !t.is_finite() || !(0.0..=1.0).contains(&t) {
        return Err(VectorError::InvalidInput);
    }
    let mut result = path.clone();
    let subpath = result
        .subpaths
        .get_mut(subpath_index)
        .ok_or(VectorError::InvalidInput)?;
    let segment_count = if subpath.closed {
        subpath.anchors.len()
    } else {
        subpath.anchors.len().saturating_sub(1)
    };
    if segment_index >= segment_count || subpath.anchors.len() >= ink_model::MAX_BEZIER_ANCHORS {
        return Err(VectorError::TooComplex);
    }
    let next = (segment_index + 1) % subpath.anchors.len();
    let a = subpath.anchors[segment_index];
    let b = subpath.anchors[next];
    let p0 = (a.x, a.y);
    let p1 = (a.outgoing[0], a.outgoing[1]);
    let p2 = (b.incoming[0], b.incoming[1]);
    let p3 = (b.x, b.y);
    let point_01 = lerp(p0, p1, t);
    let point_12 = lerp(p1, p2, t);
    let point_23 = lerp(p2, p3, t);
    let left_curve_control = lerp(point_01, point_12, t);
    let right_curve_control = lerp(point_12, point_23, t);
    let point = lerp(left_curve_control, right_curve_control, t);
    subpath.anchors[segment_index].outgoing = [point_01.0, point_01.1];
    subpath.anchors[next].incoming = [point_23.0, point_23.1];
    let inserted = BezierAnchor {
        x: point.0,
        y: point.1,
        incoming: [left_curve_control.0, left_curve_control.1],
        outgoing: [right_curve_control.0, right_curve_control.1],
        kind: AnchorKind::Smooth,
    };
    subpath.anchors.insert(segment_index + 1, inserted);
    Ok(result)
}

/// Change an anchor's handle constraint without changing its position.
///
/// # Errors
/// Returns `InvalidInput` if the anchor does not exist.
pub fn set_anchor_kind(
    path: &BezierPath,
    subpath: usize,
    index: usize,
    kind: AnchorKind,
) -> Result<BezierPath, VectorError> {
    let mut result = path.clone();
    let anchor = result
        .subpaths
        .get_mut(subpath)
        .and_then(|s| s.anchors.get_mut(index))
        .ok_or(VectorError::InvalidInput)?;
    anchor.kind = kind;
    if kind == AnchorKind::Smooth {
        let dx = anchor.outgoing[0] - anchor.x;
        let dy = anchor.outgoing[1] - anchor.y;
        let length = dx.hypot(dy);
        if length > f64::EPSILON {
            let incoming_length =
                (anchor.incoming[0] - anchor.x).hypot(anchor.incoming[1] - anchor.y);
            anchor.incoming = [
                anchor.x - dx / length * incoming_length,
                anchor.y - dy / length * incoming_length,
            ];
        }
    }
    Ok(result)
}

/// Delete an anchor if the open/closed path remains structurally valid.
///
/// # Errors
/// Returns `InvalidInput` if the anchor is missing or deletion would leave
/// the subpath below its minimum number of anchors.
pub fn delete_anchor(
    path: &BezierPath,
    subpath: usize,
    index: usize,
) -> Result<BezierPath, VectorError> {
    let mut result = path.clone();
    let contour = result
        .subpaths
        .get_mut(subpath)
        .ok_or(VectorError::InvalidInput)?;
    let min = if contour.closed { 3 } else { 2 };
    if contour.anchors.len() <= min || index >= contour.anchors.len() {
        return Err(VectorError::InvalidInput);
    }
    contour.anchors.remove(index);
    Ok(result)
}

fn lerp(a: (f64, f64), b: (f64, f64), t: f64) -> (f64, f64) {
    (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t)
}

fn make_path(subpath: BezierSubpath, pressure: f64) -> BezierPath {
    let pressure = pressure.clamp(0.0, 1.0);
    BezierPath {
        subpaths: vec![subpath],
        style: VectorStyle {
            fill: None,
            stroke: Some(Rgba8 {
                r: 24,
                g: 24,
                b: 28,
                // Pressure is clamped to [0, 1], bounding the byte value to
                // [114, 255] before conversion.
                #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
                a: ((0.45 + pressure * 0.55) * 255.0).round() as u8,
            }),
            stroke_width: 1.5 + 5.5 * pressure,
            cap: StrokeCap::Round,
            join: StrokeJoin::Round,
            miter_limit: 4.0,
            fill_rule: FillRule::NonZero,
        },
    }
}

fn open_line(a: (f64, f64), b: (f64, f64), pressure: f64) -> BezierPath {
    make_path(
        BezierSubpath {
            anchors: vec![anchor(a), anchor(b)],
            closed: false,
        },
        pressure,
    )
}

fn ellipse(x0: f64, y0: f64, x1: f64, y1: f64, pressure: f64) -> BezierPath {
    let cx = f64::midpoint(x0, x1);
    let cy = f64::midpoint(y0, y1);
    let rx = (x1 - x0) / 2.0;
    let ry = (y1 - y0) / 2.0;
    let k = 0.552_284_749_830_793_6;
    let points = [
        (
            (cx + rx, cy),
            (cx + rx, cy - k * ry),
            (cx + rx, cy + k * ry),
        ),
        (
            (cx, cy + ry),
            (cx + k * rx, cy + ry),
            (cx - k * rx, cy + ry),
        ),
        (
            (cx - rx, cy),
            (cx - rx, cy + k * ry),
            (cx - rx, cy - k * ry),
        ),
        (
            (cx, cy - ry),
            (cx - k * rx, cy - ry),
            (cx + k * rx, cy - ry),
        ),
    ];
    let anchors = points
        .into_iter()
        .map(|(p, incoming, outgoing)| BezierAnchor {
            x: p.0,
            y: p.1,
            incoming: [incoming.0, incoming.1],
            outgoing: [outgoing.0, outgoing.1],
            kind: AnchorKind::Smooth,
        })
        .collect();
    make_path(
        BezierSubpath {
            anchors,
            closed: true,
        },
        pressure,
    )
}

fn rotated_rectangle(rect: Rect, rotation_deg: f64, pressure: f64) -> BezierPath {
    let center = rect.center();
    let corners = [
        Point::new(rect.x0, rect.y0),
        Point::new(rect.x1, rect.y0),
        Point::new(rect.x1, rect.y1),
        Point::new(rect.x0, rect.y1),
    ];
    let anchors = corners
        .into_iter()
        .map(|p| {
            let q = rotate_about(center, p, rotation_deg);
            anchor((q.x, q.y))
        })
        .collect();
    make_path(
        BezierSubpath {
            anchors,
            closed: true,
        },
        pressure,
    )
}

fn rotated_ellipse(rect: Rect, rotation_deg: f64, pressure: f64) -> BezierPath {
    let mut path = ellipse(rect.x0, rect.y0, rect.x1, rect.y1, pressure);
    let center = rect.center();
    for subpath in &mut path.subpaths {
        for p in &mut subpath.anchors {
            let q = rotate_about(center, Point::new(p.x, p.y), rotation_deg);
            let incoming = rotate_about(
                center,
                Point::new(p.incoming[0], p.incoming[1]),
                rotation_deg,
            );
            let outgoing = rotate_about(
                center,
                Point::new(p.outgoing[0], p.outgoing[1]),
                rotation_deg,
            );
            (p.x, p.y) = (q.x, q.y);
            p.incoming = [incoming.x, incoming.y];
            p.outgoing = [outgoing.x, outgoing.y];
        }
    }
    path
}

fn rotate_about(center: Point, point: Point, degrees: f64) -> Point {
    let (sin, cos) = degrees.to_radians().sin_cos();
    let (x, y) = (point.x - center.x, point.y - center.y);
    Point::new(center.x + cos * x - sin * y, center.y + sin * x + cos * y)
}

fn regular_polygon(
    center: Point,
    radius: f64,
    sides: u32,
    rotation_deg: f64,
    pressure: f64,
) -> BezierPath {
    let anchors = (0..sides)
        .map(|index| {
            let angle = (rotation_deg - 90.0).to_radians()
                + std::f64::consts::TAU * f64::from(index) / f64::from(sides);
            anchor((
                center.x + radius * angle.cos(),
                center.y + radius * angle.sin(),
            ))
        })
        .collect();
    make_path(
        BezierSubpath {
            anchors,
            closed: true,
        },
        pressure,
    )
}

fn anchor(point: (f64, f64)) -> BezierAnchor {
    BezierAnchor {
        x: point.0,
        y: point.1,
        incoming: [point.0, point.1],
        outgoing: [point.0, point.1],
        kind: AnchorKind::Corner,
    }
}

fn mean_pressure(points: &[ink_model::VectorPoint]) -> f64 {
    points
        .iter()
        .map(|p| f64::from(p.pressure.clamp(0.0, 1.0)))
        .sum::<f64>()
        / f64::from(u32::try_from(points.len().max(1)).unwrap_or(u32::MAX))
}

fn point_line_distance(p: (f64, f64), a: (f64, f64), b: (f64, f64)) -> f64 {
    let dx = b.0 - a.0;
    let dy = b.1 - a.1;
    let length2 = dx * dx + dy * dy;
    if length2 <= f64::EPSILON {
        return (p.0 - a.0).hypot(p.1 - a.1);
    }
    let t = (((p.0 - a.0) * dx + (p.1 - a.1) * dy) / length2).clamp(0.0, 1.0);
    (p.0 - (a.0 + t * dx)).hypot(p.1 - (a.1 + t * dy))
}

#[cfg(test)]
#[allow(
    clippy::cast_possible_truncation,
    clippy::cast_precision_loss,
    clippy::float_cmp,
    reason = "Geometry fixtures use small exact points and assert deterministic endpoints."
)]
mod tests {
    use super::*;
    use ink_model::VectorPoint;
    use kurbo::ParamCurve;

    fn stroke(coords: &[(f32, f32)], closed: bool) -> VectorStroke {
        VectorStroke {
            points: coords
                .iter()
                .map(|(x, y)| VectorPoint {
                    x: *x,
                    y: *y,
                    pressure: 0.5,
                    tilt: 0.0,
                })
                .collect(),
            closed,
        }
    }

    #[test]
    fn recognizes_line_rectangle_and_ellipse() {
        assert!(matches!(
            recognize(&stroke(&[(0.0, 0.0), (10.0, 1.0), (20.0, 0.0)], false))
                .unwrap()
                .unwrap()
                .kind,
            RecognizedKind::Line
        ));
        assert!(matches!(
            recognize(&stroke(
                &[
                    (0.0, 0.0),
                    (10.0, 0.0),
                    (10.0, 10.0),
                    (0.0, 10.0),
                    (1.0, 1.0)
                ],
                true
            ))
            .unwrap()
            .unwrap()
            .kind,
            RecognizedKind::Rectangle
        ));
        let circle: Vec<_> = (0..65)
            .map(|i| {
                let a = std::f32::consts::TAU * i as f32 / 64.0;
                (50.0 + 30.0 * a.cos(), 50.0 + 20.0 * a.sin())
            })
            .collect();
        assert!(matches!(
            recognize(&stroke(&circle, true)).unwrap().unwrap().kind,
            RecognizedKind::Ellipse
        ));
    }

    #[test]
    fn recognized_shapes_keep_the_required_path_topology() {
        let line = recognize(&stroke(&[(0.0, 0.0), (10.0, 0.0), (20.0, 0.0)], false))
            .unwrap()
            .unwrap();
        assert!(!line.path.subpaths[0].closed);

        let rectangle = recognize(&stroke(
            &[
                (0.0, 0.0),
                (20.0, 0.0),
                (20.0, 20.0),
                (0.0, 20.0),
                (1.0, 1.0),
            ],
            true,
        ))
        .unwrap()
        .unwrap();
        assert!(rectangle.path.subpaths[0].closed);

        let ellipse_points: Vec<_> = (0..65)
            .map(|index| {
                let angle = std::f32::consts::TAU * index as f32 / 64.0;
                (50.0 + 30.0 * angle.cos(), 50.0 + 20.0 * angle.sin())
            })
            .collect();
        let ellipse = recognize(&stroke(&ellipse_points, true)).unwrap().unwrap();
        assert!(ellipse.path.subpaths[0].closed);
        assert_eq!(ellipse.path.subpaths[0].anchors.len(), 4);

        let corners = [(0.0_f32, 20.0_f32), (20.0, 0.0), (40.0, 20.0)];
        let mut triangle_points = Vec::new();
        for edge in 0..3 {
            let start = corners[edge];
            let end = corners[(edge + 1) % 3];
            for step in 0..12 {
                let amount = step as f32 / 12.0;
                triangle_points.push((
                    start.0 + (end.0 - start.0) * amount,
                    start.1 + (end.1 - start.1) * amount,
                ));
            }
        }
        let triangle = recognize(&stroke(&triangle_points, true)).unwrap().unwrap();
        assert_eq!(triangle.kind, RecognizedKind::Triangle);
        assert!(triangle.path.subpaths[0].closed);
    }

    #[test]
    fn tap_is_a_no_match_instead_of_an_input_error() {
        let tap = VectorStroke {
            points: vec![VectorPoint {
                x: 12.0,
                y: 18.0,
                pressure: 0.7,
                tilt: 0.0,
            }],
            closed: false,
        };
        assert!(recognize(&tap).unwrap().is_none());
        assert!(recognize_object(&tap).unwrap().is_none());
    }

    #[test]
    fn unsupported_hexagons_are_no_match() {
        let mut corners = Vec::new();
        for index in 0_u16..6 {
            let angle = std::f32::consts::TAU * f32::from(index) / 6.0;
            corners.push((100.0 + 80.0 * angle.cos(), 100.0 + 80.0 * angle.sin()));
        }
        let mut points = Vec::new();
        for edge in 0_usize..6 {
            let start = corners[edge];
            let end = corners[(edge + 1) % 6];
            for step in 0_u16..15 {
                let amount = f32::from(step) / 15.0;
                points.push((
                    start.0 + (end.0 - start.0) * amount,
                    start.1 + (end.1 - start.1) * amount,
                ));
            }
        }
        assert!(recognize(&stroke(&points, true)).unwrap().is_none());
    }

    #[test]
    fn circle_and_square_constraints_preserve_center_and_rotation() {
        let rectangle = rotated_rectangle(Rect::new(-20.0, -10.0, 20.0, 10.0), 31.0, 0.5);
        let square = constrain_recognized_shape(&rectangle, ShapeConstraint::Square).unwrap();
        let square_anchors = &square.subpaths[0].anchors;
        let edge_a = point_distance(
            (square_anchors[0].x, square_anchors[0].y),
            (square_anchors[1].x, square_anchors[1].y),
        );
        let edge_b = point_distance(
            (square_anchors[1].x, square_anchors[1].y),
            (square_anchors[2].x, square_anchors[2].y),
        );
        assert!((edge_a - edge_b).abs() < 1e-10);
        let center_before = rectangle.subpaths[0]
            .anchors
            .iter()
            .fold((0.0, 0.0), |sum, point| {
                (sum.0 + point.x / 4.0, sum.1 + point.y / 4.0)
            });
        let center_after = square_anchors.iter().fold((0.0, 0.0), |sum, point| {
            (sum.0 + point.x / 4.0, sum.1 + point.y / 4.0)
        });
        assert!(point_distance(center_before, center_after) < 1e-10);

        let ellipse = rotated_ellipse(Rect::new(-20.0, -10.0, 20.0, 10.0), 31.0, 0.5);
        let circle = constrain_recognized_shape(&ellipse, ShapeConstraint::Circle).unwrap();
        let circle_anchors = &circle.subpaths[0].anchors;
        let radius_x = point_distance(
            (circle_anchors[0].x, circle_anchors[0].y),
            (circle_anchors[2].x, circle_anchors[2].y),
        );
        let radius_y = point_distance(
            (circle_anchors[1].x, circle_anchors[1].y),
            (circle_anchors[3].x, circle_anchors[3].y),
        );
        assert!((radius_x - radius_y).abs() < 1e-10);
        assert_eq!(circle_anchors[0].kind, AnchorKind::Smooth);
    }

    #[test]
    fn fit_curve_is_bounded_and_preserves_endpoints() {
        let input = stroke(
            &[(0.0, 0.0), (1.0, 0.1), (2.0, 0.0), (3.0, 0.0), (4.0, 0.0)],
            false,
        );
        let result = fit_curve(&input, 1.0).unwrap();
        let anchors = &result.subpaths[0].anchors;
        assert_eq!(anchors.first().unwrap().x, 0.0);
        assert_eq!(anchors.last().unwrap().x, 4.0);
    }

    #[test]
    fn fit_curve_recovers_a_smooth_cubic_from_sampled_points() {
        let original = kurbo::CubicBez::new(
            Point::new(0.0, 0.0),
            Point::new(30.0, 60.0),
            Point::new(70.0, 60.0),
            Point::new(100.0, 0.0),
        );
        let coords: Vec<_> = (0..=40)
            .map(|index| {
                let point = original.eval(f64::from(index) / 40.0);
                (point.x as f32, point.y as f32)
            })
            .collect();
        let fitted = fit_curve(&stroke(&coords, false), 0.5).unwrap();
        let anchors = &fitted.subpaths[0].anchors;
        assert_eq!(anchors.len(), 2);
        assert!(
            (anchors[0].outgoing[0] - original.p1.x).hypot(anchors[0].outgoing[1] - original.p1.y)
                < 2.0
        );
        assert!(
            (anchors[1].incoming[0] - original.p2.x).hypot(anchors[1].incoming[1] - original.p2.y)
                < 2.0
        );
    }

    #[test]
    fn fit_curve_keeps_sharp_corners_as_corner_anchors() {
        let mut coords: Vec<_> = (0..=10).map(|x| (x as f32, 0.0)).collect();
        coords.extend((1..=10).map(|y| (10.0, y as f32)));
        let fitted = fit_curve(&stroke(&coords, false), 0.5).unwrap();
        let anchors = &fitted.subpaths[0].anchors;
        assert_eq!(anchors.len(), 3);
        assert_eq!(anchors[1].kind, AnchorKind::Corner);
        assert_eq!((anchors[1].x, anchors[1].y), (10.0, 0.0));
    }

    #[test]
    fn fitted_conversion_archives_exact_ink_and_discloses_uniform_style_values() {
        let mut input = stroke(&[(0.0, 0.0), (10.0, 4.0), (20.0, 0.0)], false);
        input.points[0].pressure = 0.2;
        input.points[1].pressure = 0.5;
        input.points[2].pressure = 0.8;
        input.points[1].tilt = 0.37;
        let object = fit_curve_object(&input, 1.0).unwrap();
        let ink_model::VectorObject::BezierPath { path, source } = object else {
            panic!("curve fit should return a Bézier object");
        };
        assert_eq!(source.unwrap().legacy, input);
        assert_eq!(path.style.fill, None);
        assert!((path.style.stroke_width - 4.25).abs() < 1e-6);
        assert_eq!(path.style.stroke.unwrap().a, 185);
    }

    #[test]
    fn handle_edits_preserve_corner_independence_and_smooth_invariants() {
        let mut corner = open_line((0.0, 0.0), (10.0, 0.0), 0.5);
        corner.subpaths[0].anchors[0].incoming = [-2.0, 0.0];
        let moved_corner = move_handle(&corner, 0, 0, HandleKind::Outgoing, (0.0, 4.0)).unwrap();
        assert_eq!(moved_corner.subpaths[0].anchors[0].incoming, [-2.0, 0.0]);
        assert_eq!(moved_corner.subpaths[0].anchors[0].outgoing, [0.0, 4.0]);

        let mut smooth = corner;
        smooth.subpaths[0].anchors[0].kind = AnchorKind::Smooth;
        smooth.subpaths[0].anchors[0].incoming = [-3.0, 0.0];
        smooth.subpaths[0].anchors[0].outgoing = [2.0, 0.0];
        let moved_smooth = move_handle(&smooth, 0, 0, HandleKind::Outgoing, (0.0, 4.0)).unwrap();
        let anchor = moved_smooth.subpaths[0].anchors[0];
        assert!((anchor.incoming[0] - 0.0).abs() < f64::EPSILON);
        assert!((anchor.incoming[1] + 3.0).abs() < f64::EPSILON);
        assert!((anchor.outgoing[1] - 4.0).abs() < f64::EPSILON);
    }

    #[test]
    fn path_transform_is_uniform_and_scales_stroke_width() {
        let path = open_line((1.0, 0.0), (1.0, 2.0), 0.5);
        let transformed = transform_path(
            &path,
            VectorTransform {
                translate: (10.0, 0.0),
                rotation_degrees: 90.0,
                scale: 2.0,
            },
        )
        .unwrap();
        let first = transformed.subpaths[0].anchors[0];
        assert!((first.x - 10.0).abs() < 1e-12);
        assert!((first.y - 2.0).abs() < 1e-12);
        assert!((transformed.style.stroke_width - path.style.stroke_width * 2.0).abs() < 1e-12);
        assert!(
            transform_path(
                &path,
                VectorTransform {
                    translate: (0.0, 0.0),
                    rotation_degrees: 0.0,
                    scale: -1.0,
                }
            )
            .is_err()
        );
    }

    #[test]
    fn tracing_keeps_components_and_holes_and_rejects_oversized_input() {
        let mut rgba = vec![255u8; 9 * 9 * 4];
        for y in 2..7 {
            for x in 2..7 {
                let i = (y * 9 + x) * 4;
                rgba[i..i + 4].copy_from_slice(&[0, 0, 0, 255]);
            }
        }
        for y in 3..6 {
            for x in 3..6 {
                let i = (y * 9 + x) * 4;
                rgba[i..i + 4].copy_from_slice(&[255, 255, 255, 255]);
            }
        }
        let paths = trace_black_white(
            9,
            9,
            &rgba,
            TraceOptions {
                min_component_pixels: 1,
                ..TraceOptions::default()
            },
        )
        .unwrap();
        assert_eq!(paths.len(), 1);
        assert_eq!(paths[0].subpaths.len(), 2);
        assert!(trace_black_white(4097, 1, &[], TraceOptions::default()).is_err());
    }

    #[test]
    fn tracing_keeps_diagonal_foreground_pixels_as_separate_components() {
        let mut rgba = vec![255; 2 * 2 * 4];
        rgba[0..4].copy_from_slice(&[0, 0, 0, 255]);
        rgba[12..16].copy_from_slice(&[0, 0, 0, 255]);
        let paths = trace_black_white(
            2,
            2,
            &rgba,
            TraceOptions {
                min_component_pixels: 1,
                ..TraceOptions::default()
            },
        )
        .unwrap();
        assert_eq!(paths.len(), 2);
        assert!(paths.iter().all(|path| path.subpaths.len() == 1));
    }

    #[test]
    fn tracing_rejects_component_explosion_before_building_contours() {
        let width = 256usize;
        let height = 256usize;
        let mut rgba = vec![255u8; width * height * 4];
        for y in (0..height).step_by(2) {
            for x in (0..width).step_by(2) {
                let offset = (y * width + x) * 4;
                rgba[offset..offset + 4].copy_from_slice(&[0, 0, 0, 255]);
            }
        }

        assert_eq!(
            trace_black_white(
                width as u32,
                height as u32,
                &rgba,
                TraceOptions {
                    min_component_pixels: 1,
                    ..TraceOptions::default()
                },
            ),
            Err(VectorError::TooComplex),
        );
    }

    #[test]
    fn tracing_composites_alpha_over_white_and_uses_strict_threshold() {
        let options = TraceOptions {
            threshold: 128,
            min_component_pixels: 1,
            ..TraceOptions::default()
        };
        let translucent_black = [0, 0, 0, 128];
        assert_eq!(
            trace_black_white(1, 1, &translucent_black, options)
                .unwrap()
                .len(),
            1
        );
        assert!(
            trace_black_white(
                1,
                1,
                &translucent_black,
                TraceOptions {
                    threshold: 127,
                    ..options
                }
            )
            .unwrap()
            .is_empty()
        );
        assert!(
            trace_black_white(1, 1, &[0, 0, 0, 0], options)
                .unwrap()
                .is_empty()
        );
    }
}

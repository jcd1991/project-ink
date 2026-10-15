use ink_model::{BezierPath, BezierSubpath, FillRule, Rgba8, StrokeCap, StrokeJoin};
use kurbo::{BezPath, Cap, CubicBez, Join, ParamCurve, PathEl, Point, Stroke, StrokeOpts};

const FLATNESS_PX: f64 = 0.25;
const MAX_SUBDIVISION_DEPTH: u8 = 16;
const MAX_FLATTENED_SEGMENTS: usize = 4_096;
const MAX_RASTER_PIXELS: usize = 4_194_304;
const MAX_RASTER_OUTPUT_PIXELS: usize = 8_388_608;
const COVERAGE_GRID: u32 = 4;

/// One premultiplied-coverage sample for a path paint operation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RasterPixel {
    /// Document-space pixel X coordinate.
    pub x: u32,
    /// Document-space pixel Y coordinate.
    pub y: u32,
    /// Straight-alpha source color for `TileStore::blend_pixel`.
    pub color: Rgba8,
    /// Coverage and source alpha combined into the engine opacity value.
    pub opacity: u16,
}

/// Rasterize a filled and/or stroked Bézier path into bounded 4×4 coverage
/// samples. The source path is never modified.
///
/// # Errors
/// Returns `InvalidInput` for invalid path data, or `TooComplex` when curve
/// subdivision, flattened segments, or the clipped raster footprint exceed
/// the fixed budgets.
pub fn rasterize_bezier_path(
    path: &BezierPath,
    width_px: u32,
    height_px: u32,
) -> Result<Vec<RasterPixel>, super::VectorError> {
    if width_px == 0 || height_px == 0 {
        return Err(super::VectorError::InvalidInput);
    }
    ink_model::validate_bezier_path(
        path,
        ink_model::DocumentSpec {
            width_px,
            height_px,
            dpi: 1.0,
            color_space: ink_model::ColorSpace::Srgb,
            background: Rgba8::default(),
        },
    )
    .map_err(|_| super::VectorError::InvalidInput)?;
    let mut output = Vec::new();
    if let Some(fill) = path.style.fill {
        let contours = flatten_model_subpaths(&path.subpaths)?;
        rasterize_contours(
            &contours,
            path.style.fill_rule,
            fill,
            width_px,
            height_px,
            &mut output,
        )?;
    }
    if let Some(stroke_color) = path.style.stroke {
        let mut source = BezPath::new();
        for subpath in &path.subpaths {
            append_model_subpath(&mut source, subpath);
        }
        let style = Stroke {
            width: path.style.stroke_width,
            join: match path.style.join {
                StrokeJoin::Miter => Join::Miter,
                StrokeJoin::Bevel => Join::Bevel,
                StrokeJoin::Round => Join::Round,
            },
            miter_limit: path.style.miter_limit,
            start_cap: match path.style.cap {
                StrokeCap::Butt => Cap::Butt,
                StrokeCap::Square => Cap::Square,
                StrokeCap::Round => Cap::Round,
            },
            end_cap: match path.style.cap {
                StrokeCap::Butt => Cap::Butt,
                StrokeCap::Square => Cap::Square,
                StrokeCap::Round => Cap::Round,
            },
            dash_pattern: kurbo::Dashes::default(),
            dash_offset: 0.0,
        };
        let outline = kurbo::stroke(source.iter(), &style, &StrokeOpts::default(), FLATNESS_PX);
        let contours = flatten_path_elements(outline.iter())?;
        rasterize_contours(
            &contours,
            FillRule::NonZero,
            stroke_color,
            width_px,
            height_px,
            &mut output,
        )?;
    }
    Ok(output)
}

type Contour = Vec<Point>;

fn append_model_subpath(path: &mut BezPath, subpath: &BezierSubpath) {
    let Some(first) = subpath.anchors.first() else {
        return;
    };
    path.move_to(Point::new(first.x, first.y));
    let segment_count = if subpath.closed {
        subpath.anchors.len()
    } else {
        subpath.anchors.len().saturating_sub(1)
    };
    for index in 0..segment_count {
        let from = subpath.anchors[index];
        let to = subpath.anchors[(index + 1) % subpath.anchors.len()];
        path.curve_to(
            Point::new(from.outgoing[0], from.outgoing[1]),
            Point::new(to.incoming[0], to.incoming[1]),
            Point::new(to.x, to.y),
        );
    }
    if subpath.closed {
        path.close_path();
    }
}

fn flatten_model_subpaths(subpaths: &[BezierSubpath]) -> Result<Vec<Contour>, super::VectorError> {
    let mut contours = Vec::new();
    let mut segment_budget = 0usize;
    for subpath in subpaths {
        if !subpath.closed {
            continue;
        }
        let Some(first) = subpath.anchors.first() else {
            continue;
        };
        let mut contour = Vec::new();
        contour
            .try_reserve(subpath.anchors.len())
            .map_err(|_| super::VectorError::TooComplex)?;
        contour.push(Point::new(first.x, first.y));
        let segment_count = if subpath.closed {
            subpath.anchors.len()
        } else {
            subpath.anchors.len().saturating_sub(1)
        };
        for index in 0..segment_count {
            let from = subpath.anchors[index];
            let to = subpath.anchors[(index + 1) % subpath.anchors.len()];
            let curve = CubicBez::new(
                Point::new(from.x, from.y),
                Point::new(from.outgoing[0], from.outgoing[1]),
                Point::new(to.incoming[0], to.incoming[1]),
                Point::new(to.x, to.y),
            );
            flatten_cubic(curve, &mut contour, &mut segment_budget)?;
        }
        if subpath.closed && contour.len() > 1 && contour.first() == contour.last() {
            contour.pop();
        }
        contours
            .try_reserve(1)
            .map_err(|_| super::VectorError::TooComplex)?;
        contours.push(contour);
    }
    Ok(contours)
}

fn flatten_cubic(
    curve: CubicBez,
    output: &mut Contour,
    segment_budget: &mut usize,
) -> Result<(), super::VectorError> {
    let mut pending = Vec::new();
    pending
        .try_reserve(usize::from(MAX_SUBDIVISION_DEPTH))
        .map_err(|_| super::VectorError::TooComplex)?;
    pending.push((curve, 0_u8));
    while let Some((segment, depth)) = pending.pop() {
        let chord = segment.p3 - segment.p0;
        let chord_len = chord.hypot();
        let flatness = if chord_len <= f64::EPSILON {
            (segment.p1 - segment.p0)
                .hypot()
                .max((segment.p2 - segment.p0).hypot())
        } else {
            let distance = |point: Point| ((point - segment.p0).cross(chord)).abs() / chord_len;
            distance(segment.p1).max(distance(segment.p2))
        };
        if flatness <= FLATNESS_PX {
            *segment_budget = segment_budget
                .checked_add(1)
                .ok_or(super::VectorError::TooComplex)?;
            if *segment_budget > MAX_FLATTENED_SEGMENTS {
                return Err(super::VectorError::TooComplex);
            }
            output
                .try_reserve(1)
                .map_err(|_| super::VectorError::TooComplex)?;
            output.push(segment.p3);
            continue;
        }
        if depth >= MAX_SUBDIVISION_DEPTH {
            return Err(super::VectorError::TooComplex);
        }
        let (left, right) = segment.subdivide();
        pending
            .try_reserve(2)
            .map_err(|_| super::VectorError::TooComplex)?;
        pending.push((right, depth + 1));
        pending.push((left, depth + 1));
    }
    Ok(())
}

fn flatten_path_elements(
    elements: impl IntoIterator<Item = PathEl>,
) -> Result<Vec<Contour>, super::VectorError> {
    let mut contours = Vec::new();
    let mut active: Option<Contour> = None;
    let mut current = None;
    let mut start = None;
    let mut segment_budget = 0usize;
    for element in elements {
        match element {
            PathEl::MoveTo(point) => {
                if let Some(contour) = active.take() {
                    contours.push(contour);
                }
                let mut contour = Vec::new();
                contour
                    .try_reserve(8)
                    .map_err(|_| super::VectorError::TooComplex)?;
                contour.push(point);
                active = Some(contour);
                current = Some(point);
                start = Some(point);
            }
            PathEl::LineTo(point) => {
                let contour = active.as_mut().ok_or(super::VectorError::InvalidInput)?;
                segment_budget = segment_budget
                    .checked_add(1)
                    .ok_or(super::VectorError::TooComplex)?;
                if segment_budget > MAX_FLATTENED_SEGMENTS {
                    return Err(super::VectorError::TooComplex);
                }
                contour
                    .try_reserve(1)
                    .map_err(|_| super::VectorError::TooComplex)?;
                contour.push(point);
                current = Some(point);
            }
            PathEl::QuadTo(control, point) => {
                let from = current.ok_or(super::VectorError::InvalidInput)?;
                let c1 = from + (control - from) * (2.0 / 3.0);
                let c2 = point + (control - point) * (2.0 / 3.0);
                flatten_cubic(
                    CubicBez::new(from, c1, c2, point),
                    active.as_mut().ok_or(super::VectorError::InvalidInput)?,
                    &mut segment_budget,
                )?;
                current = Some(point);
            }
            PathEl::CurveTo(control1, control2, point) => {
                let from = current.ok_or(super::VectorError::InvalidInput)?;
                flatten_cubic(
                    CubicBez::new(from, control1, control2, point),
                    active.as_mut().ok_or(super::VectorError::InvalidInput)?,
                    &mut segment_budget,
                )?;
                current = Some(point);
            }
            PathEl::ClosePath => {
                let mut contour = active.take().ok_or(super::VectorError::InvalidInput)?;
                if let Some(start) = start
                    && contour.last() == Some(&start)
                {
                    contour.pop();
                }
                contours
                    .try_reserve(1)
                    .map_err(|_| super::VectorError::TooComplex)?;
                contours.push(contour);
                current = None;
                start = None;
            }
        }
    }
    if let Some(contour) = active {
        contours
            .try_reserve(1)
            .map_err(|_| super::VectorError::TooComplex)?;
        contours.push(contour);
    }
    Ok(contours)
}

fn rasterize_contours(
    contours: &[Contour],
    fill_rule: FillRule,
    color: Rgba8,
    width_px: u32,
    height_px: u32,
    output: &mut Vec<RasterPixel>,
) -> Result<(), super::VectorError> {
    let Some((min_x, min_y, max_x, max_y)) = contour_bounds(contours) else {
        return Ok(());
    };
    let x0 = bounded_coordinate(min_x.floor(), width_px);
    let y0 = bounded_coordinate(min_y.floor(), height_px);
    let x1 = bounded_coordinate(max_x.ceil(), width_px);
    let y1 = bounded_coordinate(max_y.ceil(), height_px);
    if x0 >= x1 || y0 >= y1 {
        return Ok(());
    }
    let area = usize::try_from(x1 - x0)
        .ok()
        .and_then(|w| usize::try_from(y1 - y0).ok().and_then(|h| w.checked_mul(h)))
        .ok_or(super::VectorError::TooComplex)?;
    if area > MAX_RASTER_PIXELS {
        return Err(super::VectorError::TooComplex);
    }
    let sample_count = COVERAGE_GRID * COVERAGE_GRID;
    for y in y0..y1 {
        for x in x0..x1 {
            let mut covered = 0_u32;
            for sy in 0..COVERAGE_GRID {
                for sx in 0..COVERAGE_GRID {
                    let point = Point::new(
                        f64::from(x) + (f64::from(sx) + 0.5) / f64::from(COVERAGE_GRID),
                        f64::from(y) + (f64::from(sy) + 0.5) / f64::from(COVERAGE_GRID),
                    );
                    if contains(contours, fill_rule, point) {
                        covered += 1;
                    }
                }
            }
            if covered == 0 {
                continue;
            }
            if output.len() >= MAX_RASTER_OUTPUT_PIXELS {
                return Err(super::VectorError::TooComplex);
            }
            let opacity =
                u16::try_from(u32::from(u16::MAX) * covered / sample_count).unwrap_or(u16::MAX);
            output
                .try_reserve(1)
                .map_err(|_| super::VectorError::TooComplex)?;
            output.push(RasterPixel {
                x,
                y,
                color,
                opacity,
            });
        }
    }
    Ok(())
}

#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
fn bounded_coordinate(value: f64, limit: u32) -> u32 {
    value.clamp(0.0, f64::from(limit)) as u32
}

fn contour_bounds(contours: &[Contour]) -> Option<(f64, f64, f64, f64)> {
    let mut bounds = (
        f64::INFINITY,
        f64::INFINITY,
        f64::NEG_INFINITY,
        f64::NEG_INFINITY,
    );
    let mut found = false;
    for point in contours.iter().flatten() {
        if !point.x.is_finite() || !point.y.is_finite() {
            continue;
        }
        found = true;
        bounds.0 = bounds.0.min(point.x);
        bounds.1 = bounds.1.min(point.y);
        bounds.2 = bounds.2.max(point.x);
        bounds.3 = bounds.3.max(point.y);
    }
    found.then_some(bounds)
}

fn contains(contours: &[Contour], rule: FillRule, point: Point) -> bool {
    let mut winding = 0_i32;
    let mut crossings = 0_u32;
    for contour in contours {
        if contour.len() < 3 {
            continue;
        }
        for index in 0..contour.len() {
            let a = contour[index];
            let b = contour[(index + 1) % contour.len()];
            if (a.y > point.y) != (b.y > point.y) {
                let x = a.x + (point.y - a.y) * (b.x - a.x) / (b.y - a.y);
                if x > point.x {
                    crossings += 1;
                    if b.y > a.y {
                        winding += 1;
                    } else {
                        winding -= 1;
                    }
                }
            }
        }
    }
    match rule {
        FillRule::NonZero => winding != 0,
        FillRule::EvenOdd => crossings % 2 == 1,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ink_model::{AnchorKind, BezierAnchor, BezierSubpath, VectorStyle};

    fn rectangle_path(left: f64, top: f64, right: f64, bottom: f64) -> BezierPath {
        let anchor = |x, y| BezierAnchor {
            x,
            y,
            incoming: [x, y],
            outgoing: [x, y],
            kind: AnchorKind::Corner,
        };
        BezierPath {
            subpaths: vec![BezierSubpath {
                anchors: vec![
                    anchor(left, top),
                    anchor(right, top),
                    anchor(right, bottom),
                    anchor(left, bottom),
                ],
                closed: true,
            }],
            style: VectorStyle {
                fill: Some(Rgba8 {
                    r: 220,
                    g: 40,
                    b: 20,
                    a: 255,
                }),
                stroke: None,
                stroke_width: 0.0,
                cap: StrokeCap::Butt,
                join: StrokeJoin::Miter,
                miter_limit: 4.0,
                fill_rule: FillRule::NonZero,
            },
        }
    }

    #[test]
    fn fills_closed_shapes_with_fixed_four_by_four_coverage() {
        let pixels = rasterize_bezier_path(&rectangle_path(1.0, 1.0, 4.0, 4.0), 8, 8)
            .expect("rasterize rectangle");
        assert_eq!(pixels.len(), 9);
        assert!(pixels.iter().all(|pixel| pixel.opacity == u16::MAX));
        assert!(pixels.iter().all(|pixel| pixel.color.r == 220));

        let antialiased = rasterize_bezier_path(&rectangle_path(1.5, 1.0, 4.5, 4.0), 8, 8)
            .expect("rasterize fractional rectangle");
        assert!(antialiased.iter().any(|pixel| pixel.opacity < u16::MAX));
    }

    #[test]
    fn open_paths_do_not_create_implicit_fills() {
        let mut path = rectangle_path(1.0, 1.0, 4.0, 4.0);
        path.subpaths[0].closed = false;
        assert!(
            rasterize_bezier_path(&path, 8, 8)
                .expect("open path has no fill")
                .is_empty()
        );
    }
}

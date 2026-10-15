use ink_model::{BezierPath, VectorStroke};
use kurbo::{ParamCurveNearest, Point, Shape};

use crate::VectorError;

/// Test a point against the filled and stroked geometry of a bounded Bézier
/// object. Kurbo computes curve distance and winding directly; work is bounded
/// by the model's path-anchor and subpath limits.
///
/// # Errors
/// Returns `InvalidInput` for non-finite coordinates, an out-of-range
/// tolerance, or malformed subpaths.
pub fn hit_test_bezier_path(
    path: &BezierPath,
    x: f64,
    y: f64,
    tolerance_px: f64,
) -> Result<bool, VectorError> {
    if !x.is_finite()
        || !y.is_finite()
        || !tolerance_px.is_finite()
        || !(0.0..=4096.0).contains(&tolerance_px)
    {
        return Err(VectorError::InvalidInput);
    }
    let anchor_count = path
        .subpaths
        .iter()
        .try_fold(0usize, |count, subpath| {
            count.checked_add(subpath.anchors.len())
        })
        .ok_or(VectorError::InvalidInput)?;
    if path.subpaths.is_empty()
        || path.subpaths.len() > ink_model::MAX_BEZIER_SUBPATHS
        || anchor_count > ink_model::MAX_BEZIER_ANCHORS
        || path
            .subpaths
            .iter()
            .any(|subpath| subpath.anchors.len() < 2)
        || !path.style.stroke_width.is_finite()
        || !(0.0..=4096.0).contains(&path.style.stroke_width)
        || !path.style.miter_limit.is_finite()
        || !(1.0..=64.0).contains(&path.style.miter_limit)
        || (path.style.fill.is_none() && path.style.stroke.is_none())
    {
        return Err(VectorError::InvalidInput);
    }
    let mut numeric_scale: f64 = 1.0;
    for anchor in path.subpaths.iter().flat_map(|subpath| &subpath.anchors) {
        for coordinate in [
            anchor.x,
            anchor.y,
            anchor.incoming[0],
            anchor.incoming[1],
            anchor.outgoing[0],
            anchor.outgoing[1],
        ] {
            if !coordinate.is_finite() || coordinate.abs() > 17_179_869_180.0 {
                return Err(VectorError::InvalidInput);
            }
            numeric_scale = numeric_scale.max(coordinate.abs());
        }
    }
    let stroke_visible = path.style.stroke.is_some_and(|color| color.a > 0);
    let fill_visible = path.style.fill.is_some_and(|color| color.a > 0);
    let boundary_visible = stroke_visible || fill_visible;
    let stroke_radius = if stroke_visible {
        path.style.stroke_width * 0.5
    } else {
        0.0
    };
    let limit = tolerance_px + stroke_radius;
    let limit_squared = limit * limit;
    let bezier = crate::to_kurbo(path)?;
    let point = Point::new(x, y);
    let nearest_accuracy = (0.01 / (numeric_scale * 8.0)).max(1e-14);
    let hit_boundary = boundary_visible
        && bezier
            .segments()
            .any(|segment| segment.nearest(point, nearest_accuracy).distance_sq <= limit_squared);
    let winding = if fill_visible {
        i64::from(bezier.winding(point))
    } else {
        0
    };
    let hit_fill = fill_visible
        && match path.style.fill_rule {
            ink_model::FillRule::EvenOdd => winding.unsigned_abs() % 2 == 1,
            ink_model::FillRule::NonZero => winding != 0,
        };
    Ok(hit_boundary || hit_fill)
}

/// Test a point against sampled legacy ink using the requested document-space
/// selection tolerance. The scan is bounded by the legacy sample limit.
///
/// # Errors
/// Returns `InvalidInput` for non-finite coordinates, an out-of-range
/// tolerance, or a stroke outside the supported sample bounds.
pub fn hit_test_legacy_stroke(
    stroke: &VectorStroke,
    x: f64,
    y: f64,
    tolerance_px: f64,
) -> Result<bool, VectorError> {
    if !x.is_finite()
        || !y.is_finite()
        || !tolerance_px.is_finite()
        || !(0.0..=4096.0).contains(&tolerance_px)
        || stroke.points.is_empty()
        || stroke.points.len() > 8_192
    {
        return Err(VectorError::InvalidInput);
    }
    let limit_squared = tolerance_px * tolerance_px;
    if stroke.points.len() == 1 {
        let point = stroke.points[0];
        return Ok(
            (f64::from(point.x) - x).powi(2) + (f64::from(point.y) - y).powi(2) <= limit_squared,
        );
    }
    let consecutive_hit = stroke.points.windows(2).any(|segment| {
        distance_to_segment_squared(
            (x, y),
            (f64::from(segment[0].x), f64::from(segment[0].y)),
            (f64::from(segment[1].x), f64::from(segment[1].y)),
        ) <= limit_squared
    });
    let closing_hit = stroke.closed && stroke.points.len() > 2 && {
        let first = stroke.points[0];
        let last = stroke.points[stroke.points.len() - 1];
        distance_to_segment_squared(
            (x, y),
            (f64::from(last.x), f64::from(last.y)),
            (f64::from(first.x), f64::from(first.y)),
        ) <= limit_squared
    };
    Ok(consecutive_hit || closing_hit)
}

fn distance_to_segment_squared(point: (f64, f64), a: (f64, f64), b: (f64, f64)) -> f64 {
    let dx = b.0 - a.0;
    let dy = b.1 - a.1;
    let length_squared = dx * dx + dy * dy;
    let t = if length_squared <= f64::EPSILON {
        0.0
    } else {
        (((point.0 - a.0) * dx + (point.1 - a.1) * dy) / length_squared).clamp(0.0, 1.0)
    };
    let nearest_x = a.0 + t * dx;
    let nearest_y = a.1 + t * dy;
    (point.0 - nearest_x).powi(2) + (point.1 - nearest_y).powi(2)
}

#[cfg(test)]
mod tests {
    use super::{hit_test_bezier_path, hit_test_legacy_stroke};
    use ink_model::{
        AnchorKind, BezierAnchor, BezierPath, BezierSubpath, FillRule, Rgba8, StrokeCap,
        StrokeJoin, VectorPoint, VectorStroke, VectorStyle,
    };

    fn rectangle() -> BezierPath {
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
                    anchor(0.0, 0.0),
                    anchor(20.0, 0.0),
                    anchor(20.0, 20.0),
                    anchor(0.0, 20.0),
                ],
                closed: true,
            }],
            style: VectorStyle {
                fill: Some(Rgba8 {
                    r: 10,
                    g: 20,
                    b: 30,
                    a: 255,
                }),
                stroke: None,
                stroke_width: 0.0,
                cap: StrokeCap::Round,
                join: StrokeJoin::Round,
                miter_limit: 4.0,
                fill_rule: FillRule::EvenOdd,
            },
        }
    }

    #[test]
    fn bezier_hit_testing_respects_fill_tolerance_and_bounds() {
        let path = rectangle();
        assert!(hit_test_bezier_path(&path, 10.0, 10.0, 0.0).expect("inside fill"));
        assert!(hit_test_bezier_path(&path, -1.0, 10.0, 1.1).expect("near edge"));
        assert!(!hit_test_bezier_path(&path, -3.0, 10.0, 1.0).expect("outside"));
        assert!(hit_test_bezier_path(&path, f64::NAN, 1.0, 1.0).is_err());
        let mut transparent = path;
        transparent.style.fill.as_mut().expect("fill").a = 0;
        assert!(
            !hit_test_bezier_path(&transparent, 10.0, 10.0, 0.0)
                .expect("transparent fill is not selectable")
        );
    }

    #[test]
    fn bezier_hit_testing_uses_the_curve_not_a_fixed_chord_sample() {
        let mut path = rectangle();
        path.subpaths[0].anchors[0].outgoing = [0.0, -1000.0];
        path.subpaths[0].anchors[1].incoming = [20.0, -1000.0];
        let t = 0.51_f64;
        let inverse = 1.0 - t;
        let x = 3.0 * inverse * t * t * 20.0 + t * t * t * 20.0;
        let y = 3.0 * inverse * inverse * t * -1000.0 + 3.0 * inverse * t * t * -1000.0;
        assert!(hit_test_bezier_path(&path, x, y, 0.001).expect("curve hit"));
    }

    #[test]
    fn legacy_hit_testing_uses_document_space_tolerance() {
        let stroke = VectorStroke {
            points: vec![
                VectorPoint {
                    x: 0.0,
                    y: 0.0,
                    pressure: 1.0,
                    tilt: 0.0,
                },
                VectorPoint {
                    x: 10.0,
                    y: 0.0,
                    pressure: 1.0,
                    tilt: 0.0,
                },
            ],
            closed: false,
        };
        assert!(hit_test_legacy_stroke(&stroke, 5.0, 2.0, 2.1).expect("near ink"));
        assert!(!hit_test_legacy_stroke(&stroke, 5.0, 3.0, 2.0).expect("outside tolerance"));
    }
}

//! Bounded helpers for materializing repeated Bézier artwork.

use ink_model::{BezierPath, MAX_BEZIER_ANCHORS};

use crate::{VectorError, VectorTransform, transform_path};

/// Maximum number of additional paths produced by one repeat operation.
pub const MAX_REPEAT_OBJECTS: usize = 64;

/// Create radial copies around a document-space center.
///
/// The source path is not included in the result. Each returned path is an
/// ordinary transformed Bézier path and can be inserted by one vector patch.
///
/// # Errors
/// Returns `InvalidInput` for invalid settings and `TooComplex` when the copy
/// count or source anchor count exceeds the bounded operation budget.
pub fn repeat_radial(
    path: &BezierPath,
    center: (f64, f64),
    additional_copies: usize,
    step_degrees: f64,
    scale_per_copy: f64,
) -> Result<Vec<BezierPath>, VectorError> {
    if additional_copies > MAX_REPEAT_OBJECTS
        || additional_copies == 0
        || !center.0.is_finite()
        || !center.1.is_finite()
        || !step_degrees.is_finite()
        || !scale_per_copy.is_finite()
        || scale_per_copy <= 0.0
    {
        return Err(VectorError::InvalidInput);
    }
    ensure_anchor_budget(path, additional_copies)?;
    let mut output = Vec::new();
    output
        .try_reserve_exact(additional_copies)
        .map_err(|_| VectorError::TooComplex)?;
    for index in 1..=additional_copies {
        let exponent = f64::from(u32::try_from(index).map_err(|_| VectorError::TooComplex)?);
        let scale = scale_per_copy.powf(exponent);
        let angle = step_degrees * exponent;
        if !scale.is_finite() || !angle.is_finite() {
            return Err(VectorError::InvalidInput);
        }
        let (sin, cos) = angle.to_radians().sin_cos();
        let scaled_x = center.0 * scale;
        let scaled_y = center.1 * scale;
        let translate = (
            center.0 - (cos * scaled_x - sin * scaled_y),
            center.1 - (sin * scaled_x + cos * scaled_y),
        );
        output.push(transform_path(
            path,
            VectorTransform {
                translate,
                rotation_degrees: angle,
                scale,
            },
        )?);
    }
    Ok(output)
}

/// Create row-major grid copies, omitting the original at row/column zero.
///
/// # Errors
/// Returns `InvalidInput` for invalid dimensions or spacing and `TooComplex`
/// when the number of copies or total generated anchors exceeds its limit.
pub fn repeat_grid(
    path: &BezierPath,
    columns: usize,
    rows: usize,
    spacing_x: f64,
    spacing_y: f64,
) -> Result<Vec<BezierPath>, VectorError> {
    if columns == 0 || rows == 0 || columns > MAX_REPEAT_OBJECTS || rows > MAX_REPEAT_OBJECTS {
        return Err(VectorError::InvalidInput);
    }
    if !spacing_x.is_finite() || !spacing_y.is_finite() {
        return Err(VectorError::InvalidInput);
    }
    let total = columns.checked_mul(rows).ok_or(VectorError::TooComplex)?;
    let copies = total.checked_sub(1).ok_or(VectorError::InvalidInput)?;
    if copies == 0 || copies > MAX_REPEAT_OBJECTS {
        return Err(VectorError::TooComplex);
    }
    ensure_anchor_budget(path, copies)?;
    let mut output = Vec::new();
    output
        .try_reserve_exact(copies)
        .map_err(|_| VectorError::TooComplex)?;
    for row in 0..rows {
        for column in 0..columns {
            if row == 0 && column == 0 {
                continue;
            }
            let x_index = f64::from(u32::try_from(column).map_err(|_| VectorError::TooComplex)?);
            let y_index = f64::from(u32::try_from(row).map_err(|_| VectorError::TooComplex)?);
            output.push(transform_path(
                path,
                VectorTransform {
                    translate: (x_index * spacing_x, y_index * spacing_y),
                    rotation_degrees: 0.0,
                    scale: 1.0,
                },
            )?);
        }
    }
    Ok(output)
}

/// Reflect a path across one or both document-space axes.
///
/// `vertical_axis_x` reflects left/right across the given vertical line;
/// `horizontal_axis_y` reflects top/bottom across the given horizontal line.
/// Reflections intentionally remain a repeat-only operation and do not widen
/// the normal transform contract.
///
/// # Errors
/// Returns `InvalidInput` if no finite axis is supplied and `TooComplex` if
/// the path exceeds the shared anchor limit.
pub fn mirror_path(
    path: &BezierPath,
    vertical_axis_x: Option<f64>,
    horizontal_axis_y: Option<f64>,
) -> Result<BezierPath, VectorError> {
    if vertical_axis_x.is_none() && horizontal_axis_y.is_none()
        || vertical_axis_x.is_some_and(|value| !value.is_finite())
        || horizontal_axis_y.is_some_and(|value| !value.is_finite())
    {
        return Err(VectorError::InvalidInput);
    }
    ensure_anchor_budget(path, 1)?;
    let mut mirrored = path.clone();
    for anchor in mirrored
        .subpaths
        .iter_mut()
        .flat_map(|subpath| &mut subpath.anchors)
    {
        if let Some(axis) = vertical_axis_x {
            anchor.x = 2.0 * axis - anchor.x;
            anchor.incoming[0] = 2.0 * axis - anchor.incoming[0];
            anchor.outgoing[0] = 2.0 * axis - anchor.outgoing[0];
        }
        if let Some(axis) = horizontal_axis_y {
            anchor.y = 2.0 * axis - anchor.y;
            anchor.incoming[1] = 2.0 * axis - anchor.incoming[1];
            anchor.outgoing[1] = 2.0 * axis - anchor.outgoing[1];
        }
    }
    if mirrored
        .subpaths
        .iter()
        .flat_map(|subpath| &subpath.anchors)
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
    Ok(mirrored)
}

fn ensure_anchor_budget(path: &BezierPath, copies: usize) -> Result<(), VectorError> {
    let anchors = path
        .subpaths
        .iter()
        .try_fold(0usize, |count, subpath| {
            count.checked_add(subpath.anchors.len())
        })
        .ok_or(VectorError::TooComplex)?;
    if anchors == 0
        || anchors > MAX_BEZIER_ANCHORS
        || anchors.checked_mul(copies).is_none_or(|n| n > 4_096)
    {
        return Err(VectorError::TooComplex);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use ink_model::{
        AnchorKind, BezierAnchor, BezierSubpath, FillRule, StrokeCap, StrokeJoin, VectorStyle,
    };

    fn path() -> BezierPath {
        BezierPath {
            subpaths: vec![BezierSubpath {
                anchors: vec![
                    BezierAnchor {
                        x: 10.0,
                        y: 10.0,
                        incoming: [9.0, 10.0],
                        outgoing: [11.0, 10.0],
                        kind: AnchorKind::Smooth,
                    },
                    BezierAnchor {
                        x: 20.0,
                        y: 10.0,
                        incoming: [20.0, 9.0],
                        outgoing: [20.0, 11.0],
                        kind: AnchorKind::Corner,
                    },
                ],
                closed: false,
            }],
            style: VectorStyle {
                fill: None,
                stroke: None,
                stroke_width: 2.0,
                cap: StrokeCap::Round,
                join: StrokeJoin::Round,
                miter_limit: 4.0,
                fill_rule: FillRule::NonZero,
            },
        }
    }

    #[test]
    fn radial_copies_rotate_about_center_and_are_materialized_paths() {
        let copies =
            repeat_radial(&path(), (0.0, 0.0), 3, 90.0, 1.0).expect("bounded radial repeat");
        assert_eq!(copies.len(), 3);
        assert!((copies[0].subpaths[0].anchors[0].x + 10.0).abs() < 1e-9);
        assert!((copies[0].subpaths[0].anchors[0].y - 10.0).abs() < 1e-9);
        assert_eq!(copies[0].style.stroke_width.to_bits(), 2.0_f64.to_bits());
    }

    #[test]
    fn grid_omits_source_and_mirror_reflects_handles_and_anchors() {
        let copies = repeat_grid(&path(), 2, 2, 30.0, 40.0).expect("bounded grid");
        assert_eq!(copies.len(), 3);
        assert_eq!(
            (
                copies[0].subpaths[0].anchors[0].x,
                copies[0].subpaths[0].anchors[0].y
            ),
            (40.0, 10.0)
        );
        let mirrored = mirror_path(&path(), Some(15.0), None).expect("mirror");
        assert_eq!(
            mirrored.subpaths[0].anchors[0].x.to_bits(),
            20.0_f64.to_bits()
        );
        assert_eq!(
            mirrored.subpaths[0].anchors[0].incoming[0].to_bits(),
            21.0_f64.to_bits()
        );
    }

    #[test]
    fn repeat_rejects_unbounded_or_invalid_requests() {
        assert_eq!(
            repeat_radial(&path(), (0.0, 0.0), MAX_REPEAT_OBJECTS + 1, 1.0, 1.0),
            Err(VectorError::InvalidInput)
        );
        assert_eq!(
            repeat_grid(&path(), 9, 8, 1.0, 1.0),
            Err(VectorError::TooComplex)
        );
        assert_eq!(
            mirror_path(&path(), None, None),
            Err(VectorError::InvalidInput)
        );
    }
}

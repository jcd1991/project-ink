//! Deterministic, bounded object-aware alignment snapping.

/// Alignment coordinates contributed by anchors, bounds edges, or centers.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct GuideFeatures {
    /// Candidate x coordinates in document pixels.
    pub x: Vec<f64>,
    /// Candidate y coordinates in document pixels.
    pub y: Vec<f64>,
}

/// One selected-object feature aligned to a reference feature.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SmartGuideMatch {
    /// Selected feature coordinate before snapping.
    pub moving: f64,
    /// Reference feature coordinate.
    pub target: f64,
    /// Translation to apply on this axis.
    pub delta: f64,
}

/// Snapped translation and guide lines to display during the drag.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SmartGuideResult {
    /// Corrected total x translation to use for this drag update.
    pub delta_x: f64,
    /// Corrected total y translation to use for this drag update.
    pub delta_y: f64,
    /// Vertical guide location, if an x alignment was found.
    pub vertical_guide_x: Option<f64>,
    /// Horizontal guide location, if a y alignment was found.
    pub horizontal_guide_y: Option<f64>,
}

/// Snap moving-object features to the nearest reference feature on each axis.
///
/// Coordinates are document pixels. `requested_delta` is the user's raw
/// translation and `tolerance_px` should be converted from screen pixels by
/// the caller using the current viewport scale. Inputs are bounded to 1,024
/// features per axis to keep drag-time work predictable.
///
/// # Errors
/// Returns `None` for invalid or oversized input. An empty result means no
/// alignment fell within tolerance.
#[must_use]
pub fn snap_smart_guides(
    moving: &GuideFeatures,
    references: &GuideFeatures,
    requested_delta: (f64, f64),
    tolerance_px: f64,
) -> Option<SmartGuideResult> {
    const MAX_FEATURES_PER_AXIS: usize = 1_024;
    if !requested_delta.0.is_finite()
        || !requested_delta.1.is_finite()
        || !tolerance_px.is_finite()
        || tolerance_px < 0.0
        || moving.x.len() > MAX_FEATURES_PER_AXIS
        || moving.y.len() > MAX_FEATURES_PER_AXIS
        || references.x.len() > MAX_FEATURES_PER_AXIS
        || references.y.len() > MAX_FEATURES_PER_AXIS
        || moving
            .x
            .iter()
            .chain(&moving.y)
            .any(|value| !value.is_finite())
        || references
            .x
            .iter()
            .chain(&references.y)
            .any(|value| !value.is_finite())
    {
        return None;
    }

    let x = nearest_alignment(&moving.x, &references.x, requested_delta.0, tolerance_px);
    let y = nearest_alignment(&moving.y, &references.y, requested_delta.1, tolerance_px);
    Some(SmartGuideResult {
        delta_x: x.map_or(0.0, |alignment| alignment.delta),
        delta_y: y.map_or(0.0, |alignment| alignment.delta),
        vertical_guide_x: x.map(|alignment| alignment.target),
        horizontal_guide_y: y.map(|alignment| alignment.target),
    })
}

fn nearest_alignment(
    moving: &[f64],
    references: &[f64],
    requested_delta: f64,
    tolerance: f64,
) -> Option<SmartGuideMatch> {
    let mut best: Option<SmartGuideMatch> = None;
    for moving_feature in moving {
        let moved = moving_feature + requested_delta;
        for target in references {
            let correction = target - moved;
            if correction.abs() > tolerance {
                continue;
            }
            let candidate = SmartGuideMatch {
                moving: *moving_feature,
                target: *target,
                delta: requested_delta + correction,
            };
            let replace = best.is_none_or(|current| {
                let current_correction = (current.delta - requested_delta).abs();
                correction.abs().total_cmp(&current_correction).is_lt()
                    || (correction.abs().total_cmp(&current_correction).is_eq()
                        && target.total_cmp(&current.target).is_lt())
            });
            if replace {
                best = Some(candidate);
            }
        }
    }
    best
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snaps_nearest_x_and_y_alignments_independently() {
        let result = snap_smart_guides(
            &GuideFeatures {
                x: vec![10.0, 20.0],
                y: vec![10.0, 30.0],
            },
            &GuideFeatures {
                x: vec![34.0, 39.0],
                y: vec![41.0],
            },
            (18.0, 10.0),
            3.0,
        )
        .expect("valid bounded guides");
        assert_eq!(result.delta_x.to_bits(), 19.0_f64.to_bits());
        assert_eq!(result.vertical_guide_x, Some(39.0));
        assert_eq!(result.delta_y.to_bits(), 11.0_f64.to_bits());
        assert_eq!(result.horizontal_guide_y, Some(41.0));
    }

    #[test]
    fn tie_breaks_by_lower_reference_coordinate_and_rejects_invalid_inputs() {
        let moving = GuideFeatures {
            x: vec![0.0],
            y: vec![],
        };
        let refs = GuideFeatures {
            x: vec![2.0, -2.0],
            y: vec![],
        };
        assert_eq!(
            snap_smart_guides(&moving, &refs, (0.0, 0.0), 2.0)
                .and_then(|result| result.vertical_guide_x),
            Some(-2.0)
        );
        assert!(snap_smart_guides(&moving, &refs, (f64::NAN, 0.0), 2.0).is_none());
        assert!(snap_smart_guides(&moving, &refs, (0.0, 0.0), -1.0).is_none());
    }

    #[test]
    fn guide_outside_tolerance_does_not_snap() {
        let result = snap_smart_guides(
            &GuideFeatures {
                x: vec![1.0],
                y: vec![1.0],
            },
            &GuideFeatures {
                x: vec![10.0],
                y: vec![10.0],
            },
            (0.0, 0.0),
            4.0,
        )
        .expect("valid inputs");
        assert_eq!(result, SmartGuideResult::default());
    }
}

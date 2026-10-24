use super::{
    BrushDraftSettings, BrushEditUndo, BrushId, BrushPresetV2, BrushPressureDraftResponse,
    BrushPreviewPoint, BrushResource, BrushSummaryProjection, CPU_BRUSH_V4, CombineOp, Document,
    EngineError, EngineEvent, EngineSemantics, LayerId, LayerKind, MAX_DOCUMENT_RESOURCE_BYTES,
    PaintBehavior, ParameterBinding, ParameterId, ResponseCurve, Rgba8, SensorId, TipBehavior,
    VectorObjectSummaryTuple, VectorStroke, VectorStrokeSummaryTuple, advance_revision,
    brush_summary_projection, builtin_library, decode_editor_curve, hex_hash, lock_recover,
    next_available_brush_id, render_brush_dabs, resource_hashes_for_preset, resource_total_bytes,
    validate_brush_draft_settings,
};
use ink_input::{DeviceKind, Phase, PointerSample, flags};
use std::collections::{BTreeMap, HashSet};
use std::sync::atomic::Ordering;

const MAX_VECTOR_HIT_TEST_OBJECTS: usize = 4_096;

fn validate_brush_preview_bounds(
    width: u16,
    height: u16,
    points: &[BrushPreviewPoint],
) -> Result<(), EngineError> {
    if width == 0
        || height == 0
        || usize::from(width) * usize::from(height) > 256 * 256
        || points.is_empty()
        || points.len() > 1024
        || points.iter().any(|point| {
            !point.x.is_finite()
                || !point.y.is_finite()
                || !point.pressure.is_finite()
                || point.x < 0.0
                || point.y < 0.0
                || point.x > f32::from(width)
                || point.y > f32::from(height)
                || !(0.0..=1.0).contains(&point.pressure)
        })
    {
        return Err(EngineError::InvalidCommand(
            "brush preview points are outside the supported bounds".into(),
        ));
    }
    Ok(())
}

fn vector_stroke_near_point(stroke: &VectorStroke, x: f64, y: f64, tolerance: f64) -> bool {
    let Some(first) = stroke.points.first() else {
        return false;
    };
    let mut bounds = [first.x, first.y, first.x, first.y];
    for point in &stroke.points[1..] {
        bounds[0] = bounds[0].min(point.x);
        bounds[1] = bounds[1].min(point.y);
        bounds[2] = bounds[2].max(point.x);
        bounds[3] = bounds[3].max(point.y);
    }
    x >= f64::from(bounds[0]) - tolerance
        && x <= f64::from(bounds[2]) + tolerance
        && y >= f64::from(bounds[1]) - tolerance
        && y <= f64::from(bounds[3]) + tolerance
}

fn vector_path_near_point(path: &ink_model::BezierPath, x: f64, y: f64, tolerance: f64) -> bool {
    let mut bounds = [
        f64::INFINITY,
        f64::INFINITY,
        f64::NEG_INFINITY,
        f64::NEG_INFINITY,
    ];
    for anchor in path.subpaths.iter().flat_map(|subpath| &subpath.anchors) {
        for (px, py) in [
            (anchor.x, anchor.y),
            (anchor.incoming[0], anchor.incoming[1]),
            (anchor.outgoing[0], anchor.outgoing[1]),
        ] {
            bounds[0] = bounds[0].min(px);
            bounds[1] = bounds[1].min(py);
            bounds[2] = bounds[2].max(px);
            bounds[3] = bounds[3].max(py);
        }
    }
    let expansion = tolerance
        + path.style.stroke.map_or(0.0, |color| {
            if color.a == 0 {
                0.0
            } else {
                path.style.stroke_width
                    * 0.5
                    * if path.style.join == ink_model::StrokeJoin::Miter {
                        path.style.miter_limit
                    } else {
                        1.0
                    }
            }
        });
    x >= bounds[0] - expansion
        && x <= bounds[2] + expansion
        && y >= bounds[1] - expansion
        && y <= bounds[3] + expansion
}

fn stroke_bounds(points: &[ink_model::VectorPoint]) -> [f32; 4] {
    let Some(first) = points.first() else {
        return [0.0; 4];
    };
    let mut bounds = [first.x, first.y, first.x, first.y];
    for point in &points[1..] {
        bounds[0] = bounds[0].min(point.x);
        bounds[1] = bounds[1].min(point.y);
        bounds[2] = bounds[2].max(point.x);
        bounds[3] = bounds[3].max(point.y);
    }
    bounds
}

fn bezier_bounds_and_anchor_count(path: &ink_model::BezierPath) -> ([f32; 4], usize) {
    let mut bounds = [
        f32::INFINITY,
        f32::INFINITY,
        f32::NEG_INFINITY,
        f32::NEG_INFINITY,
    ];
    let mut count = 0usize;
    for anchor in path.subpaths.iter().flat_map(|subpath| &subpath.anchors) {
        count = count.saturating_add(1);
        for (x, y) in [
            (anchor.x, anchor.y),
            (anchor.incoming[0], anchor.incoming[1]),
            (anchor.outgoing[0], anchor.outgoing[1]),
        ] {
            bounds[0] = bounds[0].min(x as f32);
            bounds[1] = bounds[1].min(y as f32);
            bounds[2] = bounds[2].max(x as f32);
            bounds[3] = bounds[3].max(y as f32);
        }
    }
    if count == 0 {
        ([0.0; 4], 0)
    } else {
        let stroke_expansion = path.style.stroke.map_or(0.0, |color| {
            if color.a == 0 {
                0.0
            } else {
                path.style.stroke_width
                    * 0.5
                    * if path.style.join == ink_model::StrokeJoin::Miter {
                        path.style.miter_limit
                    } else {
                        1.0
                    }
            }
        }) as f32;
        bounds[0] -= stroke_expansion;
        bounds[1] -= stroke_expansion;
        bounds[2] += stroke_expansion;
        bounds[3] += stroke_expansion;
        (bounds, count)
    }
}

impl Document {
    /// Update one unambiguous pressure binding without rewriting other
    /// dynamics or changing the binding's base/combine semantics.
    pub fn update_brush_pressure_response(
        &mut self,
        brush_id: BrushId,
        target: super::BrushPressureTarget,
        amount: f32,
        enabled: bool,
        curve_points: &[f32],
    ) -> Result<u64, EngineError> {
        if !amount.is_finite() || !(0.0..=1.0).contains(&amount) {
            return Err(EngineError::InvalidCommand(
                "pressure response amount must be finite and normalized".into(),
            ));
        }
        let curve = ResponseCurve {
            points: decode_editor_curve(curve_points, 0.5)?,
        };
        self.flush_input()?;
        let mut state = lock_recover(&self.state);
        if state.active_stroke.is_some() {
            return Err(EngineError::InvalidCommand(
                "finish or cancel the active stroke before editing a brush".into(),
            ));
        }
        let parameter = match target {
            super::BrushPressureTarget::Size => ParameterId::Diameter,
            super::BrushPressureTarget::Opacity => ParameterId::Opacity,
            super::BrushPressureTarget::Flow => ParameterId::Flow,
        };
        let previous_override = state.brush_overrides.get(&brush_id).cloned();
        let mut preset = previous_override
            .clone()
            .or_else(|| {
                builtin_library()
                    .into_iter()
                    .find(|item| item.id == brush_id)
            })
            .ok_or_else(|| EngineError::InvalidCommand("unknown Phase 2 brush".into()))?;
        let matches: Vec<_> = preset
            .dynamics
            .iter()
            .enumerate()
            .filter(|(_, binding)| {
                binding.sensor == SensorId::Pressure && binding.target == parameter
            })
            .map(|(index, _)| index)
            .collect();
        if matches.len() > 1 {
            return Err(EngineError::InvalidCommand(
                "pressure response has multiple bindings and cannot be edited in the simple editor"
                    .into(),
            ));
        }
        if let Some(index) = matches.first() {
            let binding = &mut preset.dynamics[*index];
            binding.curve = curve;
            binding.amount = if enabled { amount } else { 0.0 };
        } else {
            preset.dynamics.push(ParameterBinding {
                target: parameter,
                base: 1.0,
                sensor: SensorId::Pressure,
                curve,
                amount: if enabled { amount } else { 0.0 },
                combine: CombineOp::Multiply,
            });
        }
        preset
            .validate()
            .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
        state.brush_overrides.insert(brush_id, preset);
        let current_override = state.brush_overrides.get(&brush_id).cloned();
        state.brush_undo = Some(BrushEditUndo {
            brush_id,
            previous_override,
            current_override,
        });
        state.brush_redo = None;
        let revision = advance_revision(&mut state)?;
        state.events.push(EngineEvent::DocumentChanged { revision });
        Ok(revision)
    }

    /// Render one bounded preview stroke without changing document pixels,
    /// history, or revision.
    pub fn render_brush_preview_rgba8(
        &self,
        brush_id: BrushId,
        width: u16,
        height: u16,
        points: &[BrushPreviewPoint],
    ) -> Result<Vec<u8>, EngineError> {
        validate_brush_preview_bounds(width, height, points)?;
        let (mut preset, draft) = {
            let state = lock_recover(&self.state);
            let preset = state
                .brush_overrides
                .get(&brush_id)
                .cloned()
                .or_else(|| {
                    builtin_library()
                        .into_iter()
                        .find(|preset| preset.id == brush_id)
                })
                .ok_or_else(|| EngineError::InvalidCommand("unknown Phase 2 brush".into()))?;
            let draft = state
                .brush_drafts
                .values()
                .find(|(draft_brush_id, _)| *draft_brush_id == brush_id)
                .map(|(_, settings)| settings.clone());
            (preset, draft)
        };
        if let Some(settings) = draft
            && validate_brush_draft_settings(&settings).is_ok()
        {
            apply_brush_draft_to_preset(&mut preset, &settings, false)?;
        }
        let count = points.len();
        let samples = points
            .iter()
            .enumerate()
            .map(|(index, point)| PointerSample {
                pointer_id: 1,
                flags: flags::ACTUAL,
                device_kind: DeviceKind::Stylus,
                phase: if index == 0 {
                    Phase::Down
                } else if index + 1 == count {
                    Phase::Up
                } else {
                    Phase::Move
                },
                canvas_x: point.x,
                canvas_y: point.y,
                pressure: (point.pressure * f32::from(u16::MAX)).round() as u16,
                tilt_x: 0.0,
                tilt_y: 0.0,
                azimuth: 0.0,
                twist: 0.0,
                timestamp_ns: index as u64 * 1_000_000,
                sequence: index as u32,
            })
            .collect::<Vec<_>>();
        let dabs = preset
            .compile()
            .and_then(|compiled| compiled.render(&samples))
            .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
        let resources = {
            let state = lock_recover(&self.state);
            dabs.iter()
                .filter_map(|dab| dab.tip_resource_hash)
                .filter_map(|hash| {
                    state
                        .resources
                        .get(&hash)
                        .map(|resource| (hash, resource.clone()))
                })
                .collect::<BTreeMap<_, _>>()
        };
        let mut tiles = ink_raster::TileStore::default();
        render_brush_dabs(
            &mut tiles,
            &dabs,
            &resources,
            None,
            false,
            false,
            false,
            u32::from(width),
            u32::from(height),
        );
        let mut pixels = Vec::with_capacity(usize::from(width) * usize::from(height) * 4);
        for y in 0..u32::from(height) {
            for x in 0..u32::from(width) {
                let pixel = tiles.sample_pixel(x, y);
                pixels.extend_from_slice(&[pixel.r, pixel.g, pixel.b, pixel.a]);
            }
        }
        Ok(pixels)
    }

    /// Start a temporary, Rust-owned brush edit transaction. Drafts are not
    /// visible to stroke capture until committed and are discarded on close.
    pub fn begin_brush_draft(&mut self, brush_id: BrushId) -> Result<u64, EngineError> {
        self.flush_input()?;
        let mut state = lock_recover(&self.state);
        if state.active_stroke.is_some() {
            return Err(EngineError::InvalidCommand(
                "finish or cancel the active stroke before editing a brush".into(),
            ));
        }
        let exists = state.brush_overrides.contains_key(&brush_id)
            || builtin_library().iter().any(|preset| preset.id == brush_id);
        if !exists {
            return Err(EngineError::InvalidCommand("unknown Phase 2 brush".into()));
        }
        let id = state.next_brush_draft;
        state.next_brush_draft = id.checked_add(1).ok_or_else(|| {
            EngineError::InvalidCommand("brush draft ID space is exhausted".into())
        })?;
        state.brush_drafts.insert(
            id,
            (
                brush_id,
                BrushDraftSettings {
                    diameter_px: 0.0,
                    opacity: 0.0,
                    spacing: 0.0,
                    smoothing: 0.0,
                    pressure_size: 0.0,
                    pressure_opacity: 0.0,
                    pressure_curve: 0.5,
                    hardness: 0.0,
                    texture_scale: 0.0,
                    scatter: 0.0,
                    rotation_jitter: 0.0,
                    smudge: 0.0,
                    wetness: 0.0,
                    pulled_string: false,
                    stabilizer_distance_px: 0.0,
                    catch_up_on_end: false,
                    pressure_curve_points: Vec::new(),
                    pressure_responses: Vec::new(),
                },
            ),
        );
        Ok(id)
    }

    /// Replace the pending settings for a brush draft without touching the
    /// installed library. The complete settings vector is required so a
    /// commit cannot accidentally inherit stale UI state.
    #[allow(clippy::too_many_arguments)]
    pub fn update_brush_draft(
        &mut self,
        draft_id: u64,
        diameter_px: f32,
        opacity: f32,
        spacing: f32,
        smoothing: f32,
        pressure_size: f32,
        pressure_opacity: f32,
        pressure_curve: f32,
        hardness: f32,
        texture_scale: f32,
        scatter: f32,
        rotation_jitter: f32,
        smudge: f32,
        wetness: f32,
        pulled_string: bool,
        stabilizer_distance_px: f32,
        catch_up_on_end: bool,
        pressure_curve_points: &[f32],
    ) -> Result<(), EngineError> {
        let settings = BrushDraftSettings {
            diameter_px,
            opacity,
            spacing,
            smoothing,
            pressure_size,
            pressure_opacity,
            pressure_curve,
            hardness,
            texture_scale,
            scatter,
            rotation_jitter,
            smudge,
            wetness,
            pulled_string,
            stabilizer_distance_px,
            catch_up_on_end,
            pressure_curve_points: pressure_curve_points.to_vec(),
            pressure_responses: Vec::new(),
        };
        validate_brush_draft_settings(&settings)?;
        self.flush_input()?;
        let mut state = lock_recover(&self.state);
        let Some((_, draft)) = state.brush_drafts.get_mut(&draft_id) else {
            return Err(EngineError::InvalidCommand(
                "brush draft is not active".into(),
            ));
        };
        let mut settings = settings;
        settings
            .pressure_responses
            .clone_from(&draft.pressure_responses);
        *draft = settings;
        Ok(())
    }

    /// Update one response inside an open brush draft; Commit publishes it.
    pub fn update_brush_pressure_response_draft(
        &mut self,
        draft_id: u64,
        target: super::BrushPressureTarget,
        amount: f32,
        enabled: bool,
        curve_points: &[f32],
    ) -> Result<(), EngineError> {
        if !amount.is_finite() || !(0.0..=1.0).contains(&amount) {
            return Err(EngineError::InvalidCommand(
                "pressure response amount must be finite and normalized".into(),
            ));
        }
        decode_editor_curve(curve_points, 0.5)?;
        self.flush_input()?;
        let mut state = lock_recover(&self.state);
        let Some((brush_id, _)) = state.brush_drafts.get(&draft_id) else {
            return Err(EngineError::InvalidCommand(
                "brush draft is not active".into(),
            ));
        };
        let brush_id = *brush_id;
        let parameter = pressure_parameter(target);
        let preset = state
            .brush_overrides
            .get(&brush_id)
            .cloned()
            .or_else(|| {
                builtin_library()
                    .into_iter()
                    .find(|preset| preset.id == brush_id)
            })
            .ok_or_else(|| EngineError::InvalidCommand("unknown Phase 2 brush".into()))?;
        if preset
            .dynamics
            .iter()
            .filter(|binding| binding.sensor == SensorId::Pressure && binding.target == parameter)
            .count()
            > 1
        {
            return Err(EngineError::InvalidCommand(
                "pressure response has multiple bindings and cannot be edited in the simple editor"
                    .into(),
            ));
        }
        let (_, draft) = state
            .brush_drafts
            .get_mut(&draft_id)
            .expect("draft checked above");
        if let Some(existing) = draft
            .pressure_responses
            .iter_mut()
            .find(|response| response.target == target)
        {
            existing.amount = amount;
            existing.enabled = enabled;
            existing.curve_points = curve_points.to_vec();
        } else {
            draft.pressure_responses.push(BrushPressureDraftResponse {
                target,
                amount,
                enabled,
                curve_points: curve_points.to_vec(),
            });
        }
        Ok(())
    }

    /// Commit a complete brush draft as one library mutation.
    #[allow(clippy::too_many_lines)]
    pub fn commit_brush_draft(&mut self, draft_id: u64) -> Result<u64, EngineError> {
        let (brush_id, settings) = {
            let mut state = lock_recover(&self.state);
            let (brush_id, settings) = state
                .brush_drafts
                .remove(&draft_id)
                .ok_or_else(|| EngineError::InvalidCommand("brush draft is not active".into()))?;
            (brush_id, settings)
        };
        if let Err(error) = validate_brush_draft_settings(&settings) {
            let mut state = lock_recover(&self.state);
            state.brush_drafts.insert(draft_id, (brush_id, settings));
            return Err(error);
        }
        let result = self.update_brush_settings_internal(
            brush_id,
            settings.diameter_px,
            settings.opacity,
            settings.spacing,
            settings.smoothing,
            settings.pressure_size,
            settings.pressure_opacity,
            settings.pressure_curve,
            settings.hardness,
            settings.texture_scale,
            settings.scatter,
            settings.rotation_jitter,
            settings.smudge,
            settings.wetness,
            &settings.pressure_curve_points,
            Some((
                settings.pulled_string,
                settings.stabilizer_distance_px,
                settings.catch_up_on_end,
            )),
            false,
            &settings.pressure_responses,
        );
        match result {
            Ok(revision) => Ok(revision),
            Err(error) => {
                let mut state = lock_recover(&self.state);
                state.brush_drafts.insert(draft_id, (brush_id, settings));
                Err(error)
            }
        }
    }

    /// Discard a draft without changing document revision or brush state.
    pub fn cancel_brush_draft(&mut self, draft_id: u64) -> Result<(), EngineError> {
        self.flush_input()?;
        let mut state = lock_recover(&self.state);
        if state.brush_drafts.remove(&draft_id).is_none() {
            return Err(EngineError::InvalidCommand(
                "brush draft is not active".into(),
            ));
        }
        Ok(())
    }

    /// Update the bounded, pixel-affecting controls for a user brush copy.
    ///
    /// The edit is validated and stored in Rust before the next stroke can
    /// capture it. Active strokes retain their immutable compiled preset.
    #[allow(clippy::too_many_arguments)]
    #[allow(clippy::too_many_lines)]
    pub fn update_brush_settings(
        &mut self,
        brush_id: BrushId,
        diameter_px: f32,
        opacity: f32,
        spacing: f32,
        smoothing: f32,
        pressure_size: f32,
        pressure_opacity: f32,
        pressure_curve: f32,
        hardness: f32,
        texture_scale: f32,
        scatter: f32,
        rotation_jitter: f32,
        smudge: f32,
        wetness: f32,
        pressure_curve_points: &[f32],
    ) -> Result<u64, EngineError> {
        self.update_brush_settings_internal(
            brush_id,
            diameter_px,
            opacity,
            spacing,
            smoothing,
            pressure_size,
            pressure_opacity,
            pressure_curve,
            hardness,
            texture_scale,
            scatter,
            rotation_jitter,
            smudge,
            wetness,
            pressure_curve_points,
            None,
            true,
            &[],
        )
    }

    /// Update the ordinary brush controls and path stabilizer as one undoable
    /// library mutation.
    #[allow(clippy::too_many_arguments)]
    #[allow(clippy::too_many_lines)]
    pub fn update_brush_settings_with_stabilizer(
        &mut self,
        brush_id: BrushId,
        diameter_px: f32,
        opacity: f32,
        spacing: f32,
        smoothing: f32,
        pressure_size: f32,
        pressure_opacity: f32,
        pressure_curve: f32,
        hardness: f32,
        texture_scale: f32,
        scatter: f32,
        rotation_jitter: f32,
        smudge: f32,
        wetness: f32,
        pressure_curve_points: &[f32],
        pulled_string: bool,
        stabilizer_distance_px: f32,
        catch_up_on_end: bool,
    ) -> Result<u64, EngineError> {
        self.update_brush_settings_internal(
            brush_id,
            diameter_px,
            opacity,
            spacing,
            smoothing,
            pressure_size,
            pressure_opacity,
            pressure_curve,
            hardness,
            texture_scale,
            scatter,
            rotation_jitter,
            smudge,
            wetness,
            pressure_curve_points,
            Some((pulled_string, stabilizer_distance_px, catch_up_on_end)),
            true,
            &[],
        )
    }

    #[allow(clippy::too_many_arguments)]
    #[allow(clippy::too_many_lines)]
    fn update_brush_settings_internal(
        &mut self,
        brush_id: BrushId,
        diameter_px: f32,
        opacity: f32,
        spacing: f32,
        smoothing: f32,
        pressure_size: f32,
        pressure_opacity: f32,
        pressure_curve: f32,
        hardness: f32,
        texture_scale: f32,
        scatter: f32,
        rotation_jitter: f32,
        smudge: f32,
        wetness: f32,
        pressure_curve_points: &[f32],
        stabilizer: Option<(bool, f32, bool)>,
        update_shared_curve: bool,
        pressure_responses: &[BrushPressureDraftResponse],
    ) -> Result<u64, EngineError> {
        self.flush_input()?;
        if !diameter_px.is_finite()
            || !opacity.is_finite()
            || !spacing.is_finite()
            || !smoothing.is_finite()
            || !pressure_size.is_finite()
            || !pressure_opacity.is_finite()
            || !pressure_curve.is_finite()
            || !hardness.is_finite()
            || !texture_scale.is_finite()
            || !scatter.is_finite()
            || !rotation_jitter.is_finite()
            || !smudge.is_finite()
            || !wetness.is_finite()
            || !(0.25..=4096.0).contains(&diameter_px)
            || !(0.0..=1.0).contains(&opacity)
            || !(0.001..=1.0).contains(&spacing)
            || !(0.0..=1.0).contains(&smoothing)
            || !(0.0..=1.0).contains(&pressure_size)
            || !(0.0..=1.0).contains(&pressure_opacity)
            || !(0.0..=1.0).contains(&pressure_curve)
            || !(0.0..=1.0).contains(&hardness)
            || !(0.01..=64.0).contains(&texture_scale)
            || !(0.0..=1.0).contains(&scatter)
            || !(0.0..=1.0).contains(&rotation_jitter)
            || !(0.0..=1.0).contains(&smudge)
            || !(0.0..=1.0).contains(&wetness)
            || stabilizer.is_some_and(|(_, distance, _)| {
                !distance.is_finite() || !(0.0..=100.0).contains(&distance)
            })
        {
            return Err(EngineError::InvalidCommand(
                "brush settings are outside the supported finite ranges".into(),
            ));
        }
        let mut state = lock_recover(&self.state);
        if state.active_stroke.is_some() {
            return Err(EngineError::InvalidCommand(
                "finish or cancel the active stroke before editing a brush".into(),
            ));
        }
        let previous_override = state.brush_overrides.get(&brush_id).cloned();
        let mut preset = previous_override
            .clone()
            .or_else(|| {
                builtin_library()
                    .into_iter()
                    .find(|candidate| candidate.id == brush_id)
            })
            .ok_or_else(|| EngineError::InvalidCommand("unknown Phase 2 brush".into()))?;
        let (pulled_string, stabilizer_distance_px, catch_up_on_end) = stabilizer.unwrap_or((
            preset.stroke.stabilizer == ink_brush::PathStabilizer::PulledString,
            preset.stroke.distance_px,
            preset.stroke.catch_up_on_end,
        ));
        let settings = BrushDraftSettings {
            diameter_px,
            opacity,
            spacing,
            smoothing,
            pressure_size,
            pressure_opacity,
            pressure_curve,
            hardness,
            texture_scale,
            scatter,
            rotation_jitter,
            smudge,
            wetness,
            pulled_string,
            stabilizer_distance_px,
            catch_up_on_end,
            pressure_curve_points: pressure_curve_points.to_vec(),
            pressure_responses: Vec::new(),
        };
        apply_brush_draft_to_preset(&mut preset, &settings, update_shared_curve)?;
        apply_pressure_response_drafts(&mut preset, pressure_responses)?;
        state.brush_overrides.insert(brush_id, preset);
        let current_override = state.brush_overrides.get(&brush_id).cloned();
        state.brush_undo = Some(BrushEditUndo {
            brush_id,
            previous_override,
            current_override,
        });
        state.brush_redo = None;
        let revision = advance_revision(&mut state)?;
        state.events.push(EngineEvent::DocumentChanged { revision });
        Ok(revision)
    }

    /// Update the active color of a Rust-owned brush copy.
    ///
    /// Color changes are document-library mutations, so they are rejected
    /// during an active stroke and advance the same revision/event stream as
    /// other brush edits. The color remains part of the saved brush override.
    pub fn update_brush_color(
        &mut self,
        brush_id: BrushId,
        color: Rgba8,
    ) -> Result<u64, EngineError> {
        self.flush_input()?;
        let mut state = lock_recover(&self.state);
        if state.active_stroke.is_some() {
            return Err(EngineError::InvalidCommand(
                "finish or cancel the active stroke before editing a brush".into(),
            ));
        }
        let previous_override = state.brush_overrides.get(&brush_id).cloned();
        let mut preset = previous_override
            .clone()
            .or_else(|| {
                builtin_library()
                    .into_iter()
                    .find(|candidate| candidate.id == brush_id)
            })
            .ok_or_else(|| EngineError::InvalidCommand("unknown Phase 2 brush".into()))?;
        set_brush_paint_color(&mut preset.paint, color);
        preset
            .validate()
            .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
        state.brush_overrides.insert(brush_id, preset);
        let current_override = state.brush_overrides.get(&brush_id).cloned();
        state.brush_undo = Some(BrushEditUndo {
            brush_id,
            previous_override,
            current_override,
        });
        state.brush_redo = None;
        let revision = advance_revision(&mut state)?;
        state.events.push(EngineEvent::DocumentChanged { revision });
        Ok(revision)
    }

    /// Set the shared foreground color used by subsequent strokes in this
    /// document session. This does not edit or persist any brush preset.
    pub fn set_active_brush_color(&mut self, color: Rgba8) {
        lock_recover(&self.state).active_brush_color = Some(color);
    }

    /// Rename a user-owned brush copy without changing its rendering data.
    pub fn rename_brush(&mut self, brush_id: BrushId, name: &str) -> Result<u64, EngineError> {
        self.flush_input()?;
        let name = name.trim();
        if name.is_empty() || name.len() > 256 {
            return Err(EngineError::InvalidCommand(
                "brush name must contain 1 to 256 UTF-8 bytes".into(),
            ));
        }
        let mut state = lock_recover(&self.state);
        if state.active_stroke.is_some() {
            return Err(EngineError::InvalidCommand(
                "finish or cancel the active stroke before editing a brush".into(),
            ));
        }
        let previous_override = state.brush_overrides.get(&brush_id).cloned();
        let mut preset = previous_override.clone().ok_or_else(|| {
            EngineError::InvalidCommand("only duplicated or imported brushes can be renamed".into())
        })?;
        name.clone_into(&mut preset.metadata.name);
        preset.revision = preset
            .revision
            .checked_add(1)
            .ok_or_else(|| EngineError::InvalidCommand("brush revision is exhausted".into()))?;
        preset
            .validate()
            .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
        state.brush_overrides.insert(brush_id, preset.clone());
        state.brush_undo = Some(BrushEditUndo {
            brush_id,
            previous_override,
            current_override: Some(preset),
        });
        state.brush_redo = None;
        let revision = advance_revision(&mut state)?;
        state.events.push(EngineEvent::DocumentChanged { revision });
        Ok(revision)
    }

    /// Export a Rust-owned brush preset without exposing its mutable state.
    pub fn export_brush(
        &mut self,
        brush_id: BrushId,
        destination: &std::path::Path,
    ) -> Result<(), EngineError> {
        self.flush_input()?;
        let state = lock_recover(&self.state);
        let preset = state
            .brush_overrides
            .get(&brush_id)
            .cloned()
            .or_else(|| {
                builtin_library()
                    .into_iter()
                    .find(|candidate| candidate.id == brush_id)
            })
            .ok_or_else(|| EngineError::InvalidCommand("unknown Phase 2 brush".into()))?;
        let resources = resource_hashes_for_preset(&preset)
            .into_iter()
            .map(|hash| {
                let resource = state.resources.get(&hash).ok_or_else(|| {
                    EngineError::InvalidCommand(
                        "brush references a resource that is not available".into(),
                    )
                })?;
                Ok(ink_brush::ImportedResource {
                    name: format!("{}.rgba", hex_hash(&hash)),
                    kind: resource.kind.clone(),
                    sha256: hash,
                    bytes: u64::try_from(resource.rgba8.len()).unwrap_or(u64::MAX),
                    data: resource.rgba8.clone(),
                    width: resource.width,
                    height: resource.height,
                })
            })
            .collect::<Result<Vec<_>, EngineError>>()?;
        ink_brush::export_inkbrush_with_resources(destination, &preset, &resources)
            .map_err(|error| EngineError::InvalidCommand(format!("brush export failed: {error}")))
    }

    /// Duplicate a built-in or imported preset into a new Rust-owned brush.
    /// The duplicate receives a fresh stable ID and participates in the same
    /// single-edit undo/redo boundary as other brush-library mutations.
    pub fn duplicate_brush(&mut self, brush_id: BrushId) -> Result<BrushId, EngineError> {
        self.flush_input()?;
        let mut state = lock_recover(&self.state);
        if state.active_stroke.is_some() {
            return Err(EngineError::InvalidCommand(
                "finish or cancel the active stroke before duplicating a brush".into(),
            ));
        }
        let mut preset = state
            .brush_overrides
            .get(&brush_id)
            .cloned()
            .or_else(|| {
                builtin_library()
                    .into_iter()
                    .find(|candidate| candidate.id == brush_id)
            })
            .ok_or_else(|| EngineError::InvalidCommand("unknown Phase 2 brush".into()))?;
        let duplicate_id = next_available_brush_id(&state)?;
        let suffix = " Copy";
        let mut name = String::new();
        for character in preset.metadata.name.chars() {
            if name
                .len()
                .saturating_add(character.len_utf8())
                .saturating_add(suffix.len())
                > 256
            {
                break;
            }
            name.push(character);
        }
        name.push_str(suffix);
        preset.id = duplicate_id;
        preset.revision = preset
            .revision
            .checked_add(1)
            .ok_or_else(|| EngineError::InvalidCommand("brush revision is exhausted".into()))?;
        preset.metadata.name = name;
        preset
            .validate()
            .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
        state.brush_overrides.insert(duplicate_id, preset.clone());
        state.brush_undo = Some(BrushEditUndo {
            brush_id: duplicate_id,
            previous_override: None,
            current_override: Some(preset),
        });
        state.brush_redo = None;
        let revision = advance_revision(&mut state)?;
        state.events.push(EngineEvent::DocumentChanged { revision });
        Ok(duplicate_id)
    }

    /// Convert and install a supported external brush into the Rust-owned
    /// document library. Guided reports without a decoded preset are rejected.
    pub fn import_brush(&mut self, source: &std::path::Path) -> Result<BrushId, EngineError> {
        self.import_brush_verified(source, None)
    }

    /// Convert and install a brush only if its content still matches the hash
    /// presented during the import report step. This closes path-based TOCTOU
    /// races without exposing source bytes to Flutter.
    pub fn import_brush_verified(
        &mut self,
        source: &std::path::Path,
        expected_sha256: Option<[u8; 32]>,
    ) -> Result<BrushId, EngineError> {
        self.flush_input()?;
        let report = ink_brush::import_external(source).map_err(|error| {
            EngineError::InvalidCommand(format!("brush import failed: {error}"))
        })?;
        if expected_sha256.is_some_and(|expected| expected != report.source_sha256) {
            return Err(EngineError::InvalidCommand(
                "brush source changed after compatibility inspection".into(),
            ));
        }
        let mut preset = report.preset.ok_or_else(|| {
            EngineError::InvalidCommand(
                "this source requires guided brush recreation and cannot be installed automatically"
                    .into(),
            )
        })?;
        let resources = report.resources;
        if resources.iter().any(|resource| resource.data.is_empty()) {
            return Err(EngineError::InvalidCommand(
                "imported brush resource has no decoded payload".into(),
            ));
        }
        preset.validate().map_err(|error| {
            EngineError::InvalidCommand(format!("imported brush validation failed: {error}"))
        })?;
        let mut state = lock_recover(&self.state);
        if state.active_stroke.is_some() {
            return Err(EngineError::InvalidCommand(
                "finish or cancel the active stroke before importing a brush".into(),
            ));
        }
        let next_id = state
            .brush_overrides
            .keys()
            .map(|id| id.0)
            .chain(1_u128..=12)
            .max()
            .and_then(|id| id.checked_add(1))
            .ok_or_else(|| EngineError::InvalidCommand("brush ID space is exhausted".into()))?;
        preset.id = BrushId::from_u128(next_id);
        let id = preset.id;
        if state.revision == u64::MAX {
            return Err(EngineError::InvalidCommand(
                "document revision is exhausted".into(),
            ));
        }
        let incoming_bytes = resources
            .iter()
            .filter(|resource| !state.resources.contains_key(&resource.sha256))
            .map(|resource| resource.data.len())
            .sum::<usize>();
        if resource_total_bytes(&state.resources).saturating_add(incoming_bytes)
            > MAX_DOCUMENT_RESOURCE_BYTES
        {
            return Err(EngineError::InvalidCommand(
                "brush resources exceed the document memory limit".into(),
            ));
        }
        for resource in resources {
            state
                .resources
                .entry(resource.sha256)
                .or_insert_with(|| BrushResource {
                    kind: resource.kind,
                    width: resource.width,
                    height: resource.height,
                    rgba8: resource.data,
                });
        }
        state.brush_overrides.insert(id, preset);
        let revision = advance_revision(&mut state)?;
        state.events.push(EngineEvent::DocumentChanged { revision });
        Ok(id)
    }

    /// Convert and install every member of a native brush pack as one
    /// transaction. A changed source or a single invalid member aborts the
    /// whole operation before the library is mutated.
    pub fn import_brush_pack_verified(
        &mut self,
        source: &std::path::Path,
        expected_sha256: Option<[u8; 32]>,
    ) -> Result<Vec<BrushId>, EngineError> {
        self.flush_input()?;
        let reports = ink_brush::import_inkbrushpack(source).map_err(|error| {
            EngineError::InvalidCommand(format!("brush pack import failed: {error}"))
        })?;
        self.install_imported_brush_reports(reports, expected_sha256, "brush pack")
    }

    /// Convert and install every `.kpp` member of a Krita bundle as one
    /// transaction. A changed source or a single invalid member aborts the
    /// whole operation before the library is mutated.
    pub fn import_krita_bundle_verified(
        &mut self,
        source: &std::path::Path,
        expected_sha256: Option<[u8; 32]>,
    ) -> Result<Vec<BrushId>, EngineError> {
        self.flush_input()?;
        let reports = ink_brush::import_krita_bundle(source).map_err(|error| {
            EngineError::InvalidCommand(format!("Krita bundle import failed: {error}"))
        })?;
        self.install_imported_brush_reports(reports, expected_sha256, "Krita bundle")
    }

    /// Convert and install every readable ABR tip as one library transaction.
    /// A changed source, invalid preset, or resource-budget failure leaves the
    /// current brush library untouched.
    pub fn import_photoshop_abr_verified(
        &mut self,
        source: &std::path::Path,
        expected_sha256: Option<[u8; 32]>,
    ) -> Result<Vec<BrushId>, EngineError> {
        self.flush_input()?;
        let reports = ink_brush::import_photoshop_abr(source).map_err(|error| {
            EngineError::InvalidCommand(format!("Photoshop ABR import failed: {error}"))
        })?;
        self.install_imported_brush_reports(reports, expected_sha256, "Photoshop ABR")
    }

    fn install_imported_brush_reports(
        &mut self,
        reports: Vec<ink_brush::BrushImportReport>,
        expected_sha256: Option<[u8; 32]>,
        source_label: &str,
    ) -> Result<Vec<BrushId>, EngineError> {
        if let Some(expected) = expected_sha256 {
            let actual = reports
                .first()
                .map(|report| report.source_sha256)
                .ok_or_else(|| EngineError::InvalidCommand(format!("{source_label} is empty")))?;
            if actual != expected {
                return Err(EngineError::InvalidCommand(format!(
                    "{source_label} source changed after compatibility inspection"
                )));
            }
        }
        let mut prepared = Vec::with_capacity(reports.len());
        for report in reports {
            let preset = report.preset.ok_or_else(|| {
                EngineError::InvalidCommand(format!("{source_label} member has no decoded preset"))
            })?;
            let resources = report.resources;
            if resources.iter().any(|resource| resource.data.is_empty()) {
                return Err(EngineError::InvalidCommand(format!(
                    "{source_label} resource has no decoded payload"
                )));
            }
            preset.validate().map_err(|error| {
                EngineError::InvalidCommand(format!("imported brush validation failed: {error}"))
            })?;
            prepared.push((preset, resources));
        }
        let mut state = lock_recover(&self.state);
        if state.active_stroke.is_some() {
            return Err(EngineError::InvalidCommand(
                "finish or cancel the active stroke before importing brushes".into(),
            ));
        }
        let next_id = state
            .brush_overrides
            .keys()
            .map(|id| id.0)
            .chain(1_u128..=12)
            .max()
            .and_then(|id| id.checked_add(1))
            .ok_or_else(|| EngineError::InvalidCommand("brush ID space is exhausted".into()))?;
        if state.revision == u64::MAX {
            return Err(EngineError::InvalidCommand(
                "document revision is exhausted".into(),
            ));
        }
        if next_id.checked_add(prepared.len() as u128).is_none() {
            return Err(EngineError::InvalidCommand(
                "brush ID space is exhausted".into(),
            ));
        }
        // A multi-member pack/bundle may legitimately share one decoded tip
        // or grain resource. Count each content hash once for the document
        // budget; installation below is already content-addressed and
        // deduplicates the same resource in the state map.
        let mut incoming_hashes = HashSet::new();
        let incoming_bytes = prepared
            .iter()
            .flat_map(|(_, resources)| resources.iter())
            .filter(|resource| !state.resources.contains_key(&resource.sha256))
            .filter(|resource| incoming_hashes.insert(resource.sha256))
            .map(|resource| resource.data.len())
            .sum::<usize>();
        if resource_total_bytes(&state.resources).saturating_add(incoming_bytes)
            > MAX_DOCUMENT_RESOURCE_BYTES
        {
            return Err(EngineError::InvalidCommand(format!(
                "{source_label} resources exceed the document memory limit"
            )));
        }
        let mut installed = Vec::with_capacity(prepared.len());
        for (index, (mut preset, resources)) in prepared.into_iter().enumerate() {
            for resource in resources {
                state
                    .resources
                    .entry(resource.sha256)
                    .or_insert_with(|| BrushResource {
                        kind: resource.kind,
                        width: resource.width,
                        height: resource.height,
                        rgba8: resource.data,
                    });
            }
            preset.id = BrushId::from_u128(next_id + index as u128);
            let id = preset.id;
            state.brush_overrides.insert(id, preset);
            installed.push(id);
        }
        let revision = advance_revision(&mut state)?;
        state.events.push(EngineEvent::DocumentChanged { revision });
        Ok(installed)
    }

    /// Return built-in and imported brush metadata in stable ID order.
    #[must_use]
    pub fn brush_summaries(&self) -> Vec<BrushSummaryProjection> {
        let _ = self.flush_input();
        let state = lock_recover(&self.state);
        let mut presets = builtin_library()
            .into_iter()
            .map(|preset| (preset.id, preset))
            .collect::<BTreeMap<_, _>>();
        for (id, preset) in &state.brush_overrides {
            presets.insert(*id, preset.clone());
        }
        presets
            .into_values()
            .map(|preset| brush_summary_projection(&preset))
            .collect()
    }

    /// Return bounded vector-stroke metadata for one vector layer.
    pub fn vector_stroke_summaries(
        &self,
        layer_id: LayerId,
    ) -> Result<Vec<VectorStrokeSummaryTuple>, EngineError> {
        let _ = self.flush_input();
        let state = lock_recover(&self.state);
        let layer = state
            .layers
            .get(&layer_id)
            .ok_or(EngineError::InvalidLayer)?;
        if layer.layer.kind != LayerKind::VectorInk {
            return Err(EngineError::InvalidCommand(
                "vector stroke summaries require a vector layer".into(),
            ));
        }
        Ok(layer
            .vectors
            .iter()
            .map(|(id, stroke)| {
                let mut bounds = [
                    f32::INFINITY,
                    f32::INFINITY,
                    f32::NEG_INFINITY,
                    f32::NEG_INFINITY,
                ];
                for point in &stroke.points {
                    bounds[0] = bounds[0].min(point.x);
                    bounds[1] = bounds[1].min(point.y);
                    bounds[2] = bounds[2].max(point.x);
                    bounds[3] = bounds[3].max(point.y);
                }
                (
                    *id,
                    u32::try_from(stroke.points.len()).unwrap_or(u32::MAX),
                    bounds,
                    stroke
                        .points
                        .iter()
                        .flat_map(|point| [point.x, point.y, point.pressure, point.tilt])
                        .collect(),
                )
            })
            .collect())
    }

    /// Return one bounded page of lightweight mixed-vector summaries.
    pub fn vector_object_summaries(
        &self,
        layer_id: LayerId,
        offset: usize,
        limit: usize,
    ) -> Result<Vec<VectorObjectSummaryTuple>, EngineError> {
        if limit == 0 || limit > 64 {
            return Err(EngineError::InvalidCommand(
                "vector summary page size must be between 1 and 64".into(),
            ));
        }
        self.flush_input()?;
        let state = lock_recover(&self.state);
        let layer = state
            .layers
            .get(&layer_id)
            .ok_or(EngineError::InvalidLayer)?;
        if layer.layer.kind != LayerKind::VectorInk {
            return Err(EngineError::InvalidCommand(
                "vector object summaries require a vector layer".into(),
            ));
        }
        let end = offset.saturating_add(limit).min(layer.vector_order.len());
        if offset >= end {
            return Ok(Vec::new());
        }
        let mut page = Vec::new();
        page.try_reserve(end - offset).map_err(|_| {
            EngineError::InvalidCommand("vector summary page exceeds available memory".into())
        })?;
        for id in &layer.vector_order[offset..end] {
            if let Some((_, stroke)) = layer.vectors.iter().find(|(candidate, _)| candidate == id) {
                let bounds = stroke_bounds(&stroke.points);
                page.push((
                    *id,
                    "LegacyInk".to_owned(),
                    u32::try_from(stroke.points.len()).unwrap_or(u32::MAX),
                    bounds,
                    Vec::new(),
                    Vec::new(),
                    Vec::new(),
                    Vec::new(),
                    false,
                ));
                continue;
            }
            let Some((_, path, source)) = layer
                .bezier_paths
                .iter()
                .find(|(candidate, _, _)| candidate == id)
            else {
                continue;
            };
            let (bounds, anchor_count) = bezier_bounds_and_anchor_count(path);
            page.push((
                *id,
                "BezierPath".to_owned(),
                u32::try_from(anchor_count).unwrap_or(u32::MAX),
                bounds,
                Vec::new(),
                Vec::new(),
                Vec::new(),
                Vec::new(),
                source.is_some(),
            ));
        }
        Ok(page)
    }

    /// Fetch full geometry for a single selected object only.
    pub fn vector_object_detail(
        &self,
        layer_id: LayerId,
        object_id: ink_model::StrokeId,
    ) -> Result<Option<VectorObjectSummaryTuple>, EngineError> {
        self.flush_input()?;
        let state = lock_recover(&self.state);
        let layer = state
            .layers
            .get(&layer_id)
            .ok_or(EngineError::InvalidLayer)?;
        if layer.layer.kind != LayerKind::VectorInk {
            return Err(EngineError::InvalidCommand(
                "vector object details require a vector layer".into(),
            ));
        }
        if let Some((_, stroke)) = layer
            .vectors
            .iter()
            .find(|(candidate, _)| *candidate == object_id)
        {
            let bounds = stroke_bounds(&stroke.points);
            let mut points = Vec::new();
            points
                .try_reserve(stroke.points.len().saturating_mul(4))
                .map_err(|_| {
                    EngineError::InvalidCommand(
                        "vector object detail exceeds available memory".into(),
                    )
                })?;
            for point in &stroke.points {
                points.extend([point.x, point.y, point.pressure, point.tilt]);
            }
            return Ok(Some((
                object_id,
                "LegacyInk".to_owned(),
                u32::try_from(stroke.points.len()).unwrap_or(u32::MAX),
                bounds,
                points,
                Vec::new(),
                Vec::new(),
                Vec::new(),
                false,
            )));
        }
        let Some((_, path, source)) = layer
            .bezier_paths
            .iter()
            .find(|(candidate, _, _)| *candidate == object_id)
        else {
            return Ok(None);
        };
        let (bounds, anchor_count) = bezier_bounds_and_anchor_count(path);
        let mut geometry = Vec::new();
        geometry
            .try_reserve(anchor_count.saturating_mul(6))
            .map_err(|_| {
                EngineError::InvalidCommand("vector object detail exceeds available memory".into())
            })?;
        let mut subpath_starts = Vec::new();
        let mut closed = Vec::new();
        subpath_starts
            .try_reserve(path.subpaths.len())
            .map_err(|_| {
                EngineError::InvalidCommand("vector detail exceeds available memory".into())
            })?;
        closed.try_reserve(path.subpaths.len()).map_err(|_| {
            EngineError::InvalidCommand("vector detail exceeds available memory".into())
        })?;
        let mut anchor_offset = 0usize;
        for subpath in &path.subpaths {
            subpath_starts.push(u32::try_from(anchor_offset).map_err(|_| {
                EngineError::InvalidCommand("vector subpath index exceeds supported range".into())
            })?);
            closed.push(subpath.closed);
            for anchor in &subpath.anchors {
                geometry.extend([
                    anchor.x,
                    anchor.y,
                    anchor.incoming[0],
                    anchor.incoming[1],
                    anchor.outgoing[0],
                    anchor.outgoing[1],
                ]);
            }
            anchor_offset = anchor_offset
                .checked_add(subpath.anchors.len())
                .ok_or_else(|| {
                    EngineError::InvalidCommand(
                        "vector anchor count exceeds supported range".into(),
                    )
                })?;
        }
        Ok(Some((
            object_id,
            "BezierPath".to_owned(),
            u32::try_from(anchor_count).unwrap_or(u32::MAX),
            bounds,
            Vec::new(),
            geometry,
            subpath_starts,
            closed,
            source.is_some(),
        )))
    }

    /// Hit-test the topmost editable vector object near a document-space point.
    /// Geometry work runs after the state lock is released, and at most 4,096
    /// ordered objects are examined per request.
    pub fn vector_hit_test(
        &self,
        layer_id: LayerId,
        x: f64,
        y: f64,
        tolerance_px: f64,
    ) -> Result<Option<ink_model::StrokeId>, EngineError> {
        if !x.is_finite()
            || !y.is_finite()
            || !tolerance_px.is_finite()
            || !(0.0..=4096.0).contains(&tolerance_px)
        {
            return Err(EngineError::InvalidCommand(
                "vector hit-test coordinates or tolerance are invalid".into(),
            ));
        }
        self.flush_input()?;
        let (object_count, revision) = {
            let state = lock_recover(&self.state);
            let layer = state
                .layers
                .get(&layer_id)
                .ok_or(EngineError::InvalidLayer)?;
            if layer.layer.kind != LayerKind::VectorInk {
                return Err(EngineError::InvalidCommand(
                    "vector hit-testing requires a vector-ink layer".into(),
                ));
            }
            let mut ancestor = Some(layer_id);
            while let Some(id) = ancestor {
                let current = state.layers.get(&id).ok_or(EngineError::InvalidLayer)?;
                if !current.layer.visible || current.layer.locked {
                    return Err(EngineError::InvalidCommand(
                        "vector hit-test target is hidden or locked".into(),
                    ));
                }
                ancestor = current.layer.parent;
            }
            (layer.vector_order.len(), state.revision)
        };
        let examined = object_count.min(MAX_VECTOR_HIT_TEST_OBJECTS);
        for index in (object_count - examined..object_count).rev() {
            let object = {
                let state = lock_recover(&self.state);
                if state.revision != revision {
                    return Err(EngineError::InvalidCommand(
                        "vector hit-test became stale during selection".into(),
                    ));
                }
                let layer = state
                    .layers
                    .get(&layer_id)
                    .ok_or(EngineError::InvalidLayer)?;
                let id = layer.vector_order[index];
                if let Some((_, stroke)) =
                    layer.vectors.iter().find(|(candidate, _)| *candidate == id)
                {
                    vector_stroke_near_point(stroke, x, y, tolerance_px).then(|| {
                        (
                            id,
                            ink_model::VectorObject::LegacyInk {
                                stroke: stroke.clone(),
                            },
                        )
                    })
                } else if let Some((_, path, source)) = layer
                    .bezier_paths
                    .iter()
                    .find(|(candidate, _, _)| *candidate == id)
                {
                    vector_path_near_point(path, x, y, tolerance_px).then(|| {
                        (
                            id,
                            ink_model::VectorObject::BezierPath {
                                path: path.clone(),
                                source: source.clone(),
                            },
                        )
                    })
                } else {
                    None
                }
            };
            let Some((object_id, object)) = object else {
                continue;
            };
            let hit = match object {
                ink_model::VectorObject::LegacyInk { stroke } => {
                    ink_vector::hit_test_legacy_stroke(&stroke, x, y, tolerance_px)
                }
                ink_model::VectorObject::BezierPath { path, .. } => {
                    ink_vector::hit_test_bezier_path(&path, x, y, tolerance_px)
                }
            }
            .map_err(|error| {
                EngineError::InvalidCommand(format!("vector hit-test failed: {error:?}"))
            })?;
            if hit {
                return Ok(Some(object_id));
            }
        }
        if object_count > MAX_VECTOR_HIT_TEST_OBJECTS {
            return Err(EngineError::InvalidCommand(
                "vector hit-test exceeded its 4,096-object scan limit".into(),
            ));
        }
        Ok(None)
    }

    /// Capture one visible, editable legacy vector stroke for an off-lock
    /// recognition or fitting preview. It clones only the selected legacy
    /// stroke so geometry work can run after this lock is released.
    pub fn vector_stroke_for_candidate(
        &self,
        layer_id: LayerId,
        stroke_id: ink_model::StrokeId,
    ) -> Result<(u64, VectorStroke), EngineError> {
        self.flush_input()?;
        let state = lock_recover(&self.state);
        let layer = state
            .layers
            .get(&layer_id)
            .ok_or(EngineError::InvalidLayer)?;
        if layer.layer.kind != LayerKind::VectorInk {
            return Err(EngineError::InvalidCommand(
                "vector candidates require a vector-ink layer".into(),
            ));
        }
        let mut ancestor = Some(layer_id);
        while let Some(id) = ancestor {
            let current = state.layers.get(&id).ok_or(EngineError::InvalidLayer)?;
            if !current.layer.visible || current.layer.locked {
                return Err(EngineError::InvalidCommand(
                    "vector candidate target is hidden or locked".into(),
                ));
            }
            ancestor = current.layer.parent;
        }
        let (_, stroke) = layer
            .vectors
            .iter()
            .find(|(candidate_id, _)| *candidate_id == stroke_id)
            .ok_or_else(|| {
                EngineError::InvalidCommand(
                    "selected object is not an editable legacy vector stroke".into(),
                )
            })?;
        if !layer.vector_order.contains(&stroke_id) {
            return Err(EngineError::InvalidCommand(
                "vector order is inconsistent".into(),
            ));
        }
        Ok((state.revision, stroke.clone()))
    }

    /// Capture the exact sampled source of a converted path for one-step
    /// restoration. The revision is checked again by the applying command.
    pub fn vector_source_for_restore(
        &self,
        layer_id: LayerId,
        object_id: ink_model::StrokeId,
    ) -> Result<(u64, VectorStroke), EngineError> {
        self.flush_input()?;
        let state = lock_recover(&self.state);
        let layer = state
            .layers
            .get(&layer_id)
            .ok_or(EngineError::InvalidLayer)?;
        if layer.layer.kind != LayerKind::VectorInk {
            return Err(EngineError::InvalidCommand(
                "vector restoration requires a vector-ink layer".into(),
            ));
        }
        let mut ancestor = Some(layer_id);
        while let Some(id) = ancestor {
            let current = state.layers.get(&id).ok_or(EngineError::InvalidLayer)?;
            if !current.layer.visible || current.layer.locked {
                return Err(EngineError::InvalidCommand(
                    "vector restoration target is hidden or locked".into(),
                ));
            }
            ancestor = current.layer.parent;
        }
        let (_, _, archive) = layer
            .bezier_paths
            .iter()
            .find(|(id, _, _)| *id == object_id)
            .ok_or_else(|| EngineError::InvalidCommand("editable path does not exist".into()))?;
        let source = archive.as_ref().ok_or_else(|| {
            EngineError::InvalidCommand("this path has no recoverable original ink".into())
        })?;
        Ok((state.revision, source.legacy.clone()))
    }

    /// Capture one editable path and its archive for off-lock path-edit
    /// candidate work.
    pub fn vector_path_for_candidate(
        &self,
        layer_id: LayerId,
        object_id: ink_model::StrokeId,
    ) -> Result<
        (
            u64,
            ink_model::BezierPath,
            Option<ink_model::VectorSourceArchive>,
        ),
        EngineError,
    > {
        self.flush_input()?;
        let state = lock_recover(&self.state);
        let layer = state
            .layers
            .get(&layer_id)
            .ok_or(EngineError::InvalidLayer)?;
        if layer.layer.kind != LayerKind::VectorInk {
            return Err(EngineError::InvalidCommand(
                "path editing requires a vector-ink layer".into(),
            ));
        }
        let mut ancestor = Some(layer_id);
        while let Some(id) = ancestor {
            let current = state.layers.get(&id).ok_or(EngineError::InvalidLayer)?;
            if !current.layer.visible || current.layer.locked {
                return Err(EngineError::InvalidCommand(
                    "path edit target is hidden or locked".into(),
                ));
            }
            ancestor = current.layer.parent;
        }
        let (_, path, source) = layer
            .bezier_paths
            .iter()
            .find(|(id, _, _)| *id == object_id)
            .ok_or_else(|| EngineError::InvalidCommand("editable path does not exist".into()))?;
        Ok((state.revision, path.clone(), source.clone()))
    }

    /// Capture an editable path and allocate collision-free IDs for one
    /// bounded repeat operation. Geometry work happens after this lock drops;
    /// callers must apply the resulting patch against the returned revision.
    pub fn vector_path_for_repeat(
        &self,
        layer_id: LayerId,
        object_id: ink_model::StrokeId,
        copy_count: usize,
    ) -> Result<(u64, ink_model::BezierPath, u32, Vec<ink_model::StrokeId>), EngineError> {
        if copy_count == 0 || copy_count > ink_vector::MAX_REPEAT_OBJECTS {
            return Err(EngineError::InvalidCommand(
                "vector repeat count is outside the supported range".into(),
            ));
        }
        self.flush_input()?;
        let state = lock_recover(&self.state);
        let layer = state
            .layers
            .get(&layer_id)
            .ok_or(EngineError::InvalidLayer)?;
        if layer.layer.kind != LayerKind::VectorInk {
            return Err(EngineError::InvalidCommand(
                "vector repeat requires a vector-ink layer".into(),
            ));
        }
        let mut ancestor = Some(layer_id);
        while let Some(id) = ancestor {
            let current = state.layers.get(&id).ok_or(EngineError::InvalidLayer)?;
            if !current.layer.visible || current.layer.locked {
                return Err(EngineError::InvalidCommand(
                    "vector repeat target is hidden or locked".into(),
                ));
            }
            ancestor = current.layer.parent;
        }
        let (_, path, _) = layer
            .bezier_paths
            .iter()
            .find(|(id, _, _)| *id == object_id)
            .ok_or_else(|| {
                EngineError::InvalidCommand("vector repeat requires a Bézier path".into())
            })?;
        let position = layer
            .vector_order
            .iter()
            .position(|id| *id == object_id)
            .ok_or_else(|| EngineError::InvalidCommand("vector order is inconsistent".into()))?;
        let position = u32::try_from(position.saturating_add(1)).map_err(|_| {
            EngineError::InvalidCommand("vector order exceeds the supported range".into())
        })?;
        let mut used = std::collections::HashSet::new();
        used.try_reserve(layer.vector_order.len().saturating_add(copy_count))
            .map_err(|_| EngineError::InvalidCommand("vector repeat IDs exceed memory".into()))?;
        used.extend(layer.vector_order.iter().map(|id| id.0));
        let mut next = layer
            .vector_order
            .iter()
            .map(|id| id.0)
            .max()
            .and_then(|id| id.checked_add(1))
            .unwrap_or(1);
        let mut ids = Vec::new();
        ids.try_reserve_exact(copy_count)
            .map_err(|_| EngineError::InvalidCommand("vector repeat IDs exceed memory".into()))?;
        let attempts = layer.vector_order.len().saturating_add(copy_count);
        for _ in 0..attempts {
            if ids.len() == copy_count {
                break;
            }
            if used.insert(next) {
                ids.push(ink_model::StrokeId::from_u128(next));
            }
            next = next.checked_add(1).unwrap_or(1);
        }
        if ids.len() != copy_count {
            return Err(EngineError::InvalidCommand(
                "unable to allocate vector repeat object IDs".into(),
            ));
        }
        Ok((state.revision, path.clone(), position, ids))
    }

    /// Consume a high-frequency packet and rasterize confirmed samples.
    pub fn push_pointer_packet(&mut self, bytes: &[u8]) -> Result<(), EngineError> {
        if bytes.len() > ink_input::MAX_PACKET_BYTES {
            return Err(EngineError::Packet(ink_input::PacketError::TrailingBytes));
        }
        self.worker.enqueue(bytes.to_vec())?;
        Ok(())
    }

    /// Drain Rust-generated ephemeral dabs for a live preview surface. The
    /// queue is not persisted and draining it cannot change document truth.
    pub fn drain_live_dabs(
        &mut self,
        limit: usize,
    ) -> Result<Vec<ink_live_render::LiveDab>, EngineError> {
        self.flush_input()?;
        self.drain_live_dabs_available(limit)
    }

    /// Drain dabs produced so far without waiting for CPU tile rasterization.
    /// The queue has its own lock so GPU presentation never contends with the
    /// document-state lock held by the authoritative renderer.
    pub fn drain_live_dabs_available(
        &self,
        limit: usize,
    ) -> Result<Vec<ink_live_render::LiveDab>, EngineError> {
        if limit > 65_536 {
            return Err(EngineError::InvalidCommand(
                "live dab drain exceeds the safety limit".into(),
            ));
        }
        Ok(lock_recover(&self.live_dabs).drain(limit))
    }

    /// Return and clear the number of confirmed live-preview dabs that could
    /// not be queued since the previous poll. This is a preview-health signal;
    /// it never indicates document loss because CPU rasterization has already
    /// committed the corresponding samples.
    pub fn take_live_dab_overflow_count(&mut self) -> Result<u64, EngineError> {
        self.flush_input()?;
        Ok(self.take_live_dab_overflow_count_available())
    }

    /// Read a best-effort preview health signal without waiting for the CPU
    /// renderer or acquiring the document-state lock.
    pub fn take_live_dab_overflow_count_available(&self) -> u64 {
        self.live_dab_overflow_count.swap(0, Ordering::AcqRel)
    }

    pub(super) fn flush_input(&self) -> Result<(), EngineError> {
        self.worker.flush();
        if let Some(error) = self.worker.take_error() {
            return Err(EngineError::InvalidCommand(error));
        }
        Ok(())
    }
}

fn apply_brush_draft_to_preset(
    preset: &mut BrushPresetV2,
    settings: &BrushDraftSettings,
    update_shared_curve: bool,
) -> Result<(), EngineError> {
    validate_brush_draft_settings(settings)?;
    preset.stroke.spacing = settings.spacing;
    preset.stroke.smoothing = settings.smoothing;
    preset
        .set_path_stabilizer(
            settings.pulled_string,
            settings.stabilizer_distance_px,
            settings.catch_up_on_end,
        )
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    preset.engine_semantics = EngineSemantics(CPU_BRUSH_V4);
    let pressure_curve = ResponseCurve {
        points: decode_editor_curve(&settings.pressure_curve_points, settings.pressure_curve)?,
    };
    let size_binding_count = preset
        .dynamics
        .iter()
        .filter(|binding| {
            binding.sensor == SensorId::Pressure && binding.target == ParameterId::Diameter
        })
        .count();
    let opacity_binding_count = preset
        .dynamics
        .iter()
        .filter(|binding| {
            binding.sensor == SensorId::Pressure && binding.target == ParameterId::Opacity
        })
        .count();
    for binding in &mut preset.dynamics {
        if binding.sensor == SensorId::Pressure {
            if binding.target == ParameterId::Diameter
                && (update_shared_curve || size_binding_count == 1)
            {
                binding.amount = settings.pressure_size;
            }
            if binding.target == ParameterId::Opacity
                && (update_shared_curve || opacity_binding_count == 1)
            {
                binding.amount = settings.pressure_opacity;
            }
            if update_shared_curve {
                binding.curve = pressure_curve.clone();
            }
        }
    }
    if update_shared_curve
        && !preset.dynamics.iter().any(|binding| {
            binding.sensor == SensorId::Pressure && binding.target == ParameterId::Diameter
        })
    {
        preset.dynamics.push(ParameterBinding {
            target: ParameterId::Diameter,
            base: 1.0,
            sensor: SensorId::Pressure,
            curve: pressure_curve.clone(),
            amount: settings.pressure_size,
            combine: CombineOp::Multiply,
        });
    }
    if update_shared_curve
        && !preset.dynamics.iter().any(|binding| {
            binding.sensor == SensorId::Pressure && binding.target == ParameterId::Opacity
        })
    {
        preset.dynamics.push(ParameterBinding {
            target: ParameterId::Opacity,
            base: 1.0,
            sensor: SensorId::Pressure,
            curve: pressure_curve,
            amount: settings.pressure_opacity,
            combine: CombineOp::Multiply,
        });
    }
    apply_brush_tip_settings(&mut preset.tip, settings);
    apply_brush_paint_settings(&mut preset.paint, settings);
    if let Some(grain) = &mut preset.grain {
        grain.scale = settings.texture_scale;
        grain.depth = settings.scatter;
    }
    preset
        .validate()
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))
}

fn pressure_parameter(target: super::BrushPressureTarget) -> ParameterId {
    match target {
        super::BrushPressureTarget::Size => ParameterId::Diameter,
        super::BrushPressureTarget::Opacity => ParameterId::Opacity,
        super::BrushPressureTarget::Flow => ParameterId::Flow,
    }
}

fn apply_pressure_response_drafts(
    preset: &mut BrushPresetV2,
    drafts: &[BrushPressureDraftResponse],
) -> Result<(), EngineError> {
    for draft in drafts {
        if !draft.amount.is_finite() || !(0.0..=1.0).contains(&draft.amount) {
            return Err(EngineError::InvalidCommand(
                "pressure response amount must be finite and normalized".into(),
            ));
        }
        let parameter = pressure_parameter(draft.target);
        let indices: Vec<_> = preset
            .dynamics
            .iter()
            .enumerate()
            .filter(|(_, binding)| {
                binding.sensor == SensorId::Pressure && binding.target == parameter
            })
            .map(|(index, _)| index)
            .collect();
        if indices.len() > 1 {
            return Err(EngineError::InvalidCommand(
                "pressure response has multiple bindings and cannot be edited in the simple editor"
                    .into(),
            ));
        }
        let curve = ResponseCurve {
            points: decode_editor_curve(&draft.curve_points, 0.5)?,
        };
        if let Some(index) = indices.first() {
            let binding = &mut preset.dynamics[*index];
            binding.curve = curve;
            binding.amount = if draft.enabled { draft.amount } else { 0.0 };
        } else {
            preset.dynamics.push(ParameterBinding {
                target: parameter,
                base: 1.0,
                sensor: SensorId::Pressure,
                curve,
                amount: if draft.enabled { draft.amount } else { 0.0 },
                combine: CombineOp::Multiply,
            });
        }
    }
    Ok(())
}

fn apply_brush_tip_settings(tip: &mut TipBehavior, settings: &BrushDraftSettings) {
    match tip {
        TipBehavior::Stamp(tip) => {
            tip.diameter_px = settings.diameter_px;
            tip.editor_scatter = settings.scatter;
            tip.density = (tip.density * (1.0 - settings.scatter * 0.5)).clamp(0.01, 1.0);
            tip.angle_degrees = settings.rotation_jitter * 180.0;
        }
        TipBehavior::Spray(tip) => {
            tip.diameter_px = settings.diameter_px;
            tip.scatter = settings.scatter;
        }
        TipBehavior::Ribbon(tip) => tip.width_px = settings.diameter_px,
        TipBehavior::Bristle(tip) => {
            tip.diameter_px = settings.diameter_px;
            tip.spread = (tip.spread + settings.scatter * 0.25).clamp(0.0, 1.0);
            tip.lag = (tip.lag + settings.smoothing * 0.25).clamp(0.0, 1.0);
        }
    }
    match tip {
        TipBehavior::Stamp(tip) => tip.hardness = settings.hardness,
        TipBehavior::Spray(tip) => tip.hardness = settings.hardness,
        TipBehavior::Ribbon(_) => {}
        TipBehavior::Bristle(tip) => tip.stiffness = settings.hardness,
    }
}

fn apply_brush_paint_settings(paint: &mut PaintBehavior, settings: &BrushDraftSettings) {
    match paint {
        PaintBehavior::Solid(paint) => {
            paint.opacity = settings.opacity;
            paint.flow = (1.0 - settings.wetness * 0.5).clamp(0.01, 1.0);
        }
        PaintBehavior::Glaze(paint) => {
            paint.opacity = settings.opacity;
            paint.flow = (1.0 - settings.wetness * 0.5).clamp(0.01, 1.0);
        }
        PaintBehavior::Marker(paint) => {
            paint.opacity = settings.opacity;
            paint.flow = (1.0 - settings.wetness * 0.5).clamp(0.01, 1.0);
        }
        PaintBehavior::ColorPickup(paint) => {
            paint.opacity = settings.opacity;
            paint.pickup = settings.smudge;
            paint.blur = (settings.smudge * 0.5).clamp(0.0, 1.0);
        }
        PaintBehavior::DigitalWatercolor(paint) => {
            paint.wash = settings.opacity;
            paint.dilution = settings.wetness;
            paint.pickup = settings.smudge;
            paint.granulation = ((settings.texture_scale - 0.01) / 63.99).clamp(0.0, 1.0);
        }
    }
}

pub(crate) fn set_brush_paint_color(paint: &mut PaintBehavior, color: ink_model::Rgba8) {
    match paint {
        PaintBehavior::Solid(value) => value.color = color,
        PaintBehavior::Glaze(value) => value.color = color,
        PaintBehavior::Marker(value) => value.color = color,
        PaintBehavior::ColorPickup(value) => value.color = color,
        PaintBehavior::DigitalWatercolor(value) => value.color = color,
    }
}

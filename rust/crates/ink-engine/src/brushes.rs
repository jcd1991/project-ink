use super::{
    BrushDraftSettings, BrushEditUndo, BrushId, BrushPresetV2, BrushPreviewPoint, BrushResource,
    BrushSummaryProjection, CombineOp, Document, EngineError, EngineEvent, LayerId, LayerKind,
    MAX_DOCUMENT_RESOURCE_BYTES, PaintBehavior, ParameterBinding, ParameterId, ResponseCurve,
    Rgba8, SensorId, TipBehavior, VectorStrokeSummaryTuple, advance_revision,
    brush_summary_projection, builtin_library, decode_editor_curve, hex_hash, lock_recover,
    next_available_brush_id, render_brush_dabs, resource_hashes_for_preset, resource_total_bytes,
    validate_brush_draft_settings,
};
use ink_input::{DeviceKind, Phase, PointerSample, flags};
use std::collections::{BTreeMap, HashSet};
use std::sync::atomic::Ordering;

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

impl Document {
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
            apply_brush_draft_to_preset(&mut preset, &settings)?;
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
                    pressure_curve_points: Vec::new(),
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
            pressure_curve_points: pressure_curve_points.to_vec(),
        };
        validate_brush_draft_settings(&settings)?;
        self.flush_input()?;
        let mut state = lock_recover(&self.state);
        let Some((_, draft)) = state.brush_drafts.get_mut(&draft_id) else {
            return Err(EngineError::InvalidCommand(
                "brush draft is not active".into(),
            ));
        };
        *draft = settings;
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
        let result = self.update_brush_settings(
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
            pressure_curve_points: pressure_curve_points.to_vec(),
        };
        apply_brush_draft_to_preset(&mut preset, &settings)?;
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
) -> Result<(), EngineError> {
    validate_brush_draft_settings(settings)?;
    preset.stroke.spacing = settings.spacing;
    preset.stroke.smoothing = settings.smoothing;
    let pressure_curve = ResponseCurve {
        points: decode_editor_curve(&settings.pressure_curve_points, settings.pressure_curve)?,
    };
    for binding in &mut preset.dynamics {
        if binding.sensor == SensorId::Pressure {
            if binding.target == ParameterId::Diameter {
                binding.amount = settings.pressure_size;
            }
            if binding.target == ParameterId::Opacity {
                binding.amount = settings.pressure_opacity;
            }
            binding.curve = pressure_curve.clone();
        }
    }
    if !preset.dynamics.iter().any(|binding| {
        binding.sensor == SensorId::Pressure && binding.target == ParameterId::Diameter
    }) {
        preset.dynamics.push(ParameterBinding {
            target: ParameterId::Diameter,
            base: 1.0,
            sensor: SensorId::Pressure,
            curve: pressure_curve.clone(),
            amount: settings.pressure_size,
            combine: CombineOp::Multiply,
        });
    }
    if !preset.dynamics.iter().any(|binding| {
        binding.sensor == SensorId::Pressure && binding.target == ParameterId::Opacity
    }) {
        preset.dynamics.push(ParameterBinding {
            target: ParameterId::Opacity,
            base: 1.0,
            sensor: SensorId::Pressure,
            curve: pressure_curve,
            amount: settings.pressure_opacity,
            combine: CombineOp::Multiply,
        });
    }
    match &mut preset.tip {
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
    match &mut preset.tip {
        TipBehavior::Stamp(tip) => tip.hardness = settings.hardness,
        TipBehavior::Spray(tip) => tip.hardness = settings.hardness,
        TipBehavior::Ribbon(_) => {}
        TipBehavior::Bristle(tip) => tip.stiffness = settings.hardness,
    }
    match &mut preset.paint {
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
    if let Some(grain) = &mut preset.grain {
        grain.scale = settings.texture_scale;
        grain.depth = settings.scatter;
    }
    preset
        .validate()
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))
}

fn set_brush_paint_color(paint: &mut PaintBehavior, color: ink_model::Rgba8) {
    match paint {
        PaintBehavior::Solid(value) => value.color = color,
        PaintBehavior::Glaze(value) => value.color = color,
        PaintBehavior::Marker(value) => value.color = color,
        PaintBehavior::ColorPickup(value) => value.color = color,
        PaintBehavior::DigitalWatercolor(value) => value.color = color,
    }
}

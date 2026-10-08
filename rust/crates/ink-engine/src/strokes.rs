use super::{
    ActiveStroke, BTreeMap, BrushPreset, BrushResource, Dab, EngineError, EngineEvent, EngineState,
    MAX_STROKE_INPUT_SEGMENT_SAMPLES, PointerPacket, SelectionMask, StrokeRenderMetrics,
    TileBounds, TileDescriptor, advance_revision, flags, legacy_dab_opacity, legacy_dab_radius,
    mask_preview_to_alpha, queue_live_dab, render_brush_dabs, render_dabs, resample_from,
};
use ink_brush::BrushDab;
use ink_model::{LayerKind, Rgba8};
use ink_raster::{TILE_SIZE, TileCoord, TileStore};

#[derive(Clone, Copy)]
pub(super) struct MaskDabInput<'a> {
    pub(super) preset: BrushPreset,
    pub(super) compiled_dabs: Option<&'a [BrushDab]>,
    pub(super) legacy_dabs: &'a [Dab],
    pub(super) resources: &'a BTreeMap<[u8; 32], BrushResource>,
    pub(super) selection: Option<&'a SelectionMask>,
    pub(super) eraser: bool,
    pub(super) width_px: u32,
    pub(super) height_px: u32,
}

pub(super) fn render_mask_dabs(mask: &mut TileStore, input: MaskDabInput<'_>) -> Vec<TileCoord> {
    let MaskDabInput {
        preset,
        compiled_dabs,
        legacy_dabs,
        resources,
        selection,
        eraser,
        width_px,
        height_px,
    } = input;
    let color = compiled_dabs
        .and_then(|dabs| dabs.first().map(|dab| dab.color))
        .unwrap_or(preset.color);
    let target_hidden = if eraser {
        u8::MAX
    } else {
        let luminance =
            (u32::from(color.r) * 54 + u32::from(color.g) * 183 + u32::from(color.b) * 19 + 128)
                / 256;
        u8::MAX - u8::try_from(luminance).unwrap_or(u8::MAX)
    };
    let color_opacity = if eraser { u8::MAX } else { color.a };
    let white = Rgba8 {
        r: 255,
        g: 255,
        b: 255,
        a: 255,
    };
    let mut stamps = TileStore::default();
    let dirty = if let Some(dabs) = compiled_dabs {
        let mut stamps_for_brush = dabs.to_vec();
        for dab in &mut stamps_for_brush {
            dab.color = white;
        }
        render_brush_dabs(
            &mut stamps,
            &stamps_for_brush,
            resources,
            selection,
            false,
            false,
            false,
            width_px,
            height_px,
        )
    } else {
        let mut white_preset = preset;
        white_preset.color = white;
        render_dabs(
            &mut stamps,
            legacy_dabs,
            white_preset,
            selection,
            false,
            false,
            false,
            width_px,
            height_px,
        )
    };
    for coordinate in &dirty {
        let stamp = stamps.read(*coordinate);
        let stamp_bytes = stamp.bytes();
        let origin_x = i64::from(coordinate.x) * i64::from(TILE_SIZE);
        let origin_y = i64::from(coordinate.y) * i64::from(TILE_SIZE);
        for index in 0..(TILE_SIZE * TILE_SIZE) as usize {
            let coverage = ((u16::from(stamp_bytes[index * 4 + 3]) * u16::from(color_opacity)
                + 127)
                / 255) as u8;
            if coverage == 0 {
                continue;
            }
            let x = origin_x + i64::try_from(index % TILE_SIZE as usize).unwrap_or(i64::MAX);
            let y = origin_y + i64::try_from(index / TILE_SIZE as usize).unwrap_or(i64::MAX);
            if x < 0 || y < 0 || x >= i64::from(width_px) || y >= i64::from(height_px) {
                continue;
            }
            let x = u32::try_from(x).unwrap_or(u32::MAX);
            let y = u32::try_from(y).unwrap_or(u32::MAX);
            let old_hidden = mask.sample_pixel(x, y).a;
            let next_hidden = ((u32::from(old_hidden) * (255 - u32::from(coverage))
                + u32::from(target_hidden) * u32::from(coverage)
                + 127)
                / 255) as u8;
            mask.set_pixel(
                x,
                y,
                Rgba8 {
                    r: 0,
                    g: 0,
                    b: 0,
                    a: next_hidden,
                },
            );
        }
    }
    dirty
}

pub(super) fn same_brush_sample(a: ink_input::PointerSample, b: ink_input::PointerSample) -> bool {
    a.pointer_id == b.pointer_id
        && a.flags == b.flags
        && a.device_kind == b.device_kind
        && a.canvas_x.to_bits() == b.canvas_x.to_bits()
        && a.canvas_y.to_bits() == b.canvas_y.to_bits()
        && a.pressure == b.pressure
        && a.tilt_x.to_bits() == b.tilt_x.to_bits()
        && a.tilt_y.to_bits() == b.tilt_y.to_bits()
        && a.azimuth.to_bits() == b.azimuth.to_bits()
        && a.twist.to_bits() == b.twist.to_bits()
}

pub(super) fn interpolate_pointer_sample(
    start: ink_input::PointerSample,
    end: ink_input::PointerSample,
    t: f32,
) -> ink_input::PointerSample {
    let lerp = |a: f32, b: f32| a + (b - a) * t;
    let timestamp_delta = end.timestamp_ns.saturating_sub(start.timestamp_ns);
    ink_input::PointerSample {
        pointer_id: end.pointer_id,
        flags: end.flags,
        device_kind: end.device_kind,
        phase: end.phase,
        canvas_x: lerp(start.canvas_x, end.canvas_x),
        canvas_y: lerp(start.canvas_y, end.canvas_y),
        pressure: lerp(f32::from(start.pressure), f32::from(end.pressure)).round() as u16,
        tilt_x: lerp(start.tilt_x, end.tilt_x),
        tilt_y: lerp(start.tilt_y, end.tilt_y),
        azimuth: lerp(start.azimuth, end.azimuth),
        twist: lerp(start.twist, end.twist),
        timestamp_ns: start
            .timestamp_ns
            .saturating_add((timestamp_delta as f64 * f64::from(t)) as u64),
        sequence: end.sequence,
    }
}

/// Clip one raw pointer segment to the document rectangle. Off-canvas motion
/// must not be converted into a stroke along the document border.
pub(super) fn clip_pointer_segment(
    start: Option<ink_input::PointerSample>,
    end: ink_input::PointerSample,
    max_x: f32,
    max_y: f32,
) -> Vec<ink_input::PointerSample> {
    let Some(start) = start else {
        return (end.canvas_x >= 0.0
            && end.canvas_x <= max_x
            && end.canvas_y >= 0.0
            && end.canvas_y <= max_y)
            .then_some(end)
            .into_iter()
            .collect();
    };
    let dx = end.canvas_x - start.canvas_x;
    let dy = end.canvas_y - start.canvas_y;
    let mut t0 = 0.0_f32;
    let mut t1 = 1.0_f32;
    for (p, q) in [
        (-dx, start.canvas_x),
        (dx, max_x - start.canvas_x),
        (-dy, start.canvas_y),
        (dy, max_y - start.canvas_y),
    ] {
        if p == 0.0 {
            if q < 0.0 {
                return Vec::new();
            }
            continue;
        }
        let ratio = q / p;
        if p < 0.0 {
            t0 = t0.max(ratio);
        } else {
            t1 = t1.min(ratio);
        }
        if t0 > t1 {
            return Vec::new();
        }
    }
    let clipped_start = interpolate_pointer_sample(start, end, t0);
    let clipped_end = if t1 >= 1.0 {
        end
    } else {
        interpolate_pointer_sample(start, end, t1)
    };
    // The previous in-canvas endpoint has already been accepted by the
    // preceding sample/packet. Returning it again for every ordinary segment
    // doubled confirmed sample work; source flags can differ between actual
    // and coalesced samples, so the later stationary-sample compactor cannot
    // reliably remove these duplicates. Only synthesize a new start point
    // when this segment enters the document from outside.
    if t0 <= f32::EPSILON {
        return vec![clipped_end];
    }
    if (clipped_end.canvas_x - clipped_start.canvas_x).abs() < f32::EPSILON
        && (clipped_end.canvas_y - clipped_start.canvas_y).abs() < f32::EPSILON
    {
        vec![clipped_end]
    } else {
        vec![clipped_start, clipped_end]
    }
}

pub(super) fn sample_inside_document(
    sample: ink_input::PointerSample,
    max_x: f32,
    max_y: f32,
) -> bool {
    sample.canvas_x >= 0.0
        && sample.canvas_x <= max_x
        && sample.canvas_y >= 0.0
        && sample.canvas_y <= max_y
}

pub(super) fn compact_stationary_samples(
    previous: Option<ink_input::PointerSample>,
    incoming: Vec<ink_input::PointerSample>,
    stationary_rate_hz: f32,
) -> Vec<ink_input::PointerSample> {
    let mut compacted = Vec::with_capacity(incoming.len());
    let mut last = previous;
    for sample in incoming {
        let stationary_dab_due = stationary_rate_hz > 0.0
            && last.is_some_and(|previous| {
                let interval_ns = (1_000_000_000.0 / stationary_rate_hz).ceil() as u64;
                sample.timestamp_ns.saturating_sub(previous.timestamp_ns) >= interval_ns
            });
        let is_terminal = matches!(
            sample.phase,
            ink_input::Phase::Up | ink_input::Phase::Cancel
        );
        if !is_terminal
            && last.is_some_and(|previous| same_brush_sample(previous, sample))
            && !stationary_dab_due
        {
            continue;
        }
        compacted.push(sample);
        last = Some(sample);
    }
    compacted
}

pub(super) fn consume_packet(
    state: &mut EngineState,
    packet: PointerPacket,
) -> Result<(), EngineError> {
    consume_packet_with_sample_limit(state, packet, MAX_STROKE_INPUT_SEGMENT_SAMPLES)
}

pub(super) fn record_confirmed_stroke_samples(
    active: &mut ActiveStroke,
    samples: &[ink_input::PointerSample],
    segment_limit: usize,
) {
    let segment_limit = segment_limit.max(1);
    for sample in samples.iter().copied() {
        if active.samples.len() >= segment_limit {
            active.samples.clear();
            active.sample_history_complete = false;
            active.work_segments = active.work_segments.saturating_add(1);
            eprintln!(
                "Project Ink stroke input segment rollover: stroke={} segment={} reason=confirmed_sample_limit",
                active.stroke.0, active.work_segments,
            );
        }
        let pressure = f32::from(sample.pressure) / f32::from(u16::MAX);
        let metrics = &mut active.input_metrics;
        if let Some(previous) = metrics.path_end {
            let dx = f64::from(sample.canvas_x - previous.canvas_x);
            let dy = f64::from(sample.canvas_y - previous.canvas_y);
            metrics.path_length += dx.hypot(dy);
        } else {
            metrics.path_start = Some(sample);
        }
        metrics.path_end = Some(sample);
        metrics.sample_count = metrics.sample_count.saturating_add(1);
        metrics.bounds = Some(match metrics.bounds {
            Some((min_x, min_y, max_x, max_y)) => (
                min_x.min(sample.canvas_x),
                min_y.min(sample.canvas_y),
                max_x.max(sample.canvas_x),
                max_y.max(sample.canvas_y),
            ),
            None => (
                sample.canvas_x,
                sample.canvas_y,
                sample.canvas_x,
                sample.canvas_y,
            ),
        });
        metrics.pressure_range = Some(match metrics.pressure_range {
            Some((minimum, maximum)) => (minimum.min(pressure), maximum.max(pressure)),
            None => (pressure, pressure),
        });
        active.samples.push(sample);
        active.last_confirmed_sample = Some(sample);
    }
}

pub(super) fn stroke_render_metrics(active: &ActiveStroke) -> StrokeRenderMetrics {
    let direct_length = active
        .input_metrics
        .path_start
        .zip(active.input_metrics.path_end)
        .map_or(0.0, |(start, end)| {
            f64::from(end.canvas_x - start.canvas_x).hypot(f64::from(end.canvas_y - start.canvas_y))
        });
    StrokeRenderMetrics {
        confirmed_sample_count: u64::try_from(active.input_metrics.sample_count)
            .unwrap_or(u64::MAX),
        path_length: active.input_metrics.path_length,
        direct_length,
        legacy_dabs: u64::try_from(active.legacy_rendered_dabs).unwrap_or(u64::MAX),
        compiled_dabs: u64::try_from(active.compiled_rendered_dabs).unwrap_or(u64::MAX),
        cpu_tiles_written: u64::try_from(active.cpu_tile_updates).unwrap_or(u64::MAX),
        compiled_cpu_tile_updates: u64::try_from(active.compiled_cpu_tile_updates)
            .unwrap_or(u64::MAX),
        work_segments: active.work_segments,
        work_limit_reached: active.work_limit_reached,
    }
}

/// Evaluate a confirmed batch transactionally in bounded segments. If a
/// packet is too expensive for one brush work segment, subdivide it while
/// preserving the evaluator's spacing and smoothing state. The returned
/// sample count is the confirmed prefix actually accepted; the caller must
/// commit that prefix and report a work-limit failure for any remainder.
pub(super) fn render_compiled_confirmed_bounded(
    brush: &ink_brush::CompiledBrush,
    samples: &[ink_input::PointerSample],
    state: &mut ink_brush::CompiledBrushState,
) -> Result<(Vec<ink_brush::BrushDab>, usize, bool), ink_brush::BrushValidationError> {
    fn render_slice(
        brush: &ink_brush::CompiledBrush,
        samples: &[ink_input::PointerSample],
        state: &mut ink_brush::CompiledBrushState,
    ) -> Result<(Vec<ink_brush::BrushDab>, usize, bool), ink_brush::BrushValidationError> {
        match brush.render_incremental(samples, state) {
            Ok(dabs) => return Ok((dabs, samples.len(), false)),
            Err(ink_brush::BrushValidationError::WorkLimitExceeded) => {}
            Err(error) => return Err(error),
        }

        if state.begin_work_segment() {
            match brush.render_incremental(samples, state) {
                Ok(dabs) => return Ok((dabs, samples.len(), false)),
                Err(ink_brush::BrushValidationError::WorkLimitExceeded) => {}
                Err(error) => return Err(error),
            }
        }

        if samples.len() <= 1 {
            return Ok((Vec::new(), 0, true));
        }

        let split = samples.len() / 2;
        let (mut first_dabs, first_count, first_limited) =
            render_slice(brush, &samples[..split], state)?;
        if first_limited {
            return Ok((first_dabs, first_count, true));
        }
        let (second_dabs, second_count, second_limited) =
            render_slice(brush, &samples[split..], state)?;
        first_dabs.extend(second_dabs);
        Ok((first_dabs, first_count + second_count, second_limited))
    }

    render_slice(brush, samples, state)
}

pub(super) fn resample_legacy_confirmed_bounded(
    samples: &[ink_input::PointerSample],
    preset: BrushPreset,
    anchor: Option<ink_brush::Dab>,
) -> Result<(Vec<ink_brush::Dab>, Option<ink_brush::Dab>, usize, bool), ink_brush::BrushError> {
    match ink_brush::resample_from(samples, preset, anchor) {
        Ok((dabs, next_anchor)) => return Ok((dabs, next_anchor, samples.len(), false)),
        Err(ink_brush::BrushError::TooManyDabs) => {}
    }

    if samples.len() <= 1 {
        return Ok((Vec::new(), anchor, 0, true));
    }

    let split = samples.len() / 2;
    let (mut first_dabs, first_anchor, first_count, first_limited) =
        resample_legacy_confirmed_bounded(&samples[..split], preset, anchor)?;
    if first_limited {
        return Ok((first_dabs, first_anchor, first_count, true));
    }
    let (second_dabs, second_anchor, second_count, second_limited) =
        resample_legacy_confirmed_bounded(&samples[split..], preset, first_anchor)?;
    first_dabs.extend(second_dabs);
    Ok((
        first_dabs,
        second_anchor,
        first_count + second_count,
        second_limited,
    ))
}

#[allow(clippy::too_many_lines)]
pub(super) fn consume_packet_with_sample_limit(
    state: &mut EngineState,
    packet: PointerPacket,
    sample_limit: usize,
) -> Result<(), EngineError> {
    if state.active_stroke.is_none() {
        return Ok(());
    }
    if state
        .active_stroke
        .as_ref()
        .is_some_and(|active| active.work_limit_reached)
    {
        return Err(EngineError::InvalidCommand(
            "stroke_work_limit_reached: confirmed input could not be continued safely".into(),
        ));
    }
    // A single native packet may contain coalesced samples from both sides of
    // a page exit and re-entry. Consume the pre-gap segment first so resetting
    // the brush path below cannot accidentally join samples from both sides.
    let max_x = state.width_px.saturating_sub(1) as f32;
    let max_y = state.height_px.saturating_sub(1) as f32;
    let mut raw_previous = state
        .active_stroke
        .as_ref()
        .and_then(|active| active.last_input_sample);
    let mut outside_after_exit = state
        .active_stroke
        .as_ref()
        .is_some_and(|active| active.stopped_at_page_edge);
    let mut reentry_indices = Vec::new();
    for (index, sample) in packet.samples.iter().enumerate() {
        if sample.flags & (flags::HOVER | flags::PALM_REJECTED | flags::PREDICTED) != 0 {
            continue;
        }
        let inside = sample_inside_document(*sample, max_x, max_y);
        if outside_after_exit && inside {
            if index > 0 {
                reentry_indices.push(index);
            }
            outside_after_exit = false;
        }
        if raw_previous
            .is_some_and(|previous| sample_inside_document(previous, max_x, max_y) && !inside)
        {
            outside_after_exit = true;
        }
        raw_previous = Some(*sample);
    }
    if !reentry_indices.is_empty() {
        let mut start = 0;
        for end in reentry_indices.into_iter().chain([packet.samples.len()]) {
            if start < end {
                consume_packet_with_sample_limit(
                    state,
                    PointerPacket {
                        samples: packet.samples[start..end].to_vec(),
                    },
                    sample_limit,
                )?;
            }
            start = end;
        }
        return Ok(());
    }
    let stroke_id = state
        .active_stroke
        .as_ref()
        .map(|active| active.stroke)
        .ok_or_else(|| EngineError::InvalidCommand("stroke is not active".into()))?;
    let mut confirmed = Vec::new();
    let mut predicted = Vec::new();
    let mut raw_previous = state
        .active_stroke
        .as_ref()
        .and_then(|active| active.last_input_sample);
    let mut outside_after_exit = state
        .active_stroke
        .as_ref()
        .is_some_and(|active| active.stopped_at_page_edge);
    for sample in packet.samples {
        if sample.flags & (flags::HOVER | flags::PALM_REJECTED) != 0 {
            continue;
        }
        if sample.flags & flags::PREDICTED != 0 {
            // Predictions are disposable and are replaced by confirmed
            // samples; keep them bounded for the ephemeral preview path.
            let stopped_at_page_edge = state
                .active_stroke
                .as_ref()
                .is_some_and(|active| active.stopped_at_page_edge);
            if !stopped_at_page_edge {
                let mut bounded = sample;
                bounded.canvas_x = bounded.canvas_x.clamp(0.0, max_x);
                bounded.canvas_y = bounded.canvas_y.clamp(0.0, max_y);
                predicted.push(bounded);
            }
        } else {
            let sample_inside = sample_inside_document(sample, max_x, max_y);
            if outside_after_exit && sample_inside {
                // Start a fresh brush path at the re-entry boundary. The
                // stroke remains one undo transaction, but no dab interpolation
                // bridges the part of the pointer path outside the page.
                if let Some(active) = state.active_stroke.as_mut() {
                    active.stopped_at_page_edge = false;
                    active.last_confirmed_sample = None;
                    active.legacy_resample_anchor = None;
                    active.compiled_brush_state = ink_brush::CompiledBrushState::default();
                    active.compiled_dab_last_position = None;
                }
                outside_after_exit = false;
            }
            confirmed.extend(clip_pointer_segment(raw_previous, sample, max_x, max_y));
            if raw_previous.is_some_and(|previous| {
                sample_inside_document(previous, max_x, max_y) && !sample_inside
            }) {
                if let Some(active) = state.active_stroke.as_mut() {
                    active.stopped_at_page_edge = true;
                }
                outside_after_exit = true;
                predicted.clear();
            }
            raw_previous = Some(sample);
        }
    }
    if let Some(active) = state.active_stroke.as_mut() {
        active.last_input_sample = raw_previous;
    }

    // Pointer capture remains active after leaving the artwork. Every sample
    // is clamped to the document edge above; a stationary cursor beyond that
    // edge can therefore produce thousands of identical points. Rebuilding
    // the full smoothed path for each duplicate makes a long drag quadratic
    // work and can stall the whole editor. Preserve sensor changes and the
    // configured stationary-brush cadence, but do not retain redundant input.
    let (previous_sample, stationary_rate_hz) =
        state.active_stroke.as_ref().map_or((None, 0.0), |active| {
            (
                active.last_confirmed_sample,
                active
                    .compiled_brush
                    .as_ref()
                    .map_or(0.0, |brush| brush.stroke.stationary_rate_hz),
            )
        });
    confirmed = compact_stationary_samples(previous_sample, confirmed, stationary_rate_hz);
    predicted = compact_stationary_samples(previous_sample, predicted, stationary_rate_hz);

    let mut committed_dirty = Vec::new();

    let committed = if confirmed.is_empty() {
        None
    } else {
        let active = state
            .active_stroke
            .as_mut()
            .ok_or_else(|| EngineError::InvalidCommand("stroke is not active".into()))?;
        let eraser = confirmed
            .iter()
            .any(|sample| sample.flags & flags::ERASER != 0);
        let (dabs, phase_two_dabs) = if let Some(compiled) = active.compiled_brush.as_ref() {
            let (phase_two_dabs, accepted_count, hit_work_limit) =
                match render_compiled_confirmed_bounded(
                    compiled,
                    &confirmed,
                    &mut active.compiled_brush_state,
                ) {
                    Ok(result) => result,
                    Err(ink_brush::BrushValidationError::WorkLimitExceeded) => {
                        active.work_limit_reached = true;
                        eprintln!(
                            "Project Ink stroke work limit reached: compiled_sample_work_limit stroke={}",
                            stroke_id.0,
                        );
                        (Vec::new(), 0, true)
                    }
                    Err(error) => return Err(EngineError::InvalidCommand(error.to_string())),
                };
            if accepted_count < confirmed.len() {
                confirmed.truncate(accepted_count);
            }
            if hit_work_limit {
                active.work_limit_reached = true;
                active.work_segments = active.work_segments.saturating_add(1);
                eprintln!(
                    "Project Ink stroke work limit reached: compiled_sample_work_limit stroke={} acceptedPacketSamples={}",
                    stroke_id.0, accepted_count,
                );
            }
            if active
                .compiled_brush_state
                .segment_work_near_limit(compiled.limits.max_dabs)
                && active.compiled_brush_state.begin_work_segment()
            {
                active.work_segments = active.work_segments.saturating_add(1);
                eprintln!(
                    "Project Ink stroke work segment rollover: stroke={} segment={} reason=safety_threshold",
                    stroke_id.0, active.work_segments,
                );
            }
            (Vec::new(), Some(phase_two_dabs))
        } else {
            let (dabs, anchor, accepted_count, hit_work_limit) =
                match resample_legacy_confirmed_bounded(
                    &confirmed,
                    active.brush,
                    active.legacy_resample_anchor,
                ) {
                    Ok(result) => result,
                    Err(error) => return Err(EngineError::InvalidCommand(error.to_string())),
                };
            if accepted_count < confirmed.len() {
                confirmed.truncate(accepted_count);
            }
            if hit_work_limit {
                active.work_limit_reached = true;
                eprintln!(
                    "Project Ink stroke work limit reached: legacy_sample_work_limit stroke={} acceptedPacketSamples={}",
                    stroke_id.0, accepted_count,
                );
            }
            if active.legacy_segment_dabs.saturating_add(dabs.len()) > ink_brush::MAX_RESAMPLED_DABS
            {
                // resample_from returns a continuation anchor; resetting this
                // segment counter preserves spacing across the same logical
                // stroke and leaves undo/history as one transaction.
                active.legacy_segment_dabs = 0;
                active.work_segments = active.work_segments.saturating_add(1);
                eprintln!(
                    "Project Ink stroke work segment rollover: stroke={} segment={} reason=legacy_dab_limit",
                    stroke_id.0, active.work_segments,
                );
            }
            active.legacy_segment_dabs = active.legacy_segment_dabs.saturating_add(dabs.len());
            active.legacy_rendered_dabs = active.legacy_rendered_dabs.saturating_add(dabs.len());
            active.legacy_resample_anchor = anchor;
            (dabs, None)
        };
        if let Some(brush_dabs) = phase_two_dabs.as_ref() {
            for dab in brush_dabs {
                if let Some((previous_x, previous_y)) = active.compiled_dab_last_position {
                    let step = (dab.x - previous_x).hypot(dab.y - previous_y);
                    active.compiled_dab_path_length += f64::from(step);
                    active.compiled_dab_max_step = active.compiled_dab_max_step.max(step);
                }
                active.compiled_dab_last_position = Some((dab.x, dab.y));
            }
            active.compiled_rendered_dabs = active
                .compiled_rendered_dabs
                .saturating_add(brush_dabs.len());
        }
        record_confirmed_stroke_samples(active, &confirmed, sample_limit);
        Some((
            active.layer,
            active.brush,
            active.compiled_brush.clone(),
            dabs,
            phase_two_dabs,
            eraser,
        ))
    };
    if let Some((layer_id, preset, compiled_brush, dabs, phase_two_dabs, eraser)) =
        committed.as_ref()
    {
        let sequence = confirmed
            .iter()
            .map(|sample| sample.sequence)
            .max()
            .unwrap_or(0);
        if let Some(brush_dabs) = phase_two_dabs.as_deref() {
            for (dab_index, dab) in brush_dabs.iter().enumerate() {
                queue_live_dab(
                    state,
                    ink_live_render::LiveDab {
                        stroke_id: stroke_id.0,
                        sequence,
                        dab_index: u32::try_from(dab_index).unwrap_or(u32::MAX),
                        x: dab.x,
                        y: dab.y,
                        radius: f32::midpoint(dab.radius_x.abs(), dab.radius_y.abs()),
                        opacity: (dab.opacity * dab.flow).clamp(0.0, 1.0),
                        rotation: dab.angle,
                        color: [dab.color.r, dab.color.g, dab.color.b, dab.color.a],
                        phase: ink_live_render::DabPhase::Confirmed,
                    },
                );
            }
        } else {
            for (dab_index, dab) in dabs.iter().enumerate() {
                queue_live_dab(
                    state,
                    ink_live_render::LiveDab {
                        stroke_id: stroke_id.0,
                        sequence,
                        dab_index: u32::try_from(dab_index).unwrap_or(u32::MAX),
                        x: dab.x,
                        y: dab.y,
                        radius: legacy_dab_radius(*preset, dab.pressure),
                        opacity: legacy_dab_opacity(*preset, dab.pressure),
                        rotation: 0.0,
                        color: [
                            preset.color.r,
                            preset.color.g,
                            preset.color.b,
                            preset.color.a,
                        ],
                        phase: ink_live_render::DabPhase::Confirmed,
                    },
                );
            }
        }
        let resolved_resources =
            phase_two_dabs
                .as_deref()
                .map_or_else(BTreeMap::new, |brush_dabs| {
                    state
                        .resource_cache
                        .resolve_for_dabs(brush_dabs, &state.resources)
                });
        let layer_state = state
            .layers
            .get_mut(layer_id)
            .ok_or(EngineError::InvalidLayer)?;
        let alpha_lock = layer_state.layer.alpha_lock;
        let is_mask = layer_state.layer.kind == LayerKind::Mask;
        let mut compiled_tile_updates = 0;
        if is_mask {
            let tiles = render_mask_dabs(
                &mut layer_state.tiles,
                MaskDabInput {
                    preset: *preset,
                    compiled_dabs: phase_two_dabs.as_deref(),
                    legacy_dabs: dabs,
                    resources: &resolved_resources,
                    selection: state.selection.as_ref(),
                    eraser: *eraser,
                    width_px: state.width_px,
                    height_px: state.height_px,
                },
            );
            committed_dirty.extend(tiles);
        } else if compiled_brush.is_some() {
            let tiles = render_brush_dabs(
                &mut layer_state.tiles,
                phase_two_dabs.as_deref().unwrap_or_default(),
                &resolved_resources,
                state.selection.as_ref(),
                *eraser,
                false,
                alpha_lock,
                state.width_px,
                state.height_px,
            );
            compiled_tile_updates = tiles.len();
            committed_dirty.extend(tiles.iter().copied());
        } else {
            let tiles = render_dabs(
                &mut layer_state.tiles,
                dabs,
                *preset,
                state.selection.as_ref(),
                *eraser,
                false,
                alpha_lock,
                state.width_px,
                state.height_px,
            );
            committed_dirty.extend(tiles.iter().copied());
        }
        if compiled_brush.is_some()
            && let Some(active) = state.active_stroke.as_mut()
        {
            active.compiled_cpu_tile_updates = active
                .compiled_cpu_tile_updates
                .saturating_add(compiled_tile_updates);
        }
    }

    // The accepted prefix, if any, has now been rasterized. Do not evaluate
    // predicted samples past a confirmed-work ceiling; they are disposable and
    // must not re-trigger the same bounded evaluator failure.
    let work_limit_reached = state
        .active_stroke
        .as_ref()
        .is_some_and(|active| active.work_limit_reached);

    if !confirmed.is_empty() {
        let active = state
            .active_stroke
            .as_mut()
            .ok_or_else(|| EngineError::InvalidCommand("stroke is not active".into()))?;
        active.preview_tiles.clear();
        active.preview_eraser = false;
    }
    if !predicted.is_empty() && !work_limit_reached {
        let (dabs, preview_eraser, brush_dabs) = {
            let active = state
                .active_stroke
                .as_mut()
                .ok_or_else(|| EngineError::InvalidCommand("stroke is not active".into()))?;
            let dabs = if active.compiled_brush.is_none() {
                // Confirmed dabs already live in the authoritative raster.
                // Rebuilding the full confirmed path for every prediction
                // made long strokes quadratic; only sample forward from the
                // last confirmed spacing anchor for this replaceable preview.
                resample_from(&predicted, active.brush, active.legacy_resample_anchor)
                    .map_err(|error| EngineError::InvalidCommand(error.to_string()))?
                    .0
            } else {
                Vec::new()
            };
            active.preview_eraser = predicted
                .iter()
                .any(|sample| sample.flags & flags::ERASER != 0);
            let preview_eraser = active.preview_eraser;
            let brush_dabs = if let Some(compiled) = active.compiled_brush.as_ref() {
                let mut preview_state = active.compiled_brush_state.clone_for_prediction();
                let preview = compiled
                    .render_incremental(&predicted, &mut preview_state)
                    .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
                Some(preview)
            } else {
                None
            };
            (dabs, preview_eraser, brush_dabs)
        };
        let resolved_resources = brush_dabs.as_deref().map_or_else(BTreeMap::new, |dabs| {
            state
                .resource_cache
                .resolve_for_dabs(dabs, &state.resources)
        });
        let sequence = predicted
            .iter()
            .map(|sample| sample.sequence)
            .max()
            .unwrap_or(0);
        if let Some(brush_dabs) = brush_dabs.as_deref() {
            for (dab_index, dab) in brush_dabs.iter().enumerate() {
                queue_live_dab(
                    state,
                    ink_live_render::LiveDab {
                        stroke_id: stroke_id.0,
                        sequence,
                        dab_index: u32::try_from(dab_index).unwrap_or(u32::MAX),
                        x: dab.x,
                        y: dab.y,
                        radius: f32::midpoint(dab.radius_x.abs(), dab.radius_y.abs()),
                        opacity: (dab.opacity * dab.flow).clamp(0.0, 1.0),
                        rotation: dab.angle,
                        color: [dab.color.r, dab.color.g, dab.color.b, dab.color.a],
                        phase: ink_live_render::DabPhase::Predicted,
                    },
                );
            }
        } else {
            let brush = state
                .active_stroke
                .as_ref()
                .map_or(BrushPreset::starters()[0], |active| active.brush);
            for (dab_index, dab) in dabs.iter().enumerate() {
                queue_live_dab(
                    state,
                    ink_live_render::LiveDab {
                        stroke_id: stroke_id.0,
                        sequence,
                        dab_index: u32::try_from(dab_index).unwrap_or(u32::MAX),
                        x: dab.x,
                        y: dab.y,
                        radius: legacy_dab_radius(brush, dab.pressure),
                        opacity: legacy_dab_opacity(brush, dab.pressure),
                        rotation: 0.0,
                        color: [0, 0, 0, 255],
                        phase: ink_live_render::DabPhase::Predicted,
                    },
                );
            }
        }
        let preview_layer_id = state.active_stroke.as_ref().map(|active| active.layer);
        let preview_alpha_source = preview_layer_id
            .filter(|layer_id| {
                state
                    .layers
                    .get(layer_id)
                    .is_some_and(|layer| layer.layer.alpha_lock)
            })
            .and_then(|layer_id| state.layers.get(&layer_id).map(|layer| layer.tiles.clone()));
        let active = state
            .active_stroke
            .as_mut()
            .ok_or_else(|| EngineError::InvalidCommand("stroke is not active".into()))?;
        active.preview_tiles.clear();
        if let Some(brush_dabs) = brush_dabs.as_deref() {
            render_brush_dabs(
                &mut active.preview_tiles,
                brush_dabs,
                &resolved_resources,
                state.selection.as_ref(),
                preview_eraser,
                true,
                false,
                state.width_px,
                state.height_px,
            );
        } else {
            render_dabs(
                &mut active.preview_tiles,
                &dabs,
                active.brush,
                state.selection.as_ref(),
                preview_eraser,
                true,
                false,
                state.width_px,
                state.height_px,
            );
        }
        if let Some(source) = preview_alpha_source.as_ref() {
            mask_preview_to_alpha(
                &mut active.preview_tiles,
                source,
                state.width_px,
                state.height_px,
            );
        }
    }

    committed_dirty.sort_unstable_by_key(|coordinate| (coordinate.y, coordinate.x));
    committed_dirty.dedup();
    let dirty_bounds = TileBounds::from_coordinates(&committed_dirty);
    let committed_tiles = committed_dirty.clone();
    let highest_committed_sequence = confirmed.iter().map(|sample| sample.sequence).max();
    if !committed_dirty.is_empty() {
        let cpu_tile_count = committed_dirty.len();
        if let Some(active) = state.active_stroke.as_mut() {
            active.cpu_tile_updates = active.cpu_tile_updates.saturating_add(cpu_tile_count);
        }
        let layer_id = state
            .active_stroke
            .as_ref()
            .map(|active| active.layer)
            .or_else(|| committed.as_ref().map(|(layer, _, _, _, _, _)| *layer))
            .ok_or(EngineError::InvalidLayer)?;
        advance_revision(state)?;
        state.events.push(EngineEvent::TilesDirty {
            revision: state.revision,
            tiles: committed_tiles
                .iter()
                .copied()
                .map(|coordinate| TileDescriptor {
                    layer: layer_id,
                    coordinate,
                })
                .collect(),
        });
        state.events.push(EngineEvent::CompositeTilesDirty {
            revision: state.revision,
            tiles: committed_tiles.clone(),
        });
    }
    if let Some(highest_committed_sequence) = highest_committed_sequence {
        let metrics = state
            .active_stroke
            .as_ref()
            .map(stroke_render_metrics)
            .ok_or_else(|| EngineError::InvalidCommand("stroke is not active".into()))?;
        state.events.push(EngineEvent::StrokeAcknowledged {
            stroke: stroke_id,
            highest_committed_sequence,
            revision: state.revision,
            dirty_bounds,
            dirty_tiles: committed_tiles,
            metrics,
        });
    }
    Ok(())
}

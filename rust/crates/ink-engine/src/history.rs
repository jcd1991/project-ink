use super::{
    BTreeMap, LayerId, LayerState, MAX_HISTORY_SNAPSHOT_BYTES, TimeLapseRecording, layer_map_bytes,
};

pub(super) fn trim_history_snapshots(snapshots: &mut Vec<BTreeMap<LayerId, LayerState>>) {
    while snapshots.len() > 128
        || (snapshots.len() > 1
            && snapshots
                .iter()
                .map(layer_map_bytes)
                .fold(0usize, usize::saturating_add)
                > MAX_HISTORY_SNAPSHOT_BYTES)
    {
        snapshots.remove(0);
    }
}

pub(super) fn time_lapse_has_capacity(
    recording: &TimeLapseRecording,
    additional_samples: usize,
) -> bool {
    let recorded_samples = recording
        .strokes
        .iter()
        .map(|stroke| stroke.samples.len())
        .fold(0usize, usize::saturating_add);
    time_lapse_has_capacity_at(
        recording.strokes.len(),
        recorded_samples,
        additional_samples,
    )
}

pub(super) fn time_lapse_has_capacity_at(
    recorded_strokes: usize,
    recorded_samples: usize,
    additional_samples: usize,
) -> bool {
    recorded_strokes < TimeLapseRecording::MAX_STROKES
        && recorded_samples.saturating_add(additional_samples) <= TimeLapseRecording::MAX_SAMPLES
}

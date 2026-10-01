//! Small deterministic fixtures shared by integration tests.
#![allow(missing_docs)]
#![allow(
    clippy::missing_errors_doc,
    clippy::missing_panics_doc,
    clippy::must_use_candidate
)]

/// Build a one-sample pointer packet for recorded-stroke tests.
#[must_use]
pub fn one_sample(x: f32, y: f32, pressure: f32) -> Vec<u8> {
    let mut bytes = vec![1, 0, 1, 0];
    bytes.extend([0u8; ink_input::SAMPLE_BYTES]);
    bytes[12..16].copy_from_slice(&x.to_le_bytes());
    bytes[16..20].copy_from_slice(&y.to_le_bytes());
    bytes[20..24].copy_from_slice(&pressure.to_le_bytes());
    bytes
}

/// Encode a bounded pointer packet for worker and replay tests.
#[must_use]
pub fn pointer_packet(samples: &[ink_input::PointerSample]) -> Vec<u8> {
    assert!(samples.len() <= ink_input::MAX_SAMPLES);
    let count = u16::try_from(samples.len()).expect("packet sample count fits u16");
    let mut bytes = Vec::with_capacity(4 + samples.len() * ink_input::SAMPLE_BYTES);
    bytes.extend_from_slice(&ink_input::PACKET_VERSION.to_le_bytes());
    bytes.extend_from_slice(&count.to_le_bytes());
    for sample in samples {
        bytes.extend_from_slice(&sample.pointer_id.to_le_bytes());
        bytes.extend_from_slice(&sample.flags.to_le_bytes());
        bytes.push(sample.device_kind as u8);
        bytes.push(sample.phase as u8);
        bytes.extend_from_slice(&sample.canvas_x.to_le_bytes());
        bytes.extend_from_slice(&sample.canvas_y.to_le_bytes());
        let pressure = f32::from(sample.pressure) / f32::from(u16::MAX);
        bytes.extend_from_slice(&pressure.to_le_bytes());
        bytes.extend_from_slice(&sample.tilt_x.to_le_bytes());
        bytes.extend_from_slice(&sample.tilt_y.to_le_bytes());
        bytes.extend_from_slice(&sample.azimuth.to_le_bytes());
        bytes.extend_from_slice(&sample.twist.to_le_bytes());
        bytes.extend_from_slice(&sample.timestamp_ns.to_le_bytes());
        bytes.extend_from_slice(&sample.sequence.to_le_bytes());
    }
    bytes
}

//! Platform-neutral pointer packet decoding and quantization.
#![allow(missing_docs)]
#![allow(
    clippy::missing_errors_doc,
    clippy::missing_panics_doc,
    clippy::must_use_candidate
)]

use std::collections::VecDeque;
use std::fmt;

/// Packet version accepted by the engine.
pub const PACKET_VERSION: u16 = 1;
/// Encoded bytes per sample, including the reserved alignment word.
pub const SAMPLE_BYTES: usize = 48;
/// Maximum samples accepted in one call to prevent unbounded allocations.
pub const MAX_SAMPLES: usize = 256;
/// Maximum encoded packet size accepted at the native boundary.
///
/// Keeping this explicit prevents a hostile FFI caller from forcing a large
/// `Vec` allocation before the packet decoder can reject trailing bytes.
pub const MAX_PACKET_BYTES: usize = 4 + MAX_SAMPLES * SAMPLE_BYTES;
/// Largest accepted canvas-space magnitude. This covers the v1 canvas limit
/// plus navigation overscroll without allowing pathological resampling work.
pub const MAX_COORDINATE_ABS: f32 = 65_536.0;

/// Sample flags shared by native adapters.
pub mod flags {
    pub const ACTUAL: u16 = 1 << 0;
    pub const COALESCED: u16 = 1 << 1;
    pub const PREDICTED: u16 = 1 << 2;
    pub const ERASER: u16 = 1 << 3;
    pub const BARREL: u16 = 1 << 4;
    pub const HOVER: u16 = 1 << 5;
    pub const PALM_REJECTED: u16 = 1 << 6;
    pub const KNOWN: u16 = ACTUAL | COALESCED | PREDICTED | ERASER | BARREL | HOVER | PALM_REJECTED;
    pub const SAMPLE_SOURCE: u16 = ACTUAL | COALESCED | PREDICTED;
}

/// Pointer device category.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum DeviceKind {
    Unknown = 0,
    Stylus = 1,
    Touch = 2,
    Mouse = 3,
}

/// Pointer lifecycle phase.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum Phase {
    Down = 0,
    Move = 1,
    Up = 2,
    Cancel = 3,
}

/// Quantized sample consumed by the brush worker.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PointerSample {
    pub pointer_id: u32,
    pub flags: u16,
    pub device_kind: DeviceKind,
    pub phase: Phase,
    pub canvas_x: f32,
    pub canvas_y: f32,
    pub pressure: u16,
    pub tilt_x: f32,
    pub tilt_y: f32,
    pub azimuth: f32,
    pub twist: f32,
    pub timestamp_ns: u64,
    pub sequence: u32,
}

/// A decoded bounded packet.
#[derive(Clone, Debug, PartialEq)]
pub struct PointerPacket {
    pub samples: Vec<PointerSample>,
}

/// Result of attempting to enqueue a packet into the bounded worker queue.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum QueueOutcome {
    Enqueued,
    DroppedPredicted,
}

/// Bounded packet queue. Native adapters may use this as the control boundary;
/// confirmed samples are never displaced by predicted-only traffic.
#[derive(Debug)]
pub struct PacketQueue {
    capacity: usize,
    packets: VecDeque<Vec<u8>>,
}

impl PacketQueue {
    /// Construct a queue with a minimum capacity of one packet.
    #[must_use]
    pub fn new(capacity: usize) -> Self {
        Self {
            capacity: capacity.max(1),
            packets: VecDeque::new(),
        }
    }

    /// Enqueue a packet, evicting the oldest predicted-only packet if full.
    pub fn push(&mut self, bytes: Vec<u8>) -> Result<QueueOutcome, PacketError> {
        self.push_preserving_on_error(bytes)
            .map_err(|(error, _bytes)| error)
    }

    /// Enqueue a packet while returning its original bytes on error. This lets
    /// a producer wait for capacity without copying high-frequency packets.
    pub fn push_preserving_on_error(
        &mut self,
        bytes: Vec<u8>,
    ) -> Result<QueueOutcome, (PacketError, Vec<u8>)> {
        let packet = match decode(&bytes) {
            Ok(packet) => packet,
            Err(error) => return Err((error, bytes)),
        };
        if self.packets.len() < self.capacity {
            self.packets.push_back(bytes);
            return Ok(QueueOutcome::Enqueued);
        }
        let predicted_only = packet
            .samples
            .iter()
            .all(|sample| sample.flags & flags::PREDICTED != 0);
        if let Some(index) = self.packets.iter().position(|queued| {
            decode(queued).is_ok_and(|value| {
                value
                    .samples
                    .iter()
                    .all(|sample| sample.flags & flags::PREDICTED != 0)
            })
        }) {
            self.packets.remove(index);
            if predicted_only {
                return Ok(QueueOutcome::DroppedPredicted);
            }
            self.packets.push_back(bytes);
            return Ok(QueueOutcome::Enqueued);
        }
        if predicted_only {
            Ok(QueueOutcome::DroppedPredicted)
        } else {
            Err((PacketError::QueueFull, bytes))
        }
    }

    /// Pop the oldest packet for the render worker.
    pub fn pop(&mut self) -> Option<Vec<u8>> {
        self.packets.pop_front()
    }
    /// Number of queued packets.
    #[must_use]
    pub fn len(&self) -> usize {
        self.packets.len()
    }
    /// Whether no packet is waiting.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.packets.is_empty()
    }
}

/// Malformed or unsafe packet input.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PacketError {
    TooShort,
    UnsupportedVersion(u16),
    TooManySamples,
    Truncated,
    TrailingBytes,
    InvalidPhase(u8),
    InvalidDeviceKind(u8),
    InvalidFlags(u16),
    InvalidFloat,
    CoordinateOutOfRange,
    QueueFull,
}

impl fmt::Display for PacketError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::TooShort => f.write_str("pointer packet header is truncated"),
            Self::UnsupportedVersion(v) => write!(f, "unsupported pointer packet version {v}"),
            Self::TooManySamples => f.write_str("pointer packet exceeds sample limit"),
            Self::Truncated => f.write_str("pointer packet sample is truncated"),
            Self::TrailingBytes => f.write_str("pointer packet has trailing bytes"),
            Self::InvalidPhase(phase) => write!(f, "pointer packet has invalid phase {phase}"),
            Self::InvalidDeviceKind(kind) => {
                write!(f, "pointer packet has invalid device kind {kind}")
            }
            Self::InvalidFlags(flags) => write!(f, "pointer packet has invalid flags {flags:#06x}"),
            Self::InvalidFloat => f.write_str("pointer packet contains a non-finite value"),
            Self::CoordinateOutOfRange => {
                f.write_str("pointer packet coordinate exceeds the safety limit")
            }
            Self::QueueFull => f.write_str("confirmed pointer packet queue is full"),
        }
    }
}

impl std::error::Error for PacketError {}

fn u16_at(bytes: &[u8], offset: usize) -> Result<u16, PacketError> {
    bytes
        .get(offset..offset + 2)
        .map(|b| u16::from_le_bytes([b[0], b[1]]))
        .ok_or(PacketError::Truncated)
}
fn u32_at(bytes: &[u8], offset: usize) -> Result<u32, PacketError> {
    bytes
        .get(offset..offset + 4)
        .map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
        .ok_or(PacketError::Truncated)
}
fn u64_at(bytes: &[u8], offset: usize) -> Result<u64, PacketError> {
    let value = bytes
        .get(offset..offset + 8)
        .ok_or(PacketError::Truncated)?;
    Ok(u64::from_le_bytes([
        value[0], value[1], value[2], value[3], value[4], value[5], value[6], value[7],
    ]))
}
fn f32_at(bytes: &[u8], offset: usize) -> Result<f32, PacketError> {
    let value = f32::from_bits(u32_at(bytes, offset)?);
    if value.is_finite() {
        Ok(value)
    } else {
        Err(PacketError::InvalidFloat)
    }
}

/// Decode and quantize a wire packet. Positions use 1/256 px and pressure 16 bits.
pub fn decode(bytes: &[u8]) -> Result<PointerPacket, PacketError> {
    if bytes.len() < 4 {
        return Err(PacketError::TooShort);
    }
    let version = u16_at(bytes, 0)?;
    if version != PACKET_VERSION {
        return Err(PacketError::UnsupportedVersion(version));
    }
    let count = usize::from(u16_at(bytes, 2)?);
    if count > MAX_SAMPLES {
        return Err(PacketError::TooManySamples);
    }
    let expected_length = 4 + count * SAMPLE_BYTES;
    if bytes.len() < expected_length {
        return Err(PacketError::Truncated);
    }
    if bytes.len() > expected_length {
        return Err(PacketError::TrailingBytes);
    }
    let mut samples = Vec::with_capacity(count);
    for index in 0..count {
        let base = 4 + index * SAMPLE_BYTES;
        let x = f32_at(bytes, base + 8)?;
        let y = f32_at(bytes, base + 12)?;
        if x.abs() > MAX_COORDINATE_ABS || y.abs() > MAX_COORDINATE_ABS {
            return Err(PacketError::CoordinateOutOfRange);
        }
        let pressure = f32_at(bytes, base + 16)?.clamp(0.0, 1.0);
        let sample_flags = u16_at(bytes, base + 4)?;
        if sample_flags & !flags::KNOWN != 0
            || (sample_flags & flags::SAMPLE_SOURCE).count_ones() > 1
        {
            return Err(PacketError::InvalidFlags(sample_flags));
        }
        let device_kind = match bytes[base + 6] {
            0 => DeviceKind::Unknown,
            1 => DeviceKind::Stylus,
            2 => DeviceKind::Touch,
            3 => DeviceKind::Mouse,
            kind => return Err(PacketError::InvalidDeviceKind(kind)),
        };
        let sample = PointerSample {
            pointer_id: u32_at(bytes, base)?,
            flags: sample_flags,
            device_kind,
            phase: match bytes[base + 7] {
                0 => Phase::Down,
                1 => Phase::Move,
                2 => Phase::Up,
                3 => Phase::Cancel,
                phase => return Err(PacketError::InvalidPhase(phase)),
            },
            canvas_x: (x * 256.0).round() / 256.0,
            canvas_y: (y * 256.0).round() / 256.0,
            #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
            pressure: (pressure * f32::from(u16::MAX)).round() as u16,
            tilt_x: f32_at(bytes, base + 20)?,
            tilt_y: f32_at(bytes, base + 24)?,
            azimuth: f32_at(bytes, base + 28)?,
            twist: f32_at(bytes, base + 32)?,
            timestamp_ns: u64_at(bytes, base + 36)?,
            sequence: u32_at(bytes, base + 44)?,
        };
        samples.push(sample);
    }
    Ok(PointerPacket { samples })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_truncated_packet() {
        assert_eq!(decode(&[1, 0, 1, 0]), Err(PacketError::Truncated));
    }

    #[test]
    fn rejects_trailing_packet_bytes() {
        let mut bytes = packet(flags::ACTUAL, 0);
        bytes.push(0);
        assert_eq!(decode(&bytes), Err(PacketError::TrailingBytes));
    }

    #[test]
    fn rejects_unknown_pointer_phase() {
        assert_eq!(
            decode(&packet(flags::ACTUAL, 4)),
            Err(PacketError::InvalidPhase(4))
        );
    }

    #[test]
    fn rejects_unknown_flags_and_multiple_sample_sources() {
        assert_eq!(
            decode(&packet(flags::ACTUAL | (1 << 15), 0)),
            Err(PacketError::InvalidFlags(flags::ACTUAL | (1 << 15)))
        );
        assert_eq!(
            decode(&packet(flags::ACTUAL | flags::PREDICTED, 0)),
            Err(PacketError::InvalidFlags(flags::ACTUAL | flags::PREDICTED))
        );
    }

    #[test]
    fn rejects_unknown_device_and_unbounded_coordinates() {
        let mut bytes = packet(flags::ACTUAL, 0);
        bytes[10] = 99;
        assert_eq!(decode(&bytes), Err(PacketError::InvalidDeviceKind(99)));

        let mut bytes = packet(flags::ACTUAL, 0);
        bytes[12..16].copy_from_slice(&(65_537.0f32).to_le_bytes());
        assert_eq!(decode(&bytes), Err(PacketError::CoordinateOutOfRange));
    }
    #[test]
    fn quantizes_samples() {
        let mut bytes = vec![1, 0, 1, 0];
        bytes.extend([0u8; SAMPLE_BYTES]);
        bytes[12..16].copy_from_slice(&1.2345f32.to_le_bytes());
        bytes[16..20].copy_from_slice(&2.0f32.to_le_bytes());
        bytes[20..24].copy_from_slice(&0.5f32.to_le_bytes());
        let packet = decode(&bytes).expect("valid packet");
        assert!(
            (packet.samples[0].canvas_x - (1.2345f32 * 256.0).round() / 256.0).abs() < f32::EPSILON
        );
        assert_eq!(packet.samples[0].pressure, 32768);
    }

    fn packet(flags_value: u16, phase: u8) -> Vec<u8> {
        let mut bytes = vec![1, 0, 1, 0];
        bytes.extend([0u8; SAMPLE_BYTES]);
        bytes[8..10].copy_from_slice(&flags_value.to_le_bytes());
        bytes[11] = phase;
        bytes
    }

    #[test]
    fn queue_drops_predicted_before_confirmed_samples() {
        let mut queue = PacketQueue::new(1);
        assert_eq!(
            queue.push(packet(flags::PREDICTED, 1)),
            Ok(QueueOutcome::Enqueued)
        );
        assert_eq!(
            queue.push(packet(flags::ACTUAL, 1)),
            Ok(QueueOutcome::Enqueued)
        );
        assert_eq!(queue.pop(), Some(packet(flags::ACTUAL, 1)));
    }

    #[test]
    fn queue_rejects_confirmed_when_no_predicted_packet_can_be_evicted() {
        let mut queue = PacketQueue::new(1);
        assert_eq!(
            queue.push(packet(flags::ACTUAL, 0)),
            Ok(QueueOutcome::Enqueued)
        );
        assert_eq!(
            queue.push(packet(flags::ACTUAL, 1)),
            Err(PacketError::QueueFull)
        );
        assert_eq!(queue.len(), 1);
    }
}

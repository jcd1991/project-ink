//! Bounded public-command undo/redo costs after a long sparse painting session.
use ink_brush::BrushPreset;
use ink_command::EditorCommand;
use ink_engine::Document;
use ink_model::{ColorSpace, DocumentId, DocumentSpec, Rgba8, StrokeId};
use ink_raster::TileCoord;
use std::time::Instant;

fn p95(samples: &mut [u128]) -> u128 {
    samples.sort_unstable();
    samples[(samples.len() * 95).div_ceil(100) - 1]
}

fn main() {
    let mut document = Document::new(
        DocumentId::from_u128(0x4849_5354),
        DocumentSpec {
            width_px: 16384,
            height_px: 16384,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        },
    )
    .expect("benchmark document");
    let layer = document.layers()[0].id;
    let mut commit_ns = Vec::new();
    for index in 0..256_u32 {
        let stroke = StrokeId::from_u128(0x1000 + u128::from(index));
        document
            .dispatch(EditorCommand::BeginStroke {
                stroke,
                layer,
                brush: BrushPreset::starters()[0].id,
            })
            .expect("begin");
        let started = Instant::now();
        let x = (index % 16) * 768 + 32;
        let y = (index / 16) * 768 + 32;
        document
            .push_pointer_packet(&ink_test_support::one_sample(
                f32::from(u16::try_from(x).expect("bounded x")),
                f32::from(u16::try_from(y).expect("bounded y")),
                1.0,
            ))
            .expect("sample");
        document
            .dispatch(EditorCommand::EndStroke { stroke })
            .expect("commit");
        commit_ns.push(started.elapsed().as_nanos());
        document
            .drain_live_dabs_available(65_536)
            .expect("drain preview");
        document.drain_events().expect("drain invalidations");
    }
    let coordinate = TileCoord { x: 45, y: 45 };
    let committed = document.read_composite_tile(coordinate).expect("last tile");
    assert!(committed.iter().any(|byte| *byte != 0));
    let mut undo_ns = Vec::new();
    for _ in 0..128 {
        let revision = document.revision();
        let started = Instant::now();
        document.dispatch(EditorCommand::Undo).expect("undo");
        let elapsed = started.elapsed().as_nanos();
        if document.revision() == revision {
            break;
        }
        undo_ns.push(elapsed);
    }
    assert!(
        document
            .read_composite_tile(coordinate)
            .expect("undone tile")
            .iter()
            .all(|byte| *byte == 0)
    );
    let mut redo_ns = Vec::new();
    for _ in 0..undo_ns.len() {
        let revision = document.revision();
        let started = Instant::now();
        document.dispatch(EditorCommand::Redo).expect("redo");
        redo_ns.push(started.elapsed().as_nanos());
        assert!(document.revision() > revision, "redo must perform an edit");
    }
    assert_eq!(
        document
            .read_composite_tile(coordinate)
            .expect("restored tile"),
        committed
    );
    println!(
        "{{\"strokes\":256,\"undo_commands\":128,\"redo_commands\":128,\"commit_p95_ns\":{},\"undo_p95_ns\":{},\"redo_p95_ns\":{}}}",
        p95(&mut commit_ns),
        p95(&mut undo_ns),
        p95(&mut redo_ns)
    );
    document.close();
}

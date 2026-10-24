//! Deterministic headless lifecycle scenarios with independent pixel expectations.
use super::*;

fn expected_tile(masked: bool, red_on_top: bool) -> Vec<u8> {
    let mut pixels = vec![0; 256 * 256 * 4];
    for y in 0..8 {
        for x in 0..8 {
            let pixel = if red_on_top || (masked && x >= 4) {
                [0, 0, 255, 255]
            } else {
                [255, 0, 0, 255]
            };
            pixels[(y * 256 + x) * 4..(y * 256 + x + 1) * 4].copy_from_slice(&pixel);
        }
    }
    pixels
}

fn fixture(id: u128) -> (Document, LayerId, LayerId) {
    let spec = DocumentSpec {
        width_px: 8,
        height_px: 8,
        dpi: 144.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut document = Document::new(DocumentId::from_u128(id), spec).expect("fixture document");
    let red = document.layers()[0].id;
    let blue = document.add_layer(LayerKind::Raster).expect("blue layer");
    let mask = document.add_layer(LayerKind::Mask).expect("mask");
    // Synthetic source fixture; all subsequent transitions use engine commands.
    {
        let mut state = lock_recover(&document.state);
        for y in 0..8 {
            for x in 0..8 {
                state.layers.get_mut(&red).expect("red").tiles.set_pixel(
                    x,
                    y,
                    Rgba8 {
                        r: 255,
                        g: 0,
                        b: 0,
                        a: 255,
                    },
                );
                state.layers.get_mut(&blue).expect("blue").tiles.set_pixel(
                    x,
                    y,
                    Rgba8 {
                        r: 0,
                        g: 0,
                        b: 255,
                        a: 255,
                    },
                );
                let value = if x < 4 { 0 } else { 255 };
                state.layers.get_mut(&mask).expect("mask").tiles.set_pixel(
                    x,
                    y,
                    Rgba8 {
                        r: value,
                        g: value,
                        b: value,
                        a: value,
                    },
                );
            }
        }
    }
    (document, red, mask)
}

#[test]
fn headless_contract_mask_reorder_undo_snapshot_and_reopen() {
    let mut outputs = Vec::new();
    for run in 0..2 {
        let (mut document, red, mask) = fixture(0xcafe_0000 + run);
        let coordinate = TileCoord { x: 0, y: 0 };
        let composite = |doc: &Document| doc.read_composite_tile(coordinate).expect("composite");
        assert_pixels(&composite(&document), &expected_tile(true, false));
        let frozen = document.capture_composite_tile_snapshot(&[coordinate]);
        let revision = frozen.revision();
        document
            .dispatch(EditorCommand::SetMaskEnabled {
                mask,
                enabled: false,
            })
            .expect("disable mask");
        assert!(document.revision() > revision);
        assert_pixels(&composite(&document), &expected_tile(false, false));
        assert_eq!(
            frozen.read_tiles(&[coordinate]).expect("frozen pixels")[0],
            expected_tile(true, false)
        );
        document
            .dispatch(EditorCommand::Undo)
            .expect("undo mask edit");
        assert_pixels(&composite(&document), &expected_tile(true, false));
        document
            .dispatch(EditorCommand::MoveLayer {
                layer: red,
                parent: None,
                index: 1,
            })
            .expect("reorder");
        assert_pixels(&composite(&document), &expected_tile(true, true));
        document
            .dispatch(EditorCommand::Undo)
            .expect("undo reorder");
        assert_pixels(&composite(&document), &expected_tile(true, false));
        document
            .dispatch(EditorCommand::Redo)
            .expect("redo reorder");
        assert_pixels(&composite(&document), &expected_tile(true, true));
        // Invalid commands must leave revision and visible pixels unchanged.
        let revision = document.revision();
        assert!(
            document
                .dispatch(EditorCommand::MoveLayer {
                    layer: red,
                    parent: Some(red),
                    index: 0
                })
                .is_err()
        );
        assert_eq!(document.revision(), revision);
        assert_pixels(&composite(&document), &expected_tile(true, true));
        let path = std::env::temp_dir().join(format!(
            "ink-headless-contract-{}-{run}.inkproj",
            std::process::id()
        ));
        assert!(
            !path.exists(),
            "never overwrite an earlier diagnostic fixture"
        );
        document.save_as(&path).expect("save scenario");
        document.close();
        let mut reopened = Document::open(&path).expect("cold reopen");
        let pixels = composite(&reopened);
        assert_pixels(&pixels, &expected_tile(true, true));
        outputs.push(pixels);
        reopened.close();
        std::fs::remove_dir_all(path).expect("remove owned fixture");
    }
    assert_eq!(
        outputs[0], outputs[1],
        "independent runs produce identical pixels"
    );
}

fn assert_pixels(actual: &[u8], expected: &[u8]) {
    assert_eq!(actual.len(), expected.len());
    for (index, (actual, expected)) in actual
        .as_chunks::<4>()
        .0
        .iter()
        .zip(expected.as_chunks::<4>().0.iter())
        .enumerate()
    {
        assert_eq!(actual, expected, "pixel ({}, {})", index % 256, index / 256);
    }
}

#[test]
fn headless_contract_painted_mask_invalidates_revision_and_preserves_old_snapshot() {
    let (mut document, _, mask) = fixture(0xcafe_ffff);
    let coordinate = TileCoord { x: 0, y: 0 };
    let before = document.capture_composite_tile_snapshot(&[coordinate]);
    let brush = BrushPreset::starters()[0].id;
    document
        .update_brush_color(
            brush,
            Rgba8 {
                r: 0,
                g: 0,
                b: 0,
                a: 255,
            },
        )
        .expect("black mask brush");
    let stroke = ink_model::StrokeId::from_u128(0xcafe_eeee);
    document
        .dispatch(EditorCommand::BeginStroke {
            stroke,
            layer: mask,
            brush,
        })
        .expect("begin mask paint");
    document
        .push_pointer_packet(&ink_test_support::one_sample(2.0, 2.0, 1.0))
        .expect("mask sample");
    document
        .dispatch(EditorCommand::EndStroke { stroke })
        .expect("commit mask paint");
    assert!(document.revision() > before.revision());
    let painted = document
        .read_composite_tile(coordinate)
        .expect("painted mask");
    let center = (2 * 256 + 2) * 4;
    assert_eq!(&painted[center..center + 4], &[0, 0, 255, 255]);
    assert_ne!(painted, expected_tile(true, false));
    assert_pixels(
        &before
            .read_tiles(&[coordinate])
            .expect("immutable mask snapshot")[0],
        &expected_tile(true, false),
    );
    document
        .dispatch(EditorCommand::Undo)
        .expect("undo mask paint");
    assert_pixels(
        &document
            .read_composite_tile(coordinate)
            .expect("undo pixels"),
        &expected_tile(true, false),
    );
    document.close();
}

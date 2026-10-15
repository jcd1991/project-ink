//! Conformance checks against small PSDs authored and saved by Photoshop.

use ink_export::{ExportError, decode_png_rgba8, decode_psd, decode_psd_editable, inspect_psd};

const BASELINE_PSD: &[u8] =
    include_bytes!("../../../testdata/photocraft-psd/baseline-layer-copy.psd");
const BASELINE_RGBA: &[u8] =
    include_bytes!("../../../testdata/photocraft-psd/baseline-layer-copy.rgba");
const CLIPPED_ADJUSTMENT_PSD: &[u8] =
    include_bytes!("../../../testdata/photocraft-psd/clipped-hue-sat-blend-color.psd");
const CLIPPED_ADJUSTMENT_RGBA: &[u8] =
    include_bytes!("../../../testdata/photocraft-psd/clipped-hue-sat-blend-color.rgba");
const MASKED_ADJUSTMENT_PSD: &[u8] =
    include_bytes!("../../../testdata/photocraft-psd/masked-curves-gradient-mask-opacity60.psd");
const MASKED_ADJUSTMENT_RGBA: &[u8] =
    include_bytes!("../../../testdata/photocraft-psd/masked-curves-gradient-mask-opacity60.rgba");

fn assert_embedded_composite_matches_oracle(psd: &[u8], expected_rgba: &[u8]) {
    let (width, height, actual_rgba) = decode_psd(psd).expect("decode Photoshop composite");
    assert_eq!((width, height), (96, 96));
    assert_eq!(actual_rgba.as_slice(), expected_rgba);
}

#[test]
fn independently_authored_layered_psd_matches_external_composite_oracle() {
    const PSD: &[u8] =
        include_bytes!("../../../testdata/pine-and-birch-psd/sample-design-640x480.psd");
    const ORACLE_PNG: &[u8] =
        include_bytes!("../../../testdata/pine-and-birch-psd/sample-design-640x480.oracle.png");

    let inspection = inspect_psd(PSD).expect("inspect independent layered PSD");
    assert_eq!(
        (inspection.width, inspection.height, inspection.depth),
        (640, 480, 8)
    );
    assert!(
        inspection.editable_import_available,
        "{:?}",
        inspection.incompatibilities
    );
    assert!(inspection.flattened_import_available);

    let editable = decode_psd_editable(PSD).expect("decode independent editable layers");
    assert_eq!((editable.width, editable.height), (640, 480));
    assert_eq!(editable.layers.len(), 4);
    for name in ["Background", "Navy Circle", "Pine Bar", "Birch Band"] {
        assert!(
            editable.layers.iter().any(|layer| layer.name == name),
            "missing {name}"
        );
    }
    assert!(
        editable
            .layers
            .iter()
            .any(|layer| layer.rgba.iter().any(|sample| *sample != 0))
    );

    let (oracle_width, oracle_height, expected) =
        decode_png_rgba8(ORACLE_PNG).expect("decode psd-tools oracle");
    assert_eq!((oracle_width, oracle_height), (640, 480));
    let (width, height, actual) = decode_psd(PSD).expect("decode independent PSD composite");
    assert_eq!((width, height), (oracle_width, oracle_height));
    assert_eq!(
        actual, expected,
        "merged pixels differ from independent psd-tools output"
    );
}

#[test]
fn photoshop_authored_raster_file_matches_merged_oracle_and_reports_lock_mismatch() {
    let report = inspect_psd(BASELINE_PSD).expect("inspect Photoshop PSD");
    assert_eq!((report.width, report.height, report.depth), (96, 96, 8));
    assert_eq!(report.layers.len(), 2);
    assert_eq!(report.layers[0].name, "Background");
    assert_eq!(report.layers[1].name, "copy");
    assert!(!report.editable_import_available);
    assert!(report.flattened_import_available);
    assert!(
        report
            .incompatibilities
            .iter()
            .any(|reason| { reason.contains("position lock") })
    );
    assert!(matches!(
        decode_psd_editable(BASELINE_PSD),
        Err(ExportError::UnsupportedPsd(_))
    ));
    assert_embedded_composite_matches_oracle(BASELINE_PSD, BASELINE_RGBA);
}

#[test]
fn photoshop_authored_clipped_adjustment_is_reported_and_only_flattened_explicitly() {
    let report = inspect_psd(CLIPPED_ADJUSTMENT_PSD).expect("inspect Photoshop PSD");
    let clipped = report
        .layers
        .iter()
        .find(|layer| layer.name == "colorize clipped")
        .expect("clipped adjustment projection");
    assert!(clipped.clipping);
    assert!(clipped.has_raster_mask);
    assert!(
        report
            .incompatibilities
            .iter()
            .any(|reason| { reason.contains("adjustment or fill layer") })
    );
    assert!(
        report
            .incompatibilities
            .iter()
            .any(|reason| { reason.contains("unsupported blend mode") })
    );
    assert!(!report.editable_import_available);
    assert!(report.flattened_import_available);
    assert!(matches!(
        decode_psd_editable(CLIPPED_ADJUSTMENT_PSD),
        Err(ExportError::UnsupportedPsd(_))
    ));
    assert_embedded_composite_matches_oracle(CLIPPED_ADJUSTMENT_PSD, CLIPPED_ADJUSTMENT_RGBA);
}

#[test]
fn photoshop_authored_masked_adjustment_is_reported_and_only_flattened_explicitly() {
    let report = inspect_psd(MASKED_ADJUSTMENT_PSD).expect("inspect Photoshop PSD");
    let masked = report
        .layers
        .iter()
        .find(|layer| layer.name == "inverted curves")
        .expect("masked adjustment projection");
    assert!(masked.has_raster_mask);
    assert_eq!(masked.opacity, 153);
    assert!(
        report
            .incompatibilities
            .iter()
            .any(|reason| { reason.contains("adjustment or fill layer") })
    );
    assert!(!report.editable_import_available);
    assert!(report.flattened_import_available);
    assert!(matches!(
        decode_psd_editable(MASKED_ADJUSTMENT_PSD),
        Err(ExportError::UnsupportedPsd(_))
    ));
    assert_embedded_composite_matches_oracle(MASKED_ADJUSTMENT_PSD, MASKED_ADJUSTMENT_RGBA);
}

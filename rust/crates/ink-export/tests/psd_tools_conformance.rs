//! Conformance checks against an independently authored Photoshop group PSD.

use ink_export::{decode_psd_editable, inspect_psd};

const GROUP_CLIPPING_PSD: &[u8] =
    include_bytes!("../../../testdata/psd-tools-conformance/group-clipping/group-clipping.psd");
const MASK_PSD: &[u8] =
    include_bytes!("../../../testdata/psd-tools-conformance/simple-mask/masked-raster.psd");

#[test]
fn photoshop_group_clipping_records_map_to_the_supported_layer_tree() {
    let report = inspect_psd(GROUP_CLIPPING_PSD).expect("inspect group/clipping PSD");
    assert_eq!((report.width, report.height, report.depth), (627, 510, 8));
    assert!(
        report.editable_import_available,
        "{:?}",
        report.incompatibilities
    );

    let group_record = report
        .layers
        .iter()
        .find(|layer| layer.name == "clipping")
        .expect("Photoshop group record");
    assert!(group_record.is_group);
    // Photoshop stores the clipping byte on this folder record, but the
    // group is not a clipping layer and its external composite ignores it.
    assert!(!group_record.clipping);

    let blue_record = report
        .layers
        .iter()
        .find(|layer| layer.name == "blue")
        .expect("clipped raster record");
    assert!(!blue_record.is_group);
    assert!(blue_record.clipping);
    assert_eq!((blue_record.left, blue_record.top), (175, 80));

    let decoded = decode_psd_editable(GROUP_CLIPPING_PSD).expect("decode editable tree");
    let group = decoded
        .layers
        .iter()
        .find(|layer| layer.name == "clipping")
        .expect("decoded group");
    let red = decoded
        .layers
        .iter()
        .find(|layer| layer.name == "red")
        .expect("decoded red layer");
    let blue = decoded
        .layers
        .iter()
        .find(|layer| layer.name == "blue")
        .expect("decoded blue layer");
    assert_eq!(red.parent_index, Some(group.source_index));
    assert_eq!(blue.parent_index, Some(group.source_index));
    assert_eq!((red.left, red.top), (258, 44));
    assert_eq!((blue.left, blue.top), (175, 80));
    assert!(blue.clipping);
}

#[test]
fn photoshop_raster_mask_fixture_maps_to_mask_bounds_and_samples() {
    let report = inspect_psd(MASK_PSD).expect("inspect simple raster-mask PSD");
    assert_eq!((report.width, report.height, report.depth), (100, 150, 8));
    assert!(
        report.editable_import_available,
        "{:?}",
        report.incompatibilities
    );
    assert!(report.layers.iter().any(|layer| layer.has_raster_mask));

    let decoded = decode_psd_editable(MASK_PSD).expect("decode simple raster mask");
    let masked_layer = decoded
        .layers
        .iter()
        .find(|layer| layer.name == "Background copy")
        .expect("masked raster layer");
    let mask = masked_layer.mask.as_ref().expect("decoded layer mask");
    assert!(mask.enabled);
    assert_eq!(
        (mask.left, mask.top, mask.width, mask.height),
        (23, 10, 71, 57)
    );
    assert_eq!(mask.samples.len(), 71 * 57);
    assert!(mask.samples.contains(&0));
    assert!(mask.samples.contains(&u8::MAX));
}

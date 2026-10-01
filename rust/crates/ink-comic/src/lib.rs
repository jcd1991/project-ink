//! Bounded comic, manga, and webtoon project domain model.
//!
//! The comic model deliberately stores structure rather than pixels. Panels,
//! balloons, text, tones, and effect lines are editable objects and can be
//! rendered by the existing raster engine without repainting their contents.
//! Every public mutator validates limits before changing state so a malformed
//! imported project cannot cause unbounded allocation or path traversal.

#![allow(missing_docs)]
#![allow(
    clippy::missing_errors_doc,
    clippy::missing_panics_doc,
    clippy::must_use_candidate,
    clippy::too_many_lines,
    clippy::cast_precision_loss,
    clippy::cast_possible_truncation,
    clippy::float_cmp
)]

use base64::Engine as _;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fmt::{self, Write as _};
use std::path::Path;

const MAX_PAGES: usize = 512;
const MAX_PANELS_PER_PAGE: usize = 256;
const MAX_BALLOONS_PER_PAGE: usize = 512;
const MAX_TEXT_BYTES: usize = 16 * 1024;
const MAX_MATERIALS: usize = 4096;
const MAX_MATERIAL_BYTES: usize = 256;
const MAX_EFFECT_LINES: usize = 2048;
const MAX_INK_LINES: usize = 4096;
const MAX_TONE_LAYERS: usize = 256;
const MAX_POLYGON_POINTS: usize = 64;
const MAX_EXPORT_SEGMENTS: usize = 4096;
const FORMAT_VERSION: u16 = 2;
// Panel IDs and mask IDs are separate metadata namespaces. A deterministic
// namespace transform lets split operations create a stable mask identity for
// the new panel without changing the public bridge signature or consuming a
// second caller-provided ID.
// Comic layer IDs cross the existing Flutter layer API as signed Dart `int`
// values, even though Rust stores IDs as u128. Keep generated layer IDs in
// the positive i64 range; the previous 128-bit namespaces collapsed to
// duplicate/saturated Dart integers and rejected panel materialization.
const SPLIT_MASK_NAMESPACE: u128 = 0x6a09_e667_f3bc_c909;
const PANEL_GROUP_NAMESPACE: u128 = 0x4c3b_2a19_8877_6655;
// Distinct role namespaces avoid the old low-bit-offset collision where an
// adjacent panel's Ink could equal another panel's Sketch layer.
const SKETCH_LAYER_NAMESPACE: u128 = 0x1122_3344_5566_7788;
const INK_LAYER_NAMESPACE: u128 = 0x2233_4455_6677_8899;
const COLOR_LAYER_NAMESPACE: u128 = 0x3344_5566_7788_99aa;
const TONE_LAYER_NAMESPACE: u128 = 0x4455_6677_8899_aabb;
const EFFECTS_LAYER_NAMESPACE: u128 = 0x5566_7788_99aa_bbcc;

fn panel_layer_binding(panel_id: u128) -> PanelLayerBinding {
    PanelLayerBinding {
        panel_id,
        panel_group_id: panel_id ^ PANEL_GROUP_NAMESPACE,
        mask_layer_id: panel_id ^ SPLIT_MASK_NAMESPACE,
        sketch_layer_id: panel_id ^ SKETCH_LAYER_NAMESPACE,
        ink_layer_id: panel_id ^ INK_LAYER_NAMESPACE,
        color_layer_id: panel_id ^ COLOR_LAYER_NAMESPACE,
        tone_layer_id: panel_id ^ TONE_LAYER_NAMESPACE,
        effects_layer_id: panel_id ^ EFFECTS_LAYER_NAMESPACE,
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum ProjectTemplate {
    Illustration,
    PrintComic,
    Webtoon,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum TextOrientation {
    Horizontal,
    Vertical,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum PanelShape {
    Rectangle,
    Polygon,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum BalloonShape {
    Oval,
    Thought,
    Narration,
    Burst,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Rect {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

impl Rect {
    pub fn validate(self) -> Result<Self, ComicError> {
        if [self.x, self.y, self.width, self.height]
            .iter()
            .any(|value| !value.is_finite())
            || self.width <= 0.0
            || self.height <= 0.0
        {
            return Err(ComicError::InvalidGeometry);
        }
        Ok(self)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Insets {
    pub left: f32,
    pub top: f32,
    pub right: f32,
    pub bottom: f32,
}

impl Insets {
    fn validate(self) -> Result<Self, ComicError> {
        if [self.left, self.top, self.right, self.bottom]
            .iter()
            .any(|value| !value.is_finite() || *value < 0.0)
        {
            return Err(ComicError::InvalidGeometry);
        }
        Ok(self)
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PageSpec {
    pub width_px: u32,
    pub height_px: u32,
    pub dpi: f32,
    pub bleed_px: Insets,
    pub trim: Rect,
    pub safety: Insets,
    pub page_number: u32,
}

impl PageSpec {
    pub fn validate(&self) -> Result<(), ComicError> {
        if self.width_px == 0
            || self.height_px == 0
            || self.width_px > 32_768
            || self.height_px > 32_768
            || !self.dpi.is_finite()
            || self.dpi <= 0.0
        {
            return Err(ComicError::InvalidPageSpec);
        }
        self.bleed_px.validate()?;
        self.safety.validate()?;
        self.trim.validate()?;
        if self.trim.x < 0.0
            || self.trim.y < 0.0
            || self.trim.x + self.trim.width > self.width_px as f32
            || self.trim.y + self.trim.height > self.height_px as f32
        {
            return Err(ComicError::InvalidPageSpec);
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Panel {
    pub id: u128,
    pub shape: PanelShape,
    pub bounds: Rect,
    pub polygon: Vec<(f32, f32)>,
    pub gutter_px: f32,
    pub mask_layer_id: Option<u128>,
}

/// Stable document/layer ownership metadata for a panel. Pixels remain in
/// the page document; this record lets a portable project reconnect the panel
/// group and its conventional child layers after moving between devices.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PanelLayerBinding {
    pub panel_id: u128,
    pub panel_group_id: u128,
    pub mask_layer_id: u128,
    pub sketch_layer_id: u128,
    pub ink_layer_id: u128,
    pub color_layer_id: u128,
    pub tone_layer_id: u128,
    pub effects_layer_id: u128,
}

impl Panel {
    fn validate(&self) -> Result<(), ComicError> {
        self.bounds.validate()?;
        if !self.gutter_px.is_finite() || !(0.0..=4096.0).contains(&self.gutter_px) {
            return Err(ComicError::InvalidGeometry);
        }
        if self.shape == PanelShape::Polygon {
            if self.polygon.len() < 3 || self.polygon.len() > MAX_POLYGON_POINTS {
                return Err(ComicError::InvalidGeometry);
            }
            if self
                .polygon
                .iter()
                .any(|(x, y)| !x.is_finite() || !y.is_finite())
            {
                return Err(ComicError::InvalidGeometry);
            }
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct TextStyle {
    pub font_family: String,
    pub font_size_px: f32,
    pub outline_px: f32,
    pub fill_rgba: [u8; 4],
    pub outline_rgba: [u8; 4],
    pub orientation: TextOrientation,
}

impl Default for TextStyle {
    fn default() -> Self {
        Self {
            font_family: "sans-serif".into(),
            font_size_px: 32.0,
            outline_px: 0.0,
            fill_rgba: [0, 0, 0, 255],
            outline_rgba: [255, 255, 255, 255],
            orientation: TextOrientation::Horizontal,
        }
    }
}

impl TextStyle {
    fn validate(&self) -> Result<(), ComicError> {
        if self.font_family.len() > MAX_MATERIAL_BYTES
            || !self.font_size_px.is_finite()
            || !(1.0..=2048.0).contains(&self.font_size_px)
            || !self.outline_px.is_finite()
            || !(0.0..=256.0).contains(&self.outline_px)
        {
            return Err(ComicError::InvalidTextStyle);
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Balloon {
    pub id: u128,
    pub shape: BalloonShape,
    pub bounds: Rect,
    pub tail: Vec<(f32, f32)>,
    pub text: String,
    pub style: TextStyle,
    pub panel_id: Option<u128>,
}

impl Balloon {
    fn validate(&self) -> Result<(), ComicError> {
        self.bounds.validate()?;
        self.style.validate()?;
        if self.text.len() > MAX_TEXT_BYTES {
            return Err(ComicError::TextTooLong);
        }
        if self.tail.len() > MAX_POLYGON_POINTS
            || self
                .tail
                .iter()
                .any(|(x, y)| !x.is_finite() || !y.is_finite())
        {
            return Err(ComicError::InvalidGeometry);
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ToneLayer {
    pub id: u128,
    pub frequency_lpi: f32,
    pub angle_degrees: f32,
    pub density: f32,
    pub shape: String,
    pub bounds: Rect,
}

impl ToneLayer {
    fn validate(&self) -> Result<(), ComicError> {
        if !self.frequency_lpi.is_finite()
            || !(1.0..=1200.0).contains(&self.frequency_lpi)
            || !self.angle_degrees.is_finite()
            || !self.density.is_finite()
            || !(0.0..=1.0).contains(&self.density)
            || self.shape.is_empty()
            || self.shape.len() > MAX_MATERIAL_BYTES
        {
            return Err(ComicError::InvalidTone);
        }
        self.bounds.validate().map(|_| ())
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct EffectLine {
    pub id: u128,
    pub kind: String,
    pub points: Vec<(f32, f32)>,
    pub width_px: f32,
    pub opacity: f32,
}

impl EffectLine {
    fn validate(&self) -> Result<(), ComicError> {
        if self.kind.is_empty()
            || self.kind.len() > MAX_MATERIAL_BYTES
            || self.points.len() < 2
            || self.points.len() > MAX_POLYGON_POINTS * 8
            || self
                .points
                .iter()
                .any(|(x, y)| !x.is_finite() || !y.is_finite())
            || !self.width_px.is_finite()
            || !(0.1..=4096.0).contains(&self.width_px)
            || !self.opacity.is_finite()
            || !(0.0..=1.0).contains(&self.opacity)
        {
            return Err(ComicError::InvalidEffectLine);
        }
        Ok(())
    }
}

/// A bounded vector-ink stroke used for comic artwork and deterministic
/// structural previews. Raster paint remains owned by the main document
/// engine; these lines are lightweight page-local comic content.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct InkLine {
    pub points: Vec<(f32, f32)>,
    pub width_px: f32,
    pub color_rgba: [u8; 4],
}

impl InkLine {
    fn validate(&self) -> Result<(), ComicError> {
        if self.points.len() < 2
            || self.points.len() > MAX_POLYGON_POINTS * 16
            || self
                .points
                .iter()
                .any(|(x, y)| !x.is_finite() || !y.is_finite())
            || !self.width_px.is_finite()
            || !(0.1..=4096.0).contains(&self.width_px)
        {
            return Err(ComicError::InvalidGeometry);
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MaterialAsset {
    pub id: u128,
    pub name: String,
    pub kind: String,
    pub license: String,
    pub attribution: Option<String>,
    pub source: Option<String>,
}

impl MaterialAsset {
    fn validate(&self) -> Result<(), ComicError> {
        for value in [&self.name, &self.kind, &self.license] {
            if value.is_empty() || value.len() > MAX_MATERIAL_BYTES {
                return Err(ComicError::InvalidMaterial);
            }
        }
        for value in [&self.attribution, &self.source] {
            if value.as_ref().is_some_and(|v| v.len() > MAX_MATERIAL_BYTES) {
                return Err(ComicError::InvalidMaterial);
            }
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Page {
    pub id: u128,
    pub spec: PageSpec,
    pub panels: Vec<Panel>,
    pub balloons: Vec<Balloon>,
    pub tones: Vec<ToneLayer>,
    pub effect_lines: Vec<EffectLine>,
    #[serde(default)]
    pub ink_lines: Vec<InkLine>,
}

/// The page document is kept inside the `.inkproj` container. Paths are
/// generated by Rust and validated, never accepted from an imported project.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PageDocumentRef {
    pub page_id: u128,
    pub document_id: u128,
    pub relative_path: String,
}

impl Page {
    fn validate(&self) -> Result<(), ComicError> {
        self.spec.validate()?;
        if self.panels.len() > MAX_PANELS_PER_PAGE
            || self.balloons.len() > MAX_BALLOONS_PER_PAGE
            || self.tones.len() > MAX_TONE_LAYERS
            || self.effect_lines.len() > MAX_EFFECT_LINES
            || self.ink_lines.len() > MAX_INK_LINES
        {
            return Err(ComicError::LimitExceeded);
        }
        for panel in &self.panels {
            panel.validate()?;
            if !rect_inside_page(self, panel.bounds)
                || (panel.shape == PanelShape::Polygon
                    && !panel
                        .polygon
                        .iter()
                        .all(|(x, y)| point_inside_page(self, *x, *y)))
            {
                return Err(ComicError::InvalidGeometry);
            }
        }
        for balloon in &self.balloons {
            balloon.validate()?;
            if let Some(panel_id) = balloon.panel_id
                && !self.panels.iter().any(|panel| panel.id == panel_id)
            {
                return Err(ComicError::DanglingReference);
            }
        }
        for tone in &self.tones {
            tone.validate()?;
        }
        for effect in &self.effect_lines {
            effect.validate()?;
        }
        for line in &self.ink_lines {
            line.validate()?;
        }
        Ok(())
    }
}

fn rect_inside_page(page: &Page, rect: Rect) -> bool {
    rect.x >= 0.0
        && rect.y >= 0.0
        && rect.x + rect.width <= page.spec.width_px as f32
        && rect.y + rect.height <= page.spec.height_px as f32
}

fn point_inside_page(page: &Page, x: f32, y: f32) -> bool {
    x >= 0.0 && y >= 0.0 && x <= page.spec.width_px as f32 && y <= page.spec.height_px as f32
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ComicProject {
    pub format_version: u16,
    pub id: u128,
    pub template: ProjectTemplate,
    pub title: String,
    pub pages: Vec<Page>,
    pub materials: Vec<MaterialAsset>,
    #[serde(default)]
    pub page_documents: Vec<PageDocumentRef>,
    #[serde(default)]
    pub panel_layers: Vec<PanelLayerBinding>,
}

#[derive(Deserialize)]
struct ComicFormatEnvelope {
    format_version: u16,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DialogueHit {
    pub page_index: usize,
    pub balloon_id: u128,
    pub match_start: usize,
    pub match_end: usize,
}

#[derive(Clone, Debug, PartialEq)]
pub struct WebtoonSegment {
    pub page_index: usize,
    pub segment_index: usize,
    pub source_y: u32,
    pub height_px: u32,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PrintPreviewReport {
    pub page_count: usize,
    pub bleed_safe: bool,
    pub safety_safe: bool,
    pub moire_warnings: Vec<String>,
}

/// Deterministic bounded RGBA preview of one comic page. The preview is a
/// print/layout aid; editable source remains the Rust-owned comic structure.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ComicPreviewImage {
    pub width: u32,
    pub height: u32,
    pub pixels_rgba: Vec<u8>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ComicError {
    InvalidVersion,
    InvalidPageSpec,
    InvalidGeometry,
    CannotRemoveLastPage,
    InvalidTextStyle,
    InvalidTone,
    InvalidEffectLine,
    InvalidMaterial,
    TextTooLong,
    LimitExceeded,
    DanglingReference,
    DuplicateId,
    InvalidPath,
    InvalidJson(String),
}

impl fmt::Display for ComicError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let text = match self {
            Self::InvalidVersion => "unsupported comic project version",
            Self::InvalidPageSpec => "invalid page specification",
            Self::InvalidGeometry => "invalid comic geometry",
            Self::CannotRemoveLastPage => "a comic project must contain at least one page",
            Self::InvalidTextStyle => "invalid text style",
            Self::InvalidTone => "invalid screentone",
            Self::InvalidEffectLine => "invalid effect line",
            Self::InvalidMaterial => "invalid material metadata",
            Self::TextTooLong => "dialogue exceeds the text limit",
            Self::LimitExceeded => "comic project exceeds a safety limit",
            Self::DanglingReference => "comic object references a missing object",
            Self::DuplicateId => "comic IDs must be unique",
            Self::InvalidPath => "comic export path is unsafe",
            Self::InvalidJson(message) => return write!(f, "invalid comic JSON: {message}"),
        };
        f.write_str(text)
    }
}

impl std::error::Error for ComicError {}

impl ComicProject {
    pub fn new(id: u128, template: ProjectTemplate, title: impl Into<String>) -> Self {
        Self {
            format_version: FORMAT_VERSION,
            id,
            template,
            title: title.into(),
            pages: Vec::new(),
            materials: Vec::new(),
            page_documents: Vec::new(),
            panel_layers: Vec::new(),
        }
    }

    pub fn validate(&self) -> Result<(), ComicError> {
        if self.format_version != FORMAT_VERSION
            || self.title.len() > MAX_TEXT_BYTES
            || self.pages.len() > MAX_PAGES
            || self.materials.len() > MAX_MATERIALS
            || self.page_documents.len() != self.pages.len()
        {
            return Err(if self.format_version == FORMAT_VERSION {
                ComicError::LimitExceeded
            } else {
                ComicError::InvalidVersion
            });
        }
        let mut ids = std::collections::HashSet::new();
        for page in &self.pages {
            if !ids.insert(page.id) {
                return Err(ComicError::DuplicateId);
            }
            page.validate()?;
            for panel in &page.panels {
                if !ids.insert(panel.id) {
                    return Err(ComicError::DuplicateId);
                }
            }
            for balloon in &page.balloons {
                if !ids.insert(balloon.id) {
                    return Err(ComicError::DuplicateId);
                }
            }
            for tone in &page.tones {
                if !ids.insert(tone.id) {
                    return Err(ComicError::DuplicateId);
                }
            }
            for effect in &page.effect_lines {
                if !ids.insert(effect.id) {
                    return Err(ComicError::DuplicateId);
                }
            }
        }
        let mut page_ids = std::collections::HashSet::new();
        for page_document in &self.page_documents {
            if !page_ids.insert(page_document.page_id)
                || !self
                    .pages
                    .iter()
                    .any(|page| page.id == page_document.page_id)
                || page_document.document_id == 0
                || page_document.relative_path != format!("pages/{:032x}", page_document.page_id)
            {
                return Err(ComicError::InvalidVersion);
            }
        }
        let mut panel_layer_ids = std::collections::HashSet::new();
        for binding in &self.panel_layers {
            if !self
                .pages
                .iter()
                .flat_map(|page| page.panels.iter())
                .any(|panel| panel.id == binding.panel_id)
            {
                return Err(ComicError::DanglingReference);
            }
            for id in [
                binding.panel_group_id,
                binding.mask_layer_id,
                binding.sketch_layer_id,
                binding.ink_layer_id,
                binding.color_layer_id,
                binding.tone_layer_id,
                binding.effects_layer_id,
            ] {
                if id == 0 || !panel_layer_ids.insert(id) {
                    return Err(ComicError::DuplicateId);
                }
            }
        }
        for material in &self.materials {
            material.validate()?;
            if !ids.insert(material.id) {
                return Err(ComicError::DuplicateId);
            }
        }
        if self.panel_layers.len() > MAX_PANELS_PER_PAGE.saturating_mul(MAX_PAGES) {
            return Err(ComicError::LimitExceeded);
        }
        Ok(())
    }

    pub fn add_page(&mut self, page: Page) -> Result<usize, ComicError> {
        page.validate()?;
        if self.pages.len() >= MAX_PAGES {
            return Err(ComicError::LimitExceeded);
        }
        let mut incoming = std::collections::HashSet::new();
        for id in std::iter::once(page.id)
            .chain(page.panels.iter().map(|item| item.id))
            .chain(page.balloons.iter().map(|item| item.id))
            .chain(page.tones.iter().map(|item| item.id))
            .chain(page.effect_lines.iter().map(|item| item.id))
        {
            if !incoming.insert(id) || self.contains_id(id) {
                return Err(ComicError::DuplicateId);
            }
        }
        let page_id = page.id;
        self.pages.push(page);
        self.page_documents.push(PageDocumentRef {
            page_id,
            document_id: page_id,
            relative_path: format!("pages/{page_id:032x}"),
        });
        self.resequence_pages();
        Ok(self.pages.len() - 1)
    }

    pub fn add_panel(&mut self, page_index: usize, panel: Panel) -> Result<(), ComicError> {
        panel.validate()?;
        if self.contains_id(panel.id) {
            return Err(ComicError::DuplicateId);
        }
        let page = self
            .pages
            .get_mut(page_index)
            .ok_or(ComicError::InvalidGeometry)?;
        if !rect_inside_page(page, panel.bounds)
            || (panel.shape == PanelShape::Polygon
                && !panel
                    .polygon
                    .iter()
                    .all(|(x, y)| point_inside_page(page, *x, *y)))
        {
            return Err(ComicError::InvalidGeometry);
        }
        if page.panels.len() >= MAX_PANELS_PER_PAGE {
            return Err(ComicError::LimitExceeded);
        }
        let panel_id = panel.id;
        page.panels.push(panel);
        self.panel_layers.push(panel_layer_binding(panel_id));
        Ok(())
    }

    pub fn add_balloon(&mut self, page_index: usize, balloon: Balloon) -> Result<(), ComicError> {
        balloon.validate()?;
        if self.contains_id(balloon.id) {
            return Err(ComicError::DuplicateId);
        }
        let page = self
            .pages
            .get_mut(page_index)
            .ok_or(ComicError::InvalidGeometry)?;
        if page.balloons.len() >= MAX_BALLOONS_PER_PAGE {
            return Err(ComicError::LimitExceeded);
        }
        if let Some(panel_id) = balloon.panel_id
            && !page.panels.iter().any(|panel| panel.id == panel_id)
        {
            return Err(ComicError::DanglingReference);
        }
        page.balloons.push(balloon);
        Ok(())
    }

    pub fn add_material(&mut self, material: MaterialAsset) -> Result<(), ComicError> {
        material.validate()?;
        if self.materials.len() >= MAX_MATERIALS {
            return Err(ComicError::LimitExceeded);
        }
        if self.contains_id(material.id) {
            return Err(ComicError::DuplicateId);
        }
        self.materials.push(material);
        Ok(())
    }

    pub fn add_tone(&mut self, page_index: usize, tone: ToneLayer) -> Result<(), ComicError> {
        tone.validate()?;
        if self.contains_id(tone.id) {
            return Err(ComicError::DuplicateId);
        }
        let page = self
            .pages
            .get_mut(page_index)
            .ok_or(ComicError::InvalidGeometry)?;
        if page.tones.len() >= MAX_TONE_LAYERS {
            return Err(ComicError::LimitExceeded);
        }
        page.tones.push(tone);
        Ok(())
    }

    pub fn add_effect_line(
        &mut self,
        page_index: usize,
        effect_line: EffectLine,
    ) -> Result<(), ComicError> {
        effect_line.validate()?;
        if self.contains_id(effect_line.id) {
            return Err(ComicError::DuplicateId);
        }
        let page = self
            .pages
            .get_mut(page_index)
            .ok_or(ComicError::InvalidGeometry)?;
        if page.effect_lines.len() >= MAX_EFFECT_LINES {
            return Err(ComicError::LimitExceeded);
        }
        page.effect_lines.push(effect_line);
        Ok(())
    }

    pub fn set_tone(
        &mut self,
        page_index: usize,
        tone_id: u128,
        tone: ToneLayer,
    ) -> Result<(), ComicError> {
        if tone.id != tone_id {
            return Err(ComicError::InvalidTone);
        }
        tone.validate()?;
        let page = self
            .pages
            .get_mut(page_index)
            .ok_or(ComicError::InvalidGeometry)?;
        let current = page
            .tones
            .iter_mut()
            .find(|candidate| candidate.id == tone_id)
            .ok_or(ComicError::DanglingReference)?;
        *current = tone;
        Ok(())
    }

    pub fn remove_tone(&mut self, page_index: usize, tone_id: u128) -> Result<(), ComicError> {
        let page = self
            .pages
            .get_mut(page_index)
            .ok_or(ComicError::InvalidGeometry)?;
        let before = page.tones.len();
        page.tones.retain(|tone| tone.id != tone_id);
        if before == page.tones.len() {
            return Err(ComicError::DanglingReference);
        }
        Ok(())
    }

    pub fn set_effect_line(
        &mut self,
        page_index: usize,
        effect_id: u128,
        effect_line: EffectLine,
    ) -> Result<(), ComicError> {
        if effect_line.id != effect_id {
            return Err(ComicError::InvalidEffectLine);
        }
        effect_line.validate()?;
        let page = self
            .pages
            .get_mut(page_index)
            .ok_or(ComicError::InvalidGeometry)?;
        let current = page
            .effect_lines
            .iter_mut()
            .find(|candidate| candidate.id == effect_id)
            .ok_or(ComicError::DanglingReference)?;
        *current = effect_line;
        Ok(())
    }

    pub fn remove_effect_line(
        &mut self,
        page_index: usize,
        effect_id: u128,
    ) -> Result<(), ComicError> {
        let page = self
            .pages
            .get_mut(page_index)
            .ok_or(ComicError::InvalidGeometry)?;
        let before = page.effect_lines.len();
        page.effect_lines.retain(|line| line.id != effect_id);
        if before == page.effect_lines.len() {
            return Err(ComicError::DanglingReference);
        }
        Ok(())
    }

    pub fn set_panel_polygon(
        &mut self,
        page_index: usize,
        panel_id: u128,
        polygon: Vec<(f32, f32)>,
    ) -> Result<(), ComicError> {
        if polygon.len() < 3 || polygon.len() > MAX_POLYGON_POINTS {
            return Err(ComicError::InvalidGeometry);
        }
        if polygon
            .iter()
            .any(|(x, y)| !x.is_finite() || !y.is_finite())
        {
            return Err(ComicError::InvalidGeometry);
        }
        let page = self
            .pages
            .get_mut(page_index)
            .ok_or(ComicError::InvalidGeometry)?;
        if !polygon.iter().all(|(x, y)| point_inside_page(page, *x, *y)) {
            return Err(ComicError::InvalidGeometry);
        }
        let panel = page
            .panels
            .iter_mut()
            .find(|panel| panel.id == panel_id)
            .ok_or(ComicError::DanglingReference)?;
        panel.shape = PanelShape::Polygon;
        panel.polygon = polygon;
        Ok(())
    }

    /// Move or resize a rectangular panel without touching any page content.
    /// Polygon panels must use `set_panel_polygon` so their geometry is not
    /// silently discarded by a rectangle edit.
    pub fn set_panel_bounds(
        &mut self,
        page_index: usize,
        panel_id: u128,
        bounds: Rect,
    ) -> Result<(), ComicError> {
        bounds.validate()?;
        let page = self
            .pages
            .get(page_index)
            .ok_or(ComicError::InvalidGeometry)?;
        if !rect_inside_page(page, bounds) {
            return Err(ComicError::InvalidGeometry);
        }
        let page = self
            .pages
            .get_mut(page_index)
            .ok_or(ComicError::InvalidGeometry)?;
        let panel = page
            .panels
            .iter_mut()
            .find(|panel| panel.id == panel_id)
            .ok_or(ComicError::DanglingReference)?;
        if panel.shape != PanelShape::Rectangle {
            return Err(ComicError::InvalidGeometry);
        }
        panel.bounds = bounds;
        Ok(())
    }

    /// Divide a rectangular panel into two editable panels while preserving
    /// the original gutter and the first linked mask. The operation is
    /// bounded and validates all IDs before changing the page.
    pub fn split_panel(
        &mut self,
        page_index: usize,
        panel_id: u128,
        first_id: u128,
        second_id: u128,
        axis: u8,
        ratio: f32,
    ) -> Result<(), ComicError> {
        let second_mask_id = second_id ^ SPLIT_MASK_NAMESPACE;
        if first_id == second_id
            || self.contains_id(first_id)
            || self.contains_id(second_id)
            || self
                .pages
                .iter()
                .flat_map(|page| page.panels.iter())
                .any(|panel| panel.mask_layer_id == Some(second_mask_id))
            || !(0.1..=0.9).contains(&ratio)
            || axis > 1
        {
            return Err(if axis > 1 || !(0.1..=0.9).contains(&ratio) {
                ComicError::InvalidGeometry
            } else {
                ComicError::DuplicateId
            });
        }
        let page = self
            .pages
            .get_mut(page_index)
            .ok_or(ComicError::InvalidGeometry)?;
        let panel_index = page
            .panels
            .iter()
            .position(|panel| panel.id == panel_id)
            .ok_or(ComicError::DanglingReference)?;
        let original = page.panels[panel_index].clone();
        if original.shape != PanelShape::Rectangle {
            return Err(ComicError::InvalidGeometry);
        }
        let gap = original.gutter_px;
        let (first, second) = if axis == 0 {
            let split = original.bounds.width * ratio;
            let first_width = split - gap / 2.0;
            let second_width = original.bounds.width - split - gap / 2.0;
            if first_width <= 0.0 || second_width <= 0.0 {
                return Err(ComicError::InvalidGeometry);
            }
            (
                Panel {
                    id: first_id,
                    shape: PanelShape::Rectangle,
                    bounds: Rect {
                        width: first_width,
                        ..original.bounds
                    },
                    polygon: Vec::new(),
                    gutter_px: gap,
                    mask_layer_id: original.mask_layer_id,
                },
                Panel {
                    id: second_id,
                    shape: PanelShape::Rectangle,
                    bounds: Rect {
                        x: original.bounds.x + split + gap / 2.0,
                        width: second_width,
                        ..original.bounds
                    },
                    polygon: Vec::new(),
                    gutter_px: gap,
                    mask_layer_id: Some(second_mask_id),
                },
            )
        } else {
            let split = original.bounds.height * ratio;
            let first_height = split - gap / 2.0;
            let second_height = original.bounds.height - split - gap / 2.0;
            if first_height <= 0.0 || second_height <= 0.0 {
                return Err(ComicError::InvalidGeometry);
            }
            (
                Panel {
                    id: first_id,
                    shape: PanelShape::Rectangle,
                    bounds: Rect {
                        height: first_height,
                        ..original.bounds
                    },
                    polygon: Vec::new(),
                    gutter_px: gap,
                    mask_layer_id: original.mask_layer_id,
                },
                Panel {
                    id: second_id,
                    shape: PanelShape::Rectangle,
                    bounds: Rect {
                        y: original.bounds.y + split + gap / 2.0,
                        height: second_height,
                        ..original.bounds
                    },
                    polygon: Vec::new(),
                    gutter_px: gap,
                    mask_layer_id: Some(second_mask_id),
                },
            )
        };
        page.panels
            .splice(panel_index..=panel_index, [first, second]);
        // Preserve the original panel's document-layer IDs for the first
        // split half. This keeps already-painted content attached to the
        // first child instead of orphaning it behind the removed panel ID.
        // Projects created from structural metadata only have no binding to
        // preserve, so they receive the deterministic binding as usual.
        if let Some(binding) = self
            .panel_layers
            .iter_mut()
            .find(|binding| binding.panel_id == panel_id)
        {
            binding.panel_id = first_id;
        } else if !self
            .panel_layers
            .iter()
            .any(|binding| binding.panel_id == first_id)
        {
            self.panel_layers.push(panel_layer_binding(first_id));
        }
        self.panel_layers.push(panel_layer_binding(second_id));
        for balloon in &mut page.balloons {
            if balloon.panel_id == Some(panel_id) {
                balloon.panel_id = Some(first_id);
            }
        }
        Ok(())
    }

    pub fn remove_material(&mut self, material_id: u128) -> Result<(), ComicError> {
        let before = self.materials.len();
        self.materials.retain(|material| material.id != material_id);
        if before == self.materials.len() {
            return Err(ComicError::DanglingReference);
        }
        Ok(())
    }

    pub fn reorder_page(&mut self, from: usize, to: usize) -> Result<(), ComicError> {
        if from >= self.pages.len() || to >= self.pages.len() {
            return Err(ComicError::InvalidGeometry);
        }
        let page = self.pages.remove(from);
        self.pages.insert(to, page);
        let document = self.page_documents.remove(from);
        self.page_documents.insert(to, document);
        self.resequence_pages();
        Ok(())
    }

    /// Remove a page and every panel-layer binding owned by that page.
    /// Projects retain at least one page so an active page document always
    /// exists for the canvas and save pipeline.
    pub fn remove_page(&mut self, index: usize) -> Result<Page, ComicError> {
        if index >= self.pages.len() {
            return Err(ComicError::InvalidGeometry);
        }
        if self.pages.len() == 1 {
            return Err(ComicError::CannotRemoveLastPage);
        }
        let page = self.pages.remove(index);
        self.page_documents
            .retain(|document| document.page_id != page.id);
        let removed_panel_ids = page
            .panels
            .iter()
            .map(|panel| panel.id)
            .collect::<std::collections::HashSet<_>>();
        self.panel_layers
            .retain(|binding| !removed_panel_ids.contains(&binding.panel_id));
        self.resequence_pages();
        Ok(page)
    }

    /// Update print-layout metadata without touching panels or page content.
    /// Validation happens before the page is mutated so a rejected layout
    /// leaves the project byte-for-byte unchanged.
    pub fn set_page_layout(
        &mut self,
        page_index: usize,
        dpi: f32,
        bleed_px: Insets,
        trim: Rect,
        safety: Insets,
    ) -> Result<(), ComicError> {
        let page = self
            .pages
            .get(page_index)
            .ok_or(ComicError::InvalidGeometry)?;
        let next = PageSpec {
            width_px: page.spec.width_px,
            height_px: page.spec.height_px,
            dpi,
            bleed_px,
            trim,
            safety,
            page_number: page.spec.page_number,
        };
        next.validate()?;
        if safety.left + safety.right >= trim.width || safety.top + safety.bottom >= trim.height {
            return Err(ComicError::InvalidPageSpec);
        }
        let page = self
            .pages
            .get_mut(page_index)
            .ok_or(ComicError::InvalidGeometry)?;
        page.spec = next;
        Ok(())
    }

    pub fn resize_gutter(
        &mut self,
        page_index: usize,
        panel_id: u128,
        gutter_px: f32,
    ) -> Result<(), ComicError> {
        if !gutter_px.is_finite() || !(0.0..=4096.0).contains(&gutter_px) {
            return Err(ComicError::InvalidGeometry);
        }
        let page = self
            .pages
            .get_mut(page_index)
            .ok_or(ComicError::InvalidGeometry)?;
        let panel = page
            .panels
            .iter_mut()
            .find(|panel| panel.id == panel_id)
            .ok_or(ComicError::DanglingReference)?;
        panel.gutter_px = gutter_px;
        Ok(())
    }

    pub fn set_dialogue(
        &mut self,
        page_index: usize,
        balloon_id: u128,
        text: String,
    ) -> Result<(), ComicError> {
        if text.len() > MAX_TEXT_BYTES {
            return Err(ComicError::TextTooLong);
        }
        let page = self
            .pages
            .get_mut(page_index)
            .ok_or(ComicError::InvalidGeometry)?;
        let balloon = page
            .balloons
            .iter_mut()
            .find(|balloon| balloon.id == balloon_id)
            .ok_or(ComicError::DanglingReference)?;
        balloon.text = text;
        Ok(())
    }

    pub fn set_balloon_tail(
        &mut self,
        page_index: usize,
        balloon_id: u128,
        tail: Vec<(f32, f32)>,
    ) -> Result<(), ComicError> {
        if tail.len() > MAX_POLYGON_POINTS
            || tail.iter().any(|(x, y)| !x.is_finite() || !y.is_finite())
        {
            return Err(ComicError::InvalidGeometry);
        }
        let page = self
            .pages
            .get_mut(page_index)
            .ok_or(ComicError::InvalidGeometry)?;
        let balloon = page
            .balloons
            .iter_mut()
            .find(|balloon| balloon.id == balloon_id)
            .ok_or(ComicError::DanglingReference)?;
        balloon.tail = tail;
        Ok(())
    }

    pub fn set_balloon_style(
        &mut self,
        page_index: usize,
        balloon_id: u128,
        style: TextStyle,
    ) -> Result<(), ComicError> {
        style.validate()?;
        let page = self
            .pages
            .get_mut(page_index)
            .ok_or(ComicError::InvalidGeometry)?;
        let balloon = page
            .balloons
            .iter_mut()
            .find(|balloon| balloon.id == balloon_id)
            .ok_or(ComicError::DanglingReference)?;
        balloon.style = style;
        Ok(())
    }

    pub fn search_dialogue(&self, query: &str) -> Vec<DialogueHit> {
        if query.is_empty() {
            return Vec::new();
        }
        let folded = query.to_lowercase();
        self.pages
            .iter()
            .enumerate()
            .flat_map(|(page_index, page)| {
                let folded = folded.clone();
                page.balloons.iter().filter_map(move |balloon| {
                    let text = balloon.text.to_lowercase();
                    text.find(&folded).map(|start| DialogueHit {
                        page_index,
                        balloon_id: balloon.id,
                        match_start: start,
                        match_end: start + folded.len(),
                    })
                })
            })
            .collect()
    }

    pub fn webtoon_segments(
        &self,
        page_index: usize,
        max_height_px: u32,
    ) -> Result<Vec<WebtoonSegment>, ComicError> {
        if max_height_px == 0 || max_height_px > 32_768 {
            return Err(ComicError::InvalidPageSpec);
        }
        let page = self
            .pages
            .get(page_index)
            .ok_or(ComicError::InvalidGeometry)?;
        let count = page.spec.height_px.div_ceil(max_height_px) as usize;
        if count > MAX_EXPORT_SEGMENTS {
            return Err(ComicError::LimitExceeded);
        }
        Ok((0..count)
            .map(|segment_index| WebtoonSegment {
                page_index,
                segment_index,
                source_y: (segment_index as u32) * max_height_px,
                height_px: max_height_px
                    .min(page.spec.height_px - (segment_index as u32) * max_height_px),
            })
            .collect())
    }

    pub fn export_manifest(&self, destination: &Path) -> Result<(), ComicError> {
        self.validate()?;
        if destination.as_os_str().is_empty()
            || destination
                .components()
                .any(|component| matches!(component, std::path::Component::ParentDir))
        {
            return Err(ComicError::InvalidPath);
        }
        let bytes = serde_json::to_vec_pretty(self)
            .map_err(|error| ComicError::InvalidJson(error.to_string()))?;
        std::fs::write(destination, bytes).map_err(|_| ComicError::InvalidPath)
    }

    pub fn batch_export_page_manifests(&self, directory: &Path) -> Result<usize, ComicError> {
        self.validate()?;
        if directory.as_os_str().is_empty()
            || directory
                .components()
                .any(|component| matches!(component, std::path::Component::ParentDir))
        {
            return Err(ComicError::InvalidPath);
        }
        std::fs::create_dir_all(directory).map_err(|_| ComicError::InvalidPath)?;
        for (index, page) in self.pages.iter().enumerate() {
            let name = format!("page-{:04}.json", index + 1);
            let destination = directory.join(name);
            let bytes = serde_json::to_vec_pretty(page)
                .map_err(|error| ComicError::InvalidJson(error.to_string()))?;
            let temporary = destination.with_extension("json.tmp");
            std::fs::write(&temporary, bytes).map_err(|_| ComicError::InvalidPath)?;
            std::fs::rename(&temporary, &destination).map_err(|_| ComicError::InvalidPath)?;
        }
        Ok(self.pages.len())
    }

    /// Export each page as a self-contained, editable SVG. Structural objects
    /// are rendered directly so a comic can be reviewed or shared even when
    /// its raster tiles are still being edited in the drawing document.
    pub fn batch_export_page_svgs(&self, directory: &Path) -> Result<usize, ComicError> {
        self.validate()?;
        validate_export_directory(directory)?;
        std::fs::create_dir_all(directory).map_err(|_| ComicError::InvalidPath)?;
        for (index, _page) in self.pages.iter().enumerate() {
            let name = format!("page-{:04}.svg", index + 1);
            let destination = directory.join(name);
            let temporary = destination.with_extension("svg.tmp");
            let bytes = self.page_svg(index)?;
            std::fs::write(&temporary, bytes).map_err(|_| ComicError::InvalidPath)?;
            std::fs::rename(&temporary, &destination).map_err(|_| ComicError::InvalidPath)?;
        }
        Ok(self.pages.len())
    }

    /// Export long-canvas pages as independently viewable SVG segments. The
    /// original page coordinates remain intact inside each cropped viewBox,
    /// so no panel, balloon, or tone geometry is repainted or re-authored.
    pub fn batch_export_webtoon_segments(
        &self,
        directory: &Path,
        max_height_px: u32,
    ) -> Result<usize, ComicError> {
        self.validate()?;
        validate_export_directory(directory)?;
        if max_height_px == 0 || max_height_px > 32_768 {
            return Err(ComicError::InvalidPageSpec);
        }
        std::fs::create_dir_all(directory).map_err(|_| ComicError::InvalidPath)?;
        let mut exported = 0usize;
        for page_index in 0..self.pages.len() {
            for segment in self.webtoon_segments(page_index, max_height_px)? {
                let name = format!(
                    "page-{:04}-segment-{:04}.svg",
                    page_index + 1,
                    segment.segment_index + 1
                );
                let destination = directory.join(name);
                let temporary = destination.with_extension("svg.tmp");
                let bytes =
                    self.page_svg_segment(page_index, segment.source_y, segment.height_px)?;
                std::fs::write(&temporary, bytes).map_err(|_| ComicError::InvalidPath)?;
                std::fs::rename(&temporary, &destination).map_err(|_| ComicError::InvalidPath)?;
                exported = exported.saturating_add(1);
            }
        }
        Ok(exported)
    }

    /// Export one page as a self-contained SVG for preview or downstream
    /// layout tools. No external fonts, images, URLs, or scripts are emitted.
    pub fn export_page_svg(&self, page_index: usize, destination: &Path) -> Result<(), ComicError> {
        self.validate()?;
        validate_export_file(destination)?;
        let bytes = self.page_svg(page_index)?;
        let temporary = destination.with_extension("svg.tmp");
        std::fs::write(&temporary, bytes).map_err(|_| ComicError::InvalidPath)?;
        std::fs::rename(&temporary, destination).map_err(|_| ComicError::InvalidPath)
    }

    pub fn print_preview_report(&self) -> Result<PrintPreviewReport, ComicError> {
        self.validate()?;
        let mut warnings = Vec::new();
        for (page_index, page) in self.pages.iter().enumerate() {
            for tone in &page.tones {
                if tone.frequency_lpi > page.spec.dpi / 2.0 {
                    warnings.push(format!(
                        "page {} tone {} LPI may moiré at {} DPI",
                        page_index + 1,
                        tone.frequency_lpi,
                        page.spec.dpi
                    ));
                }
            }
        }
        Ok(PrintPreviewReport {
            page_count: self.pages.len(),
            bleed_safe: self.pages.iter().all(|page| {
                page.spec.trim.x >= page.spec.bleed_px.left
                    && page.spec.trim.y >= page.spec.bleed_px.top
                    && page.spec.trim.x + page.spec.trim.width
                        <= page.spec.width_px as f32 - page.spec.bleed_px.right
                    && page.spec.trim.y + page.spec.trim.height
                        <= page.spec.height_px as f32 - page.spec.bleed_px.bottom
            }),
            safety_safe: self.pages.iter().all(|page| {
                page.spec.safety.left + page.spec.safety.right < page.spec.trim.width
                    && page.spec.safety.top + page.spec.safety.bottom < page.spec.trim.height
            }),
            moire_warnings: warnings,
        })
    }

    /// Rasterize the bounded page structure for print-preview inspection.
    /// Coordinates are scaled uniformly and all drawing work is capped by the
    /// output dimensions; no external fonts, files, or network resources are
    /// consulted.
    pub fn render_page_preview(
        &self,
        page_index: usize,
        max_dimension: u32,
    ) -> Result<ComicPreviewImage, ComicError> {
        self.validate()?;
        if !(64..=4096).contains(&max_dimension) {
            return Err(ComicError::InvalidPageSpec);
        }
        let page = self
            .pages
            .get(page_index)
            .ok_or(ComicError::InvalidGeometry)?;
        let largest = page.spec.width_px.max(page.spec.height_px).max(1) as f32;
        let scale = (max_dimension as f32 / largest).min(1.0);
        let width = preview_dimension(page.spec.width_px, scale);
        let height = preview_dimension(page.spec.height_px, scale);
        let pixel_count = usize::try_from(width)
            .ok()
            .and_then(|w| usize::try_from(height).ok().and_then(|h| w.checked_mul(h)))
            .ok_or(ComicError::LimitExceeded)?;
        if pixel_count > 16 * 1024 * 1024 {
            return Err(ComicError::LimitExceeded);
        }
        let mut pixels = vec![255_u8; pixel_count * 4];
        for alpha in (3..pixels.len()).step_by(4) {
            pixels[alpha] = 255;
        }
        let blue = [37, 99, 235, 220];
        let orange = [217, 119, 6, 220];
        draw_rect_outline(&mut pixels, width, height, page.spec.trim, scale, blue, 2.0);
        draw_rect_outline(
            &mut pixels,
            width,
            height,
            Rect {
                x: page.spec.trim.x + page.spec.safety.left,
                y: page.spec.trim.y + page.spec.safety.top,
                width: page.spec.trim.width - page.spec.safety.left - page.spec.safety.right,
                height: page.spec.trim.height - page.spec.safety.top - page.spec.safety.bottom,
            },
            scale,
            orange,
            2.0,
        );
        for panel in &page.panels {
            if panel.shape == PanelShape::Polygon && panel.polygon.len() >= 3 {
                draw_polygon_outline(
                    &mut pixels,
                    width,
                    height,
                    &panel.polygon,
                    scale,
                    [29, 78, 121, 255],
                    panel.gutter_px,
                );
            } else {
                draw_rect_outline(
                    &mut pixels,
                    width,
                    height,
                    panel.bounds,
                    scale,
                    [29, 78, 121, 255],
                    panel.gutter_px,
                );
            }
        }
        for line in &page.ink_lines {
            draw_polyline(
                &mut pixels,
                width,
                height,
                &line.points,
                scale,
                line.color_rgba,
                line.width_px,
            );
        }
        for tone in &page.tones {
            draw_tone(&mut pixels, width, height, tone, scale, page.spec.dpi);
        }
        for effect in &page.effect_lines {
            draw_polyline(
                &mut pixels,
                width,
                height,
                &effect.points,
                scale,
                [17, 24, 39, preview_alpha(effect.opacity, 255.0)],
                effect.width_px,
            );
        }
        for balloon in &page.balloons {
            draw_polyline(
                &mut pixels,
                width,
                height,
                &balloon.tail,
                scale,
                [17, 17, 17, 255],
                balloon.style.outline_px.max(3.0),
            );
            match balloon.shape {
                BalloonShape::Thought => draw_thought_outline(
                    &mut pixels,
                    width,
                    height,
                    balloon.bounds,
                    scale,
                    balloon.style.outline_px.max(2.0),
                ),
                BalloonShape::Burst => draw_burst_outline(
                    &mut pixels,
                    width,
                    height,
                    balloon.bounds,
                    scale,
                    balloon.style.outline_px.max(2.0),
                ),
                _ => draw_ellipse_outline(
                    &mut pixels,
                    width,
                    height,
                    balloon.bounds,
                    scale,
                    [17, 17, 17, 255],
                    balloon.style.outline_px.max(2.0),
                ),
            }
            draw_text_stub(
                &mut pixels,
                width,
                height,
                balloon.bounds,
                balloon.text.len(),
                scale,
            );
        }
        Ok(ComicPreviewImage {
            width,
            height,
            pixels_rgba: pixels,
        })
    }

    pub fn to_json(&self) -> Result<Vec<u8>, ComicError> {
        self.validate()?;
        serde_json::to_vec(self).map_err(|error| ComicError::InvalidJson(error.to_string()))
    }

    /// Return a deterministic digest of the validated structure and every
    /// SVG/raster page projection. Devices can compare this after a transfer
    /// without relying on platform font caches or filesystem ordering.
    pub fn portable_render_digest(&self) -> Result<[u8; 32], ComicError> {
        let mut digest = Sha256::new();
        digest.update(self.to_json()?);
        for page_index in 0..self.pages.len() {
            digest.update(self.page_svg(page_index)?);
            let preview = self.render_page_preview(page_index, 1024)?;
            digest.update(preview.width.to_le_bytes());
            digest.update(preview.height.to_le_bytes());
            digest.update(preview.pixels_rgba);
        }
        Ok(digest.finalize().into())
    }

    pub fn from_json(bytes: &[u8]) -> Result<Self, ComicError> {
        if bytes.len() > 64 * 1024 * 1024 {
            return Err(ComicError::LimitExceeded);
        }
        // Read only the small version envelope first.  Deserializing the
        // complete project directly is important: routing it through
        // `serde_json::Value` would coerce UUID-sized u128 IDs to f64 on
        // serde_json builds without arbitrary-precision numbers.
        let envelope: ComicFormatEnvelope = serde_json::from_slice(bytes)
            .map_err(|error| ComicError::InvalidJson(error.to_string()))?;
        if envelope.format_version != 1 && envelope.format_version != FORMAT_VERSION {
            return Err(ComicError::InvalidVersion);
        }
        let mut project: Self = serde_json::from_slice(bytes)
            .map_err(|error| ComicError::InvalidJson(error.to_string()))?;
        if envelope.format_version == 1 {
            project.format_version = FORMAT_VERSION;
            project.page_documents = project
                .pages
                .iter()
                .map(|page| PageDocumentRef {
                    page_id: page.id,
                    document_id: page.id,
                    relative_path: format!("pages/{:032x}", page.id),
                })
                .collect();
            project.panel_layers = project
                .pages
                .iter()
                .flat_map(|page| {
                    page.panels
                        .iter()
                        .map(|panel| panel_layer_binding(panel.id))
                })
                .collect();
        }
        project.validate()?;
        Ok(project)
    }

    fn resequence_pages(&mut self) {
        for (index, page) in self.pages.iter_mut().enumerate() {
            page.spec.page_number = (index + 1) as u32;
        }
    }

    fn contains_id(&self, id: u128) -> bool {
        self.pages.iter().any(|page| {
            page.id == id
                || page.panels.iter().any(|panel| panel.id == id)
                || page.balloons.iter().any(|balloon| balloon.id == id)
                || page.tones.iter().any(|tone| tone.id == id)
                || page.effect_lines.iter().any(|effect| effect.id == id)
        }) || self.materials.iter().any(|material| material.id == id)
    }

    fn page_svg(&self, page_index: usize) -> Result<Vec<u8>, ComicError> {
        self.page_svg_with_artwork(page_index, None)
    }

    /// Render a self-contained page SVG with the actual page-document PNG
    /// beneath editable comic structure. The embedded raster is bounded so
    /// imported or malformed projects cannot create unbounded SVG output.
    pub fn page_svg_with_raster_artwork(
        &self,
        page_index: usize,
        artwork_png: &[u8],
    ) -> Result<Vec<u8>, ComicError> {
        if artwork_png.is_empty() || artwork_png.len() > 128 * 1024 * 1024 {
            return Err(ComicError::LimitExceeded);
        }
        self.page_svg_with_artwork(page_index, Some(artwork_png))
    }

    fn page_svg_with_artwork(
        &self,
        page_index: usize,
        artwork_png: Option<&[u8]>,
    ) -> Result<Vec<u8>, ComicError> {
        let page = self
            .pages
            .get(page_index)
            .ok_or(ComicError::InvalidGeometry)?;
        let width = page.spec.width_px;
        let height = page.spec.height_px;
        let mut svg = String::with_capacity(4096);
        writeln!(
            svg,
            r#"<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" data-project-ink-page="{}">"#,
            page.spec.page_number
        )
        .map_err(|_| ComicError::InvalidJson("SVG formatting failed".into()))?;
        if let Some(artwork_png) = artwork_png {
            let encoded = base64::engine::general_purpose::STANDARD.encode(artwork_png);
            writeln!(
                svg,
                r#"<image width="{width}" height="{height}" href="data:image/png;base64,{encoded}" data-page-artwork="true"/>"#
            )
            .map_err(|_| ComicError::InvalidJson("SVG formatting failed".into()))?;
        } else {
            svg.push_str("<rect width=\"100%\" height=\"100%\" fill=\"white\"/>\n");
        }
        for (tone_index, tone) in page.tones.iter().enumerate() {
            let size = (page.spec.dpi / tone.frequency_lpi.max(1.0)).clamp(1.0, 100.0);
            writeln!(
                svg,
                r#"<defs><pattern id="tone-{page_index}-{tone_index}" width="{size:.3}" height="{size:.3}" patternUnits="userSpaceOnUse" patternTransform="rotate({angle:.3})"><circle cx="{radius:.3}" cy="{radius:.3}" r="{radius:.3}" fill="black" fill-opacity="{density:.3}"/></pattern></defs>"#,
                page_index = page_index + 1,
                tone_index = tone_index + 1,
                size = size,
                angle = tone.angle_degrees,
                radius = size / 2.0,
                density = tone.density
            )
            .map_err(|_| ComicError::InvalidJson("SVG formatting failed".into()))?;
            let r = tone.bounds;
            writeln!(
                svg,
                r#"<rect x="{x:.3}" y="{y:.3}" width="{w:.3}" height="{h:.3}" fill="url(#tone-{page_index}-{tone_index})" data-tone-shape="{shape}"/>"#,
                x = r.x,
                y = r.y,
                w = r.width,
                h = r.height,
                page_index = page_index + 1,
                tone_index = tone_index + 1,
                shape = escape_xml(&tone.shape)
            )
            .map_err(|_| ComicError::InvalidJson("SVG formatting failed".into()))?;
        }
        for panel in &page.panels {
            let r = panel.bounds;
            let mask = panel
                .mask_layer_id
                .map_or_else(String::new, |id| format!(r#" data-mask-layer="{id}""#));
            if panel.shape == PanelShape::Polygon && !panel.polygon.is_empty() {
                let points = panel
                    .polygon
                    .iter()
                    .map(|(x, y)| format!("{x:.3},{y:.3}"))
                    .collect::<Vec<_>>()
                    .join(" ");
                writeln!(
                    svg,
                    r##"<polygon points="{points}" fill="none" stroke="#111" stroke-width="{gutter:.3}"{mask}/>"##,
                    gutter = panel.gutter_px.max(1.0),
                    mask = mask
                )
                .map_err(|_| ComicError::InvalidJson("SVG formatting failed".into()))?;
            } else {
                writeln!(
                    svg,
                    r##"<rect x="{x:.3}" y="{y:.3}" width="{w:.3}" height="{h:.3}" fill="none" stroke="#111" stroke-width="{gutter:.3}"{mask}/>"##,
                    x = r.x,
                    y = r.y,
                    w = r.width,
                    h = r.height,
                    gutter = panel.gutter_px.max(1.0),
                    mask = mask
                )
                .map_err(|_| ComicError::InvalidJson("SVG formatting failed".into()))?;
            }
        }
        for line in &page.ink_lines {
            let points = line
                .points
                .iter()
                .map(|(x, y)| format!("{x:.3},{y:.3}"))
                .collect::<Vec<_>>()
                .join(" ");
            writeln!(
                svg,
                r##"<polyline points="{points}" fill="none" stroke="#{r:02x}{g:02x}{b:02x}" stroke-width="{width:.3}" stroke-opacity="{opacity:.3}" data-ink-line="true"/>"##,
                points = points,
                r = line.color_rgba[0],
                g = line.color_rgba[1],
                b = line.color_rgba[2],
                width = line.width_px,
                opacity = f32::from(line.color_rgba[3]) / 255.0,
            )
            .map_err(|_| ComicError::InvalidJson("SVG formatting failed".into()))?;
        }
        for balloon in &page.balloons {
            let r = balloon.bounds;
            let text_style = &balloon.style;
            let tail_points = balloon
                .tail
                .iter()
                .map(|(x, y)| format!("{x:.3},{y:.3}"))
                .collect::<Vec<_>>()
                .join(" ");
            if !tail_points.is_empty() {
                writeln!(
                    svg,
                    r##"<polyline points="{tail_points}" fill="none" stroke="#111" stroke-width="{width:.3}" data-balloon-tail="{id}"/>"##,
                    tail_points = tail_points,
                    width = text_style.outline_px.max(2.0),
                    id = balloon.id
                )
                .map_err(|_| ComicError::InvalidJson("SVG formatting failed".into()))?;
            }
            let text_outline = if text_style.outline_px > 0.0 {
                format!(
                    r##" stroke="#{:02x}{:02x}{:02x}" stroke-width="{:.3}" paint-order="stroke""##,
                    text_style.outline_rgba[0],
                    text_style.outline_rgba[1],
                    text_style.outline_rgba[2],
                    text_style.outline_px
                )
            } else {
                String::new()
            };
            let orientation = if text_style.orientation == TextOrientation::Vertical {
                r#" writing-mode="tb" glyph-orientation-vertical="0""#
            } else {
                ""
            };
            let centered_text = balloon.shape != BalloonShape::Narration;
            let text_x = if centered_text {
                r.x + r.width / 2.0
            } else {
                r.x + text_style.font_size_px
            };
            let text_center_y = if centered_text {
                r.y + r.height / 2.0 + text_style.font_size_px / 3.0
            } else {
                r.y + text_style.font_size_px * 1.4
            };
            let (text_markup, text_y, text_font_size) = svg_text_content(
                &balloon.text,
                SvgTextBox {
                    x: text_x,
                    center_y: text_center_y,
                    font_size: text_style.font_size_px,
                    max_width: (r.width - text_style.font_size_px * 2.0)
                        .max(text_style.font_size_px),
                    max_height: (r.height - text_style.font_size_px * 2.0)
                        .max(text_style.font_size_px),
                    centered: centered_text,
                    vertical: text_style.orientation == TextOrientation::Vertical,
                },
            );
            if balloon.shape == BalloonShape::Narration {
                writeln!(
                    svg,
                    r##"<rect x="{x:.3}" y="{y:.3}" width="{w:.3}" height="{h:.3}" rx="{radius:.3}" fill="#fff" stroke="#111" data-balloon-shape="narration"/><text x="{tx:.3}" y="{ty:.3}" font-family="{font}" font-size="{size:.3}" fill="#{fill:02x}{fill_g:02x}{fill_b:02x}"{text_outline}{orientation}>{text}</text>"##,
                    x = r.x,
                    y = r.y,
                    w = r.width,
                    h = r.height,
                    radius = (r.height / 8.0).max(2.0),
                    tx = r.x + text_style.font_size_px,
                    ty = text_y,
                    font = escape_xml(&text_style.font_family),
                    size = text_font_size,
                    fill = text_style.fill_rgba[0],
                    fill_g = text_style.fill_rgba[1],
                    fill_b = text_style.fill_rgba[2],
                    text_outline = text_outline,
                    orientation = orientation,
                    text = text_markup
                )
            } else if balloon.shape == BalloonShape::Thought {
                let bubble_one_x = r.x + r.width * 0.24;
                let bubble_one_y = r.y + r.height * 1.02;
                let bubble_two_x = r.x + r.width * 0.14;
                let bubble_two_y = r.y + r.height * 1.12;
                writeln!(
                    svg,
                    r##"<ellipse cx="{cx:.3}" cy="{cy:.3}" rx="{rx:.3}" ry="{ry:.3}" fill="#fff" stroke="#111" data-balloon-shape="thought"/><circle cx="{bubble_one_x:.3}" cy="{bubble_one_y:.3}" r="{bubble_one_r:.3}" fill="#fff" stroke="#111"/><circle cx="{bubble_two_x:.3}" cy="{bubble_two_y:.3}" r="{bubble_two_r:.3}" fill="#fff" stroke="#111"/><text x="{tx:.3}" y="{ty:.3}" text-anchor="middle" font-family="{font}" font-size="{size:.3}" fill="#{fill:02x}{fill_g:02x}{fill_b:02x}"{text_outline}{orientation}>{text}</text>"##,
                    cx = r.x + r.width / 2.0,
                    cy = r.y + r.height / 2.0,
                    rx = r.width / 2.0,
                    ry = r.height / 2.0,
                    bubble_one_x = bubble_one_x,
                    bubble_one_y = bubble_one_y,
                    bubble_one_r = (r.width.min(r.height) * 0.07).max(4.0),
                    bubble_two_x = bubble_two_x,
                    bubble_two_y = bubble_two_y,
                    bubble_two_r = (r.width.min(r.height) * 0.045).max(3.0),
                    tx = r.x + r.width / 2.0,
                    ty = text_y,
                    font = escape_xml(&text_style.font_family),
                    size = text_font_size,
                    fill = text_style.fill_rgba[0],
                    fill_g = text_style.fill_rgba[1],
                    fill_b = text_style.fill_rgba[2],
                    text_outline = text_outline,
                    orientation = orientation,
                    text = text_markup
                )
            } else if balloon.shape == BalloonShape::Burst {
                let points = burst_points(r)
                    .into_iter()
                    .map(|(x, y)| format!("{x:.3},{y:.3}"))
                    .collect::<Vec<_>>()
                    .join(" ");
                writeln!(
                    svg,
                    r##"<polygon points="{points}" fill="#fff" stroke="#111" data-balloon-shape="burst"/><text x="{tx:.3}" y="{ty:.3}" text-anchor="middle" font-family="{font}" font-size="{size:.3}" fill="#{fill:02x}{fill_g:02x}{fill_b:02x}"{text_outline}{orientation}>{text}</text>"##,
                    points = points,
                    tx = r.x + r.width / 2.0,
                    ty = text_y,
                    font = escape_xml(&text_style.font_family),
                    size = text_font_size,
                    fill = text_style.fill_rgba[0],
                    fill_g = text_style.fill_rgba[1],
                    fill_b = text_style.fill_rgba[2],
                    text_outline = text_outline,
                    orientation = orientation,
                    text = text_markup
                )
            } else {
                writeln!(
                    svg,
                    r##"<ellipse cx="{cx:.3}" cy="{cy:.3}" rx="{rx:.3}" ry="{ry:.3}" fill="#fff" stroke="#111" data-balloon-shape="{shape}"/><text x="{tx:.3}" y="{ty:.3}" text-anchor="middle" font-family="{font}" font-size="{size:.3}" fill="#{fill:02x}{fill_g:02x}{fill_b:02x}"{text_outline}{orientation}>{text}</text>"##,
                    cx = r.x + r.width / 2.0,
                    cy = r.y + r.height / 2.0,
                    rx = r.width / 2.0,
                    ry = r.height / 2.0,
                    tx = r.x + r.width / 2.0,
                    ty = text_y,
                    font = escape_xml(&text_style.font_family),
                    size = text_font_size,
                    fill = text_style.fill_rgba[0],
                    fill_g = text_style.fill_rgba[1],
                    fill_b = text_style.fill_rgba[2],
                    shape = match balloon.shape {
                        BalloonShape::Oval => "oval",
                        BalloonShape::Thought => "thought",
                        BalloonShape::Burst => "burst",
                        BalloonShape::Narration => "narration",
                    },
                    text_outline = text_outline,
                    orientation = orientation,
                    text = text_markup
                )
            }
            .map_err(|_| ComicError::InvalidJson("SVG formatting failed".into()))?;
        }
        for effect in &page.effect_lines {
            let points = effect
                .points
                .iter()
                .map(|(x, y)| format!("{x:.3},{y:.3}"))
                .collect::<Vec<_>>()
                .join(" ");
            writeln!(
                svg,
                r##"<polyline points="{points}" fill="none" stroke="#111" stroke-width="{width:.3}" stroke-opacity="{opacity:.3}" data-effect-kind="{kind}"/>"##,
                width = effect.width_px,
                opacity = effect.opacity,
                kind = escape_xml(&effect.kind),
                points = points
            )
            .map_err(|_| ComicError::InvalidJson("SVG formatting failed".into()))?;
        }
        svg.push_str("</svg>\n");
        Ok(svg.into_bytes())
    }

    fn page_svg_segment(
        &self,
        page_index: usize,
        source_y: u32,
        height_px: u32,
    ) -> Result<Vec<u8>, ComicError> {
        let page = self
            .pages
            .get(page_index)
            .ok_or(ComicError::InvalidGeometry)?;
        if source_y >= page.spec.height_px || height_px == 0 {
            return Err(ComicError::InvalidPageSpec);
        }
        let height_px = height_px.min(page.spec.height_px - source_y);
        let bytes = self.page_svg(page_index)?;
        let mut svg = String::from_utf8(bytes)
            .map_err(|_| ComicError::InvalidJson("SVG is not UTF-8".into()))?;
        let marker = format!(
            r#"height="{}" viewBox="0 0 {} {}""#,
            page.spec.height_px, page.spec.width_px, page.spec.height_px
        );
        let replacement = format!(
            r#"height="{}" viewBox="0 {} {} {}" data-segment-y="{}""#,
            height_px, source_y, page.spec.width_px, height_px, source_y
        );
        if svg.matches(&marker).count() != 1 {
            return Err(ComicError::InvalidJson("SVG root marker missing".into()));
        }
        svg = svg.replacen(&marker, &replacement, 1);
        Ok(svg.into_bytes())
    }
}

fn preview_dimension(value: u32, scale: f32) -> u32 {
    let scaled = (f64::from(value) * f64::from(scale)).ceil();
    if !scaled.is_finite() {
        return 1;
    }
    // `scale` is bounded by the caller and the result is clamped before this
    // conversion, so the value is always in the safe u32 range.
    #[allow(clippy::cast_sign_loss)]
    let bounded = scaled.clamp(1.0, 4096.0) as u32;
    bounded.max(1)
}

#[allow(clippy::cast_sign_loss)]
fn preview_alpha(value: f32, maximum: f32) -> u8 {
    if !value.is_finite() || !maximum.is_finite() || maximum <= 0.0 {
        return 0;
    }
    value.clamp(0.0, 1.0).mul_add(maximum, 0.0).round() as u8
}

fn blend_preview_pixel(pixels: &mut [u8], width: u32, height: u32, x: i32, y: i32, color: [u8; 4]) {
    if x < 0 || y < 0 {
        return;
    }
    let (Ok(x), Ok(y)) = (usize::try_from(x), usize::try_from(y)) else {
        return;
    };
    let (Ok(width), Ok(height)) = (usize::try_from(width), usize::try_from(height)) else {
        return;
    };
    if x >= width || y >= height {
        return;
    }
    let index = (y * width + x) * 4;
    let source_alpha = u32::from(color[3]);
    let inverse = 255_u32.saturating_sub(source_alpha);
    for channel in 0..3 {
        pixels[index + channel] = ((u32::from(color[channel]) * source_alpha
            + u32::from(pixels[index + channel]) * inverse
            + 127)
            / 255) as u8;
    }
    pixels[index + 3] = (source_alpha + u32::from(pixels[index + 3]) * inverse / 255) as u8;
}

fn preview_point(x: f32, y: f32, scale: f32) -> (i32, i32) {
    ((x * scale).round() as i32, (y * scale).round() as i32)
}

fn draw_preview_line(
    pixels: &mut [u8],
    width: u32,
    height: u32,
    start: (i32, i32),
    end: (i32, i32),
    color: [u8; 4],
    width_px: f32,
) {
    let dx = (end.0 - start.0).abs();
    let sx = if start.0 < end.0 { 1 } else { -1 };
    let dy = -(end.1 - start.1).abs();
    let sy = if start.1 < end.1 { 1 } else { -1 };
    let mut error = dx + dy;
    let radius = (width_px.round() as i32 / 2).clamp(0, 32);
    let mut x = start.0;
    let mut y = start.1;
    loop {
        for offset_y in -radius..=radius {
            for offset_x in -radius..=radius {
                blend_preview_pixel(pixels, width, height, x + offset_x, y + offset_y, color);
            }
        }
        if x == end.0 && y == end.1 {
            break;
        }
        let twice = 2 * error;
        if twice >= dy {
            error += dy;
            x += sx;
        }
        if twice <= dx {
            error += dx;
            y += sy;
        }
    }
}

fn draw_rect_outline(
    pixels: &mut [u8],
    width: u32,
    height: u32,
    rect: Rect,
    scale: f32,
    color: [u8; 4],
    stroke: f32,
) {
    let points = [
        preview_point(rect.x, rect.y, scale),
        preview_point(rect.x + rect.width, rect.y, scale),
        preview_point(rect.x + rect.width, rect.y + rect.height, scale),
        preview_point(rect.x, rect.y + rect.height, scale),
    ];
    for index in 0..points.len() {
        draw_preview_line(
            pixels,
            width,
            height,
            points[index],
            points[(index + 1) % points.len()],
            color,
            (stroke * scale).max(1.0),
        );
    }
}

fn draw_polygon_outline(
    pixels: &mut [u8],
    width: u32,
    height: u32,
    points: &[(f32, f32)],
    scale: f32,
    color: [u8; 4],
    stroke: f32,
) {
    if points.len() < 2 {
        return;
    }
    for index in 0..points.len() {
        draw_preview_line(
            pixels,
            width,
            height,
            preview_point(points[index].0, points[index].1, scale),
            preview_point(
                points[(index + 1) % points.len()].0,
                points[(index + 1) % points.len()].1,
                scale,
            ),
            color,
            (stroke * scale).max(1.0),
        );
    }
}

fn draw_polyline(
    pixels: &mut [u8],
    width: u32,
    height: u32,
    points: &[(f32, f32)],
    scale: f32,
    color: [u8; 4],
    stroke: f32,
) {
    for pair in points.windows(2) {
        draw_preview_line(
            pixels,
            width,
            height,
            preview_point(pair[0].0, pair[0].1, scale),
            preview_point(pair[1].0, pair[1].1, scale),
            color,
            (stroke * scale).max(1.0),
        );
    }
}

fn draw_ellipse_outline(
    pixels: &mut [u8],
    width: u32,
    height: u32,
    rect: Rect,
    scale: f32,
    color: [u8; 4],
    stroke: f32,
) {
    let samples = 96;
    let center = (rect.x + rect.width / 2.0, rect.y + rect.height / 2.0);
    let radius = (rect.width / 2.0, rect.height / 2.0);
    let mut previous = None;
    for index in 0..=samples {
        let angle = std::f32::consts::TAU * index as f32 / samples as f32;
        let point = preview_point(
            center.0 + radius.0 * angle.cos(),
            center.1 + radius.1 * angle.sin(),
            scale,
        );
        if let Some(previous) = previous {
            draw_preview_line(
                pixels,
                width,
                height,
                previous,
                point,
                color,
                (stroke * scale).max(1.0),
            );
        }
        previous = Some(point);
    }
}

fn burst_points(rect: Rect) -> Vec<(f32, f32)> {
    let center_x = rect.x + rect.width / 2.0;
    let center_y = rect.y + rect.height / 2.0;
    let outer_x = rect.width / 2.0;
    let outer_y = rect.height / 2.0;
    let inner_x = outer_x * 0.68;
    let inner_y = outer_y * 0.68;
    (0..24)
        .map(|index| {
            let angle = std::f32::consts::TAU * index as f32 / 24.0 - std::f32::consts::FRAC_PI_2;
            let (radius_x, radius_y) = if index % 2 == 0 {
                (outer_x, outer_y)
            } else {
                (inner_x, inner_y)
            };
            (
                center_x + radius_x * angle.cos(),
                center_y + radius_y * angle.sin(),
            )
        })
        .collect()
}

fn draw_thought_outline(
    pixels: &mut [u8],
    width: u32,
    height: u32,
    rect: Rect,
    scale: f32,
    stroke: f32,
) {
    let color = [17, 17, 17, 255];
    draw_ellipse_outline(pixels, width, height, rect, scale, color, stroke);
    let bubble_one = Rect {
        x: rect.x + rect.width * 0.17,
        y: rect.y + rect.height * 0.98,
        width: (rect.width.min(rect.height) * 0.14).max(8.0),
        height: (rect.width.min(rect.height) * 0.14).max(8.0),
    };
    let bubble_two = Rect {
        x: rect.x + rect.width * 0.08,
        y: rect.y + rect.height * 1.10,
        width: (rect.width.min(rect.height) * 0.09).max(6.0),
        height: (rect.width.min(rect.height) * 0.09).max(6.0),
    };
    draw_ellipse_outline(pixels, width, height, bubble_one, scale, color, stroke);
    draw_ellipse_outline(pixels, width, height, bubble_two, scale, color, stroke);
}

fn draw_burst_outline(
    pixels: &mut [u8],
    width: u32,
    height: u32,
    rect: Rect,
    scale: f32,
    stroke: f32,
) {
    draw_polygon_outline(
        pixels,
        width,
        height,
        &burst_points(rect),
        scale,
        [17, 17, 17, 255],
        stroke,
    );
}

fn draw_tone(pixels: &mut [u8], width: u32, height: u32, tone: &ToneLayer, scale: f32, dpi: f32) {
    let step = (dpi / tone.frequency_lpi.max(1.0) * scale).max(4.0);
    let left = (tone.bounds.x * scale).max(0.0) as i32;
    let top = (tone.bounds.y * scale).max(0.0) as i32;
    let right = ((tone.bounds.x + tone.bounds.width) * scale).min(width as f32) as i32;
    let bottom = ((tone.bounds.y + tone.bounds.height) * scale).min(height as f32) as i32;
    let color = [20, 20, 20, preview_alpha(tone.density, 100.0)];
    let angle = tone.angle_degrees.to_radians();
    let direction = (angle.cos() * 6.0, angle.sin() * 6.0);
    let mut count = 0usize;
    let mut y = top as f32;
    while y < bottom as f32 && count < 100_000 {
        let mut x = left as f32;
        while x < right as f32 && count < 100_000 {
            let (px, py) = (x.round() as i32, y.round() as i32);
            if tone.shape == "line" {
                draw_preview_line(
                    pixels,
                    width,
                    height,
                    (px, py),
                    (
                        (px as f32 + direction.0).round() as i32,
                        (py as f32 + direction.1).round() as i32,
                    ),
                    color,
                    1.0,
                );
            } else {
                blend_preview_pixel(pixels, width, height, px, py, color);
            }
            count += 1;
            x += step;
        }
        y += step;
    }
}

fn draw_text_stub(
    pixels: &mut [u8],
    width: u32,
    height: u32,
    bounds: Rect,
    text_len: usize,
    scale: f32,
) {
    if text_len == 0 {
        return;
    }
    let lines = text_len.clamp(1, 4);
    let left = bounds.x + bounds.width * 0.2;
    let line_width = bounds.width * 0.6;
    for line in 0..lines {
        let y = bounds.y + bounds.height * (0.35 + line as f32 * 0.14);
        draw_preview_line(
            pixels,
            width,
            height,
            preview_point(left, y, scale),
            preview_point(left + line_width, y, scale),
            [17, 17, 17, 150],
            (bounds.height * 0.015 * scale).max(1.0),
        );
    }
}

fn validate_export_directory(directory: &Path) -> Result<(), ComicError> {
    if directory.as_os_str().is_empty()
        || directory
            .components()
            .any(|component| matches!(component, std::path::Component::ParentDir))
    {
        Err(ComicError::InvalidPath)
    } else {
        Ok(())
    }
}

fn validate_export_file(destination: &Path) -> Result<(), ComicError> {
    if destination.as_os_str().is_empty()
        || destination
            .components()
            .any(|component| matches!(component, std::path::Component::ParentDir))
    {
        Err(ComicError::InvalidPath)
    } else {
        Ok(())
    }
}

fn escape_xml(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for character in value.chars() {
        match character {
            '&' => escaped.push_str("&amp;"),
            '<' => escaped.push_str("&lt;"),
            '>' => escaped.push_str("&gt;"),
            '"' => escaped.push_str("&quot;"),
            '\'' => escaped.push_str("&apos;"),
            '\t' | '\n' | '\r' => escaped.push(character),
            character if character >= ' ' => escaped.push(character),
            _ => {}
        }
    }
    escaped
}

#[derive(Clone, Copy)]
struct SvgTextBox {
    x: f32,
    center_y: f32,
    font_size: f32,
    max_width: f32,
    max_height: f32,
    centered: bool,
    vertical: bool,
}

fn svg_text_content(text: &str, layout: SvgTextBox) -> (String, f32, f32) {
    let SvgTextBox {
        x,
        center_y,
        font_size,
        max_width,
        max_height,
        centered,
        vertical,
    } = layout;
    if vertical || text.is_empty() {
        return (escape_xml(text), center_y, font_size);
    }
    let mut text_font_size = font_size;
    let mut lines = wrap_svg_text_lines(text, max_width, text_font_size);
    for _ in 0..24 {
        let line_height = (text_font_size * 1.2).max(1.0);
        let content_height = lines.len() as f32 * line_height;
        if content_height <= max_height || text_font_size <= 6.0 {
            break;
        }
        text_font_size = (text_font_size * 0.9).max(6.0);
        lines = wrap_svg_text_lines(text, max_width, text_font_size);
    }
    let line_height = (text_font_size * 1.2).max(1.0);
    let first_y = if centered {
        center_y - (lines.len().saturating_sub(1) as f32 * line_height / 2.0)
    } else {
        center_y
    };
    let mut markup = String::new();
    for (index, line) in lines.iter().enumerate() {
        let dy = if index == 0 { 0.0 } else { line_height };
        let _ = write!(
            markup,
            r#"<tspan x="{x:.3}" dy="{dy:.3}">{}</tspan>"#,
            escape_xml(line)
        );
    }
    (markup, first_y, text_font_size)
}

// The cast is safe after clamping the finite positive result into 1..=256.
#[allow(clippy::cast_sign_loss)]
fn wrap_svg_text_lines(text: &str, max_width: f32, font_size: f32) -> Vec<String> {
    let max_chars = (max_width / (font_size * 0.55).max(1.0))
        .floor()
        .clamp(1.0, 256.0) as usize;
    let mut lines = Vec::new();
    for paragraph in text.split('\n') {
        let mut line = String::new();
        for word in paragraph.split_whitespace() {
            if word.chars().count() > max_chars {
                if !line.is_empty() {
                    lines.push(std::mem::take(&mut line));
                }
                let mut fragment = String::new();
                for character in word.chars() {
                    fragment.push(character);
                    if fragment.chars().count() >= max_chars {
                        lines.push(std::mem::take(&mut fragment));
                    }
                }
                line = fragment;
            } else if line.is_empty() {
                line.push_str(word);
            } else if line.chars().count() + 1 + word.chars().count() <= max_chars {
                line.push(' ');
                line.push_str(word);
            } else {
                lines.push(std::mem::take(&mut line));
                line.push_str(word);
            }
        }
        if !line.is_empty() || paragraph.is_empty() {
            lines.push(line);
        }
    }
    lines
}

pub fn print_page(width_px: u32, height_px: u32, dpi: f32, page_number: u32, id: u128) -> Page {
    Page {
        id,
        spec: PageSpec {
            width_px,
            height_px,
            dpi,
            bleed_px: Insets {
                left: 24.0,
                top: 24.0,
                right: 24.0,
                bottom: 24.0,
            },
            trim: Rect {
                x: 24.0,
                y: 24.0,
                width: width_px.saturating_sub(48) as f32,
                height: height_px.saturating_sub(48) as f32,
            },
            safety: Insets {
                left: 72.0,
                top: 72.0,
                right: 72.0,
                bottom: 72.0,
            },
            page_number,
        },
        panels: Vec::new(),
        balloons: Vec::new(),
        tones: Vec::new(),
        effect_lines: Vec::new(),
        ink_lines: Vec::new(),
    }
}

/// A deterministic eight-page stick-figure comic used by acceptance tests and
/// as a first-run example. It exercises page reordering, panel gutters,
/// project-wide dialogue search, and visible vector stick-figure artwork
/// without requiring external raster fixtures.
pub fn xkcd_stick_figure_comic() -> ComicProject {
    let mut project = ComicProject::new(
        0x584b_4344,
        ProjectTemplate::PrintComic,
        "A tiny stick-figure comic",
    );
    for page_index in 0..8u128 {
        let mut page = print_page(
            2400,
            1800,
            300.0,
            page_index as u32 + 1,
            0x1000 + page_index,
        );
        for panel_index in 0..4u128 {
            let panel_id = 0x2000 + page_index * 16 + panel_index;
            let panel = Panel {
                id: panel_id,
                shape: PanelShape::Rectangle,
                bounds: Rect {
                    x: 120.0 + (panel_index as f32) * 560.0,
                    y: 180.0,
                    width: 500.0,
                    height: 1400.0,
                },
                polygon: Vec::new(),
                gutter_px: 24.0,
                mask_layer_id: Some(0x3000 + panel_id),
            };
            let panel_bounds = panel.bounds;
            page.panels.push(panel);
            project.panel_layers.push(panel_layer_binding(panel_id));
            page.ink_lines.extend(stick_figure_lines(panel_bounds));
            page.balloons.push(Balloon {
                id: 0x4000 + page_index * 16 + panel_index,
                shape: BalloonShape::Oval,
                bounds: Rect {
                    x: 180.0 + (panel_index as f32) * 560.0,
                    y: 260.0,
                    width: 380.0,
                    height: 220.0,
                },
                tail: vec![
                    (360.0 + (panel_index as f32) * 560.0, 480.0),
                    (330.0 + (panel_index as f32) * 560.0, 560.0),
                ],
                text: format!("Panel {}: draw the next line.", panel_index + 1),
                style: TextStyle::default(),
                panel_id: Some(panel_id),
            });
        }
        project.add_page(page).expect("generated page is valid");
    }
    project
}

fn stick_figure_lines(bounds: Rect) -> Vec<InkLine> {
    let center_x = bounds.x + bounds.width / 2.0;
    let head_center_y = bounds.y + bounds.height * 0.42;
    let head_radius = (bounds.width * 0.14).clamp(20.0, 90.0);
    let shoulder_y = head_center_y + head_radius * 1.35;
    let hip_y = bounds.y + bounds.height * 0.68;
    let foot_y = bounds.y + bounds.height * 0.86;
    let arm_span = bounds.width * 0.25;
    let leg_span = bounds.width * 0.2;
    let mut lines = Vec::with_capacity(6);
    let mut head = Vec::with_capacity(17);
    for step in 0..=16 {
        let angle = std::f32::consts::TAU * step as f32 / 16.0;
        head.push((
            center_x + head_radius * angle.cos(),
            head_center_y + head_radius * angle.sin(),
        ));
    }
    let black = [20, 20, 20, 255];
    lines.push(InkLine {
        points: head,
        width_px: 9.0,
        color_rgba: black,
    });
    lines.push(InkLine {
        points: vec![(center_x, shoulder_y), (center_x, hip_y)],
        width_px: 9.0,
        color_rgba: black,
    });
    lines.push(InkLine {
        points: vec![
            (center_x - arm_span, shoulder_y + arm_span * 0.15),
            (center_x, shoulder_y),
            (center_x + arm_span, shoulder_y + arm_span * 0.15),
        ],
        width_px: 9.0,
        color_rgba: black,
    });
    lines.push(InkLine {
        points: vec![
            (center_x, hip_y),
            (center_x - leg_span, foot_y),
            (center_x - leg_span * 1.2, foot_y),
        ],
        width_px: 9.0,
        color_rgba: black,
    });
    lines.push(InkLine {
        points: vec![
            (center_x, hip_y),
            (center_x + leg_span, foot_y),
            (center_x + leg_span * 1.2, foot_y),
        ],
        width_px: 9.0,
        color_rgba: black,
    });
    lines
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn eight_page_fixture_round_trips_and_searches_dialogue() {
        let project = xkcd_stick_figure_comic();
        project.validate().expect("fixture validates");
        let bytes = project.to_json().expect("encode");
        let restored = ComicProject::from_json(&bytes).expect("decode");
        assert_eq!(restored, project);
        assert_eq!(restored.to_json().expect("re-encode"), bytes);
        assert_eq!(
            restored.portable_render_digest().expect("digest"),
            project.portable_render_digest().expect("digest")
        );
        assert_eq!(restored.pages.len(), 8);
        assert_eq!(restored.pages[0].ink_lines.len(), 20);
        let svg = String::from_utf8(restored.page_svg(0).expect("fixture SVG"))
            .expect("fixture SVG is UTF-8");
        assert!(svg.contains("data-ink-line=\"true\""));
        assert_eq!(restored.search_dialogue("NEXT").len(), 32);
    }

    #[test]
    fn v1_project_migrates_to_portable_page_documents_without_source_mutation() {
        let project = xkcd_stick_figure_comic();
        let original = project.to_json().expect("encode v2");
        let mut legacy: serde_json::Value = serde_json::from_slice(&original).expect("json");
        let object = legacy.as_object_mut().expect("object");
        object.insert("format_version".into(), serde_json::Value::from(1_u16));
        object.remove("page_documents");
        object.remove("panel_layers");
        let legacy_bytes = serde_json::to_vec(&legacy).expect("legacy encode");

        let migrated = ComicProject::from_json(&legacy_bytes).expect("migrate");
        assert_eq!(migrated.format_version, 2);
        assert_eq!(migrated.pages, project.pages);
        assert_eq!(migrated.page_documents.len(), project.pages.len());
        assert_eq!(
            migrated.panel_layers.len(),
            project
                .pages
                .iter()
                .map(|page| page.panels.len())
                .sum::<usize>()
        );
        assert_eq!(
            migrated.page_documents[0].relative_path,
            "pages/00000000000000000000000000001000"
        );
        assert_ne!(legacy_bytes, migrated.to_json().expect("migrated encode"));
        assert_eq!(
            legacy_bytes,
            serde_json::to_vec(&legacy).expect("source unchanged")
        );
    }

    #[test]
    fn reorder_and_gutter_edit_preserve_page_content_structure() {
        let mut project = xkcd_stick_figure_comic();
        let original_panel_count = project.pages[0].panels.len();
        let panel_id = project.pages[0].panels[0].id;
        project.resize_gutter(0, panel_id, 96.0).expect("gutter");
        project.reorder_page(0, 7).expect("reorder");
        assert_eq!(project.pages[7].panels.len(), original_panel_count);
        assert_eq!(project.pages[7].panels[0].gutter_px, 96.0);
        assert_eq!(project.pages[0].spec.page_number, 1);
        assert_eq!(project.pages[7].spec.page_number, 8);
    }

    #[test]
    fn removing_page_cleans_page_documents_and_panel_bindings_atomically() {
        let mut project = xkcd_stick_figure_comic();
        let removed = project.pages[2].clone();
        let panel_ids = removed
            .panels
            .iter()
            .map(|panel| panel.id)
            .collect::<Vec<_>>();
        assert!(!panel_ids.is_empty());

        let returned = project.remove_page(2).expect("remove page");
        assert_eq!(returned, removed);
        assert_eq!(project.pages.len(), 7);
        assert_eq!(project.page_documents.len(), 7);
        assert!(project.pages.iter().all(|page| page.id != removed.id));
        assert!(
            project
                .page_documents
                .iter()
                .all(|document| document.page_id != removed.id)
        );
        assert!(
            project
                .panel_layers
                .iter()
                .all(|binding| !panel_ids.contains(&binding.panel_id))
        );
        assert!(
            project
                .pages
                .iter()
                .enumerate()
                .all(|(index, page)| page.spec.page_number == index as u32 + 1)
        );
        project
            .validate()
            .expect("remaining project references valid");

        let mut one_page = ComicProject::new(9001, ProjectTemplate::PrintComic, "One page");
        one_page
            .add_page(print_page(800, 800, 300.0, 1, 9002))
            .expect("first page");
        let before = one_page.clone();
        assert_eq!(
            one_page.remove_page(0),
            Err(ComicError::CannotRemoveLastPage)
        );
        assert_eq!(one_page, before, "rejected removal must not mutate project");
    }

    #[test]
    fn page_layout_edit_preserves_content_and_rejects_invalid_safety() {
        let mut project = xkcd_stick_figure_comic();
        let before = project.pages[0].clone();
        project
            .set_page_layout(
                0,
                350.0,
                Insets {
                    left: 96.0,
                    top: 96.0,
                    right: 96.0,
                    bottom: 96.0,
                },
                Rect {
                    x: 96.0,
                    y: 96.0,
                    width: 2208.0,
                    height: 1608.0,
                },
                Insets {
                    left: 120.0,
                    top: 120.0,
                    right: 120.0,
                    bottom: 120.0,
                },
            )
            .expect("valid page layout");
        assert_eq!(project.pages[0].panels, before.panels);
        assert_eq!(project.pages[0].balloons, before.balloons);
        assert_eq!(project.pages[0].ink_lines, before.ink_lines);
        assert_eq!(project.pages[0].spec.dpi, 350.0);
        let unchanged = project.pages[0].spec.clone();
        assert_eq!(
            project.set_page_layout(
                0,
                350.0,
                Insets {
                    left: 96.0,
                    top: 96.0,
                    right: 96.0,
                    bottom: 96.0,
                },
                Rect {
                    x: 96.0,
                    y: 96.0,
                    width: 2208.0,
                    height: 1608.0,
                },
                Insets {
                    left: 1000.0,
                    top: 120.0,
                    right: 1300.0,
                    bottom: 120.0,
                },
            ),
            Err(ComicError::InvalidPageSpec)
        );
        assert_eq!(project.pages[0].spec, unchanged);
    }

    #[test]
    fn dialogue_edit_is_bounded_and_searchable() {
        let mut project = xkcd_stick_figure_comic();
        let balloon_id = project.pages[2].balloons[1].id;
        project
            .set_dialogue(2, balloon_id, "The next panel is silent.".into())
            .expect("dialogue edit");
        let hits = project.search_dialogue("silent");
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].page_index, 2);
        assert_eq!(
            project.set_dialogue(2, balloon_id, "x".repeat(16 * 1024 + 1)),
            Err(ComicError::TextTooLong)
        );
    }

    #[test]
    fn webtoon_segmentation_is_bounded_and_exact() {
        let mut project = ComicProject::new(7, ProjectTemplate::Webtoon, "webtoon");
        project
            .add_page(print_page(1080, 5000, 144.0, 1, 9))
            .expect("page");
        let segments = project.webtoon_segments(0, 2048).expect("segments");
        assert_eq!(segments.len(), 3);
        assert_eq!(segments[2].source_y, 4096);
        assert_eq!(segments[2].height_px, 904);
        let directory =
            std::env::temp_dir().join(format!("project-ink-webtoon-export-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&directory);
        assert_eq!(
            project
                .batch_export_webtoon_segments(&directory, 2048)
                .expect("segment export"),
            3
        );
        let segment = std::fs::read_to_string(directory.join("page-0001-segment-0003.svg"))
            .expect("segment file");
        assert!(segment.contains("data-segment-y=\"4096\""));
        assert!(segment.contains("viewBox=\"0 4096 1080 904\""));
        std::fs::remove_dir_all(directory).expect("cleanup");
    }

    #[test]
    fn malformed_project_is_rejected_before_mutation_or_export() {
        let mut project = ComicProject::new(1, ProjectTemplate::PrintComic, "bad");
        let mut page = print_page(1000, 1000, 300.0, 1, 2);
        page.balloons.push(Balloon {
            id: 3,
            shape: BalloonShape::Oval,
            bounds: Rect {
                x: 1.0,
                y: 1.0,
                width: 10.0,
                height: 10.0,
            },
            tail: Vec::new(),
            text: "ok".into(),
            style: TextStyle::default(),
            panel_id: Some(99),
        });
        assert_eq!(project.add_page(page), Err(ComicError::DanglingReference));
        assert!(project.pages.is_empty());
    }

    #[test]
    fn panel_and_balloon_creation_validate_links_and_global_ids() {
        let mut project = ComicProject::new(1, ProjectTemplate::PrintComic, "editable");
        project
            .add_page(print_page(1000, 1000, 300.0, 1, 2))
            .expect("page");
        project
            .add_panel(
                0,
                Panel {
                    id: 3,
                    shape: PanelShape::Rectangle,
                    bounds: Rect {
                        x: 10.0,
                        y: 10.0,
                        width: 400.0,
                        height: 400.0,
                    },
                    polygon: Vec::new(),
                    gutter_px: 16.0,
                    mask_layer_id: None,
                },
            )
            .expect("panel");
        let binding = &project.panel_layers[0];
        let binding_ids = [
            binding.panel_group_id,
            binding.mask_layer_id,
            binding.sketch_layer_id,
            binding.ink_layer_id,
            binding.color_layer_id,
            binding.tone_layer_id,
            binding.effects_layer_id,
        ];
        assert!(binding_ids.iter().all(|id| *id != 0));
        assert_eq!(
            binding_ids
                .iter()
                .copied()
                .collect::<std::collections::HashSet<_>>()
                .len(),
            binding_ids.len()
        );
        project
            .add_balloon(
                0,
                Balloon {
                    id: 4,
                    shape: BalloonShape::Narration,
                    bounds: Rect {
                        x: 30.0,
                        y: 30.0,
                        width: 200.0,
                        height: 100.0,
                    },
                    tail: Vec::new(),
                    text: "Caption".into(),
                    style: TextStyle::default(),
                    panel_id: Some(3),
                },
            )
            .expect("balloon");
        assert_eq!(project.pages[0].balloons.len(), 1);
        assert_eq!(
            project.add_panel(
                0,
                Panel {
                    id: 3,
                    shape: PanelShape::Rectangle,
                    bounds: Rect {
                        x: 500.0,
                        y: 10.0,
                        width: 400.0,
                        height: 400.0,
                    },
                    polygon: Vec::new(),
                    gutter_px: 16.0,
                    mask_layer_id: None,
                },
            ),
            Err(ComicError::DuplicateId)
        );
    }

    #[test]
    fn batch_export_and_print_preview_are_atomic_and_report_moire() {
        let mut project = ComicProject::new(11, ProjectTemplate::PrintComic, "print");
        let mut page = print_page(1200, 1600, 300.0, 1, 12);
        page.tones.push(ToneLayer {
            id: 13,
            frequency_lpi: 180.0,
            angle_degrees: 45.0,
            density: 0.5,
            shape: "circle".into(),
            bounds: Rect {
                x: 24.0,
                y: 24.0,
                width: 1152.0,
                height: 1552.0,
            },
        });
        project.add_page(page).expect("page");
        let report = project.print_preview_report().expect("preview report");
        assert_eq!(report.page_count, 1);
        assert!(report.bleed_safe);
        assert!(report.safety_safe);
        assert_eq!(report.moire_warnings.len(), 1);
        let preview = project.render_page_preview(0, 512).expect("raster preview");
        assert!(preview.width <= 512 && preview.height <= 512);
        assert_eq!(
            preview.pixels_rgba.len(),
            (preview.width * preview.height * 4) as usize
        );
        assert!(
            preview
                .pixels_rgba
                .chunks(4)
                .any(|pixel| pixel != [255, 255, 255, 255])
        );
        assert_eq!(
            preview,
            project.render_page_preview(0, 512).expect("repeat preview")
        );

        let directory =
            std::env::temp_dir().join(format!("project-ink-comic-export-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&directory);
        assert_eq!(project.batch_export_page_manifests(&directory).unwrap(), 1);
        let output = directory.join("page-0001.json");
        assert!(std::fs::metadata(&output).unwrap().len() > 0);
        assert_eq!(project.batch_export_page_svgs(&directory).unwrap(), 1);
        let svg = std::fs::read_to_string(directory.join("page-0001.svg")).unwrap();
        assert!(svg.starts_with("<svg "));
        assert!(!svg.contains("<script"));
        project.pages[0].balloons.push(Balloon {
            id: 14,
            shape: BalloonShape::Oval,
            bounds: Rect {
                x: 10.0,
                y: 10.0,
                width: 100.0,
                height: 60.0,
            },
            tail: vec![(60.0, 70.0), (40.0, 90.0)],
            text: "<safe & sound>".into(),
            style: TextStyle {
                outline_px: 2.0,
                ..TextStyle::default()
            },
            panel_id: None,
        });
        project.pages[0].balloons.push(Balloon {
            id: 15,
            shape: BalloonShape::Thought,
            bounds: Rect {
                x: 160.0,
                y: 160.0,
                width: 180.0,
                height: 100.0,
            },
            tail: Vec::new(),
            text: "thinking".into(),
            style: TextStyle::default(),
            panel_id: None,
        });
        project.pages[0].balloons.push(Balloon {
            id: 16,
            shape: BalloonShape::Burst,
            bounds: Rect {
                x: 400.0,
                y: 160.0,
                width: 180.0,
                height: 100.0,
            },
            tail: Vec::new(),
            text: "look!".into(),
            style: TextStyle::default(),
            panel_id: None,
        });
        let escaped =
            String::from_utf8(project.page_svg(0).expect("escaped SVG")).expect("UTF-8 SVG");
        assert!(escaped.contains("<tspan x="));
        assert!(escaped.contains("&lt;"));
        assert!(escaped.contains("&amp;"));
        assert!(escaped.contains("sound&gt;"));
        assert!(escaped.contains("data-balloon-tail="));
        assert!(escaped.contains("data-balloon-shape=\"thought\""));
        assert!(escaped.contains("data-balloon-shape=\"burst\""));
        assert!(escaped.contains("<circle"));
        assert!(escaped.contains("<polygon points="));
        assert!(escaped.contains("paint-order=\"stroke\""));
        let _ = std::fs::remove_dir_all(directory);
    }

    #[test]
    fn add_page_rejects_duplicate_tone_and_effect_ids_before_mutation() {
        let mut project = ComicProject::new(21, ProjectTemplate::PrintComic, "ids");
        project
            .add_page(print_page(800, 800, 300.0, 1, 22))
            .expect("page");
        let mut duplicate = print_page(800, 800, 300.0, 2, 23);
        duplicate.tones.push(ToneLayer {
            id: 22,
            frequency_lpi: 50.0,
            angle_degrees: 0.0,
            density: 0.2,
            shape: "circle".into(),
            bounds: Rect {
                x: 1.0,
                y: 1.0,
                width: 10.0,
                height: 10.0,
            },
        });
        assert_eq!(project.add_page(duplicate), Err(ComicError::DuplicateId));
        assert_eq!(project.pages.len(), 1);
    }

    #[test]
    fn materials_keep_attribution_and_are_bounded() {
        let mut project = ComicProject::new(31, ProjectTemplate::Illustration, "materials");
        project
            .add_material(MaterialAsset {
                id: 32,
                name: "Balloon style".into(),
                kind: "balloon-style".into(),
                license: "CC0-1.0".into(),
                attribution: Some("Project Ink example asset".into()),
                source: Some("local://project-ink/example".into()),
            })
            .expect("material");
        assert_eq!(project.materials[0].license, "CC0-1.0");
        assert_eq!(project.remove_material(32), Ok(()));
        assert_eq!(
            project.remove_material(32),
            Err(ComicError::DanglingReference)
        );
    }

    #[test]
    fn tone_effect_and_polygon_edits_remain_structural() {
        let mut project = ComicProject::new(41, ProjectTemplate::PrintComic, "tools");
        let mut page = print_page(1200, 1200, 300.0, 1, 42);
        page.panels.push(Panel {
            id: 43,
            shape: PanelShape::Rectangle,
            bounds: Rect {
                x: 100.0,
                y: 100.0,
                width: 600.0,
                height: 600.0,
            },
            polygon: Vec::new(),
            gutter_px: 24.0,
            mask_layer_id: Some(44),
        });
        project.add_page(page).expect("page");
        let before = project.pages[0].panels[0].bounds;
        assert_eq!(
            project.set_panel_bounds(
                0,
                43,
                Rect {
                    x: -1.0,
                    y: 100.0,
                    width: 600.0,
                    height: 600.0,
                },
            ),
            Err(ComicError::InvalidGeometry)
        );
        assert_eq!(project.pages[0].panels[0].bounds, before);
        project
            .set_panel_polygon(
                0,
                43,
                vec![
                    (100.0, 100.0),
                    (700.0, 100.0),
                    (650.0, 700.0),
                    (100.0, 650.0),
                ],
            )
            .expect("polygon");
        project
            .add_panel(
                0,
                Panel {
                    id: 47,
                    shape: PanelShape::Rectangle,
                    bounds: Rect {
                        x: 760.0,
                        y: 100.0,
                        width: 300.0,
                        height: 300.0,
                    },
                    polygon: Vec::new(),
                    gutter_px: 24.0,
                    mask_layer_id: None,
                },
            )
            .expect("rectangle panel");
        assert_eq!(
            project.set_panel_bounds(
                0,
                47,
                Rect {
                    x: 120.0,
                    y: 120.0,
                    width: 560.0,
                    height: 560.0,
                },
            ),
            Ok(())
        );
        assert_eq!(project.pages[0].panels[1].bounds.width, 560.0);
        assert_eq!(
            project.set_panel_bounds(
                0,
                43,
                Rect {
                    x: 120.0,
                    y: 120.0,
                    width: 560.0,
                    height: 560.0,
                },
            ),
            Err(ComicError::InvalidGeometry)
        );
        project
            .add_tone(
                0,
                ToneLayer {
                    id: 45,
                    frequency_lpi: 60.0,
                    angle_degrees: 15.0,
                    density: 0.4,
                    shape: "circle".into(),
                    bounds: Rect {
                        x: 100.0,
                        y: 100.0,
                        width: 600.0,
                        height: 600.0,
                    },
                },
            )
            .expect("tone");
        project
            .add_effect_line(
                0,
                EffectLine {
                    id: 46,
                    kind: "speed".into(),
                    points: vec![(20.0, 20.0), (400.0, 400.0)],
                    width_px: 6.0,
                    opacity: 0.8,
                },
            )
            .expect("effect line");
        project.validate().expect("tools validate");
        assert_eq!(project.pages[0].panels[0].shape, PanelShape::Polygon);
        assert_eq!(project.pages[0].tones.len(), 1);
        assert_eq!(project.pages[0].effect_lines.len(), 1);
    }

    #[test]
    fn split_panel_preserves_gutter_and_links_both_masks_without_mutating_other_pages() {
        let mut project = ComicProject::new(51, ProjectTemplate::PrintComic, "split");
        let mut page = print_page(1200, 1200, 300.0, 1, 52);
        page.panels.push(Panel {
            id: 53,
            shape: PanelShape::Rectangle,
            bounds: Rect {
                x: 100.0,
                y: 100.0,
                width: 800.0,
                height: 800.0,
            },
            polygon: Vec::new(),
            gutter_px: 20.0,
            mask_layer_id: Some(54),
        });
        project.add_page(page).expect("page");
        project.split_panel(0, 53, 55, 56, 0, 0.5).expect("split");
        let panels = &project.pages[0].panels;
        assert_eq!(panels.len(), 2);
        assert_eq!(panels[0].gutter_px, 20.0);
        assert_eq!(panels[0].mask_layer_id, Some(54));
        assert_eq!(panels[1].mask_layer_id, Some(0x38 ^ SPLIT_MASK_NAMESPACE));
        assert!(panels[0].bounds.x + panels[0].bounds.width < panels[1].bounds.x);
        assert_eq!(
            project.split_panel(0, 55, 55, 57, 0, 0.5),
            Err(ComicError::DuplicateId)
        );
        let panel_count = project.pages[0].panels.len();
        assert_eq!(
            project.split_panel(0, 55, 57, 0x36 ^ SPLIT_MASK_NAMESPACE, 0, 0.5,),
            Err(ComicError::DuplicateId)
        );
        assert_eq!(project.pages[0].panels.len(), panel_count);
    }

    #[test]
    fn split_panel_reuses_original_layer_binding_for_first_child() {
        let mut project = ComicProject::new(61, ProjectTemplate::PrintComic, "bound split");
        project
            .add_page(print_page(1000, 1000, 300.0, 1, 62))
            .expect("page");
        project
            .add_panel(
                0,
                Panel {
                    id: 63,
                    shape: PanelShape::Rectangle,
                    bounds: Rect {
                        x: 100.0,
                        y: 100.0,
                        width: 700.0,
                        height: 700.0,
                    },
                    polygon: Vec::new(),
                    gutter_px: 16.0,
                    mask_layer_id: None,
                },
            )
            .expect("panel");
        let original = project.panel_layers[0].clone();
        project.split_panel(0, 63, 64, 65, 0, 0.5).expect("split");
        assert_eq!(project.panel_layers.len(), 2);
        assert_eq!(project.panel_layers[0].panel_id, 64);
        assert_eq!(
            project.panel_layers[0].panel_group_id,
            original.panel_group_id
        );
        assert_eq!(
            project.panel_layers[0].mask_layer_id,
            original.mask_layer_id
        );
        assert_eq!(project.panel_layers[1].panel_id, 65);
        project.validate().expect("split remains valid");
    }
}

//! Deterministic, bundled-font layout for page lettering.
//!
//! This crate deliberately owns no comic or document state. Callers provide
//! immutable text/style geometry and receive positioned glyph outlines.

use std::borrow::Cow;
use std::ops::Range;
use std::sync::Arc;
use unicode_segmentation::UnicodeSegmentation;

use parley::fontique::{Blob, Collection, CollectionOptions, SourceCache};
use parley::{
    Alignment, AlignmentOptions, FontContext, FontFamilyName, LayoutContext, PositionedLayoutItem,
    StyleProperty,
};
use skrifa::outline::{DrawSettings, OutlinePen};
use skrifa::{FontRef, GlyphId, MetadataProvider};

static SANS: &[u8] = include_bytes!("../../../assets/fonts/cjk/NotoSansCJKjp-Regular.otf");
static SERIF: &[u8] = include_bytes!("../../../assets/fonts/cjk/NotoSerifCJKjp-Regular.otf");

/// Horizontal or Japanese vertical text flow.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Orientation {
    /// Left-to-right or bidirectional line layout.
    Horizontal,
    /// Top-to-bottom Japanese columns advancing from right to left.
    Vertical,
}

/// Bundled font family selection.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Family {
    /// Bundled Noto Sans CJK JP regular face.
    Sans,
    /// Bundled Noto Serif CJK JP regular face.
    Serif,
}

/// Immutable bounded input to the text shaper.
#[derive(Clone, Copy, Debug)]
pub struct LayoutRequest<'a> {
    /// Source text in UTF-8.
    pub text: &'a str,
    /// Deterministic bundled family to shape with.
    pub family: Family,
    /// Font size in page pixels.
    pub font_size: f32,
    /// Available horizontal extent in page pixels.
    pub width: f32,
    /// Available vertical extent in page pixels.
    pub height: f32,
    /// Horizontal or vertical flow.
    pub orientation: Orientation,
}

type SourceRangeMap = Vec<(Range<usize>, Range<usize>)>;

/// Path instruction in page pixel coordinates.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum PathElement {
    /// Starts a contour at the given page coordinate.
    Move(f32, f32),
    /// Adds a straight segment to a page coordinate.
    Line(f32, f32),
    /// Adds a quadratic Bézier segment.
    Quad(f32, f32, f32, f32),
    /// Adds a cubic Bézier segment.
    Cubic(f32, f32, f32, f32, f32, f32),
    /// Closes the current contour.
    Close,
}

/// One glyph's filled outline and source text range.
#[derive(Clone, Debug, PartialEq)]
pub struct PositionedGlyph {
    /// Glyph index in the selected bundled font face.
    pub glyph_id: u32,
    /// Byte range in the shaped input string.
    pub cluster: std::ops::Range<usize>,
    /// Positioned outline path in page pixel coordinates.
    pub path: Vec<PathElement>,
}

/// Shaped output and overflow/missing-glyph diagnostics.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct LayoutResult {
    /// Positioned glyph outlines in visual paint order.
    pub glyphs: Vec<PositionedGlyph>,
    /// Shaped content width in page pixels.
    pub width: f32,
    /// Shaped content height in page pixels.
    pub height: f32,
    /// Source byte ranges that could not be resolved to an outline.
    pub missing_glyphs: Vec<std::ops::Range<usize>>,
    /// Whether shaped output exceeds the requested content rectangle.
    pub overflow: bool,
}

impl LayoutResult {
    /// Source-over paints the positioned glyph fills into an RGBA8 canvas.
    /// Coordinates and outline control points are scaled once at this boundary.
    pub fn paint_rgba(
        &self,
        pixels: &mut [u8],
        width: u32,
        height: u32,
        origin: (f32, f32),
        scale: f32,
        color: [u8; 4],
    ) {
        self.paint_rgba_with_outline(pixels, width, height, origin, scale, color, None);
    }

    /// Source-over paints fills and an optional centered outline into RGBA8.
    #[allow(clippy::too_many_arguments)]
    pub fn paint_rgba_with_outline(
        &self,
        pixels: &mut [u8],
        width: u32,
        height: u32,
        origin: (f32, f32),
        scale: f32,
        color: [u8; 4],
        outline: Option<([u8; 4], f32)>,
    ) {
        self.paint_rgba_with_outline_clipped(
            pixels, width, height, origin, scale, color, outline, None,
        );
    }

    /// Paint glyphs while clipping to a target-pixel rectangle.
    #[allow(clippy::too_many_arguments)]
    pub fn paint_rgba_with_outline_clipped(
        &self,
        pixels: &mut [u8],
        width: u32,
        height: u32,
        origin: (f32, f32),
        scale: f32,
        color: [u8; 4],
        outline: Option<([u8; 4], f32)>,
        clip: Option<(f32, f32, f32, f32)>,
    ) {
        let Some(expected) = (width as usize)
            .checked_mul(height as usize)
            .and_then(|n| n.checked_mul(4))
        else {
            return;
        };
        if pixels.len() != expected
            || width > 32_768
            || height > 32_768
            || !scale.is_finite()
            || scale <= 0.0
        {
            return;
        }
        let clip = clip.map(|rect| clamp_clip(rect, width, height));
        for glyph in &self.glyphs {
            let contours = flatten_path(&glyph.path, origin, scale);
            if let Some((outline_color, outline_width)) = outline
                && outline_width.is_finite()
                && outline_width > 0.0
            {
                paint_outline(
                    pixels,
                    width,
                    height,
                    &contours,
                    outline_color,
                    outline_width * scale,
                    clip,
                );
            }
            paint_contours(pixels, width, height, &contours, color, clip);
        }
    }
}

// The public painter bounds dimensions to 32768 and clamps each edge to the
// image rectangle before converting finite geometry into integer pixels.
#[allow(
    clippy::cast_possible_truncation,
    clippy::cast_precision_loss,
    clippy::cast_sign_loss
)]
fn clamp_clip(
    (left, top, right, bottom): (f32, f32, f32, f32),
    width: u32,
    height: u32,
) -> (i32, i32, i32, i32) {
    (
        left.floor().max(0.0) as i32,
        top.floor().max(0.0) as i32,
        right.ceil().min(width as f32) as i32,
        bottom.ceil().min(height as f32) as i32,
    )
}

/// Reusable font database and shaping scratch space. It has no system-font
/// backend, so a layout does not vary with the host operating system.
pub struct TextEngine {
    fonts: FontContext,
    layout: LayoutContext<()>,
}

impl Default for TextEngine {
    fn default() -> Self {
        Self::new()
    }
}

impl TextEngine {
    /// Creates a system-font-free engine using the bundled regular faces.
    #[must_use]
    pub fn new() -> Self {
        let mut fonts = FontContext {
            collection: Collection::new(CollectionOptions {
                shared: false,
                system_fonts: false,
            }),
            source_cache: SourceCache::default(),
        };
        fonts
            .collection
            .register_fonts(Blob::new(Arc::new(SANS)), None);
        fonts
            .collection
            .register_fonts(Blob::new(Arc::new(SERIF)), None);
        Self {
            fonts,
            layout: LayoutContext::new(),
        }
    }

    /// Shapes and extracts bounded outlines for one dialogue balloon.
    ///
    /// # Errors
    ///
    /// Returns [`TextError::InvalidRequest`] for input outside supported
    /// bounds or [`TextError::InvalidFont`] for bundled-font failures.
    #[allow(clippy::too_many_lines, clippy::cast_precision_loss)]
    pub fn layout(&mut self, request: LayoutRequest<'_>) -> Result<LayoutResult, TextError> {
        if !request.font_size.is_finite()
            || !(1.0..=2048.0).contains(&request.font_size)
            || !request.width.is_finite()
            || !request.height.is_finite()
            || request.width <= 0.0
            || request.height <= 0.0
            || request.text.len() > 16 * 1024
        {
            return Err(TextError::InvalidRequest);
        }
        if request.text.is_empty() {
            return Ok(LayoutResult::default());
        }

        let (text, vertical, source_ranges) = match request.orientation {
            Orientation::Horizontal => (request.text.to_owned(), false, Vec::new()),
            Orientation::Vertical => {
                let (text, source_ranges) = vertical_text(request.text);
                (text, true, source_ranges)
            }
        };
        let family = match request.family {
            Family::Sans => "Noto Sans CJK JP",
            Family::Serif => "Noto Serif CJK JP",
        };
        let family_name = FontFamilyName::Named(Cow::Borrowed(family));
        let mut builder = self
            .layout
            .ranged_builder(&mut self.fonts, &text, 1.0, false);
        builder.push_default(StyleProperty::FontFamily(family_name.into()));
        builder.push_default(StyleProperty::FontSize(request.font_size));
        let mut layout = builder.build(&text);
        let inline_extent = if vertical {
            request.height
        } else {
            request.width
        };
        layout.break_all_lines(Some(inline_extent));
        layout.align(Alignment::Center, AlignmentOptions::default());
        let vertical_rows = (request.height / request.font_size).floor().max(1.0);
        let mut output = LayoutResult {
            width: layout.width(),
            height: layout.height(),
            overflow: if vertical {
                (layout.len() as f32 / vertical_rows).ceil() * request.font_size > request.width
            } else {
                layout.height() > request.height
            },
            ..LayoutResult::default()
        };

        let (origin_x, origin_y) = if vertical {
            (request.width - request.font_size, 0.0)
        } else {
            (0.0, (request.height - layout.height()) * 0.5)
        };

        let rows_per_column = vertical_rows;
        for (line_index, line) in layout.lines().enumerate() {
            for item in line.items() {
                let PositionedLayoutItem::GlyphRun(run) = item else {
                    continue;
                };
                let run_font = run.run().font();
                let font = FontRef::from_index(run_font.data.as_ref(), run_font.index)
                    .map_err(|_| TextError::InvalidFont)?;
                let upem = f32::from(
                    font.metrics(
                        skrifa::instance::Size::unscaled(),
                        skrifa::instance::LocationRef::default(),
                    )
                    .units_per_em,
                );
                let scale = request.font_size / upem;
                let clusters: Vec<_> = run
                    .run()
                    .visual_clusters()
                    .flat_map(|cluster| {
                        std::iter::repeat_n(cluster.text_range(), cluster.glyphs().count())
                    })
                    .collect();
                for (glyph, shaped_cluster) in run.positioned_glyphs().zip(clusters) {
                    let cluster = source_text_range(shaped_cluster, &source_ranges);
                    if glyph.id == 0 {
                        output.missing_glyphs.push(cluster);
                        continue;
                    }
                    let Some(outline) = font.outline_glyphs().get(GlyphId::new(glyph.id)) else {
                        output.missing_glyphs.push(cluster);
                        continue;
                    };
                    let (glyph_x, glyph_y) = if vertical {
                        let row = line_index as f32 % rows_per_column;
                        let column = (line_index as f32 / rows_per_column).floor();
                        (
                            request.width - (column + 1.0) * request.font_size
                                + ((request.font_size - glyph.advance) * 0.5).max(0.0),
                            row * request.font_size + request.font_size * 0.82,
                        )
                    } else {
                        (glyph.x, glyph.y + origin_y)
                    };
                    let mut recorder = PathRecorder {
                        path: Vec::new(),
                        sx: scale,
                        sy: -scale,
                        x: origin_x + glyph_x,
                        y: glyph_y,
                    };
                    let settings = DrawSettings::unhinted(
                        skrifa::instance::Size::unscaled(),
                        skrifa::instance::LocationRef::default(),
                    );
                    if outline.draw(settings, &mut recorder).is_err() {
                        output.missing_glyphs.push(cluster);
                        continue;
                    }
                    output.glyphs.push(PositionedGlyph {
                        glyph_id: glyph.id,
                        cluster,
                        path: recorder.path,
                    });
                }
            }
        }
        Ok(output)
    }
}

/// Invalid bounded layout input or bundled-font failure.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TextError {
    /// The text, font size, or content rectangle exceeded supported limits.
    InvalidRequest,
    /// A bundled font could not be parsed or rasterized.
    InvalidFont,
}

fn vertical_text(text: &str) -> (String, SourceRangeMap) {
    let mut output = String::with_capacity(text.len() + text.graphemes(true).count());
    let mut source_ranges = Vec::new();
    for (source_start, cluster) in text.grapheme_indices(true) {
        let source_range = source_start..source_start + cluster.len();
        let output_start = output.len();
        if cluster == "\r\n" {
            output.push('\n');
            source_ranges.push((output_start..output.len(), source_range));
            continue;
        }
        let mut chars = cluster.chars();
        let first = chars.next().unwrap_or_default();
        let vertical = match first {
            '、' => '︑',
            '。' => '︒',
            'ー' => '︱',
            '（' => '︵',
            '）' => '︶',
            '「' => '﹁',
            '」' => '﹂',
            '『' => '﹃',
            '』' => '﹄',
            '【' => '︻',
            '】' => '︼',
            '\n' | '\r' => '\n',
            other => other,
        };
        output.push(vertical);
        for rest in chars {
            output.push(rest);
        }
        source_ranges.push((output_start..output.len(), source_range));
        if first != '\n' && first != '\r' {
            output.push('\n');
        }
    }
    (output, source_ranges)
}

fn source_text_range(
    shaped: std::ops::Range<usize>,
    mappings: &SourceRangeMap,
) -> std::ops::Range<usize> {
    if mappings.is_empty() {
        return shaped;
    }
    let mut matching = mappings
        .iter()
        .filter(|(rendered, _)| rendered.start < shaped.end && shaped.start < rendered.end)
        .map(|(_, source)| source.clone());
    let Some(first) = matching.next() else {
        return 0..0;
    };
    matching.fold(first, |range, next| {
        range.start.min(next.start)..range.end.max(next.end)
    })
}

struct PathRecorder {
    path: Vec<PathElement>,
    sx: f32,
    sy: f32,
    x: f32,
    y: f32,
}

impl PathRecorder {
    fn point(&self, x: f32, y: f32) -> (f32, f32) {
        (self.x + x * self.sx, self.y + y * self.sy)
    }
}

impl OutlinePen for PathRecorder {
    fn move_to(&mut self, x: f32, y: f32) {
        let (x, y) = self.point(x, y);
        self.path.push(PathElement::Move(x, y));
    }
    fn line_to(&mut self, x: f32, y: f32) {
        let (x, y) = self.point(x, y);
        self.path.push(PathElement::Line(x, y));
    }
    fn quad_to(&mut self, cx: f32, cy: f32, x: f32, y: f32) {
        let (cx, cy) = self.point(cx, cy);
        let (x, y) = self.point(x, y);
        self.path.push(PathElement::Quad(cx, cy, x, y));
    }
    fn curve_to(&mut self, c0x: f32, c0y: f32, c1x: f32, c1y: f32, x: f32, y: f32) {
        let (c0x, c0y) = self.point(c0x, c0y);
        let (c1x, c1y) = self.point(c1x, c1y);
        let (x, y) = self.point(x, y);
        self.path.push(PathElement::Cubic(c0x, c0y, c1x, c1y, x, y));
    }
    fn close(&mut self) {
        self.path.push(PathElement::Close);
    }
}

#[allow(clippy::cast_precision_loss)]
fn flatten_path(path: &[PathElement], origin: (f32, f32), scale: f32) -> Vec<Vec<(f32, f32)>> {
    let mut contours = Vec::new();
    let mut contour = Vec::new();
    let mut current = (0.0, 0.0);
    let convert = |x: f32, y: f32| (origin.0 + x * scale, origin.1 + y * scale);
    for element in path {
        match *element {
            PathElement::Move(x, y) => {
                close_contour(&mut contours, &mut contour);
                current = (x, y);
                contour.push(convert(x, y));
            }
            PathElement::Line(x, y) => {
                current = (x, y);
                contour.push(convert(x, y));
            }
            PathElement::Quad(cx, cy, x, y) => {
                let start = current;
                for step in 1..=8 {
                    let t = step as f32 / 8.0;
                    let m = 1.0 - t;
                    contour.push(convert(
                        m * m * start.0 + 2.0 * m * t * cx + t * t * x,
                        m * m * start.1 + 2.0 * m * t * cy + t * t * y,
                    ));
                }
                current = (x, y);
            }
            PathElement::Cubic(c0x, c0y, c1x, c1y, x, y) => {
                let start = current;
                for step in 1..=12 {
                    let t = step as f32 / 12.0;
                    let m = 1.0 - t;
                    contour.push(convert(
                        m.powi(3) * start.0
                            + 3.0 * m * m * t * c0x
                            + 3.0 * m * t * t * c1x
                            + t.powi(3) * x,
                        m.powi(3) * start.1
                            + 3.0 * m * m * t * c0y
                            + 3.0 * m * t * t * c1y
                            + t.powi(3) * y,
                    ));
                }
                current = (x, y);
            }
            PathElement::Close => {
                close_contour(&mut contours, &mut contour);
            }
        }
    }
    close_contour(&mut contours, &mut contour);
    contours
}

fn close_contour(contours: &mut Vec<Vec<(f32, f32)>>, contour: &mut Vec<(f32, f32)>) {
    if contour.len() > 2 {
        if contour.first() != contour.last()
            && let Some(first) = contour.first().copied()
        {
            contour.push(first);
        }
        contours.push(std::mem::take(contour));
    } else {
        contour.clear();
    }
}

// The loops below clip finite coordinates to the output before indexing.
#[allow(
    clippy::cast_possible_truncation,
    clippy::cast_precision_loss,
    clippy::cast_sign_loss
)]
fn paint_contours(
    pixels: &mut [u8],
    width: u32,
    height: u32,
    contours: &[Vec<(f32, f32)>],
    color: [u8; 4],
    clip: Option<(i32, i32, i32, i32)>,
) {
    let bounds: Option<(f32, f32, f32, f32)> =
        contours.iter().flatten().fold(None, |bounds, point| {
            if !point.0.is_finite() || !point.1.is_finite() {
                return bounds;
            }
            Some(match bounds {
                None => (point.0, point.1, point.0, point.1),
                Some((x0, y0, x1, y1)) => (
                    x0.min(point.0),
                    y0.min(point.1),
                    x1.max(point.0),
                    y1.max(point.1),
                ),
            })
        });
    let Some((min_x, min_y, max_x, max_y)) = bounds else {
        return;
    };
    let (clip_left, clip_top, clip_right, clip_bottom) =
        clip.unwrap_or((0, 0, width.cast_signed(), height.cast_signed()));
    let left = min_x.floor().max(clip_left as f32).max(0.0) as i32;
    let top = min_y.floor().max(clip_top as f32).max(0.0) as i32;
    let right = max_x.ceil().min(clip_right as f32).min(width as f32) as i32;
    let bottom = max_y.ceil().min(clip_bottom as f32).min(height as f32) as i32;
    for y in top..bottom {
        for x in left..right {
            let mut covered = 0_u32;
            for (ox, oy) in [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)] {
                let (px, py) = (x as f32 + ox, y as f32 + oy);
                let mut winding = 0_i32;
                for contour in contours {
                    for edge in contour.windows(2) {
                        let (a, b) = (edge[0], edge[1]);
                        if a.1 <= py
                            && b.1 > py
                            && (b.0 - a.0) * (py - a.1) - (px - a.0) * (b.1 - a.1) > 0.0
                        {
                            winding += 1;
                        }
                        if a.1 > py
                            && b.1 <= py
                            && (b.0 - a.0) * (py - a.1) - (px - a.0) * (b.1 - a.1) < 0.0
                        {
                            winding -= 1;
                        }
                    }
                }
                if winding != 0 {
                    covered += 1;
                }
            }
            if covered != 0 {
                let alpha = u32::from(color[3]) * covered / 4;
                let index = (y as usize * width as usize + x as usize) * 4;
                let inverse = 255 - alpha;
                for channel in 0..3 {
                    pixels[index + channel] = ((u32::from(color[channel]) * alpha
                        + u32::from(pixels[index + channel]) * inverse
                        + 127)
                        / 255) as u8;
                }
                pixels[index + 3] = (alpha + u32::from(pixels[index + 3]) * inverse / 255) as u8;
            }
        }
    }
}

// The loops below clip finite coordinates to the output before indexing.
#[allow(
    clippy::cast_possible_truncation,
    clippy::cast_precision_loss,
    clippy::cast_sign_loss
)]
fn paint_outline(
    pixels: &mut [u8],
    width: u32,
    height: u32,
    contours: &[Vec<(f32, f32)>],
    color: [u8; 4],
    stroke: f32,
    clip: Option<(i32, i32, i32, i32)>,
) {
    let (clip_left, clip_top, clip_right, clip_bottom) =
        clip.unwrap_or((0, 0, width.cast_signed(), height.cast_signed()));
    let radius = stroke.max(0.5) * 0.5;
    for contour in contours {
        for edge in contour.windows(2) {
            let (a, b) = (edge[0], edge[1]);
            let left = (a.0.min(b.0) - radius - 1.0)
                .floor()
                .max(clip_left as f32)
                .max(0.0) as i32;
            let top = (a.1.min(b.1) - radius - 1.0)
                .floor()
                .max(clip_top as f32)
                .max(0.0) as i32;
            let right = (a.0.max(b.0) + radius + 1.0)
                .ceil()
                .min(clip_right as f32)
                .min(width as f32) as i32;
            let bottom = (a.1.max(b.1) + radius + 1.0)
                .ceil()
                .min(clip_bottom as f32)
                .min(height as f32) as i32;
            let dx = b.0 - a.0;
            let dy = b.1 - a.1;
            let length_sq = dx * dx + dy * dy;
            for y in top..bottom {
                for x in left..right {
                    let mut covered = 0_u32;
                    for (ox, oy) in [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)] {
                        let px = x as f32 + ox;
                        let py = y as f32 + oy;
                        let t = if length_sq > 0.0 {
                            (((px - a.0) * dx + (py - a.1) * dy) / length_sq).clamp(0.0, 1.0)
                        } else {
                            0.0
                        };
                        let ex = px - (a.0 + t * dx);
                        let ey = py - (a.1 + t * dy);
                        if ex * ex + ey * ey <= radius * radius {
                            covered += 1;
                        }
                    }
                    if covered > 0 {
                        blend_rgba(pixels, width, x, y, color, covered);
                    }
                }
            }
        }
    }
}

#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
fn blend_rgba(pixels: &mut [u8], width: u32, x: i32, y: i32, color: [u8; 4], covered: u32) {
    let alpha = u32::from(color[3]) * covered / 4;
    let index = (y as usize * width as usize + x as usize) * 4;
    let inverse = 255 - alpha;
    for channel in 0..3 {
        pixels[index + channel] = ((u32::from(color[channel]) * alpha
            + u32::from(pixels[index + channel]) * inverse
            + 127)
            / 255) as u8;
    }
    pixels[index + 3] = (alpha + u32::from(pixels[index + 3]) * inverse / 255) as u8;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundled_japanese_font_shapes_to_paths() {
        let mut engine = TextEngine::new();
        let shaped = engine
            .layout(LayoutRequest {
                text: "こんにちは。",
                family: Family::Sans,
                font_size: 28.0,
                width: 240.0,
                height: 80.0,
                orientation: Orientation::Horizontal,
            })
            .expect("layout");
        assert!(!shaped.glyphs.is_empty());
        assert!(shaped.missing_glyphs.is_empty());
        assert!(shaped.glyphs.iter().all(|glyph| !glyph.path.is_empty()));
    }

    #[test]
    fn vertical_layout_maps_japanese_punctuation() {
        assert_eq!(vertical_text("「あ。」").0, "﹁\nあ\n︒\n﹂\n");
    }

    #[test]
    fn vertical_glyph_clusters_refer_to_original_utf8_ranges() {
        let source = "「あ。」";
        let (rendered, mapping) = vertical_text(source);
        let close_quote_range = rendered.find('﹂').expect("substituted punctuation")
            ..rendered.find('﹂').expect("substituted punctuation") + '﹂'.len_utf8();
        assert_eq!(
            source_text_range(close_quote_range, &mapping),
            9..source.len()
        );
    }

    #[test]
    fn rasterizer_paints_shaped_glyphs() {
        let mut engine = TextEngine::new();
        let shaped = engine
            .layout(LayoutRequest {
                text: "Ink",
                family: Family::Sans,
                font_size: 24.0,
                width: 80.0,
                height: 32.0,
                orientation: Orientation::Horizontal,
            })
            .expect("layout");
        let mut pixels = vec![0; 80 * 32 * 4];
        shaped.paint_rgba(&mut pixels, 80, 32, (0.0, 0.0), 1.0, [0, 0, 0, 255]);
        assert!(pixels.as_chunks::<4>().0.iter().any(|pixel| pixel[3] > 0));
    }

    #[test]
    fn clipped_rasterization_never_paints_outside_the_content_rectangle() {
        let mut engine = TextEngine::new();
        let shaped = engine
            .layout(LayoutRequest {
                text: "Ink",
                family: Family::Sans,
                font_size: 24.0,
                width: 80.0,
                height: 32.0,
                orientation: Orientation::Horizontal,
            })
            .expect("layout");
        let mut pixels = vec![0; 80 * 32 * 4];
        shaped.paint_rgba_with_outline_clipped(
            &mut pixels,
            80,
            32,
            (0.0, 0.0),
            1.0,
            [0, 0, 0, 255],
            Some(([0, 0, 0, 255], 3.0)),
            Some((20.0, 0.0, 45.0, 32.0)),
        );
        let rows = pixels.as_chunks::<4>().0.chunks(80).collect::<Vec<_>>();
        assert!(
            rows.iter()
                .any(|row| row[20..45].iter().any(|pixel| pixel[3] > 0))
        );
        assert!(rows.iter().enumerate().all(|(y, row)| {
            row.iter()
                .enumerate()
                .all(|(x, pixel)| (20..45).contains(&x) || pixel[3] == 0)
                && y < 32
        }));
    }
}

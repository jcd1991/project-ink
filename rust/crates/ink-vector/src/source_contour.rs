//! Boundary following on the pixel-crack grid.
//!
//! Vertices are pixel corners `(x, y)` with `0 ≤ x ≤ w`, `0 ≤ y ≤ h`. Every edge between an inside
//! and an outside pixel becomes a directed edge with the inside pixel on its right (y down), so
//! outer boundaries run clockwise and holes counter-clockwise. At a saddle (two inside pixels
//! touching only diagonally) the walk turns right, which keeps diagonal neighbours apart — the
//! same 4-connectivity used to label components.
#![allow(
    clippy::many_single_char_names,
    reason = "The pinned contour walker uses conventional x/y/direction notation."
)]

/// A closed boundary loop.
#[derive(Clone, Debug, PartialEq)]
pub struct Loop {
    /// Corner vertices in order (the loop closes back to the first).
    pub pts: Vec<(i32, i32)>,
    /// Twice the signed area (positive = outer boundary, negative = hole).
    pub area2: i64,
}

/// One 4-connected component of the mask: its outer loop and holes.
#[derive(Clone, Debug, PartialEq)]
pub struct Component {
    pub outer: Loop,
    pub holes: Vec<Loop>,
    /// Inside pixel count.
    pub pixels: usize,
}

const R: u8 = 1;
const D: u8 = 2;
const L: u8 = 4;
const U: u8 = 8;

fn right_of(d: u8) -> u8 {
    match d {
        R => D,
        D => L,
        L => U,
        _ => R,
    }
}

fn step(d: u8) -> (i32, i32) {
    match d {
        R => (1, 0),
        D => (0, 1),
        L => (-1, 0),
        _ => (0, -1),
    }
}

/// 4-connected component labels (`u32::MAX` outside) and per-component pixel counts.
// The caller caps both dimensions at 4096, so component IDs fit u32.
#[allow(clippy::cast_possible_truncation)]
fn label(mask: &[bool], w: usize, h: usize) -> Option<(Vec<u32>, Vec<usize>)> {
    let pixels = w.checked_mul(h)?;
    let mut comp = Vec::new();
    comp.try_reserve_exact(pixels).ok()?;
    comp.resize(pixels, u32::MAX);
    let mut sizes = Vec::new();
    let mut stack = Vec::new();
    for s in 0..pixels {
        if !mask[s] || comp[s] != u32::MAX {
            continue;
        }
        let id = u32::try_from(sizes.len()).ok()?;
        let mut n = 0usize;
        comp[s] = id;
        stack.try_reserve(1).ok()?;
        stack.push(s);
        while let Some(i) = stack.pop() {
            n = n.checked_add(1)?;
            let (x, y) = (i % w, i / w);
            let mut allocation_failed = false;
            let mut go = |j: usize| {
                if mask[j] && comp[j] == u32::MAX {
                    if stack.try_reserve(1).is_err() {
                        allocation_failed = true;
                        return;
                    }
                    comp[j] = id;
                    stack.push(j);
                }
            };
            if x > 0 {
                go(i - 1);
            }
            if x + 1 < w {
                go(i + 1);
            }
            if y > 0 {
                go(i - w);
            }
            if y + 1 < h {
                go(i + w);
            }
            if allocation_failed {
                return None;
            }
        }
        sizes.try_reserve(1).ok()?;
        sizes.push(n);
    }
    Some((comp, sizes))
}

/// Trace a validated mask, returning None before output construction when
/// its foreground boundary budget is exceeded.
// The public adapter caps dimensions at 4096, which makes these coordinate
// conversions safe and keeps the source-compatible walk below that bound.
#[allow(
    clippy::cast_possible_truncation,
    clippy::cast_possible_wrap,
    clippy::cast_sign_loss,
    clippy::too_many_lines,
    reason = "Every input dimension is validated as <= 4096 before this private call."
)]
pub fn trace_mask_bounded(mask: &[bool], w: usize, h: usize) -> Option<Vec<Component>> {
    let pixels = w.checked_mul(h)?;
    if w == 0 || h == 0 || mask.len() != pixels {
        return None;
    }
    let (comp, sizes) = label(mask, w, h)?;
    if sizes.len() > 16_384 {
        return None;
    }
    let mut boundary_edges = 0usize;
    for y in 0..h {
        for x in 0..w {
            if !mask[y * w + x] {
                continue;
            }
            let i = y * w + x;
            boundary_edges = boundary_edges
                .checked_add(usize::from(y == 0 || !mask[i - w]))?
                .checked_add(usize::from(x + 1 == w || !mask[i + 1]))?
                .checked_add(usize::from(y + 1 == h || !mask[i + w]))?
                .checked_add(usize::from(x == 0 || !mask[i - 1]))?;
            if boundary_edges > 1_000_000 {
                return None;
            }
        }
    }
    if boundary_edges == 0 {
        return Some(Vec::new());
    }

    // The latest upstream walker derives each turn from the pixels ahead. A single bit per source
    // pixel records whether its top edge has already started a loop, replacing the full corner grid.
    let inside = |x: i32, y: i32| {
        x >= 0
            && y >= 0
            && (x as usize) < w
            && (y as usize) < h
            && mask.get(y as usize * w + x as usize) == Some(&true)
    };
    let ahead = |x: i32, y: i32, d: u8| {
        let (nw, ne, se, sw) = ((x - 1, y - 1), (x, y - 1), (x, y), (x - 1, y));
        let (right, left) = match d {
            R => (se, ne),
            D => (sw, se),
            L => (nw, sw),
            _ => (ne, nw),
        };
        (inside(right.0, right.1), inside(left.0, left.1))
    };
    let mut walked = Vec::new();
    walked.try_reserve_exact(pixels).ok()?;
    walked.resize(pixels, false);
    let mut outers: Vec<Option<Loop>> = Vec::new();
    outers.try_reserve_exact(sizes.len()).ok()?;
    outers.resize_with(sizes.len(), || None);
    let mut holes: Vec<Vec<Loop>> = Vec::new();
    holes.try_reserve_exact(sizes.len()).ok()?;
    holes.resize_with(sizes.len(), Vec::new);

    for (s, (&on, &owner)) in mask.iter().zip(&comp).enumerate() {
        // Start at each unvisited top edge; a top edge uniquely seeds its closed boundary walk.
        if !on || walked[s] || (s >= w && mask.get(s - w) == Some(&true)) {
            continue;
        }
        let (sx, sy) = ((s % w) as i32, (s / w) as i32);
        walked[s] = true;
        let mut pts = Vec::new();
        pts.try_reserve(1).ok()?;
        pts.push((sx, sy));
        let (mut x, mut y) = (sx + 1, sy);
        let mut d = R;
        let mut area2 = 0i64;
        let mut prev = (sx, sy);
        let mut closed = false;
        for _ in 0..=boundary_edges {
            let contribution = i64::from(prev.0)
                .checked_mul(i64::from(y))?
                .checked_sub(i64::from(x).checked_mul(i64::from(prev.1))?)?;
            area2 = area2.checked_add(contribution)?;
            prev = (x, y);
            let (right, left) = ahead(x, y, d);
            let next = if !right {
                right_of(d)
            } else if !left {
                d
            } else {
                right_of(right_of(right_of(d)))
            };
            if (x, y) == (sx, sy) && next == R {
                closed = true;
                break;
            }
            if next == R {
                let pixel = (y as usize).checked_mul(w)?.checked_add(x as usize)?;
                *walked.get_mut(pixel)? = true;
            }
            if next != d {
                pts.try_reserve(1).ok()?;
                pts.push((x, y));
            }
            let (dx, dy) = step(next);
            x = x.checked_add(dx)?;
            y = y.checked_add(dy)?;
            d = next;
        }
        if !closed {
            return None;
        }
        let boundary = Loop { pts, area2 };
        let owner = usize::try_from(owner).ok()?;
        if boundary.area2 > 0 {
            *outers.get_mut(owner)? = Some(boundary);
        } else {
            let component_holes = holes.get_mut(owner)?;
            component_holes.try_reserve(1).ok()?;
            component_holes.push(boundary);
        }
    }

    let mut out = Vec::new();
    out.try_reserve_exact(sizes.len()).ok()?;
    for ((outer, component_holes), &component_pixels) in outers.into_iter().zip(holes).zip(&sizes) {
        if let Some(outer) = outer {
            out.push(Component {
                outer,
                holes: component_holes,
                pixels: component_pixels,
            });
        }
    }
    Some(out)
}

//! Least-squares cubic Bézier fitting of point sequences (the classic "fit a cubic with fixed end
//! tangents, then reparameterise with Newton steps, then split at the worst point" approach from
//! Graphics Gems, written from the published description).

use kurbo::{CubicBez, ParamCurve, ParamCurveDeriv, Point, Vec2};

/// Maximum Newton reparameterisation rounds per fit.
const MAX_REPARAM: usize = 6;
const MAX_FIT_SEGMENTS: usize = 1_023;

/// Unit vector or `None` if (nearly) zero.
pub(crate) fn unit(v: Vec2) -> Option<Vec2> {
    let l = v.hypot();
    if l > 1e-12 && l.is_finite() {
        Some(v / l)
    } else {
        None
    }
}

/// Fit a chain of cubics through `pts` with maximum (parametric) error `tol`.
///
/// `t0` is the unit tangent leaving `pts[0]`; `t1` is the unit tangent arriving at the last point
/// (forward direction). Consecutive output cubics are G1 continuous.
pub(crate) fn fit_cubics(pts: &[Point], t0: Vec2, t1: Vec2, tol: f64) -> Option<Vec<CubicBez>> {
    let mut out = Vec::new();
    let pts = dedup(pts)?;
    if pts.len() < 2 {
        return Some(out);
    }
    fit_rec(&pts, t0, t1, tol.max(1e-9), &mut out, 0)?;
    Some(out)
}

fn dedup(pts: &[Point]) -> Option<Vec<Point>> {
    let mut v: Vec<Point> = Vec::new();
    v.try_reserve_exact(pts.len()).ok()?;
    for &p in pts {
        if v.last().is_none_or(|q: &Point| q.distance(p) > 1e-12) {
            v.push(p);
        }
    }
    Some(v)
}

fn fit_rec(
    pts: &[Point],
    t0: Vec2,
    t1: Vec2,
    tol: f64,
    out: &mut Vec<CubicBez>,
    depth: usize,
) -> Option<()> {
    let n = pts.len();
    if n == 2 {
        if out.len() >= MAX_FIT_SEGMENTS {
            return None;
        }
        let d = pts[0].distance(pts[1]) / 3.0;
        out.try_reserve(1).ok()?;
        out.push(CubicBez::new(
            pts[0],
            pts[0] + t0 * d,
            pts[1] - t1 * d,
            pts[1],
        ));
        return Some(());
    }
    let (c, err, split) = fit_single(pts, t0, t1)?;
    if err <= tol {
        if out.len() >= MAX_FIT_SEGMENTS {
            return None;
        }
        out.try_reserve(1).ok()?;
        out.push(c);
        return Some(());
    }
    if depth >= 40 {
        return None;
    }
    // Split at the worst point with a centre tangent estimated from its neighbours.
    let split = split.clamp(1, n - 2);
    let tc = unit(pts[split + 1] - pts[split - 1]).unwrap_or(t0);
    fit_rec(&pts[..=split], t0, tc, tol, out, depth + 1)?;
    fit_rec(&pts[split..], tc, t1, tol, out, depth + 1)
}

/// Best single cubic for `pts` with the given end tangents. Returns (curve, max error, index of
/// the worst point).
pub(crate) fn fit_single(pts: &[Point], t0: Vec2, t1: Vec2) -> Option<(CubicBez, f64, usize)> {
    Some(fit_single_from(pts, chord_params(pts)?, t0, t1))
}

/// [`fit_single`] starting from the parameters `u` (one per point, 0 to 1) instead of the
/// chord-length ones.
pub(crate) fn fit_single_from(
    pts: &[Point],
    mut u: Vec<f64>,
    t0: Vec2,
    t1: Vec2,
) -> (CubicBez, f64, usize) {
    let mut best = generate(pts, &u, t0, t1);
    let (mut best_err, mut best_split) = max_error(pts, &best, &u);
    for _ in 0..MAX_REPARAM {
        for (i, ui) in u.iter_mut().enumerate() {
            *ui = newton(&best, pts[i], *ui);
        }
        let c = generate(pts, &u, t0, t1);
        let (e, s) = max_error(pts, &c, &u);
        if e < best_err {
            best = c;
            best_err = e;
            best_split = s;
        } else {
            break;
        }
    }
    (best, best_err, best_split)
}

fn chord_params(pts: &[Point]) -> Option<Vec<f64>> {
    let mut u = Vec::new();
    u.try_reserve_exact(pts.len()).ok()?;
    let mut acc = 0.0;
    u.push(0.0);
    for w in pts.windows(2) {
        acc += w[0].distance(w[1]);
        u.push(acc);
    }
    if acc > 0.0 {
        for x in &mut u {
            *x /= acc;
        }
    }
    Some(u)
}

fn bern(t: f64) -> [f64; 4] {
    let s = 1.0 - t;
    [s * s * s, 3.0 * s * s * t, 3.0 * s * t * t, t * t * t]
}

/// Solve the 2x2 normal equations for the handle lengths along the fixed tangents.
fn generate(pts: &[Point], u: &[f64], t0: Vec2, t1: Vec2) -> CubicBez {
    let (Some(&p0), Some(&p3)) = (pts.first(), pts.last()) else {
        return CubicBez::new(Point::ZERO, Point::ZERO, Point::ZERO, Point::ZERO);
    };
    let dir_in = -t1; // handle at the end points backwards
    let (mut c00, mut c01, mut c11, mut x0, mut x1) = (0.0, 0.0, 0.0, 0.0, 0.0);
    for (p, &t) in pts.iter().zip(u) {
        let b = bern(t);
        let a0 = t0 * b[1];
        let a1 = dir_in * b[2];
        c00 += a0.dot(a0);
        c01 += a0.dot(a1);
        c11 += a1.dot(a1);
        let tmp = *p - (p0.to_vec2() * (b[0] + b[1]) + p3.to_vec2() * (b[2] + b[3])).to_point();
        x0 += a0.dot(tmp);
        x1 += a1.dot(tmp);
    }
    let det = c00 * c11 - c01 * c01;
    let seg = p0.distance(p3);
    let eps = 1e-6 * seg;
    let (mut al, mut ar) = if det.abs() > 1e-12 {
        ((x0 * c11 - x1 * c01) / det, (c00 * x1 - c01 * x0) / det)
    } else {
        (seg / 3.0, seg / 3.0)
    };
    if !al.is_finite() || !ar.is_finite() || al < eps || ar < eps {
        al = seg / 3.0;
        ar = seg / 3.0;
    }
    // Guard against wild handles on nearly-degenerate data.
    let cap = seg * 4.0 + 1e-9;
    al = al.min(cap);
    ar = ar.min(cap);
    CubicBez::new(p0, p0 + t0 * al, p3 + dir_in * ar, p3)
}

fn max_error(pts: &[Point], c: &CubicBez, u: &[f64]) -> (f64, usize) {
    let mut e = 0.0;
    let mut idx = pts.len() / 2;
    for (i, (p, &t)) in pts.iter().zip(u).enumerate() {
        let d = c.eval(t).distance(*p);
        if d > e {
            e = d;
            idx = i;
        }
    }
    (e, idx)
}

fn newton(c: &CubicBez, p: Point, t: f64) -> f64 {
    let d1 = c.deriv();
    let d2 = d1.deriv();
    let q = c.eval(t) - p;
    let q1 = d1.eval(t).to_vec2();
    let q2 = d2.eval(t).to_vec2();
    let num = q.dot(q1);
    let den = q1.dot(q1) + q.dot(q2);
    if den.abs() < 1e-12 {
        return t;
    }
    let nt = t - num / den;
    if nt.is_finite() {
        nt.clamp(0.0, 1.0)
    } else {
        t
    }
}

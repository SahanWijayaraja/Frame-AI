import 'package:flutter/material.dart';
import 'composition_analyzer.dart';
import 'yolo_detector.dart';

// Draws visual overlays on top of the camera viewfinder:
//   - Rule of thirds grid (always-on, thin white lines)
//   - Intersection dots (subtle orange)
//   - Subject bounding box with animated glow
//   - Direction arrow hint (move to third intersection)
//   - Perspective tint strip at bottom edge

class CameraOverlayPainter extends CustomPainter {
  final CompositionResult? result;
  final DetectedObject?    subject;
  final bool               showGrid;
  final double             animValue;

  const CameraOverlayPainter({
    this.result,
    this.subject,
    this.showGrid  = true,
    this.animValue = 1.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final W = size.width;
    final H = size.height;

    if (showGrid) _drawGrid(canvas, W, H);
    if (subject != null) _drawSubjectBox(canvas, W, H);
    if (subject != null && result != null) _drawArrow(canvas, W, H);
    if (result != null) _drawAngleStrip(canvas, W, H);
  }

  // ── Rule-of-thirds grid ───────────────────────────────────
  void _drawGrid(Canvas canvas, double W, double H) {
    // Thin semi-transparent white lines — always visible
    final linePaint = Paint()
      ..color       = const Color(0x40FFFFFF)
      ..strokeWidth = 0.7
      ..style       = PaintingStyle.stroke;

    // Vertical
    canvas.drawLine(Offset(W/3, 0),   Offset(W/3, H),   linePaint);
    canvas.drawLine(Offset(W*2/3, 0), Offset(W*2/3, H), linePaint);
    // Horizontal
    canvas.drawLine(Offset(0, H/3),   Offset(W, H/3),   linePaint);
    canvas.drawLine(Offset(0, H*2/3), Offset(W, H*2/3), linePaint);

    // Power-point dots — orange tint
    final dotPaint = Paint()
      ..color = const Color(0x80FF6B2B)
      ..style = PaintingStyle.fill;

    for (final fx in [1/3.0, 2/3.0]) {
      for (final fy in [1/3.0, 2/3.0]) {
        canvas.drawCircle(Offset(W*fx, H*fy), 4.0, dotPaint);
      }
    }
  }

  // ── Subject bounding box with pulsing glow ────────────────
  void _drawSubjectBox(Canvas canvas, double W, double H) {
    if (subject == null) return;

    final l = subject!.x * W;
    final t = subject!.y * H;
    final r = (subject!.x + subject!.width)  * W;
    final b = (subject!.y + subject!.height) * H;

    final rect  = Rect.fromLTRB(l, t, r, b);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(6));

    // Animated outer glow
    final glowAlpha = (80 + (animValue * 80)).round().clamp(0, 200);
    final glowPaint = Paint()
      ..color       = Color.fromARGB(glowAlpha, 255, 107, 43)
      ..strokeWidth = 10
      ..style       = PaintingStyle.stroke
      ..maskFilter  = const MaskFilter.blur(BlurStyle.normal, 8);
    canvas.drawRRect(rrect, glowPaint);

    // Sharp border
    canvas.drawRRect(rrect, Paint()
      ..color       = const Color(0xCCFF6B2B)
      ..strokeWidth = 2
      ..style       = PaintingStyle.stroke);

    // Corner L-marks
    _corners(canvas, l, t, r, b);
  }

  void _corners(Canvas canvas, double l, double t, double r, double b) {
    const len = 12.0;
    final p = Paint()
      ..color = Colors.white
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke;
    // TL
    canvas.drawLine(Offset(l, t+len), Offset(l, t), p);
    canvas.drawLine(Offset(l, t), Offset(l+len, t), p);
    // TR
    canvas.drawLine(Offset(r-len, t), Offset(r, t), p);
    canvas.drawLine(Offset(r, t), Offset(r, t+len), p);
    // BL
    canvas.drawLine(Offset(l, b-len), Offset(l, b), p);
    canvas.drawLine(Offset(l, b), Offset(l+len, b), p);
    // BR
    canvas.drawLine(Offset(r-len, b), Offset(r, b), p);
    canvas.drawLine(Offset(r, b), Offset(r, b-len), p);
  }

  // ── Direction arrow → nearest third intersection ──────────
  void _drawArrow(Canvas canvas, double W, double H) {
    if (result == null || subject == null) return;
    if (result!.ruleOfThirds.score >= 75) return;

    const pts = [
      [1/3.0, 1/3.0], [2/3.0, 1/3.0],
      [1/3.0, 2/3.0], [2/3.0, 2/3.0],
    ];

    final cx = subject!.centerX;
    final cy = subject!.centerY;
    List<double> near = pts[0];
    double minD = double.infinity;
    for (final pt in pts) {
      final d = (cx-pt[0])*(cx-pt[0]) + (cy-pt[1])*(cy-pt[1]);
      if (d < minD) { minD = d; near = pt; }
    }

    final sx = cx * W, sy = cy * H;
    final ex = near[0] * W, ey = near[1] * H;
    final dx = ex - sx, dy = ey - sy;
    final mag = dx*dx + dy*dy;
    if (mag < 400) return;

    final len  = 44.0;
    final sq   = mag > 0 ? mag : 1.0;
    final ndx  = dx / sq * len;
    final ndy  = dy / sq * len;

    final p = Paint()
      ..color       = const Color(0xCCFFFFFF)
      ..strokeWidth = 2.0
      ..style       = PaintingStyle.stroke;

    canvas.drawLine(Offset(sx, sy), Offset(sx+ndx, sy+ndy), p);

    // Arrow head
    const hs = 9.0;
    final hn  = mag > 0 ? mag * 0.5 : 1.0;
    final unx = dx / hn, uny = dy / hn;
    final tip = Offset(sx+ndx, sy+ndy);
    canvas.drawLine(tip, Offset(tip.dx - hs*(unx-uny), tip.dy - hs*(uny+unx)), p);
    canvas.drawLine(tip, Offset(tip.dx - hs*(unx+uny), tip.dy - hs*(uny-unx)), p);

    // Direction text
    // dx > 0 = subject is RIGHT of target → label says move left
    final hDir = cx > near[0]+0.05 ? '← left' : cx < near[0]-0.05 ? 'right →' : '';
    final vDir = cy > near[1]+0.05 ? '↑ up'   : cy < near[1]-0.05 ? 'down ↓'  : '';
    final dir  = [hDir, vDir].where((s) => s.isNotEmpty).join('  ');
    if (dir.isNotEmpty) _label(canvas, dir, Offset(sx+ndx, sy+ndy-18));
  }

  // ── Angle colour strip at bottom ──────────────────────────
  void _drawAngleStrip(Canvas canvas, double W, double H) {
    if (result == null) return;
    final angle = result!.angleLabel;
    if (angle == 'EYE LEVEL') return;

    final color = angle == 'LOW ANGLE'  ? const Color(0x60FF6B2B)
                : angle == 'HIGH ANGLE' ? const Color(0x604A9EFF)
                : const Color(0x60A855F7);

    canvas.drawRect(
      Rect.fromLTWH(0, H - 5, W, 5),
      Paint()..color = color,
    );
  }

  // ── Text label helper ─────────────────────────────────────
  void _label(Canvas canvas, String text, Offset pos) {
    final tp = TextPainter(
      text: TextSpan(
        text:  text,
        style: const TextStyle(
          fontSize: 10, color: Color(0xFFFF6B2B),
          fontWeight: FontWeight.bold, height: 1.2,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(pos.dx-3, pos.dy-2, tp.width+6, tp.height+4),
        const Radius.circular(4),
      ),
      Paint()..color = const Color(0xCC000000),
    );
    tp.paint(canvas, pos);
  }

  @override
  bool shouldRepaint(CameraOverlayPainter old) =>
      old.result    != result    ||
      old.subject   != subject   ||
      old.showGrid  != showGrid  ||
      old.animValue != animValue;
}

// Widget wrapper with pulse animation
class CameraOverlayWidget extends StatefulWidget {
  final CompositionResult? result;
  final DetectedObject?    subject;
  final bool               showGrid;

  const CameraOverlayWidget({
    super.key, this.result, this.subject, this.showGrid = true,
  });

  @override
  State<CameraOverlayWidget> createState() => _CameraOverlayWidgetState();
}

class _CameraOverlayWidgetState extends State<CameraOverlayWidget>
    with SingleTickerProviderStateMixin {

  late AnimationController _ctrl;
  late Animation<double>   _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _anim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, __) => CustomPaint(
        painter: CameraOverlayPainter(
          result:    widget.result,
          subject:   widget.subject,
          showGrid:  widget.showGrid,
          animValue: _anim.value,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

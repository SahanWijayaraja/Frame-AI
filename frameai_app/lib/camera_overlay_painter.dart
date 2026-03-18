import 'package:flutter/material.dart';
import 'composition_analyzer.dart';
import 'yolo_detector.dart';

// Draws visual overlays on top of the camera viewfinder:
//   - Rule of thirds grid (orange dashed lines)
//   - Subject bounding box with glow outline
//   - Direction arrow hint (move left / right / up / down)
//   - Leading line highlight
//   - Depth gradient strip for perspective

class CameraOverlayPainter extends CustomPainter {
  final CompositionResult? result;
  final DetectedObject?    subject;
  final bool               showGrid;
  final double             animValue;  // 0.0 to 1.0 for pulse animation

  const CameraOverlayPainter({
    this.result,
    this.subject,
    this.showGrid  = true,
    this.animValue = 1.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (result == null) return;

    final W = size.width;
    final H = size.height;

    // Draw in this order so nothing important gets covered
    if (showGrid)        _drawGrid(canvas, W, H);
    if (subject != null) _drawSubjectGlow(canvas, W, H);
                         _drawArrowHint(canvas, W, H);
                         _drawPerspectiveStrip(canvas, W, H);
  }

  // ── Rule of thirds grid ───────────────────────────────────
  void _drawGrid(Canvas canvas, double W, double H) {
    final paint = Paint()
      ..color       = const Color(0x80FF6B2B)
      ..strokeWidth = 0.8
      ..style       = PaintingStyle.stroke;

    // Vertical lines at 1/3 and 2/3
    canvas.drawLine(Offset(W/3, 0),   Offset(W/3, H),   paint);
    canvas.drawLine(Offset(W*2/3, 0), Offset(W*2/3, H), paint);

    // Horizontal lines at 1/3 and 2/3
    canvas.drawLine(Offset(0, H/3),   Offset(W, H/3),   paint);
    canvas.drawLine(Offset(0, H*2/3), Offset(W, H*2/3), paint);

    // Intersection dots — highlight the 4 power points
    final dotPaint = Paint()
      ..color = const Color(0xCCFF6B2B)
      ..style = PaintingStyle.fill;

    for (final fx in [1/3.0, 2/3.0]) {
      for (final fy in [1/3.0, 2/3.0]) {
        canvas.drawCircle(Offset(W*fx, H*fy), 3.0, dotPaint);
      }
    }
  }

  // ── Subject bounding box with pulsing glow ────────────────
  void _drawSubjectGlow(Canvas canvas, double W, double H) {
    if (subject == null) return;

    final left   = subject!.x       * W;
    final top    = subject!.y       * H;
    final right  = (subject!.x + subject!.width)  * W;
    final bottom = (subject!.y + subject!.height) * H;
    final rect   = Rect.fromLTRB(left, top, right, bottom);
    final rrect  = RRect.fromRectAndRadius(rect, const Radius.circular(6));

    // Outer glow — pulses with animValue
    final glowOpacity = (0.3 + animValue * 0.3).clamp(0.0, 1.0);
    final glowPaint   = Paint()
      ..color       = Color.fromRGBO(255, 107, 43, glowOpacity)
      ..strokeWidth = 8
      ..style       = PaintingStyle.stroke
      ..maskFilter  = const MaskFilter.blur(BlurStyle.normal, 6);
    canvas.drawRRect(rrect, glowPaint);

    // Inner sharp border
    final borderPaint = Paint()
      ..color       = const Color(0xCCFF6B2B)
      ..strokeWidth = 2
      ..style       = PaintingStyle.stroke;
    canvas.drawRRect(rrect, borderPaint);

    // Corner accents — small L-shapes at each corner
    _drawCornerAccents(canvas, left, top, right, bottom);

    // Subject label at top of box
    _drawLabel(
      canvas,
      subject!.className,
      Offset(left + 4, top - 14),
    );
  }

  // Small L-shaped corner marks
  void _drawCornerAccents(Canvas canvas,
      double l, double t, double r, double b) {
    const len   = 10.0;
    final paint = Paint()
      ..color       = Colors.white
      ..strokeWidth = 2
      ..style       = PaintingStyle.stroke;

    // Top-left
    canvas.drawLine(Offset(l, t+len), Offset(l, t), paint);
    canvas.drawLine(Offset(l, t),     Offset(l+len, t), paint);
    // Top-right
    canvas.drawLine(Offset(r-len, t), Offset(r, t), paint);
    canvas.drawLine(Offset(r, t),     Offset(r, t+len), paint);
    // Bottom-left
    canvas.drawLine(Offset(l, b-len), Offset(l, b), paint);
    canvas.drawLine(Offset(l, b),     Offset(l+len, b), paint);
    // Bottom-right
    canvas.drawLine(Offset(r-len, b), Offset(r, b), paint);
    canvas.drawLine(Offset(r, b),     Offset(r, b-len), paint);
  }

  // ── Direction arrow hint ──────────────────────────────────
  void _drawArrowHint(Canvas canvas, double W, double H) {
    if (subject == null || result == null) return;

    final r1Score = result!.ruleOfThirds.score;
    if (r1Score >= 75) return;   // already good — no arrow needed

    // Find the nearest third intersection
    const intersections = [
      [1/3.0, 1/3.0], [2/3.0, 1/3.0],
      [1/3.0, 2/3.0], [2/3.0, 2/3.0],
    ];

    final cx = subject!.centerX;
    final cy = subject!.centerY;

    List<double> nearest = intersections[0];
    double minDist       = double.infinity;
    for (final pt in intersections) {
      final d = (cx-pt[0])*(cx-pt[0]) + (cy-pt[1])*(cy-pt[1]);
      if (d < minDist) { minDist = d; nearest = pt; }
    }

    // Arrow from subject centre toward nearest intersection
    final startX = cx        * W;
    final startY = cy        * H;
    final endX   = nearest[0]* W;
    final endY   = nearest[1]* H;

    final dx   = endX - startX;
    final dy   = endY - startY;
    final dist = (dx*dx + dy*dy).abs();
    if (dist < 10) return;   // already close enough

    final len    = 40.0;
    final mag    = (dx*dx + dy*dy) > 0 ? (dx*dx + dy*dy) : 1.0;
    final normX  = dx / mag * len;
    final normY  = dy / mag * len;

    final paint = Paint()
      ..color       = const Color(0xCCFFFFFF)
      ..strokeWidth = 2
      ..style       = PaintingStyle.stroke;

    canvas.drawLine(
      Offset(startX, startY),
      Offset(startX + normX, startY + normY),
      paint,
    );

    // Arrowhead
    _drawArrowHead(
      canvas,
      Offset(startX, startY),
      Offset(startX + normX, startY + normY),
      paint,
    );

    // "Move here" label near the arrowhead
    final hDir = cx > nearest[0] + 0.05 ? '← left'  :
                 cx < nearest[0] - 0.05 ? 'right →'  : '';
    final vDir = cy > nearest[1] + 0.05 ? '↑ up'     :
                 cy < nearest[1] - 0.05 ? 'down ↓'   : '';
    final dir  = [hDir, vDir].where((s) => s.isNotEmpty).join('  ');

    if (dir.isNotEmpty) {
      _drawLabel(
        canvas,
        dir,
        Offset(startX + normX, startY + normY - 16),
      );
    }
  }

  void _drawArrowHead(Canvas canvas, Offset from, Offset to, Paint paint) {
    final dx     = to.dx - from.dx;
    final dy     = to.dy - from.dy;
    final mag    = (dx*dx + dy*dy) > 0
        ? (dx*dx + dy*dy) * 0.5
        : 1.0;
    final normX  = dx / mag;
    final normY  = dy / mag;
    const size   = 8.0;

    final left  = Offset(
      to.dx - size * (normX - normY),
      to.dy - size * (normY + normX),
    );
    final right = Offset(
      to.dx - size * (normX + normY),
      to.dy - size * (normY - normX),
    );

    canvas.drawLine(to, left,  paint);
    canvas.drawLine(to, right, paint);
  }

  // ── Perspective depth strip at bottom ─────────────────────
  void _drawPerspectiveStrip(Canvas canvas, double W, double H) {
    if (result == null) return;

    final angle = result!.angleLabel;
    if (angle == 'EYE LEVEL') return;   // no strip for eye level

    final color = angle == 'LOW ANGLE'  ? const Color(0x80FF6B2B) :
                  angle == 'HIGH ANGLE' ? const Color(0x804A9EFF) :
                  const Color(0x80A855F7);

    // Small coloured strip along the bottom edge
    final stripPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    canvas.drawRect(
      Rect.fromLTWH(0, H - 6, W, 6),
      stripPaint,
    );

    // Angle label
    _drawLabel(canvas, angle, Offset(8, H - 18));
  }

  // ── Helper: draw a small text label with dark background ──
  void _drawLabel(Canvas canvas, String text, Offset position) {
    final tp = TextPainter(
      text: TextSpan(
        text:  text,
        style: const TextStyle(
          fontSize:   9,
          color:      Color(0xFFFF6B2B),
          fontWeight: FontWeight.bold,
          height:     1.2,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    // Dark background pill
    final bgRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        position.dx - 3,
        position.dy - 2,
        tp.width  + 6,
        tp.height + 4,
      ),
      const Radius.circular(4),
    );

    canvas.drawRRect(
      bgRect,
      Paint()..color = const Color(0xCC000000),
    );

    tp.paint(canvas, position);
  }

  @override
  bool shouldRepaint(CameraOverlayPainter old) =>
      old.result    != result    ||
      old.subject   != subject   ||
      old.showGrid  != showGrid  ||
      old.animValue != animValue;
}

// Widget that wraps the painter with a pulse animation
class CameraOverlayWidget extends StatefulWidget {
  final CompositionResult? result;
  final DetectedObject?    subject;
  final bool               showGrid;

  const CameraOverlayWidget({
    super.key,
    this.result,
    this.subject,
    this.showGrid = true,
  });

  @override
  State<CameraOverlayWidget> createState() => _CameraOverlayWidgetState();
}

class _CameraOverlayWidgetState extends State<CameraOverlayWidget>
    with SingleTickerProviderStateMixin {

  late AnimationController _controller;
  late Animation<double>   _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _animation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, _) {
        return CustomPaint(
          painter: CameraOverlayPainter(
            result:    widget.result,
            subject:   widget.subject,
            showGrid:  widget.showGrid,
            animValue: _animation.value,
          ),
          child: const SizedBox.expand(),
        );
      },
    );
  }
}

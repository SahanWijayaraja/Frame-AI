import 'package:flutter/material.dart';
import 'dart:ui' as ui;

class GlowEdgePainter extends CustomPainter {
  final ui.Image edgeMask;
  final double pulseAnim;
  final Color glowColor;

  GlowEdgePainter({
    required this.edgeMask,
    required this.pulseAnim,
    this.glowColor = const Color(0xFF00D4FF),
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = glowColor.withOpacity(0.4 + 0.3 * pulseAnim)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 5 + 10 * pulseAnim)
      ..strokeWidth = 3 + 2 * pulseAnim;

    // Draw the edge mask onto the canvas, scaled to fit
    canvas.drawImageRect(
      edgeMask,
      Rect.fromLTWH(0, 0, edgeMask.width.toDouble(), edgeMask.height.toDouble()),
      Rect.fromLTWH(0, 0, size.width, size.height),
      paint,
    );
    
    // Optional: Draw a second pass for extra glow
    final paint2 = Paint()
      ..color = glowColor.withOpacity(0.2 * pulseAnim)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 15 + 15 * pulseAnim);
      
    canvas.drawImageRect(
      edgeMask,
      Rect.fromLTWH(0, 0, edgeMask.width.toDouble(), edgeMask.height.toDouble()),
      Rect.fromLTWH(0, 0, size.width, size.height),
      paint2,
    );
  }

  @override
  bool shouldRepaint(covariant GlowEdgePainter oldDelegate) {
    return oldDelegate.pulseAnim != pulseAnim || oldDelegate.edgeMask != edgeMask;
  }
}

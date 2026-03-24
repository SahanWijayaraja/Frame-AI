import 'dart:typed_data';
import 'dart:math';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;
import 'yolo_detector.dart';

class RuleResult {
  final String ruleName;
  final int    score;     // 0–100, or -1 = N/A (not applicable)
  final String tip;
  final bool   detected;  // false = rule could not be evaluated

  const RuleResult({
    required this.ruleName,
    required this.score,
    required this.tip,
    required this.detected,
  });
}

class CompositionResult {
  final RuleResult ruleOfThirds;
  final RuleResult leadingLines;
  final RuleResult negativeSpace;
  final RuleResult symmetry;
  final RuleResult framing;
  final RuleResult perspective;
  final int        overallScore;
  final double     nimaScore;
  final String     bestTip;
  final String     angleLabel;
  final String     professionalSuggestion;

  const CompositionResult({
    required this.ruleOfThirds,
    required this.leadingLines,
    required this.negativeSpace,
    required this.symmetry,
    required this.framing,
    required this.perspective,
    required this.overallScore,
    required this.nimaScore,
    required this.bestTip,
    required this.angleLabel,
    required this.professionalSuggestion,
  });

  List<RuleResult> get allRules => [
    ruleOfThirds, leadingLines, negativeSpace,
    symmetry, framing, perspective,
  ];
}

class CompositionAnalyzer {
  final YoloDetector _yolo = YoloDetector();
  Interpreter? _deeplabInterpreter;
  Interpreter? _midasInterpreter;
  Interpreter? _nimaInterpreter;

  YoloDetector get yolo => _yolo;

  Future<void> loadModels() async {
    try {
      await _yolo.loadModel();
      final options = InterpreterOptions()..threads = 2;
      _deeplabInterpreter = await Interpreter.fromAsset(
          'assets/models/deeplabv3.tflite', options: options);
      _midasInterpreter   = await Interpreter.fromAsset(
          'assets/models/midas_small.tflite', options: options);
      _nimaInterpreter    = await Interpreter.fromAsset(
          'assets/models/nima_mobilenet.tflite', options: options);
    } catch (_) {
      // partial load — individual rules will fall back gracefully
    }
  }

  Future<CompositionResult> analyseImage(List<int> imageBytes) async {
    final image = img.decodeImage(Uint8List.fromList(imageBytes));
    if (image == null) return _errorResult('Could not decode image');

    // Run YOLO detection once; reuse result for rules 1 and 3
    final detections = await _yolo.detect(image);
    final subject    = _yolo.getPrimarySubject(detections);

    // Run all 6 rules and NIMA in parallel where possible
    final r1Future = Future.value(_checkRuleOfThirds(subject));
    final r2Future = Future.value(_checkLeadingLines(image));
    final r3Future = Future.value(_checkNegativeSpace(subject));
    final r4Future = Future.value(_checkSymmetry(image));
    final r5Future = _checkFraming(image, subject);
    final r6Future = _checkPerspective(image);
    final nimaFuture = _getNimaScore(image);

    final results = await Future.wait([
      r1Future, r2Future, r3Future, r4Future, r5Future, r6Future,
    ]);
    final nimaScore = await nimaFuture;

    final r1 = results[0]; final r2 = results[1]; final r3 = results[2];
    final r4 = results[3]; final r5 = results[4]; final r6 = results[5];

    // Overall = mean of detected rules only (don't punish for N/A)
    final active = [r1,r2,r3,r4,r5,r6].where((r) => r.detected && r.score >= 0).toList();
    final overall = active.isEmpty
        ? 50
        : (active.map((r) => r.score).reduce((a,b) => a+b) / active.length).round();

    // Best tip = from weakest detected rule
    final weakest = active.isEmpty ? null
        : active.reduce((a, b) => a.score < b.score ? a : b);

    final suggestion = _suggestion(r1, r2, r3, r4, r5, r6, nimaScore);
    final angle = r6.tip.contains('LOW') ? 'LOW ANGLE' :
                  r6.tip.contains('HIGH') ? 'HIGH ANGLE' : 'EYE LEVEL';

    return CompositionResult(
      ruleOfThirds: r1, leadingLines: r2, negativeSpace: r3,
      symmetry: r4, framing: r5, perspective: r6,
      overallScore: overall.clamp(0, 100),
      nimaScore:    nimaScore,
      bestTip:      weakest?.tip ?? 'Frame your shot and tap ANALYSE.',
      angleLabel:   angle,
      professionalSuggestion: suggestion,
    );
  }

  // ══════════════════════════════════════════════════════════
  // RULE 1 — Rule of Thirds (YOLOv8n)
  // Score 100 = subject centre is exactly on a third intersection
  // Score 0   = subject centre is at the frame centre (worst case)
  // ══════════════════════════════════════════════════════════
  RuleResult _checkRuleOfThirds(DetectedObject? subject) {
    if (subject == null) {
      return const RuleResult(
        ruleName: 'Rule of Thirds', score: -1,
        tip: 'No subject detected. Point at a clear subject.', detected: false,
      );
    }

    const intersections = [
      [1/3.0, 1/3.0], [2/3.0, 1/3.0],
      [1/3.0, 2/3.0], [2/3.0, 2/3.0],
    ];

    double minDist = double.infinity;
    List<double> nearest = intersections[0];
    for (final pt in intersections) {
      final dx = subject.centerX - pt[0];
      final dy = subject.centerY - pt[1];
      final d  = sqrt(dx*dx + dy*dy);
      if (d < minDist) { minDist = d; nearest = pt; }
    }

    // Max possible distance from any intersection is ~0.47 (at corners)
    // At distance 0 → score 100; at distance 0.47 → score 0
    final score = (max(0.0, 1.0 - minDist / 0.47) * 100).round().clamp(0, 100);

    String tip;
    if (score >= 75) {
      tip = 'Great placement at a power point.';
    } else {
      final hDir = subject.centerX > nearest[0] + 0.05 ? 'left'  :
                   subject.centerX < nearest[0] - 0.05 ? 'right' : '';
      final vDir = subject.centerY > nearest[1] + 0.05 ? 'up'    :
                   subject.centerY < nearest[1] - 0.05 ? 'down'  : '';
      final dirs = [hDir, vDir].where((d) => d.isNotEmpty).join(' & ');
      tip = dirs.isNotEmpty
          ? 'Move $dirs to hit a thirds power point.'
          : 'Slightly adjust subject position.';
    }
    return RuleResult(ruleName: 'Rule of Thirds', score: score, tip: tip, detected: true);
  }

  // ══════════════════════════════════════════════════════════
  // RULE 2 — Leading Lines (Sobel gradient convergence)
  // Score 100 = strong directional lines converging toward centre
  // Score 0   = no directional edges found
  // NOTE: returned as "detected: true" always when edges exist,
  //       so the user always gets feedback (just a lower score).
  // ══════════════════════════════════════════════════════════
  RuleResult _checkLeadingLines(img.Image image) {
    try {
      const size = 96;
      final small = img.copyResize(image, width: size, height: size);
      final gray  = img.grayscale(small);

      int converging = 0;
      int total      = 0;

      for (int y = 1; y < size - 1; y++) {
        for (int x = 1; x < size - 1; x++) {
          final tl = gray.getPixel(x-1, y-1).r.toInt();
          final tc = gray.getPixel(x,   y-1).r.toInt();
          final tr = gray.getPixel(x+1, y-1).r.toInt();
          final ml = gray.getPixel(x-1, y  ).r.toInt();
          final mr = gray.getPixel(x+1, y  ).r.toInt();
          final bl = gray.getPixel(x-1, y+1).r.toInt();
          final bc = gray.getPixel(x,   y+1).r.toInt();
          final br = gray.getPixel(x+1, y+1).r.toInt();

          final gx = (-tl - 2*ml - bl + tr + 2*mr + br).toDouble();
          final gy = (-tl - 2*tc - tr + bl + 2*bc + br).toDouble();
          final mag = sqrt(gx*gx + gy*gy);

          if (mag < 25) continue; // ignore weak edges
          total++;

          // Dot product with direction toward frame centre
          final cx = (size / 2 - x).toDouble();
          final cy = (size / 2 - y).toDouble();
          if (gx * cx + gy * cy > 0) converging++;
        }
      }

      if (total < 100) {
        return const RuleResult(
          ruleName: 'Leading Lines', score: 20,
          tip: 'Very few edges detected. Look for roads, fences, or corridors.',
          detected: true,   // always show rule — just low score
        );
      }

      // Natural images: ~48–52% converge by chance.
      // Anything >60% = real leading lines toward centre.
      final ratio = converging / total;
      // Map [0.48 .. 0.80] → [0 .. 100]
      final score = ((ratio - 0.48) / 0.32 * 100).round().clamp(0, 100);

      String tip;
      if (score >= 70)      tip = 'Great leading lines drawing the eye into the frame.';
      else if (score >= 40) tip = 'Some directional lines present. Look for stronger paths.';
      else                  tip = 'No strong leading lines. Try roads, fences, or corridors.';

      return RuleResult(ruleName: 'Leading Lines', score: score, tip: tip, detected: true);
    } catch (_) {
      return const RuleResult(
        ruleName: 'Leading Lines', score: 30,
        tip: 'Look for roads, fences, or corridors to guide the eye.', detected: true,
      );
    }
  }

  // ══════════════════════════════════════════════════════════
  // RULE 3 — Negative Space (YOLOv8n bbox area)
  // Ideal: subject fills 10–35% of the frame
  // ══════════════════════════════════════════════════════════
  RuleResult _checkNegativeSpace(DetectedObject? subject) {
    if (subject == null) {
      return const RuleResult(
        ruleName: 'Negative Space', score: -1,
        tip: 'No subject detected to measure negative space.', detected: false,
      );
    }

    final ratio = subject.area.clamp(0.0, 1.0);
    int    score;
    String tip;

    if (ratio >= 0.10 && ratio <= 0.35) {
      // Perfect! Peak at 22% centre of ideal
      final deviation = (ratio - 0.225).abs() / 0.125;
      score = (100 - deviation * 20).round().clamp(80, 100);
      tip   = 'Great breathing room — subject fills ${(ratio*100).round()}% of frame.';
    } else if (ratio < 0.10) {
      score = (ratio / 0.10 * 70).round().clamp(0, 70);
      tip   = 'Subject too small (${(ratio*100).round()}%). Move closer.';
    } else if (ratio <= 0.55) {
      final excess = (ratio - 0.35) / 0.20;
      score = (80 - excess * 60).round().clamp(10, 80);
      tip   = 'Slightly cramped (${(ratio*100).round()}%). Step back a little.';
    } else {
      score = max(0, ((1.0 - ratio) * 30).round());
      tip   = 'Too tight — subject fills ${(ratio*100).round()}%. Step further back.';
    }

    return RuleResult(ruleName: 'Negative Space', score: score.clamp(0,100), tip: tip, detected: true);
  }

  // ══════════════════════════════════════════════════════════
  // RULE 4 — Symmetry (pixel comparison)
  // FIXED: The previous threshold was far too low.
  // Natural photos have ~55–70% pixel similarity by chance.
  // True symmetric scenes (reflections, arch) reach 85–95%.
  // Score = 0 below 70%, 100 at 92%+.
  // ══════════════════════════════════════════════════════════
  RuleResult _checkSymmetry(img.Image image) {
    try {
      final small = img.copyResize(image, width: 64, height: 64);
      final W = small.width;
      final H = small.height;

      // Left-right comparison
      double lrDiff = 0;
      for (int y = 0; y < H; y++) {
        for (int x = 0; x < W ~/ 2; x++) {
          final l = small.getPixel(x,       y);
          final r = small.getPixel(W-1-x, y);
          lrDiff += ((l.r-r.r).abs() + (l.g-r.g).abs() + (l.b-r.b).abs());
        }
      }
      final lrSim = 1.0 - lrDiff / ((W/2) * H * 3 * 255);

      // Top-bottom comparison
      double tbDiff = 0;
      for (int y = 0; y < H ~/ 2; y++) {
        for (int x = 0; x < W; x++) {
          final t = small.getPixel(x, y);
          final b = small.getPixel(x, H-1-y);
          tbDiff += ((t.r-b.r).abs() + (t.g-b.g).abs() + (t.b-b.b).abs());
        }
      }
      final tbSim = 1.0 - tbDiff / (W * (H/2) * 3 * 255);

      final bestSim   = max(lrSim, tbSim);
      final direction = lrSim >= tbSim ? 'left-right' : 'top-bottom';

      // KEY FIX: Rescale so that:
      // ≤ 0.75 → score 0  (typical natural scene, not symmetric)
      // 0.88  → score ~50 (partially symmetric)
      // 0.94+ → score 100 (strong symmetry — reflections, arches)
      final score = ((bestSim - 0.75) / 0.19 * 100).round().clamp(0, 100);

      String tip;
      if (score >= 70) {
        tip = 'Strong $direction symmetry — perfectly balanced composition.';
      } else if (score >= 35) {
        tip = 'Partial $direction symmetry. Centre your subject for stronger balance.';
      } else {
        tip = 'Low symmetry — try reflections, still water, or a centred arch.';
      }

      return RuleResult(ruleName: 'Symmetry', score: score, tip: tip, detected: true);
    } catch (_) {
      return const RuleResult(
        ruleName: 'Symmetry', score: 20,
        tip: 'Try reflections or centred subjects for symmetry.', detected: true,
      );
    }
  }

  // ══════════════════════════════════════════════════════════
  // RULE 5 — Framing (DeepLabV3)
  // Checks if different semantic classes appear on the frame borders
  // ══════════════════════════════════════════════════════════
  Future<RuleResult> _checkFraming(img.Image image, DetectedObject? subject) async {
    if (_deeplabInterpreter == null) {
      return const RuleResult(
        ruleName: 'Framing', score: 20,
        tip: 'Look for windows, arches, or branches to frame your subject.',
        detected: true,
      );
    }
    try {
      const dlSize = 257;
      final resized = img.copyResize(image, width: dlSize, height: dlSize);

      // Preprocess input based on tensor type
      final inputInfo = _deeplabInterpreter!.getInputTensor(0);
      final isInt8    = inputInfo.type == TFLiteType.int8;
      final isUint8   = inputInfo.type == TFLiteType.uint8;

      Object input;
      if (isInt8 || isUint8) {
        input = List.generate(1, (_) => List.generate(
          dlSize, (y) => List.generate(dlSize, (x) {
            final p = resized.getPixel(x, y);
            if (isUint8) return [p.r.toInt(), p.g.toInt(), p.b.toInt()];
            return [p.r.toInt() - 128, p.g.toInt() - 128, p.b.toInt() - 128];
          }),
        ));
      } else {
        // Normalise to [0, 1]
        input = List.generate(1, (_) => List.generate(
          dlSize, (y) => List.generate(dlSize, (x) {
            final p = resized.getPixel(x, y);
            return [p.r / 255.0, p.g / 255.0, p.b / 255.0];
          }),
        ));
      }

      final outShape = _deeplabInterpreter!.getOutputTensor(0).shape;
      // Expected: [1, 257, 257, 21]
      final output   = List.generate(outShape[0], (_) => List.generate(
        outShape[1], (_) => List.generate(outShape[2], (_) =>
          List.filled(outShape[3], 0.0),
        ),
      ));

      _deeplabInterpreter!.run(input, output);

      // Argmax per pixel over 21 classes
      final seg = List.generate(dlSize, (y) => List.generate(dlSize, (x) {
        final s = output[0][y][x];
        int best = 0; double bv = s[0];
        for (int c = 1; c < s.length; c++) {
          if (s[c] > bv) { bv = s[c]; best = c; }
        }
        return best;
      }));

      // Determine dominant class in the centre region
      final cx1 = (dlSize * 0.25).round(); final cx2 = (dlSize * 0.75).round();
      final cy1 = (dlSize * 0.20).round(); final cy2 = (dlSize * 0.80).round();
      final counts = List.filled(21, 0);
      for (int y = cy1; y < cy2; y++) {
        for (int x = cx1; x < cx2; x++) counts[seg[y][x]]++;
      }
      counts[0] = 0; // ignore background
      int subjClass = 0, maxCnt = 0;
      for (int c = 0; c < 21; c++) {
        if (counts[c] > maxCnt) { maxCnt = counts[c]; subjClass = c; }
      }

      if (maxCnt < 100) {
        return const RuleResult(
          ruleName: 'Framing', score: 15,
          tip: 'No clear subject centre detected. Try shooting through a frame.',
          detected: true,
        );
      }

      final stripW = (dlSize * 0.15).round();
      final sides  = {
        'TOP'   : _mostCommonClass(seg, 0,          stripW,  cx1, cx2),
        'BOTTOM': _mostCommonClass(seg, dlSize-stripW, dlSize, cx1, cx2),
        'LEFT'  : _mostCommonClass(seg, cy1,          cy2,    0,   stripW),
        'RIGHT' : _mostCommonClass(seg, cy1,          cy2,    dlSize-stripW, dlSize),
      };

      // A side "frames" the subject if it has a DIFFERENT class than subject centre
      final framingSides = sides.entries
          .where((e) => e.value != subjClass && e.value != 0)
          .map((e) => e.key).toList();

      final n     = framingSides.length;
      // [0 sides=15, 1 side=35, 2 sides=60, 3 sides=80, 4 sides=98]
      final score = n == 0 ? 15 : n == 1 ? 35 : n == 2 ? 60 : n == 3 ? 80 : 98;

      String tip;
      if (n >= 3) tip = 'Excellent! Subject framed on $n sides.';
      else if (n == 2) {
        final missing = ['TOP','BOTTOM','LEFT','RIGHT']
            .where((s) => !framingSides.contains(s)).toList();
        tip = 'Add a framing element on the ${missing.first} side.';
      } else if (n == 1) tip = 'Weak framing. Try shooting through a doorway or arch.';
      else               tip = 'No framing detected. Look for windows, trees, or arches.';

      return RuleResult(ruleName: 'Framing', score: score, tip: tip, detected: true);
    } catch (_) {
      return const RuleResult(
        ruleName: 'Framing', score: 20,
        tip: 'Look for natural frames like arches, windows, or branches.',
        detected: true,
      );
    }
  }

  int _mostCommonClass(List<List<int>> seg, int y0, int y1, int x0, int x1) {
    final c = List.filled(21, 0);
    for (int y = y0; y < y1 && y < seg.length; y++) {
      for (int x = x0; x < x1 && x < seg[0].length; x++) c[seg[y][x]]++;
    }
    int best = 0, bv = 0;
    for (int i = 0; i < 21; i++) { if (c[i] > bv) { bv = c[i]; best = i; } }
    return best;
  }

  // ══════════════════════════════════════════════════════════
  // RULE 6 — Perspective & Angle (MiDaS depth map)
  // Compare mean depth of top zones vs bottom zones.
  // In MiDaS: HIGHER value = CLOSER to camera.
  // EYE LEVEL: top/bottom means are roughly equal → score 50
  // LOW ANGLE (camera tilted up): foreground=bottom is close (high depth),
  //   sky=top is far (low depth) → botMean > topMean
  // HIGH ANGLE (camera tilted down): top close → topMean > botMean
  // Score reflects intentionality of the perspective choice.
  // ══════════════════════════════════════════════════════════
  Future<RuleResult> _checkPerspective(img.Image image) async {
    if (_midasInterpreter == null) {
      return const RuleResult(
        ruleName: 'Perspective', score: 50,
        tip: 'EYE LEVEL — try a low or high angle for more drama.', detected: true,
      );
    }
    try {
      const mdSize = 256;
      final resized = img.copyResize(image, width: mdSize, height: mdSize);

      // Preprocess input based on tensor type
      final inputInfo = _midasInterpreter!.getInputTensor(0);
      final isInt8    = inputInfo.type == TFLiteType.int8;
      final isUint8   = inputInfo.type == TFLiteType.uint8;

      Object input;
      if (isInt8 || isUint8) {
        input = List.generate(1, (_) => List.generate(
          mdSize, (y) => List.generate(mdSize, (x) {
            final p = resized.getPixel(x, y);
            if (isUint8) return [p.r.toInt(), p.g.toInt(), p.b.toInt()];
            return [(p.r.toInt() - 128), (p.g.toInt() - 128), (p.b.toInt() - 128)];
          }),
        ));
      } else {
        // MiDaS Small normalisation: scale to [−1, +1]
        input = List.generate(1, (_) => List.generate(
          mdSize, (y) => List.generate(mdSize, (x) {
            final p = resized.getPixel(x, y);
            return [p.r / 127.5 - 1.0, p.g / 127.5 - 1.0, p.b / 127.5 - 1.0];
          }),
        ));
      }

      final outShape = _midasInterpreter!.getOutputTensor(0).shape;
      // Typical shape: [1, 256, 256] or [1, H, W]
      final output   = List.generate(outShape[0], (_) => List.generate(
        outShape[1], (_) => List.filled(outShape[2], 0.0),
      ));
      _midasInterpreter!.run(input, output);

      // Normalise depth to [0, 1]
      final flat   = output[0].expand((r) => r).toList();
      final dMin   = flat.reduce(min);
      final dMax   = flat.reduce(max);
      final dRange = (dMax - dMin).abs();
      if (dRange < 1e-4) {
        return const RuleResult(
          ruleName: 'Perspective', score: 50,
          tip: 'EYE LEVEL — uniform depth detected. Try a different angle.',
          detected: true,
        );
      }

      final depth = List.generate(mdSize, (y) => List.generate(
        mdSize, (x) => (output[0][y][x] - dMin) / dRange,
      ));

      // Divide into 5 vertical bands and compute means
      final band = mdSize ~/ 5;
      final means = List.generate(5, (i) {
        double s = 0; int n = 0;
        for (int y = i*band; y < (i+1)*band && y < mdSize; y++) {
          for (int x = 0; x < mdSize; x++) { s += depth[y][x]; n++; }
        }
        return n > 0 ? s / n : 0.5;
      });

      final topMean = (means[0] + means[1]) / 2;  // upper 2 bands
      final botMean = (means[3] + means[4]) / 2;  // lower 2 bands
      final vDiff   = botMean - topMean;           // positive = low angle

      // Sky detection: blue-dominant pixels in top 1/4
      int skyP = 0;
      const skyH = mdSize ~/ 4;
      for (int y = 0; y < skyH; y++) {
        for (int x = 0; x < mdSize; x++) {
          final p = resized.getPixel(x, y);
          if (p.b.toInt() > p.r.toInt() + 15 &&
              p.b.toInt() > p.g.toInt() &&
              p.b.toInt() > 85) skyP++;
        }
      }
      final skyRatio = skyP / (skyH * mdSize);

      String label;
      int    score;

      // Calibrated thresholds based on typical MiDaS depth maps:
      if (vDiff > 0.20 && (skyRatio > 0.06 || vDiff > 0.30)) {
        label = 'LOW ANGLE';
        score = min(100, (50 + (vDiff - 0.20) / 0.30 * 50).round());
      } else if (vDiff > 0.08) {
        label = 'SLIGHT LOW ANGLE';
        score = min(90, (40 + (vDiff / 0.20) * 40).round());
      } else if (vDiff < -0.20) {
        label = 'HIGH ANGLE';
        score = min(100, (50 + ((-vDiff) - 0.20) / 0.30 * 50).round());
      } else if (vDiff < -0.08) {
        label = 'SLIGHT HIGH ANGLE';
        score = min(90, (40 + ((-vDiff) / 0.20) * 40).round());
      } else {
        label = 'EYE LEVEL';
        score = 50; // valid choice — not penalised
      }

      final tip =
          label == 'LOW ANGLE'        ? 'LOW ANGLE — dramatic, powerful shot. Well done.' :
          label == 'SLIGHT LOW ANGLE' ? 'SLIGHT LOW ANGLE — go even lower for more impact.' :
          label == 'HIGH ANGLE'       ? 'HIGH ANGLE — commanding overhead perspective.' :
          label == 'SLIGHT HIGH ANGLE'? 'SLIGHT HIGH ANGLE — try going fully overhead.' :
          'EYE LEVEL — try a low or high angle for more dynamic feel.';

      return RuleResult(
        ruleName: 'Perspective', score: score.clamp(0, 100),
        tip: tip, detected: true,
      );
    } catch (_) {
      return const RuleResult(
        ruleName: 'Perspective', score: 50,
        tip: 'EYE LEVEL — try a low or high angle for more drama.', detected: true,
      );
    }
  }

  // ══════════════════════════════════════════════════════════
  // NIMA — Aesthetic quality score (MobileNet trained on AVA)
  // Output: 10 probabilities for ratings 1–10
  // Mean = Σ p(i) × i, normalised to [0,100]
  // Typical NIMA range: rating 4.5–6.5 for most photos
  // ══════════════════════════════════════════════════════════
  Future<double> _getNimaScore(img.Image image) async {
    if (_nimaInterpreter == null) return 50.0;
    try {
      // NIMA MobileNet input: 224×224, normalised [0, 1]
      final resized = img.copyResize(image, width: 224, height: 224);
      final input   = List.generate(1, (_) => List.generate(
        224, (y) => List.generate(224, (x) {
          final p = resized.getPixel(x, y);
          return [p.r / 255.0, p.g / 255.0, p.b / 255.0];
        }),
      ));

      final output = [List.filled(10, 0.0)];
      _nimaInterpreter!.run(input, output);

      // The model outputs probabilities directly (softmax already applied)
      // but we apply softmax anyway to handle logit outputs
      final raw  = output[0];
      final maxV = raw.reduce(max);
      final exps = raw.map((v) => exp(v - maxV)).toList();
      final sumE = exps.reduce((a, b) => a + b);
      final prob = exps.map((e) => e / sumE).toList();

      // weighted mean: ratings 1–10 (MATCHING COLAB LOGIC)
      double mean = 0;
      for (int i = 0; i < 10; i++) {
        mean += prob[i] * (i + 1);
      }

      // Colab output is 1-10. Map [4.0, 7.5] -> [0, 100] for the UI
      return ((mean - 4.0) / 3.5 * 100).clamp(0.0, 100.0);
    } catch (_) {
      return 50.0;
    }
  }

  // ══════════════════════════════════════════════════════════
  // Professional Suggestion
  // ══════════════════════════════════════════════════════════
  String _suggestion(RuleResult r1, RuleResult r2, RuleResult r3,
      RuleResult r4, RuleResult r5, RuleResult r6, double nima) {
    final active = [r1,r2,r3,r4,r5,r6]
        .where((r) => r.detected && r.score >= 0)
        .toList()
      ..sort((a, b) => a.score.compareTo(b.score));

    if (active.isEmpty) return 'Point at a clear subject and tap ANALYSE for feedback.';

    final avgScore = active.map((r) => r.score).reduce((a,b) => a+b) / active.length;

    if (nima >= 65 && avgScore >= 65) {
      return 'Excellent composition! Your image shows strong professional technique.';
    }
    if (nima >= 60 && avgScore >= 55) {
      return 'Good shot! ${active.first.tip}';
    }

    // Two weakest rules as the suggestion
    final tips = active.take(2).map((r) => r.tip).join(' Also: ');
    return tips;
  }

  CompositionResult _errorResult(String msg) {
    final e = RuleResult(ruleName: 'Error', score: -1, tip: msg, detected: false);
    return CompositionResult(
      ruleOfThirds: e, leadingLines: e, negativeSpace: e,
      symmetry: e, framing: e, perspective: e,
      overallScore: 0, nimaScore: 0,
      bestTip: msg, angleLabel: 'UNKNOWN',
      professionalSuggestion: msg,
    );
  }

  void dispose() {
    _yolo.dispose();
    _deeplabInterpreter?.close();
    _midasInterpreter?.close();
    _nimaInterpreter?.close();
  }
}

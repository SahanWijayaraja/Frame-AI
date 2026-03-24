import 'dart:typed_data';
import 'dart:math';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;
import 'yolo_detector.dart';

class RuleResult {
  final String ruleName;
  final int    score;     // 0–100, or -1 = N/A
  final String tip;
  final bool   detected;  // false = rule not applicable to this scene

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
  bool _modelsLoaded = false;

  // Public accessor so camera_screen can run live subject detection
  YoloDetector get yolo => _yolo;

  Future<void> loadModels() async {
    try {
      await _yolo.loadModel();
      final options = InterpreterOptions()..threads = 2;
      _deeplabInterpreter = await Interpreter.fromAsset(
        'assets/models/deeplabv3.tflite', options: options);
      _midasInterpreter = await Interpreter.fromAsset(
        'assets/models/midas_small.tflite', options: options);
      _nimaInterpreter = await Interpreter.fromAsset(
        'assets/models/nima_mobilenet.tflite', options: options);
      _modelsLoaded = true;
    } catch (e) {
      // partial load — some rules may return N/A
    }
  }

  Future<CompositionResult> analyseImage(List<int> imageBytes) async {
    final image = img.decodeImage(Uint8List.fromList(imageBytes));
    if (image == null) return _errorResult('Could not decode image');

    final detections = await _yolo.detect(image);
    final subject    = _yolo.getPrimarySubject(detections);

    final r1 = _checkRuleOfThirds(subject);
    final r2 = _checkLeadingLines(image);
    final r3 = _checkNegativeSpace(subject);
    final r4 = _checkSymmetry(image);
    final r5 = await _checkFraming(image, subject);
    final r6 = await _checkPerspective(image);

    final nimaScore = await _getNimaScore(image);
    final detected  = [r1, r2, r3, r4, r5, r6].where((r) => r.detected).toList();
    final overall   = detected.isEmpty
        ? 50
        : (detected.map((r) => r.score).reduce((a, b) => a + b) / detected.length).round();

    final weakest = detected.isEmpty ? r1
        : detected.reduce((a, b) => a.score < b.score ? a : b);

    final suggestion = _generateSuggestion(r1, r2, r3, r4, r5, r6, nimaScore);

    final angle = r6.tip.contains('LOW')   ? 'LOW ANGLE' :
                  r6.tip.contains('HIGH')  ? 'HIGH ANGLE' :
                  'EYE LEVEL';

    return CompositionResult(
      ruleOfThirds:  r1,
      leadingLines:  r2,
      negativeSpace: r3,
      symmetry:      r4,
      framing:       r5,
      perspective:   r6,
      overallScore:  overall.clamp(0, 100),
      nimaScore:     nimaScore,
      bestTip:       weakest.tip,
      angleLabel:    angle,
      professionalSuggestion: suggestion,
    );
  }

  // ── Rule 1: Rule of Thirds ────────────────────────────────
  RuleResult _checkRuleOfThirds(DetectedObject? subject) {
    if (subject == null) {
      return const RuleResult(
        ruleName: 'Rule of Thirds', score: -1,
        tip: 'No subject detected.', detected: false,
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
      final d  = sqrt(dx * dx + dy * dy);
      if (d < minDist) { minDist = d; nearest = pt; }
    }

    // 0.0 = perfect, 0.47 = corner = furthest ~ 0
    final score = (max(0.0, 1.0 - minDist / 0.47) * 100).round().clamp(0, 100);

    String tip;
    if (score >= 75) {
      tip = 'Subject placed well at a power point.';
    } else {
      final hDir = subject.centerX > nearest[0] + 0.05 ? 'left'  :
                   subject.centerX < nearest[0] - 0.05 ? 'right' : '';
      final vDir = subject.centerY > nearest[1] + 0.05 ? 'up'    :
                   subject.centerY < nearest[1] - 0.05 ? 'down'  : '';
      final dirs = [hDir, vDir].where((d) => d.isNotEmpty).join(' & ');
      tip = dirs.isNotEmpty
          ? 'Move $dirs to align subject with a thirds intersection.'
          : 'Slightly adjust subject to a power point.';
    }

    return RuleResult(ruleName: 'Rule of Thirds', score: score, tip: tip, detected: true);
  }

  // ── Rule 2: Leading Lines (gradient angle convergence) ────
  RuleResult _checkLeadingLines(img.Image image) {
    try {
      const size = 128;
      final small  = img.copyResize(image, width: size, height: size);
      final gray   = img.grayscale(small);

      // Compute Sobel gradients
      int convergingCount = 0;
      int totalEdges      = 0;
      const threshold     = 20;

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

          final gx = -tl - 2*ml - bl + tr + 2*mr + br;
          final gy = -tl - 2*tc - tr + bl + 2*bc + br;
          final mag = sqrt((gx*gx + gy*gy).toDouble());

          if (mag > threshold) {
            totalEdges++;
            // Check if this gradient direction points toward centre
            final cx = size / 2 - x;
            final cy = size / 2 - y;
            // Dot product of gradient with centre direction:
            final dot = gx * cx + gy * cy;
            if (dot > 0) convergingCount++;
          }
        }
      }

      if (totalEdges < 50) {
        return const RuleResult(
          ruleName: 'Leading Lines', score: -1,
          tip: 'No strong lines detected in this scene.', detected: false,
        );
      }

      final convergenceRatio = convergingCount / totalEdges;
      // Natural images have ~50% converging by chance; >65% is meaningful
      final adjusted = ((convergenceRatio - 0.50) / 0.30).clamp(0.0, 1.0);
      final score    = (adjusted * 100).round();

      String tip;
      if (score >= 70)      tip = 'Strong leading lines guide the eye towards your subject.';
      else if (score >= 40) tip = 'Some lines present. Look for roads, paths, or corridors.';
      else                  tip = 'Add a leading element — fences, rivers, or train tracks work well.';

      return RuleResult(
        ruleName: 'Leading Lines', score: score, tip: tip, detected: score > 20,
      );
    } catch (_) {
      return const RuleResult(
        ruleName: 'Leading Lines', score: -1, tip: 'Could not analyse lines.', detected: false,
      );
    }
  }

  // ── Rule 3: Negative Space ────────────────────────────────
  RuleResult _checkNegativeSpace(DetectedObject? subject) {
    if (subject == null) {
      return const RuleResult(
        ruleName: 'Negative Space', score: -1,
        tip: 'No subject detected.', detected: false,
      );
    }

    final ratio = subject.area;
    int    score;
    String tip;

    if (ratio >= 0.10 && ratio <= 0.35) {
      score = 90 + ((0.225 - (ratio - 0.225).abs()) / 0.225 * 10).round();
      tip   = 'Ideal subject size — great breathing room.';
    } else if (ratio < 0.10) {
      score = (ratio / 0.10 * 60).round();
      tip   = 'Subject too small (${(ratio*100).round()}%). Move closer.';
    } else if (ratio <= 0.55) {
      score = ((1 - (ratio - 0.35) / 0.20) * 70).round();
      tip   = 'Slightly cramped (${(ratio*100).round()}%). Step back a little.';
    } else {
      score = max(0, ((1 - (ratio - 0.55) / 0.45) * 40).round());
      tip   = 'Too tight (${(ratio*100).round()}%). Step further back.';
    }

    return RuleResult(
      ruleName: 'Negative Space', score: score.clamp(0, 100), tip: tip, detected: true,
    );
  }

  // ── Rule 4: Symmetry ──────────────────────────────────────
  RuleResult _checkSymmetry(img.Image image) {
    try {
      final small = img.copyResize(image, width: 64, height: 64);
      final W = small.width;
      final H = small.height;

      double lrDiff = 0;
      for (int y = 0; y < H; y++) {
        for (int x = 0; x < W ~/ 2; x++) {
          final l = small.getPixel(x, y);
          final r = small.getPixel(W - 1 - x, y);
          lrDiff += (l.r - r.r).abs() + (l.g - r.g).abs() + (l.b - r.b).abs();
        }
      }
      final lrSim = 1.0 - lrDiff / ((W / 2) * H * 3 * 255);

      double tbDiff = 0;
      for (int y = 0; y < H ~/ 2; y++) {
        for (int x = 0; x < W; x++) {
          final t = small.getPixel(x, y);
          final b = small.getPixel(x, H - 1 - y);
          tbDiff += (t.r - b.r).abs() + (t.g - b.g).abs() + (t.b - b.b).abs();
        }
      }
      final tbSim = 1.0 - tbDiff / (W * (H / 2) * 3 * 255);

      final bestSim   = max(lrSim, tbSim);
      final direction = lrSim >= tbSim ? 'left-right' : 'top-bottom';

      // Rescaled: 0.45 similarity → score 0, 0.90 similarity → score 100
      final score = ((bestSim - 0.45) / 0.45 * 100).round().clamp(0, 100);

      if (score < 10) {
        return const RuleResult(
          ruleName: 'Symmetry', score: -1,
          tip: 'No symmetry detected. Try reflections, arches, or centred subjects.',
          detected: false,
        );
      }

      String tip;
      if (score >= 70) tip = 'Strong $direction symmetry — perfectly balanced.';
      else if (score >= 40) tip = 'Partial $direction symmetry. Centre your subject more.';
      else tip = 'Weak symmetry. Try reflections or centred composition.';

      return RuleResult(ruleName: 'Symmetry', score: score, tip: tip, detected: true);
    } catch (_) {
      return const RuleResult(
        ruleName: 'Symmetry', score: -1, tip: 'Could not analyse symmetry.', detected: false,
      );
    }
  }

  // ── Rule 5: Framing (DeepLabV3) ───────────────────────────
  Future<RuleResult> _checkFraming(img.Image image, DetectedObject? subject) async {
    if (_deeplabInterpreter == null) {
      return const RuleResult(
        ruleName: 'Framing', score: -1,
        tip: 'Framing model not available.', detected: false,
      );
    }
    try {
      const dlSize = 257;
      final resized = img.copyResize(image, width: dlSize, height: dlSize);

      final input = List.generate(1, (_) => List.generate(
        dlSize, (y) => List.generate(dlSize, (x) {
          final p = resized.getPixel(x, y);
          return [p.r / 255.0, p.g / 255.0, p.b / 255.0];
        }),
      ));

      final outShape = _deeplabInterpreter!.getOutputTensor(0).shape;
      final output   = List.generate(outShape[0], (_) => List.generate(
        outShape[1], (_) => List.generate(outShape[2], (_) => List.filled(outShape[3], 0.0)),
      ));

      _deeplabInterpreter!.run(input, output);

      // Argmax per pixel
      final seg = List.generate(dlSize, (y) => List.generate(dlSize, (x) {
        final s = output[0][y][x];
        int best = 0; double bv = s[0];
        for (int c = 1; c < s.length; c++) {
          if (s[c] > bv) { bv = s[c]; best = c; }
        }
        return best;
      }));

      // Centre region subject class
      final cx1 = (dlSize * 0.28).round();
      final cx2 = (dlSize * 0.72).round();
      final cy1 = (dlSize * 0.22).round();
      final cy2 = (dlSize * 0.78).round();
      final counts = List.filled(21, 0);
      for (int y = cy1; y < cy2; y++) {
        for (int x = cx1; x < cx2; x++) counts[seg[y][x]]++;
      }
      counts[0] = 0; // ignore background
      int subjClass = 0, maxCnt = 0;
      for (int c = 0; c < 21; c++) {
        if (counts[c] > maxCnt) { maxCnt = counts[c]; subjClass = c; }
      }

      if (maxCnt == 0) {
        return const RuleResult(
          ruleName: 'Framing', score: -1,
          tip: 'No identifiable subject to check framing for.', detected: false,
        );
      }

      final strip = (dlSize * 0.18).round();
      final sides = {
        'TOP'   : _stripClass(seg, 0, strip, cx1, cx2),
        'BOTTOM': _stripClass(seg, dlSize - strip, dlSize, cx1, cx2),
        'LEFT'  : _stripClass(seg, cy1, cy2, 0, strip),
        'RIGHT' : _stripClass(seg, cy1, cy2, dlSize - strip, dlSize),
      };
      final framingSides = sides.entries
          .where((e) => e.value != subjClass && e.value != 0)
          .map((e) => e.key).toList();

      final n     = framingSides.length;
      final score = [0, 30, 60, 82, 100][n.clamp(0, 4)];

      String tip;
      if (n >= 3) tip = 'Excellent framing — subject surrounded on $n sides.';
      else if (n == 2) {
        final missing = ['TOP','BOTTOM','LEFT','RIGHT']
            .where((s) => !framingSides.contains(s)).toList();
        tip = 'Add a framing element on the ${missing.first} side.';
      } else if (n == 1) tip = 'Weak framing. Try shooting through a doorway or arch.';
      else tip = 'No framing detected. Look for windows, trees, or arches.';

      return RuleResult(ruleName: 'Framing', score: score, tip: tip, detected: n > 0);
    } catch (_) {
      return const RuleResult(
        ruleName: 'Framing', score: -1, tip: 'Could not analyse framing.', detected: false,
      );
    }
  }

  int _stripClass(List<List<int>> seg, int y0, int y1, int x0, int x1) {
    final c = List.filled(21, 0);
    for (int y = y0; y < y1 && y < seg.length; y++) {
      for (int x = x0; x < x1 && x < seg[0].length; x++) c[seg[y][x]]++;
    }
    int best = 0, bv = 0;
    for (int i = 0; i < 21; i++) { if (c[i] > bv) { bv = c[i]; best = i; } }
    return best;
  }

  // ── Rule 6: Perspective / Angle (MiDaS) ──────────────────
  Future<RuleResult> _checkPerspective(img.Image image) async {
    if (_midasInterpreter == null) {
      return const RuleResult(
        ruleName: 'Perspective', score: -1,
        tip: 'Depth model not available.', detected: false,
      );
    }
    try {
      const mdSize = 256;
      final resized = img.copyResize(image, width: mdSize, height: mdSize);

      final input = List.generate(1, (_) => List.generate(
        mdSize, (y) => List.generate(mdSize, (x) {
          final p = resized.getPixel(x, y);
          return [p.r / 127.5 - 1.0, p.g / 127.5 - 1.0, p.b / 127.5 - 1.0];
        }),
      ));

      final outShape = _midasInterpreter!.getOutputTensor(0).shape;
      final output   = List.generate(outShape[0], (_) => List.generate(
        outShape[1], (_) => List.filled(outShape[2], 0.0),
      ));
      _midasInterpreter!.run(input, output);

      final flat  = output[0].expand((r) => r).toList();
      final dMin  = flat.reduce(min);
      final dMax  = flat.reduce(max);
      final range = dMax - dMin;

      final depth = List.generate(mdSize, (y) => List.generate(
        mdSize, (x) => range > 1e-6 ? (output[0][y][x] - dMin) / range : 0.0,
      ));

      final zoneH    = mdSize ~/ 5;
      final zoneMeans = List.generate(5, (i) {
        double s = 0; int n = 0;
        for (int y = i*zoneH; y < (i+1)*zoneH && y < mdSize; y++) {
          for (int x = 0; x < mdSize; x++) { s += depth[y][x]; n++; }
        }
        return n > 0 ? s / n : 0.0;
      });

      final topMean = (zoneMeans[0] + zoneMeans[1]) / 2;
      final botMean = (zoneMeans[3] + zoneMeans[4]) / 2;
      final vDiff   = botMean - topMean;

      // Sky detection
      int skyPixels = 0;
      final skyH = mdSize ~/ 4;
      for (int y = 0; y < skyH; y++) {
        for (int x = 0; x < mdSize; x++) {
          final p = resized.getPixel(x, y);
          if (p.b.toInt() > p.r.toInt() + 15 && p.b.toInt() > p.g.toInt() && p.b.toInt() > 90) skyPixels++;
        }
      }
      final skyRatio = skyPixels / (skyH * mdSize);

      String label;
      int    score;

      if (vDiff > 0.22 && (skyRatio > 0.05 || vDiff > 0.35)) {
        label = 'LOW ANGLE'; score = min(100, (vDiff / 0.50 * 100).round());
      } else if (vDiff > 0.10) {
        label = 'SLIGHT LOW ANGLE'; score = min(100, (vDiff / 0.50 * 85).round());
      } else if (vDiff < -0.22) {
        label = 'HIGH ANGLE'; score = min(100, (vDiff.abs() / 0.50 * 100).round());
      } else if (vDiff < -0.10) {
        label = 'SLIGHT HIGH ANGLE'; score = min(100, (vDiff.abs() / 0.50 * 85).round());
      } else {
        label = 'EYE LEVEL'; score = 50; // eye level is a valid creative choice
      }

      final tip = label == 'LOW ANGLE'         ? 'LOW ANGLE — dramatic & powerful perspective.' :
                  label == 'SLIGHT LOW ANGLE'   ? 'SLIGHT LOW ANGLE — try going lower for more impact.' :
                  label == 'HIGH ANGLE'         ? 'HIGH ANGLE — overhead, commanding view.' :
                  label == 'SLIGHT HIGH ANGLE'  ? 'SLIGHT HIGH ANGLE — try going higher.' :
                  'EYE LEVEL — try a low or high angle for more drama.';

      return RuleResult(
        ruleName: 'Perspective', score: score, tip: tip,
        detected: label != 'EYE LEVEL',
      );
    } catch (_) {
      return const RuleResult(
        ruleName: 'Perspective', score: -1, tip: 'Could not analyse perspective.', detected: false,
      );
    }
  }

  // ── NIMA Overall Aesthetic Score ──────────────────────────
  Future<double> _getNimaScore(img.Image image) async {
    if (_nimaInterpreter == null) return 50.0;
    try {
      final resized = img.copyResize(image, width: 224, height: 224);
      final input   = List.generate(1, (_) => List.generate(
        224, (y) => List.generate(224, (x) {
          final p = resized.getPixel(x, y);
          return [p.r / 255.0, p.g / 255.0, p.b / 255.0];
        }),
      ));

      final output = [List.filled(10, 0.0)];
      _nimaInterpreter!.run(input, output);

      // Apply softmax in case model outputs logits
      final raw   = output[0];
      final maxV  = raw.reduce(max);
      final exps  = raw.map((v) => exp(v - maxV)).toList();
      final sumE  = exps.reduce((a, b) => a + b);
      final probs = exps.map((e) => e / sumE).toList();

      double mean = 0;
      for (int i = 0; i < 10; i++) mean += probs[i] * (i + 1);
      // NIMA ratings: 1–10  → convert to 0–100
      return ((mean - 1) / 9 * 100).clamp(0, 100);
    } catch (_) {
      return 50.0;
    }
  }

  // ── Professional Suggestion ───────────────────────────────
  String _generateSuggestion(
    RuleResult r1, RuleResult r2, RuleResult r3,
    RuleResult r4, RuleResult r5, RuleResult r6,
    double nima,
  ) {
    final active = [r1, r2, r3, r4, r5, r6].where((r) => r.detected).toList();
    if (active.isEmpty) return 'Point at a clear subject to get composition feedback.';

    active.sort((a, b) => a.score.compareTo(b.score));
    final worst  = active.first;
    final second = active.length > 1 ? active[1] : null;

    if (nima >= 70 && worst.score >= 65) {
      return 'Excellent shot! This composition demonstrates strong professional technique.';
    }
    if (worst.ruleName == 'Rule of Thirds') return worst.tip;
    if (worst.ruleName == 'Negative Space') return worst.tip;
    if (second != null && second.score < 50) {
      return '${worst.tip} Also: ${second.tip.toLowerCase()}';
    }
    return worst.tip;
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

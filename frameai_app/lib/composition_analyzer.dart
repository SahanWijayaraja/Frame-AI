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
      debugPrint('AI Models Loaded Successfully');
    } catch (e) {
      debugPrint('AI Model Load Failure: $e');
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

    if (subject == null) {
      return CompositionResult(
        ruleOfThirds: r1, leadingLines: r2, negativeSpace: r3,
        symmetry: r4, framing: r5, perspective: r6,
        overallScore: overall.clamp(0, 100),
        nimaScore:    nimaScore,
        bestTip:      weakest?.tip ?? 'No subject detected. Move closer or center a subject.',
        angleLabel:   r6.tip.contains('LOW') ? 'LOW ANGLE' : r6.tip.contains('HIGH') ? 'HIGH ANGLE' : 'EYE LEVEL',
        professionalSuggestion: 'Look for leading lines or symmetry! To get subject tips, ensure a clear person or object is in focus.',
      );
    }

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

  // ── RULE 1 — Rule of Thirds (YOLOv8n) ───────────────────
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

    final score = (max(0.0, 1.0 - minDist / 0.50) * 100).round().clamp(0, 100);

    String tip;
    if (score >= 82) {
      tip = 'Perfect power-point alignment.';
    } else {
      // dx > 0 = subject is RIGHT of target → move LEFT
      // dy > 0 = subject is BELOW target → move UP
      final dx = subject.centerX - nearest[0];
      final dy = subject.centerY - nearest[1];

      String hTip = dx > 0.05 ? 'left' : dx < -0.05 ? 'right' : '';
      String vTip = dy > 0.05 ? 'up'   : dy < -0.05 ? 'down'  : '';

      if (hTip.isNotEmpty && vTip.isNotEmpty) {
        tip = 'Shift subject $hTip and $vTip';
      } else if (hTip.isNotEmpty) {
        tip = 'Shift subject $hTip';
      } else if (vTip.isNotEmpty) {
        tip = 'Shift subject $vTip';
      } else {
        tip = 'Align subject with a grid intersection';
      }
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
      // Match Colab mapping: [0.50 .. 0.82] → [0 .. 100]
      final score = ((ratio - 0.50) / 0.32 * 100).round().clamp(0, 100);

      String tip;
      if (score >= 70) {
        tip = 'Strong leading lines! They guide the viewer right to your subject.';
      } else if (score >= 35) {
        tip = 'Subtle leading lines. Align them to point more directly at your subject.';
      } else {
        tip = 'No strong leading lines. Use roads, fences, or shoreline to guide the eye.';
      }

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

    // CALIBRATION for 3:4
    final ratio = subject.area.clamp(0.0, 1.0);
    int    score;
    String tip;

    if (ratio < 0.05) {
      score = (ratio / 0.05 * 40).round();
      tip   = 'Subject too small. Move much closer.';
    } else if (ratio < 0.10) {
      score = (40 + (ratio - 0.05) / 0.05 * 50).round();
      tip   = 'Subject slightly small. Move closer for better presence.';
    } else if (ratio <= 0.35) {
      score = 95;
      tip   = 'Ideal — subject and negative space are perfectly balanced.';
    } else if (ratio <= 0.55) {
      score = (95 - ((ratio - 0.35) / 0.20 * 45)).round();
      tip   = 'Subject fills {ratio*100:.0f}% — slightly cramped. Step back a little.';
    } else {
      score = (50 - ((ratio - 0.55) / 0.45 * 50)).round();
      tip   = 'Subject fills {ratio*100:.0f}% — very tight. Step back for breathing room.';
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
      final small = img.copyResize(image, width: 128, height: 128);
      final W = small.width;
      final H = small.height;

      double computeSim(bool horizontal) {
        double totalDiff = 0;
        const b = 4;
        if (horizontal) {
          for (int y = 0; y < H; y += b) {
            for (int x = 0; x < W ~/ 2; x += b) {
              double bL = 0, bR = 0;
              for (int dy = 0; dy < b && y+dy < H; dy++) {
                for (int dx = 0; dx < b && x+dx < W; dx++) {
                  bL += img.getLuminance(small.getPixel(x+dx, y+dy));
                  bR += img.getLuminance(small.getPixel(W-1-(x+dx), y+dy));
                }
              }
              totalDiff += (bL - bR).abs();
            }
          }
          return 1.0 - (totalDiff / ((W/2) * H * 255));
        } else {
          for (int y = 0; y < H ~/ 2; y += b) {
            for (int x = 0; x < W; x += b) {
              double bT = 0, bB = 0;
              for (int dy = 0; dy < b && y+dy < H; dy++) {
                for (int dx = 0; dx < b && x+dx < W; dx++) {
                  bT += img.getLuminance(small.getPixel(x+dx, y+dy));
                  bB += img.getLuminance(small.getPixel(x+dx, H-1-(y+dy)));
                }
              }
              totalDiff += (bT - bB).abs();
            }
          }
          return 1.0 - (totalDiff / (W * (H/2) * 255));
        }
      }

      final lrSim = computeSim(true);
      final tbSim = computeSim(false);
      final bestSim   = max(lrSim, tbSim);
      final direction = lrSim >= tbSim ? 'left-right' : 'top-bottom';

      // Match Colab mapping: [0.65, 0.96] -> [0, 100]
      final score = ((bestSim - 0.65) / 0.31 * 100).round().clamp(0, 100);

      String tip;
      if (score >= 75) tip = 'Strong $direction symmetry — very balanced composition.';
      else if (score >= 45) tip = 'Partial $direction symmetry. Centre your subject for stronger balance.';
      else tip = 'Low symmetry. Try reflections, still water, or a centred arch.';

      return RuleResult(ruleName: 'Symmetry', score: score, tip: tip, detected: true);
    } catch (_) {
      return const RuleResult(ruleName: 'Symmetry', score: 20, tip: 'Try reflections or centred subjects.', detected: true);
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
      final isInt8    = inputInfo.type == TfLiteType.kTfLiteInt8;
      final isUint8   = inputInfo.type == TfLiteType.kTfLiteUInt8;

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

      final stripW = (dlSize * 0.18).round();
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
      // Colab Scoring: [0:0, 1:25, 2:55, 3:80, 4:98]
      final score = n == 0 ? 0 : n == 1 ? 25 : n == 2 ? 55 : n == 3 ? 80 : 98;

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
      return const RuleResult(ruleName: 'Perspective', score: 50, tip: 'EYE LEVEL — try a low or high angle for drama.', detected: true);
    }
    try {
      const mdSize = 256;
      final resized = img.copyResize(image, width: mdSize, height: mdSize);

      final inputTensor = _midasInterpreter!.getInputTensor(0);
      final isInt8      = inputTensor.type == TfLiteType.kTfLiteInt8;
      
      final inputData = isInt8 ? Int8List(1 * mdSize * mdSize * 3) : Float32List(1 * mdSize * mdSize * 3);
      final data = inputData as List;
      int pIdx = 0;
      for (int y = 0; y < mdSize; y++) {
        for (int x = 0; x < mdSize; x++) {
          final p = resized.getPixel(x, y);
          if (isInt8) {
            data[pIdx++] = (p.r.toInt() - 128);
            data[pIdx++] = (p.g.toInt() - 128);
            data[pIdx++] = (p.b.toInt() - 128);
          } else {
            // Normalise to [-1, 1] per Colab
            data[pIdx++] = p.r / 127.5 - 1.0;
            data[pIdx++] = p.g / 127.5 - 1.0;
            data[pIdx++] = p.b / 127.5 - 1.0;
          }
        }
      }

      final outShape = _midasInterpreter!.getOutputTensor(0).shape;
      final output   = [List.generate(outShape[1], (_) => List.filled(outShape[2], 0.0))];
      _midasInterpreter!.run(inputData, output);

      final flat   = output[0].expand((r) => r).toList();
      final dMin   = flat.reduce(min);
      final dMax   = flat.reduce(max);
      final dRange = (dMax - dMin).abs();
      if (dRange < 1e-4) return const RuleResult(ruleName: 'Perspective', score: 50, tip: 'EYE LEVEL — flat depth.', detected: true);

      final depth = List.generate(mdSize, (y) => List.generate(mdSize, (x) => (output[0][y][x] - dMin) / dRange));

      // 5-zone analysis from Colab
      final z = mdSize ~/ 5;
      final zones = List.generate(5, (i) {
        double s = 0; int n = 0;
        for (int y = i*z; y < (i+1)*z; y++) {
          for (int x = 0; x < mdSize; x++) { s += depth[y][x]; n++; }
        }
        return s / n;
      });

      final topMean    = (zones[0] + zones[1]) / 2;
      final bottomMean = (zones[3] + zones[4]) / 2;
      final overall    = flat.map((v) => (v - dMin) / dRange).reduce((a, b) => a + b) / (mdSize * mdSize);
      final variance   = flat.map((v) => pow((v - dMin) / dRange - overall, 2)).reduce((a, b) => a + b) / (mdSize * mdSize);
      final vertDiff   = bottomMean - topMean;
      final vertRatio  = vertDiff / overall;

      // Sky detection (Colab)
      int skyCount = 0;
      for (int y = 0; y < mdSize ~/ 3; y++) {
        for (int x = 0; x < mdSize; x++) {
          final p = resized.getPixel(x, y);
          if (p.b > p.r + 15 && p.b > p.g && p.b > 90) skyCount++;
        }
      }
      final skyRatio = skyCount / (mdSize * mdSize / 3);
      final isOverhead = (skyRatio < 0.05 && variance < 0.04 && vertDiff.abs() < 0.25);

      String label;
      int    score;
      String tip;

      if (isOverhead) {
        label = 'HIGH ANGLE';
        score = 75;
        tip   = 'Camera pointing straight down — overhead shot.';
      } else if (vertRatio > 0.28 && vertDiff > 0.07 && (skyRatio > 0.04 || zones[4] > zones[0])) {
        label = 'LOW ANGLE';
        score = (min(vertRatio / 0.55, 1.0) * 100).round();
        tip   = 'Excellent! Low angles create drama and dominance.';
      } else if (vertRatio < -0.28 && vertDiff.abs() > 0.07) {
        label = 'HIGH ANGLE';
        score = (min(vertRatio.abs() / 0.55, 1.0) * 100).round();
        tip   = 'High angle works well for birds-eye shots.';
      } else {
        label = 'EYE LEVEL';
        score = (min(variance / 0.04, 1.0) * 45).round();
        tip   = 'Standard eye-level shot. Try crouching or raising the camera.';
      }

      return RuleResult(ruleName: 'Perspective', score: score.clamp(0, 100), tip: tip, detected: true);
    } catch (_) {
      return const RuleResult(ruleName: 'Perspective', score: 50, tip: 'EYE LEVEL — neutrally balanced.', detected: true);
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

    final active = [r1, r2, r3, r4, r5, r6]
        .where((r) => r.detected && r.score >= 0).toList();
    if (active.isEmpty) {
      return 'Point at a clear subject and tap ANALYSE for feedback.';
    }

    final issues = active.where((r) => r.score < 65).toList()
      ..sort((a, b) => a.score.compareTo(b.score));
    final good   = active.where((r) => r.score >= 80).toList();
    final nimaStr = nima >= 70 ? 'strong aesthetic quality'
                  : nima >= 45 ? 'decent aesthetic quality'
                  : 'low aesthetic score';

    if (issues.isEmpty) {
      final goodNames = good.map((r) => r.ruleName.toLowerCase()).toList();
      if (goodNames.length >= 3) {
        return 'Well composed shot — ${goodNames.take(2).join(', ')} and more are working well. $nimaStr.';
      }
      return 'Solid composition. ${good.first.tip} $nimaStr.';
    }

    final primary   = issues.first;
    final secondary = issues.length > 1 ? issues[1] : null;

    String intro(RuleResult r) {
      switch (r.ruleName) {
        case 'Rule of Thirds'  : return 'Composition could improve — ${r.tip.toLowerCase()}';
        case 'Leading Lines'   : return 'The shot lacks direction — ${r.tip.toLowerCase()}';
        case 'Negative Space'  : return 'Framing needs adjustment — ${r.tip.toLowerCase()}';
        case 'Symmetry'        : return 'Balance could be stronger — ${r.tip.toLowerCase()}';
        case 'Framing'         : return 'Natural framing is missing — ${r.tip.toLowerCase()}';
        case 'Perspective'     : return 'Try a different angle — ${r.tip.toLowerCase()}';
        default                : return r.tip;
      }
    }

    String result = intro(primary);
    if (secondary != null && (primary.score - secondary.score).abs() < 30) {
      result += '. Also: ${secondary.tip.toLowerCase()}';
    }
    if (good.isNotEmpty) {
      result += '. ${good.first.ruleName} looks good';
    }
    return result;
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

import 'dart:typed_data';
import 'dart:math';
import 'package:flutter/foundation.dart';
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
    }
  }

  void dispose() {
    _yolo.dispose();
    _deeplabInterpreter?.close();
    _midasInterpreter?.close();
    _nimaInterpreter?.close();
  }

  Future<CompositionResult> analyseImage(List<int> imageBytes) async {
    final image = img.decodeImage(Uint8List.fromList(imageBytes));
    if (image == null) return _errorResult('Could not decode image');

    final detections = await _yolo.detect(image);
    final subject = _yolo.getPrimarySubject(detections);

    final r1 = _ruleOfThirds(subject);
    final r2 = _leadingLines(image);
    final r3 = _negativeSpace(subject);
    final r4 = _symmetry(image);
    final r5 = await _framing(image, subject);
    final r6Raw = await _perspective(image);
    final nima = await _nimaScore(image);

    // Parse the angle label attached to the perspective tip
    final pParts = r6Raw.tip.split('|');
    final angleLabel = pParts.length > 1 ? pParts[0] : 'EYE LEVEL';
    final pTip = pParts.length > 1 ? pParts[1] : r6Raw.tip;
    final r6 = RuleResult(ruleName: r6Raw.ruleName, score: r6Raw.score, tip: pTip, detected: r6Raw.detected);

    final overallScore = ((r1.score + r2.score + r3.score + r4.score + r5.score + r6.score) / 6).round().clamp(0, 100);

    final allRules = [r1, r2, r3, r4, r5, r6];
    final weakest = allRules.reduce((a, b) => a.score < b.score ? a : b);

    return CompositionResult(
      ruleOfThirds: r1,
      leadingLines: r2,
      negativeSpace: r3,
      symmetry: r4,
      framing: r5,
      perspective: r6,
      overallScore: overallScore,
      nimaScore: nima.score.toDouble(),
      bestTip: weakest.tip,
      angleLabel: angleLabel,
      professionalSuggestion: nima.tip,
    );
  }

  CompositionResult _errorResult(String msg) {
    final err = RuleResult(ruleName: 'Error', score: 0, tip: msg, detected: false);
    return CompositionResult(
      ruleOfThirds: err, leadingLines: err, negativeSpace: err,
      symmetry: err, framing: err, perspective: err,
      overallScore: 0, nimaScore: 0, bestTip: msg, angleLabel: 'EYE LEVEL', professionalSuggestion: msg,
    );
  }

  // ── RULE 1 — Rule of Thirds  (YOLOv8n)
  RuleResult _ruleOfThirds(DetectedObject? subject) {
    if (subject == null) {
      return const RuleResult(
        ruleName: 'Rule of Thirds',
        score: 0,
        tip: 'No subject detected — point at a clear subject.',
        detected: false,
      );
    }

    final double cx = subject.x + subject.width / 2;
    final double cy = subject.y + subject.height / 2;

    final intersections = [
      const Point(1 / 3, 1 / 3),
      const Point(2 / 3, 1 / 3),
      const Point(1 / 3, 2 / 3),
      const Point(2 / 3, 2 / 3)
    ];

    double minDist = double.infinity;
    Point nearest = intersections[0];

    for (var p in intersections) {
      double dist = sqrt(pow(cx - p.x, 2) + pow(cy - p.y, 2));
      if (dist < minDist) {
        minDist = dist;
        nearest = p;
      }
    }

    int score = max(0, ((1.0 - minDist / 0.50) * 100).toInt());

    String hDir = cx > nearest.x + 0.05 ? "left" : (cx < nearest.x - 0.05 ? "right" : "");
    String vDir = cy > nearest.y + 0.05 ? "down" : (cy < nearest.y - 0.05 ? "up" : "");
    String direction = [hDir, vDir].where((s) => s.isNotEmpty).join(" and ");

    String tip;
    if (score >= 80) {
      tip = "Subject is at a strong third intersection. ";
    } else if (direction.isNotEmpty) {
      tip = "Move subject \$direction to hit a third intersection.";
    } else {
      tip = "Adjust framing slightly for Rule of Thirds.";
    }

    return RuleResult(ruleName: 'Rule of Thirds', score: score.clamp(0, 100), tip: tip, detected: true);
  }

  // ── RULE 2 — Leading Lines  (Canny/Hough approximation)
  RuleResult _leadingLines(img.Image image) {
    final resized = img.copyResize(image, width: 128, height: 128);
    int w = 128, h = 128;
    int cx = w ~/ 2, cy = h ~/ 2;
    int converging = 0;
    int total = 0;

    for (int y = 1; y < h - 1; y++) {
      for (int x = 1; x < w - 1; x++) {
        int p00 = resized.getPixel(x - 1, y - 1).r.toInt();
        int p01 = resized.getPixel(x, y - 1).r.toInt();
        int p02 = resized.getPixel(x + 1, y - 1).r.toInt();
        int p20 = resized.getPixel(x - 1, y + 1).r.toInt();
        int p21 = resized.getPixel(x, y + 1).r.toInt();
        int p22 = resized.getPixel(x + 1, y + 1).r.toInt();
        int p10 = resized.getPixel(x - 1, y).r.toInt();
        int p12 = resized.getPixel(x + 1, y).r.toInt();

        int gx = (p02 + 2 * p12 + p22) - (p00 + 2 * p10 + p20);
        int gy = (p20 + 2 * p21 + p22) - (p00 + 2 * p01 + p02);
        double mag = sqrt(gx * gx + gy * gy);

        if (mag > 80) { // Canny threshold approx
          total++;
          double angle = atan2(gy, gx) + pi / 2;
          double dx = cos(angle);
          double dy = sin(angle);
          double norm = sqrt(dx * dx + dy * dy) + 1e-6;

          double tcx = cx - x.toDouble();
          double tcy = cy - y.toDouble();
          double tNorm = sqrt(tcx * tcx + tcy * tcy) + 1e-6;

          double dot = (dx * tcx + dy * tcy) / (norm * tNorm);
          if (dot.abs() > 0.55) {
            converging++;
          }
        }
      }
    }

    if (total == 0) {
      return const RuleResult(ruleName: 'Leading Lines', score: 0, tip: "No lines found.", detected: false);
    }

    double ratio = converging / total;
    int score = min((ratio / 0.4) * 100, 100.0).toInt();

    String tip;
    if (score >= 75) {
      tip = "\$converging strong leading lines guide the eye inward. Excellent!";
    } else if (score >= 40) {
      tip = "\$converging partial leading lines. Try including a road or path.";
    } else {
      tip = "Lines don't guide toward subject. Find a path, fence, or corridor.";
    }

    return RuleResult(ruleName: 'Leading Lines', score: score.clamp(0, 100), tip: tip, detected: true);
  }

  // ── RULE 3 — Negative Space  (YOLOv8n bbox area ratio)
  RuleResult _negativeSpace(DetectedObject? subject) {
    if (subject == null) {
      return const RuleResult(
        ruleName: 'Negative Space',
        score: 50,
        tip: "No subject detected. Score is neutral.",
        detected: false,
      );
    }

    double ratio = subject.width * subject.height; // area ratio
    int score;
    String tip;

    if (ratio >= 0.10 && ratio <= 0.35) {
      score = (90 + (0.225 - (ratio - 0.225).abs()) / 0.225 * 10).toInt();
      tip = "Subject fills \${(ratio * 100).toStringAsFixed(0)}% of frame — ideal negative space.";
    } else if (ratio < 0.10) {
      score = (ratio / 0.10 * 60).toInt();
      tip = "Subject too small (\${(ratio * 100).toStringAsFixed(0)}%). Move closer.";
    } else if (ratio <= 0.55) {
      score = ((1 - (ratio - 0.35) / 0.20) * 70).toInt();
      tip = "Subject fills \${(ratio * 100).toStringAsFixed(0)}% — slightly cramped. Step back a little.";
    } else {
      score = max(0, ((1 - (ratio - 0.55) / 0.45) * 40).toInt());
      tip = "Subject fills \${(ratio * 100).toStringAsFixed(0)}% — very tight. Step back for breathing room.";
    }

    return RuleResult(ruleName: 'Negative Space', score: score.clamp(0, 100), tip: tip, detected: true);
  }

  // ── RULE 4 — Symmetry  (SSIM approx via Pixel Diff)
  RuleResult _symmetry(img.Image image) {
    final resized = img.copyResize(image, width: 64, height: 64);
    int H = 64, W = 64;
    double mseLR = 0, mseTB = 0;

    for (int y = 0; y < H; y++) {
      for (int x = 0; x < W; x++) {
        double p = resized.getPixel(x, y).luminance / 255.0;
        double pLR = resized.getPixel(W - 1 - x, y).luminance / 255.0;
        double pTB = resized.getPixel(x, H - 1 - y).luminance / 255.0;
        
        // Exaggerate structural mismatch
        mseLR += pow(p - pLR, 2);
        mseTB += pow(p - pTB, 2);
      }
    }
    
    // Normalise to 0-1 range (SSIM approximation)
    double scoreLR = max(0.0, 1.0 - (mseLR / (W * H * 0.5)));
    double scoreTB = max(0.0, 1.0 - (mseTB / (W * H * 0.5)));

    double bestSsim = max(scoreLR, scoreTB);
    String direction = scoreLR >= scoreTB ? "left-right" : "top-bottom";

    int score = max(0, ((bestSsim - 0.30) / 0.65 * 100).toInt()).clamp(0, 100);
    String tip;

    if (score >= 75) {
      tip = "Strong \$direction symmetry detected — very balanced composition.";
    } else if (score >= 45) {
      tip = "Partial \$direction symmetry. Centre your subject for stronger balance.";
    } else {
      tip = "No strong symmetry. For symmetry: centre subject, use reflections.";
    }

    return RuleResult(ruleName: 'Symmetry', score: score, tip: tip, detected: true);
  }

  // ── RULE 5 — Framing  (DeepLabV3)
  Future<RuleResult> _framing(img.Image image, DetectedObject? subject) async {
    if (_deeplabInterpreter == null) {
      return const RuleResult(ruleName: 'Framing', score: 50, tip: 'Framing unavailable.', detected: false);
    }

    try {
      const int dlSize = 257;
      final resized = img.copyResize(image, width: dlSize, height: dlSize);
      final inputData = Float32List(1 * dlSize * dlSize * 3);
      final data = inputData as List;
      int idx = 0;
      for (int y = 0; y < dlSize; y++) {
        for (int x = 0; x < dlSize; x++) {
          final p = resized.getPixel(x, y);
          data[idx++] = p.r / 255.0;
          data[idx++] = p.g / 255.0;
          data[idx++] = p.b / 255.0;
        }
      }

      final outShape = _deeplabInterpreter!.getOutputTensor(0).shape;
      final output = [List.generate(outShape[1], (_) => List.generate(outShape[2], (_) => List.filled(outShape[3], 0.0)))];
      _deeplabInterpreter!.run(inputData, output);

      final seg = List.generate(dlSize, (y) => List.filled(dlSize, 0));
      for (int y = 0; y < dlSize; y++) {
        for (int x = 0; x < dlSize; x++) {
          int maxCls = 0; double maxVal = -1;
          for (int c = 0; c < 21; c++) {
            if (output[0][y][x][c] > maxVal) { maxVal = output[0][y][x][c]; maxCls = c; }
          }
          seg[y][x] = maxCls;
        }
      }

      int H = dlSize, W = dlSize;
      int cx1 = (W * 0.28).toInt(), cx2 = (W * 0.72).toInt();
      int cy1 = (H * 0.22).toInt(), cy2 = (H * 0.78).toInt();

      final counts = List.filled(21, 0);
      for (int y = cy1; y < cy2; y++) {
        for (int x = cx1; x < cx2; x++) {
          counts[seg[y][x]]++;
        }
      }
      
      if (counts.sublist(1).reduce((a, b) => a + b) > 0) counts[0] = 0;
      int subjCls = 0; int maxCount = -1;
      for (int i = 0; i < 21; i++) {
        if (counts[i] > maxCount) { maxCount = counts[i]; subjCls = i; }
      }

      int strip = (H * 0.18).toInt();
      final strips = {
        "TOP": [0, strip, cx1, cx2],
        "BOTTOM": [H - strip, H, cx1, cx2],
        "LEFT": [cy1, cy2, 0, strip],
        "RIGHT": [cy1, cy2, W - strip, W]
      };

      List<String> framingSides = [];
      strips.forEach((side, bounds) {
        final Map<int, int> regionCounts = {};
        for (int y = bounds[0]; y < bounds[1]; y++) {
          for (int x = bounds[2]; x < bounds[3]; x++) {
            int c = seg[y][x];
            regionCounts[c] = (regionCounts[c] ?? 0) + 1;
          }
        }
        if (regionCounts.isNotEmpty) {
          int dom = -1, maxC = -1;
          regionCounts.forEach((cls, count) {
            if (count > maxC) { maxC = count; dom = cls; }
          });
          if (dom != subjCls) framingSides.add(side);
        }
      });

      int n = framingSides.length;
      int score = {0: 0, 1: 25, 2: 55, 3: 80, 4: 98}[n] ?? 0;
      String tip;

      if (n >= 3) {
        tip = "Subject framed on \$n sides (\${framingSides.join(', ')}). Excellent!";
      } else if (n == 2) {
        final miss = ["TOP", "BOTTOM", "LEFT", "RIGHT"].firstWhere((s) => !framingSides.contains(s));
        tip = "Partial framing. Add an element on the \$miss side.";
      } else if (n == 1) {
        tip = "Weak framing. Try shooting through a doorway or between trees.";
      } else {
        tip = "No framing. Look for windows, arches, or branches to frame subject.";
      }

      return RuleResult(ruleName: 'Framing', score: score, tip: tip, detected: true);
    } catch (_) {
      return const RuleResult(ruleName: 'Framing', score: 50, tip: '', detected: false);
    }
  }

  // ── RULE 6 — Perspective / Angle  (MiDaS)
  Future<RuleResult> _perspective(img.Image image) async {
    if (_midasInterpreter == null) {
      return const RuleResult(
        ruleName: 'Perspective',
        score: 50,
        tip: 'EYE LEVEL|Eye level — neutrally balanced.',
        detected: false,
      );
    }

    try {
      const int mdSize = 256;
      final resized = img.copyResize(image, width: mdSize, height: mdSize);
      
      final inputTensor = _midasInterpreter!.getInputTensor(0);
      final isInt8 = inputTensor.type == TfLiteType.kTfLiteInt8;
      
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
            data[pIdx++] = p.r / 127.5 - 1.0;
            data[pIdx++] = p.g / 127.5 - 1.0;
            data[pIdx++] = p.b / 127.5 - 1.0;
          }
        }
      }

      final outShape = _midasInterpreter!.getOutputTensor(0).shape;
      final output = [List.generate(outShape[1], (_) => List.filled(outShape[2], 0.0))];
      _midasInterpreter!.run(inputData, output);

      final flat = output[0].expand((r) => r).toList();
      final dMin = flat.reduce(min);
      final dMax = flat.reduce(max);
      final dRange = (dMax - dMin).abs();
      
      final depth = List.generate(mdSize, (y) => List.generate(mdSize, (x) => dRange > 1e-6 ? (output[0][y][x] - dMin) / dRange : output[0][y][x]));

      final zs = mdSize ~/ 5;
      final zones = List.generate(5, (i) {
        double s = 0; int n = 0;
        for (int y = i * zs; y < (i + 1) * zs; y++) {
          for (int x = 0; x < mdSize; x++) { s += depth[y][x]; n++; }
        }
        return s / n;
      });

      final topM = (zones[0] + zones[1]) / 2;
      final botM = (zones[3] + zones[4]) / 2;
      final ovr = flat.map((v) => dRange > 1e-6 ? (v - dMin) / dRange : v).reduce((a, b) => a + b) / (mdSize * mdSize);
      final varD = flat.map((v) => pow((dRange > 1e-6 ? (v - dMin)/dRange : v) - ovr, 2)).reduce((a, b) => a + b) / (mdSize * mdSize);
      final vdiff = botM - topM;
      final vratio = ovr > 1e-6 ? vdiff / ovr : 0.0;
      
      int nz = 0; double maxZ = -1;
      for (int i = 0; i < 5; i++) {
        if (zones[i] > maxZ) { maxZ = zones[i]; nz = i; }
      }

      int skyCount = 0;
      for (int y = 0; y < mdSize ~/ 3; y++) {
        for (int x = 0; x < mdSize; x++) {
          final p = resized.getPixel(x, y);
          double rf = p.r / 255.0, gf = p.g / 255.0, bf = p.b / 255.0;
          if (bf > rf + 0.05 && bf > gf && bf > 0.35) skyCount++;
        }
      }
      final skyR = skyCount / (mdSize * mdSize / 3);

      double topBr = 0, botBr = 0;
      for (int y = 0; y < mdSize ~/ 4; y++) {
        for (int x = 0; x < mdSize; x++) { topBr += resized.getPixel(x, y).luminance / 255.0; }
      }
      topBr /= (mdSize * (mdSize ~/ 4));
      
      for (int y = 3 * mdSize ~/ 4; y < mdSize; y++) {
        for (int x = 0; x < mdSize; x++) { botBr += resized.getPixel(x, y).luminance / 255.0; }
      }
      botBr /= (mdSize * (mdSize ~/ 4));

      final darkTop = topBr < 0.18 && botBr > topBr + 0.12;
      bool overhead = skyR < 0.05 && varD < 0.04 && vdiff.abs() < 0.25;
      if (skyR < 0.05 && varD < 0.025) overhead = true;

      const double STRONG = 0.28, MOD = 0.12, MIND = 0.07;
      String label, tip; int score;

      if (overhead) {
        label = "HIGH ANGLE"; score = 75; tip = "Overhead shot. Try an angle for more depth.";
      } else if (vratio > STRONG && vdiff > MIND && (skyR > 0.04 || darkTop || nz >= 3)) {
        label = "LOW ANGLE"; score = min(vratio / 0.55, 1.0) * 100 ~/ 1; tip = "Excellent low angle — creates drama and dominance.";
      } else if (vratio > MOD && vdiff > MIND * 0.6 && (skyR > 0.02 || darkTop || nz >= 3)) {
        label = "SLIGHT LOW ANGLE"; score = min(vratio / 0.55, 1.0) * 100 ~/ 1; tip = "Slight low angle. Try going lower for more drama.";
      } else if (vratio < -STRONG && vdiff.abs() > MIND) {
        label = "HIGH ANGLE"; score = min(vratio.abs() / 0.55, 1.0) * 100 ~/ 1; tip = "High angle — good for overview shots.";
      } else if (vratio < -MOD && vdiff.abs() > MIND * 0.6) {
        label = "SLIGHT HIGH ANGLE"; score = min(vratio.abs() / 0.55, 1.0) * 100 ~/ 1; tip = "Slight high angle. Try going higher for more impact.";
      } else {
        label = "EYE LEVEL"; score = min(varD / 0.04, 1.0) * 45 ~/ 1; tip = "Eye level — try crouching or raising camera.";
      }

      // Encode label into the tip to pass it safely up to analyseImage
      return RuleResult(ruleName: 'Perspective', score: score.clamp(0, 100), tip: "\$label|\$tip", detected: true);
    } catch (_) {
      return const RuleResult(ruleName: 'Perspective', score: 50, tip: "EYE LEVEL|Eye level — neutrally balanced.", detected: false);
    }
  }

  // ── NIMA MobileNet
  Future<RuleResult> _nimaScore(img.Image image) async {
    if (_nimaInterpreter == null) {
      return const RuleResult(ruleName: 'NIMA', score: 50, tip: '', detected: false);
    }

    try {
      final resized = img.copyResize(image, width: 224, height: 224);
      final inputData = Float32List(1 * 224 * 224 * 3);
      final data = inputData as List;
      int idx = 0;
      for (int y = 0; y < 224; y++) {
        for (int x = 0; x < 224; x++) {
          final p = resized.getPixel(x, y);
          data[idx++] = p.r / 255.0;
          data[idx++] = p.g / 255.0;
          data[idx++] = p.b / 255.0;
        }
      }

      final output = [List.filled(10, 0.0)];
      _nimaInterpreter!.run(inputData, output);

      double mean = 0;
      for (int i = 0; i < 10; i++) mean += output[0][i] * (i + 1);
      mean = mean / 10 * 100;
      mean = mean.clamp(0, 100);

      String tip;
      if (mean >= 65) tip = "Strong overall aesthetic quality.";
      else if (mean >= 45) tip = "Average quality. Improve composition for better results.";
      else tip = "Low aesthetic score. Focus on lighting and subject placement.";

      return RuleResult(ruleName: 'NIMA', score: mean.round(), tip: tip, detected: true);
    } catch (_) {
      return const RuleResult(ruleName: 'NIMA', score: 50, tip: '', detected: false);
    }
  }
}

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

class _FeedbackEngine {
  static final Random _rng = Random();

  static String getPraise() {
    final phrases = [
      "Great shot!", "Solid composition.", "Nicely done.",
      "Excellent eye.", "Beautifully composed.", "Very strong arrangement."
    ];
    return phrases[_rng.nextInt(phrases.length)];
  }

  static String getRuleOfThirdsTip(double dx, double dy, bool isGood) {
    if (isGood) {
      final good = [
        "Subject perfectly aligns with the power intersections.",
        "Excellent use of the rule of thirds.",
        "The rule of thirds placement creates a very balanced feel here."
      ];
      return good[_rng.nextInt(good.length)];
    }
    
    String hTip = dx > 0.05 ? 'left' : dx < -0.05 ? 'right' : '';
    String vTip = dy > 0.05 ? 'up' : dy < -0.05 ? 'down' : '';
    String dir = [hTip, vTip].where((s) => s.isNotEmpty).join(' and ');
    if (dir.isEmpty) return "Slightly adjust framing to hit a third intersection.";
    
    final tips = [
      "Try shifting the camera \$dir for a stronger rule of thirds.",
      "Pan slightly \$dir to place your subject right on a power intersection.",
      "Moving the subject \$dir will instantly improve the composition's balance."
    ];
    return tips[_rng.nextInt(tips.length)];
  }

  static String getNegativeSpaceTip(double ratio, bool isLeadRoomGood, bool isGood) {
    if (isGood) {
      final good = [
        "The negative space balances the subject perfectly.",
        "Great breathing room around the subject.",
        "Excellent spatial balance — not too cramped, not too empty."
      ];
      return good[_rng.nextInt(good.length)];
    }
    if (ratio < 0.10) {
      return ["Subject is a bit lost in the frame. Try moving closer.", 
              "Too much empty space. Fill the frame more with your subject."][_rng.nextInt(2)];
    } else if (ratio > 0.55) {
      return ["The frame feels cramped. Step back to give the subject room to breathe.",
              "Try stepping back—the subject needs more negative space around the edges."][_rng.nextInt(2)];
    } else if (!isLeadRoomGood) {
      return ["Leave more open space in front of the subject to create 'lead room'.",
              "Shift the subject to the opposite side to balance the empty space."][_rng.nextInt(2)];
    }
    return "Adjust the negative space to balance the shot better.";
  }

  static String getLeadingLinesTip(int score) {
    if (score >= 70) {
      final good = [
        "Strong leading lines! They guide the viewer right to your subject.",
        "Excellent use of natural lines to draw the eye inward.",
        "The converging lines make this a very dynamic composition."
      ];
      return good[_rng.nextInt(good.length)];
    } else if (score >= 35) {
      return ["Subtle leading lines. Align them to point more directly at your subject.",
              "Try repositioning so the lines guide the eye toward the center."][_rng.nextInt(2)];
    }
    return ["No strong leading lines. Use roads, fences, or a shoreline to guide the eye.",
            "Look for natural paths or corridors to create depth."][_rng.nextInt(2)];
  }

  static String getSymmetryTip(int score, String direction) {
    if (score >= 75) {
      return ["Strong \$direction symmetry detected. Very balanced.",
              "Excellent symmetry. The reflection or central balance works perfectly.",
              "Beautiful \$direction balance."][_rng.nextInt(3)];
    } else if (score >= 45) {
      return ["Partial \$direction symmetry. Center your subject for stronger balance.",
              "Try squaring up your camera to perfect that \$direction symmetry."][_rng.nextInt(2)];
    }
    return ["Low symmetry. Try utilizing reflections, still water, or a centered archway.",
            "If you want a symmetric shot, perfectly center the subject."][_rng.nextInt(2)];
  }

  static String generateProfessionalSuggestion(List<RuleResult> activeRules, double nima) {
    if (activeRules.isEmpty) return 'Point at a clear subject and tap ANALYSE for feedback.';

    final issues = activeRules.where((r) => r.score < 65).toList()
      ..sort((a, b) => a.score.compareTo(b.score));
    final good = activeRules.where((r) => r.score >= 80).toList();
    
    final nimaStr = nima >= 70 ? 'Amazing lighting and aesthetics.'
                  : nima >= 45 ? 'Decent aesthetic quality.'
                  : 'Focus on finding better lighting.';

    if (issues.isEmpty) {
      final goodNames = good.map((r) => r.ruleName.toLowerCase()).toList();
      return '\${getPraise()} \${goodNames.take(2).join(' and ')} are working well. \$nimaStr';
    }

    final primary = issues.first;
    String text = "\${primary.tip}";
    
    if (issues.length > 1 && (primary.score - issues[1].score).abs() < 25) {
      text += " Also: \${issues[1].tip}";
    }
    
    if (good.isNotEmpty) {
      text += " On the bright side, your \${good.first.ruleName.toLowerCase()} is quite good!";
    }
    
    return text;
  }
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
      _deeplabInterpreter = await Interpreter.fromAsset('assets/models/deeplabv3.tflite', options: options);
      _midasInterpreter   = await Interpreter.fromAsset('assets/models/midas_small.tflite', options: options);
      _nimaInterpreter    = await Interpreter.fromAsset('assets/models/nima_mobilenet.tflite', options: options);
      debugPrint('AI Models Loaded Successfully');
    } catch (e) {
      debugPrint('AI Model Load Failure: \$e');
    }
  }

  Future<CompositionResult> analyseImage(List<int> imageBytes) async {
    final image = img.decodeImage(Uint8List.fromList(imageBytes));
    if (image == null) return _errorResult('Could not decode image');

    // 1. Run YOLO detection
    final detections = await _yolo.detect(image);

    // 2. Run Perspective/Depth analysis (reusable for sensor fusion)
    final perspectiveData = await _checkPerspective(image);
    final r6 = perspectiveData.result;
    final depthMap = perspectiveData.depth;

    // 3. Sensor Fusion: Combine YOLO boxes and MiDaS depth to rank targets
    final subject = _fusionSubjectDetector(detections, depthMap);
    final bool isDepthFallback = (subject != null && subject.className == 'foreground object');

    // 4. Run remaining rules
    final r1 = _checkRuleOfThirds(subject);
    final r2 = _checkLeadingLines(image);
    final r3 = _checkNegativeSpace(subject);
    final r4 = _checkSymmetry(image);
    final r5 = await _checkFraming(image, subject);
    final nimaScore = await _getNimaScore(image);

    final active = [r1, r2, r3, r4, r5, r6].where((r) => r.detected && r.score >= 0).toList();
    final overall = active.isEmpty ? 50 : (active.map((r) => r.score).reduce((a, b) => a + b) / active.length).round();
    final weakest = active.isEmpty ? null : active.reduce((a, b) => a.score < b.score ? a : b);

    final angle = r6.tip.contains('LOW') ? 'LOW ANGLE' : r6.tip.contains('HIGH') ? 'HIGH ANGLE' : 'EYE LEVEL';
    
    String suggestion = _FeedbackEngine.generateProfessionalSuggestion(active, nimaScore);
    if (isDepthFallback) {
      suggestion = 'Composition tips based on nearest dominant object. \$suggestion';
    } else if (subject == null) {
      suggestion = 'Look for leading lines! Ensure a clear person/object is in focus for more tips.';
    }

    return CompositionResult(
      ruleOfThirds: r1, leadingLines: r2, negativeSpace: r3,
      symmetry: r4, framing: r5, perspective: r6,
      overallScore: overall.clamp(0, 100),
      nimaScore: nimaScore,
      bestTip: weakest?.tip ?? 'Frame your shot and tap ANALYSE.',
      angleLabel: angle,
      professionalSuggestion: suggestion,
    );
  }

  /// Synthesise YOLO bounding boxes with MiDaS depth map to rank by proximity and confidence.
  DetectedObject? _fusionSubjectDetector(List<DetectedObject> yoloSubjects, List<List<double>>? depth) {
    if (yoloSubjects.isEmpty && depth == null) return null;
    
    // Fallback: if no depth model loaded, default to YOLO's largest box
    if (depth == null && yoloSubjects.isNotEmpty) return _yolo.getPrimarySubject(yoloSubjects);

    int H = depth!.length;
    int W = depth[0].length;
    double maxD = 0;
    for (var row in depth) { for (var v in row) { if (v > maxD) maxD = v; } }
    if (maxD < 1e-4) maxD = 1; 

    DetectedObject? bestYoloSubject;
    double bestScore = -1;

    for (var subject in yoloSubjects) {
      int sx1 = (subject.x * W).toInt().clamp(0, W - 1);
      int sy1 = (subject.y * H).toInt().clamp(0, H - 1);
      int sx2 = ((subject.x + subject.width) * W).toInt().clamp(0, W - 1);
      int sy2 = ((subject.y + subject.height) * H).toInt().clamp(0, H - 1);
      
      double sumD = 0; int count = 0;
      for (int y = sy1; y <= sy2; y++) {
        for (int x = sx1; x <= sx2; x++) { sumD += depth[y][x]; count++; }
      }
      double avgD = count > 0 ? sumD / count : 0;
      
      // Score ranks YOLO targets by Semantic Confidence + Physical Proximity
      double score = (avgD / maxD) * 0.5 + subject.confidence * 0.5;
      if (score > bestScore) { bestScore = score; bestYoloSubject = subject; }
    }

    // Now evaluate raw depth map for geometric foreground prominence
    double threshold = maxD * 0.85;
    int minX = W, minY = H, maxX = 0, maxY = 0, count = 0;
    for (int y = 0; y < H; y++) {
      for (int x = 0; x < W; x++) {
        if (depth[y][x] >= threshold) {
          if (x < minX) minX = x; if (y < minY) minY = y;
          if (x > maxX) maxX = x; if (y > maxY) maxY = y;
          count++;
        }
      }
    }
    
    if (count > (W * H * 0.02)) { // Foreground occupies >2% of image
      double geoWidth = (maxX - minX) / W;
      double geoHeight = (maxY - minY) / H;
      if (bestYoloSubject == null) {
        return DetectedObject(className: 'foreground object', confidence: 0.8, x: minX / W, y: minY / H, width: geoWidth, height: geoHeight);
      }
    }
    return bestYoloSubject;
  }

  // ── RULE 1 — Granular Rule of Thirds
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

    // Check if the subject's exact bounding box *covers* a power point
    bool coversPoint = false;
    for (final pt in intersections) {
      if (pt[0] >= subject.x && pt[0] <= subject.x + subject.width &&
          pt[1] >= subject.y && pt[1] <= subject.y + subject.height) {
        coversPoint = true; break;
      }
    }

    double minDist = double.infinity;
    List<double> nearest = intersections[0];
    for (final pt in intersections) {
      final dx = subject.centerX - pt[0];
      final dy = subject.centerY - pt[1];
      final d  = sqrt(dx*dx + dy*dy);
      if (d < minDist) { minDist = d; nearest = pt; }
    }

    int score = coversPoint ? 95 : (max(0.0, 1.0 - minDist / 0.50) * 100).round().clamp(0, 100);
    
    final dx = subject.centerX - nearest[0];
    final dy = subject.centerY - nearest[1];
    
    String tip = _FeedbackEngine.getRuleOfThirdsTip(dx, dy, coversPoint || score >= 82);
    return RuleResult(ruleName: 'Rule of Thirds', score: score, tip: tip, detected: true);
  }

  // ── RULE 2 — Leading Lines
  RuleResult _checkLeadingLines(img.Image image) {
    try {
      const size = 96;
      final small = img.copyResize(image, width: size, height: size);
      final gray  = img.grayscale(small);
      int converging = 0; int total = 0;

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

          if (mag < 25) continue;
          total++;

          final cx = (size / 2 - x).toDouble();
          final cy = (size / 2 - y).toDouble();
          if (gx * cx + gy * cy > 0) converging++;
        }
      }

      if (total < 100) {
        return RuleResult(ruleName: 'Leading Lines', score: 20, tip: _FeedbackEngine.getLeadingLinesTip(20), detected: true);
      }

      final ratio = converging / total;
      final score = ((ratio - 0.50) / 0.32 * 100).round().clamp(0, 100);
      return RuleResult(ruleName: 'Leading Lines', score: score, tip: _FeedbackEngine.getLeadingLinesTip(score), detected: true);
    } catch (_) {
      return RuleResult(ruleName: 'Leading Lines', score: 30, tip: _FeedbackEngine.getLeadingLinesTip(30), detected: true);
    }
  }

  // ── RULE 3 — Negative Space (with Lead Room analysis)
  RuleResult _checkNegativeSpace(DetectedObject? subject) {
    if (subject == null) {
      return const RuleResult(ruleName: 'Negative Space', score: -1, tip: 'No subject detected.', detected: false);
    }

    final ratio = subject.area.clamp(0.0, 1.0);
    int score;
    bool leadRoomGood = true;

    // Check lateral looking-space limits
    if (subject.width < 0.4) {
      if (subject.centerX < 0.4) leadRoomGood = true; // left aligned, space is on right
      else if (subject.centerX > 0.6) leadRoomGood = true; // right aligned, space on left
      else leadRoomGood = true; // center aligned is fine. We just want to flag edge crowding.
      // If subject is too close to an edge while facing away from the center, that's bad lead room.
      // E.g. x > 0.8 means touching right edge. If it's a profile, it feels cramped.
      if (subject.x < 0.05 || subject.x + subject.width > 0.95) leadRoomGood = false;
    }

    if (ratio < 0.05) score = (ratio / 0.05 * 40).round();
    else if (ratio < 0.10) score = (40 + (ratio - 0.05) / 0.05 * 50).round();
    else if (ratio <= 0.35) score = leadRoomGood ? 95 : 75;
    else if (ratio <= 0.55) score = (95 - ((ratio - 0.35) / 0.20 * 45)).round();
    else score = (50 - ((ratio - 0.55) / 0.45 * 50)).round();

    bool isGood = score >= 85;
    if (!leadRoomGood) score -= 20;

    String tip = _FeedbackEngine.getNegativeSpaceTip(ratio, leadRoomGood, isGood);
    return RuleResult(ruleName: 'Negative Space', score: score.clamp(0, 100), tip: tip, detected: true);
  }

  // ── RULE 4 — Symmetry
  RuleResult _checkSymmetry(img.Image image) {
    try {
      final small = img.copyResize(image, width: 128, height: 128);
      final W = small.width; final H = small.height;

      double computeSim(bool horizontal) {
        double totalDiff = 0; const b = 4;
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
      final score = ((bestSim - 0.65) / 0.31 * 100).round().clamp(0, 100);

      String tip = _FeedbackEngine.getSymmetryTip(score, direction);
      return RuleResult(ruleName: 'Symmetry', score: score, tip: tip, detected: true);
    } catch (_) {
      return const RuleResult(ruleName: 'Symmetry', score: 20, tip: 'Try reflections or centred subjects.', detected: true);
    }
  }

  // ── RULE 5 — Framing
  Future<RuleResult> _checkFraming(img.Image image, DetectedObject? subject) async {
    if (_deeplabInterpreter == null) {
      return const RuleResult(ruleName: 'Framing', score: 20, tip: 'Look for windows, arches, or branches to frame your subject.', detected: true);
    }
    try {
      const dlSize = 257;
      final resized = img.copyResize(image, width: dlSize, height: dlSize);
      final inputInfo = _deeplabInterpreter!.getInputTensor(0);
      final isInt8    = inputInfo.type == TfLiteType.kTfLiteInt8;
      final isUint8   = inputInfo.type == TfLiteType.kTfLiteUInt8;

      Object input;
      if (isInt8 || isUint8) {
        input = List.generate(1, (_) => List.generate(dlSize, (y) => List.generate(dlSize, (x) {
          final p = resized.getPixel(x, y);
          if (isUint8) return [p.r.toInt(), p.g.toInt(), p.b.toInt()];
          return [p.r.toInt() - 128, p.g.toInt() - 128, p.b.toInt() - 128];
        })));
      } else {
        input = List.generate(1, (_) => List.generate(dlSize, (y) => List.generate(dlSize, (x) {
          final p = resized.getPixel(x, y);
          return [p.r / 255.0, p.g / 255.0, p.b / 255.0];
        })));
      }

      final outShape = _deeplabInterpreter!.getOutputTensor(0).shape;
      final output   = List.generate(outShape[0], (_) => List.generate(outShape[1], (_) => List.generate(outShape[2], (_) => List.filled(outShape[3], 0.0))));
      _deeplabInterpreter!.run(input, output);

      final seg = List.generate(dlSize, (y) => List.generate(dlSize, (x) {
        final s = output[0][y][x];
        int best = 0; double bv = s[0];
        for (int c = 1; c < s.length; c++) { if (s[c] > bv) { bv = s[c]; best = c; } }
        return best;
      }));

      final cx1 = (dlSize * 0.25).round(); final cx2 = (dlSize * 0.75).round();
      final cy1 = (dlSize * 0.20).round(); final cy2 = (dlSize * 0.80).round();
      final counts = List.filled(21, 0);
      for (int y = cy1; y < cy2; y++) { for (int x = cx1; x < cx2; x++) counts[seg[y][x]]++; }
      counts[0] = 0;
      int subjClass = 0, maxCnt = 0;
      for (int c = 0; c < 21; c++) { if (counts[c] > maxCnt) { maxCnt = counts[c]; subjClass = c; } }

      if (maxCnt < 100) return const RuleResult(ruleName: 'Framing', score: 15, tip: 'No clear subject centre detected. Try shooting through a frame.', detected: true);

      final stripW = (dlSize * 0.18).round();
      final sides  = {
        'TOP'   : _mostCommonClass(seg, 0,          stripW,  cx1, cx2),
        'BOTTOM': _mostCommonClass(seg, dlSize-stripW, dlSize, cx1, cx2),
        'LEFT'  : _mostCommonClass(seg, cy1,          cy2,    0,   stripW),
        'RIGHT' : _mostCommonClass(seg, cy1,          cy2,    dlSize-stripW, dlSize),
      };

      final framingSides = sides.entries.where((e) => e.value != subjClass && e.value != 0).map((e) => e.key).toList();
      final n = framingSides.length;
      final score = n == 0 ? 0 : n == 1 ? 25 : n == 2 ? 55 : n == 3 ? 80 : 98;

      final _rng = Random();
      String tip;
      if (n >= 3) {
        tip = ["Excellent framing! Subject framed on \$n sides.", "Perfect natural frame.", "Beautifully framed by the environment."][_rng.nextInt(3)];
      } else if (n == 2) {
        final allSides = ['TOP', 'BOTTOM', 'LEFT', 'RIGHT'];
        final missingSide = allSides.firstWhere((s) => !framingSides.contains(s), orElse: () => 'opposite');
        tip = 'Add a framing element on the $missingSide side.';
      } else if (n == 1) tip = 'Weak framing. Try shooting through a doorway or archway.';
      else tip = 'No framing detected. Look for windows, trees, or arches.';

      return RuleResult(ruleName: 'Framing', score: score, tip: tip, detected: true);
    } catch (_) {
      return const RuleResult(ruleName: 'Framing', score: 20, tip: 'Look for natural frames like arches, windows, or branches.', detected: true);
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

  // ── RULE 6 — Perspective & Angle
  Future<({RuleResult result, List<List<double>>? depth})> _checkPerspective(img.Image image) async {
    if (_midasInterpreter == null) return (result: const RuleResult(ruleName: 'Perspective', score: 50, tip: 'EYE LEVEL — try a low or high angle.', detected: true), depth: null);
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
            data[pIdx++] = (p.r.toInt() - 128); data[pIdx++] = (p.g.toInt() - 128); data[pIdx++] = (p.b.toInt() - 128);
          } else {
            data[pIdx++] = p.r / 127.5 - 1.0; data[pIdx++] = p.g / 127.5 - 1.0; data[pIdx++] = p.b / 127.5 - 1.0;
          }
        }
      }

      final outShape = _midasInterpreter!.getOutputTensor(0).shape;
      final output   = [List.generate(outShape[1], (_) => List.filled(outShape[2], 0.0))];
      _midasInterpreter!.run(inputData, output);

      final flat   = output[0].expand((r) => r).toList();
      final dMin   = flat.reduce(min); final dMax   = flat.reduce(max);
      final dRange = (dMax - dMin).abs();
      if (dRange < 1e-4) return (result: const RuleResult(ruleName: 'Perspective', score: 50, tip: 'EYE LEVEL — flat depth.', detected: true), depth: null);

      final depth = List.generate(mdSize, (y) => List.generate(mdSize, (x) => (output[0][y][x] - dMin) / dRange));

      final z = mdSize ~/ 5;
      final zones = List.generate(5, (i) {
        double s = 0; int n = 0;
        for (int y = i*z; y < (i+1)*z; y++) { for (int x = 0; x < mdSize; x++) { s += depth[y][x]; n++; } }
        return s / n;
      });

      final topMean = (zones[0] + zones[1]) / 2;
      final bottomMean = (zones[3] + zones[4]) / 2;
      final overall = flat.map((v) => (v - dMin) / dRange).reduce((a, b) => a + b) / (mdSize * mdSize);
      final variance = flat.map((v) => pow((v - dMin) / dRange - overall, 2)).reduce((a, b) => a + b) / (mdSize * mdSize);
      final vertDiff = bottomMean - topMean;
      final vertRatio = vertDiff / overall;

      int skyCount = 0;
      for (int y = 0; y < mdSize ~/ 3; y++) {
        for (int x = 0; x < mdSize; x++) {
          final p = resized.getPixel(x, y);
          if (p.b > p.r + 15 && p.b > p.g && p.b > 90) skyCount++;
        }
      }
      final skyRatio = skyCount / (mdSize * mdSize / 3);
      final isOverhead = (skyRatio < 0.05 && variance < 0.04 && vertDiff.abs() < 0.25);

      String label, tip; int score;
      if (isOverhead) { label = 'HIGH ANGLE'; score = 75; tip = 'Camera pointing straight down — overhead shot.'; } 
      else if (vertRatio > 0.28 && vertDiff > 0.07 && (skyRatio > 0.04 || zones[4] > zones[0])) { label = 'LOW ANGLE'; score = (min(vertRatio / 0.55, 1.0) * 100).round(); tip = 'Excellent! Low angles create drama and dominance.'; } 
      else if (vertRatio < -0.28 && vertDiff.abs() > 0.07) { label = 'HIGH ANGLE'; score = (min(vertRatio.abs() / 0.55, 1.0) * 100).round(); tip = 'High angle works well for overview shots.'; } 
      else { label = 'EYE LEVEL'; score = (min(variance / 0.04, 1.0) * 45).round(); tip = 'Standard eye-level shot. Try crouching or raising the camera.'; }

      return (result: RuleResult(ruleName: 'Perspective', score: score.clamp(0, 100), tip: tip, detected: true), depth: depth);
    } catch (_) {
      return (result: const RuleResult(ruleName: 'Perspective', score: 50, tip: 'EYE LEVEL — neutrally balanced.', detected: true), depth: null);
    }
  }

  // ── NIMA
  Future<double> _getNimaScore(img.Image image) async {
    if (_nimaInterpreter == null) return 50.0;
    try {
      final resized = img.copyResize(image, width: 224, height: 224);
      final input   = List.generate(1, (_) => List.generate(224, (y) => List.generate(224, (x) {
          final p = resized.getPixel(x, y); return [p.r / 255.0, p.g / 255.0, p.b / 255.0];
        })));
      final output = [List.filled(10, 0.0)];
      _nimaInterpreter!.run(input, output);

      final raw  = output[0];
      final maxV = raw.reduce(max);
      final exps = raw.map((v) => exp(v - maxV)).toList();
      final sumE = exps.reduce((a, b) => a + b);
      final prob = exps.map((e) => e / sumE).toList();

      double mean = 0;
      for (int i = 0; i < 10; i++) mean += prob[i] * (i + 1);
      return ((mean - 4.0) / 3.5 * 100).clamp(0.0, 100.0);
    } catch (_) { return 50.0; }
  }

  CompositionResult _errorResult(String msg) {
    final e = RuleResult(ruleName: 'Error', score: -1, tip: msg, detected: false);
    return CompositionResult(ruleOfThirds: e, leadingLines: e, negativeSpace: e, symmetry: e, framing: e, perspective: e, overallScore: 0, nimaScore: 0, bestTip: msg, angleLabel: 'UNKNOWN', professionalSuggestion: msg);
  }

  void dispose() {
    _yolo.dispose();
    _deeplabInterpreter?.close();
    _midasInterpreter?.close();
    _nimaInterpreter?.close();
  }
}

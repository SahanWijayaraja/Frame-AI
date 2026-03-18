import 'dart:typed_data';
import 'dart:math';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;
import 'yolo_detector.dart';

// Holds the result of one rule check
class RuleResult {
  final String ruleName;
  final int    score;      // 0 to 100
  final String tip;        // actionable advice for the user
  final bool   detected;   // was this rule applicable to the scene

  const RuleResult({
    required this.ruleName,
    required this.score,
    required this.tip,
    required this.detected,
  });
}

// Holds all results for one photo analysis
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
  });

  List<RuleResult> get allRules => [
    ruleOfThirds,
    leadingLines,
    negativeSpace,
    symmetry,
    framing,
    perspective,
  ];
}

class CompositionAnalyzer {
  // AI models
  final YoloDetector _yolo = YoloDetector();
  Interpreter? _deeplabInterpreter;
  Interpreter? _midasInterpreter;
  Interpreter? _nimaInterpreter;
  bool _modelsLoaded = false;

  // Load all models into memory
  Future<void> loadModels() async {
    try {
      await _yolo.loadModel();

      final options = InterpreterOptions()..threads = 2;

      _deeplabInterpreter = await Interpreter.fromAsset(
        'assets/models/deeplabv3.tflite',
        options: options,
      );

      _midasInterpreter = await Interpreter.fromAsset(
        'assets/models/midas_small.tflite',
        options: options,
      );

      _nimaInterpreter = await Interpreter.fromAsset(
        'assets/models/nima_mobilenet.tflite',
        options: options,
      );

      _modelsLoaded = true;
      print('CompositionAnalyzer: all models loaded');
    } catch (e) {
      print('CompositionAnalyzer: error loading models — $e');
    }
  }

  // Main entry point — analyse one image
  // imageBytes = raw bytes of the captured screenshot
  Future<CompositionResult> analyseImage(List<int> imageBytes) async {
    // Decode the image
    final image = img.decodeImage(Uint8List.fromList(imageBytes));
    if (image == null) {
      return _errorResult('Could not decode image');
    }

    // Remove camera UI from screenshots
    final cleanImage = _cropCameraUI(image);

    // Run YOLO subject detection
    final detections = await _yolo.detect(cleanImage);
    final subject    = _yolo.getPrimarySubject(detections);

    // Run all 6 rules
    final r1 = _checkRuleOfThirds(subject);
    final r2 = _checkLeadingLines(cleanImage);
    final r3 = _checkNegativeSpace(subject);
    final r4 = _checkSymmetry(cleanImage);
    final r5 = await _checkFraming(cleanImage, subject);
    final r6 = await _checkPerspective(cleanImage);

    // NIMA overall aesthetic score
    final nimaScore = await _getNimaScore(cleanImage);

    // Calculate overall score as weighted average
    final overall = _calculateOverall([r1, r2, r3, r4, r5, r6]);

    // Find the weakest rule and return its tip
    final weakest  = [r1,r2,r3,r4,r5,r6]
        .reduce((a, b) => a.score < b.score ? a : b);

    return CompositionResult(
      ruleOfThirds:  r1,
      leadingLines:  r2,
      negativeSpace: r3,
      symmetry:      r4,
      framing:       r5,
      perspective:   r6,
      overallScore:  overall,
      nimaScore:     nimaScore,
      bestTip:       weakest.tip,
      angleLabel:    r6.tip.contains('LOW')    ? 'LOW ANGLE'   :
                     r6.tip.contains('HIGH')   ? 'HIGH ANGLE'  :
                     r6.tip.contains('DUTCH')  ? 'DUTCH TILT'  :
                     'EYE LEVEL',
    );
  }

  // ── Rule 1: Rule of Thirds ────────────────────────────────
  RuleResult _checkRuleOfThirds(DetectedObject? subject) {
    if (subject == null) {
      return const RuleResult(
        ruleName: 'Rule of Thirds',
        score:    0,
        tip:      'No subject detected. Point at a clear subject.',
        detected: false,
      );
    }

    // Third intersection points
    const intersections = [
      [1/3, 1/3], [2/3, 1/3],
      [1/3, 2/3], [2/3, 2/3],
    ];

    // Find closest intersection to subject centre
    double minDist = double.infinity;
    for (final pt in intersections) {
      final dx   = subject.centerX - pt[0];
      final dy   = subject.centerY - pt[1];
      final dist = sqrt(dx*dx + dy*dy);
      if (dist < minDist) minDist = dist;
    }

    // Score: 100 if on intersection, 0 if far away
    final score = (max(0.0, 1.0 - minDist / 0.45) * 100).round();

    String tip;
    if (score >= 80) {
      tip = 'Subject is well placed at a third intersection. ';
    } else {
      // Tell user which direction to move
      final nearestPt = intersections.reduce((a, b) {
        final da = sqrt(pow(subject.centerX-a[0],2)+pow(subject.centerY-a[1],2));
        final db = sqrt(pow(subject.centerX-b[0],2)+pow(subject.centerY-b[1],2));
        return da < db ? a : b;
      });
      final hDir = subject.centerX > nearestPt[0] + 0.05 ? 'left'  :
                   subject.centerX < nearestPt[0] - 0.05 ? 'right' : '';
      final vDir = subject.centerY > nearestPt[1] + 0.05 ? 'up'    :
                   subject.centerY < nearestPt[1] - 0.05 ? 'down'  : '';
      final dirs = [hDir, vDir].where((d) => d.isNotEmpty).join(' and ');
      tip = dirs.isNotEmpty
          ? 'Move subject $dirs to hit a third intersection.'
          : 'Fine tune subject placement slightly.';
    }

    return RuleResult(
      ruleName: 'Rule of Thirds',
      score:    score.clamp(0, 100),
      tip:      tip,
      detected: true,
    );
  }

  // ── Rule 2: Leading Lines ─────────────────────────────────
  RuleResult _checkLeadingLines(img.Image image) {
    try {
      // Convert to grayscale
      final gray    = img.grayscale(image);
      final W       = gray.width;
      final H       = gray.height;

      // Simple edge detection using pixel differences
      int edgeCount   = 0;
      int convergingLines = 0;
      final cx = W / 2;
      final cy = H / 2;

      // Scan in strips to find strong directional edges
      final stripHeight = H ~/ 8;
      final strips      = H ~/ stripHeight;

      for (int strip = 0; strip < strips; strip++) {
        final y0 = strip * stripHeight;
        final y1 = y0 + stripHeight;

        // Find edge pixels in this strip
        int stripEdges = 0;
        for (int y = y0; y < y1 && y < H - 1; y++) {
          for (int x = 1; x < W - 1; x++) {
            final curr  = gray.getPixel(x, y).r;
            final right = gray.getPixel(x+1, y).r;
            final below = gray.getPixel(x, y+1).r;
            final diff  = max((curr-right).abs(), (curr-below).abs());
            if (diff > 30) stripEdges++;
          }
        }

        if (stripEdges > (W * stripHeight * 0.05)) {
          edgeCount++;
          // Check if this strip has a convergence toward centre
          convergingLines++;
        }
      }

      final ratio = strips > 0 ? convergingLines / strips : 0.0;
      final score = (min(ratio / 0.5, 1.0) * 100).round();

      String tip;
      if (score >= 70) {
        tip = 'Strong leading lines guide the eye. Excellent!';
      } else if (score >= 40) {
        tip = 'Some lines detected. Look for roads or paths to strengthen.';
      } else {
        tip = 'No leading lines. Find a road, fence, or corridor.';
      }

      return RuleResult(
        ruleName: 'Leading Lines',
        score:    score.clamp(0, 100),
        tip:      tip,
        detected: score > 20,
      );
    } catch (e) {
      return const RuleResult(
        ruleName: 'Leading Lines',
        score:    50,
        tip:      'Could not analyse leading lines.',
        detected: false,
      );
    }
  }

  // ── Rule 3: Negative Space ────────────────────────────────
  RuleResult _checkNegativeSpace(DetectedObject? subject) {
    if (subject == null) {
      return const RuleResult(
        ruleName: 'Negative Space',
        score:    50,
        tip:      'No subject detected for negative space check.',
        detected: false,
      );
    }

    final ratio = subject.area; // fraction of frame filled by subject

    int    score;
    String tip;

    if (ratio >= 0.10 && ratio <= 0.35) {
      // Ideal range — good breathing room around subject
      score = 90 + ((0.225 - (ratio - 0.225).abs()) / 0.225 * 10).round();
      tip   = 'Subject fills ${(ratio*100).round()}% of frame — ideal negative space.';
    } else if (ratio < 0.10) {
      score = (ratio / 0.10 * 60).round();
      tip   = 'Subject too small (${(ratio*100).round()}%). Move closer.';
    } else if (ratio <= 0.55) {
      score = ((1 - (ratio - 0.35) / 0.20) * 70).round();
      tip   = 'Subject fills ${(ratio*100).round()}% — slightly cramped. Step back.';
    } else {
      score = max(0, ((1 - (ratio - 0.55) / 0.45) * 40).round());
      tip   = 'Too tight (${(ratio*100).round()}%). Step back for breathing room.';
    }

    return RuleResult(
      ruleName: 'Negative Space',
      score:    score.clamp(0, 100),
      tip:      tip,
      detected: true,
    );
  }

  // ── Rule 4: Symmetry ──────────────────────────────────────
  RuleResult _checkSymmetry(img.Image image) {
    try {
      // Resize to small size for fast comparison
      final small = img.copyResize(image, width: 64, height: 64);
      final W     = small.width;
      final H     = small.height;

      // Compare left half vs right half (flipped)
      double lrDiff = 0;
      for (int y = 0; y < H; y++) {
        for (int x = 0; x < W ~/ 2; x++) {
          final left  = small.getPixel(x, y);
          final right = small.getPixel(W - 1 - x, y);
          lrDiff += (left.r - right.r).abs() +
                    (left.g - right.g).abs() +
                    (left.b - right.b).abs();
        }
      }
      final lrScore = max(0.0, 1.0 - lrDiff / (W/2 * H * 3 * 255));

      // Compare top half vs bottom half (flipped)
      double tbDiff = 0;
      for (int y = 0; y < H ~/ 2; y++) {
        for (int x = 0; x < W; x++) {
          final top    = small.getPixel(x, y);
          final bottom = small.getPixel(x, H - 1 - y);
          tbDiff += (top.r - bottom.r).abs() +
                    (top.g - bottom.g).abs() +
                    (top.b - bottom.b).abs();
        }
      }
      final tbScore = max(0.0, 1.0 - tbDiff / (W * H/2 * 3 * 255));

      final bestScore = max(lrScore, tbScore);
      final direction = lrScore >= tbScore ? 'left-right' : 'top-bottom';
      final score     = ((bestScore - 0.30) / 0.65 * 100).round().clamp(0, 100);

      String tip;
      if (score >= 70) {
        tip = 'Strong $direction symmetry — very balanced composition.';
      } else if (score >= 40) {
        tip = 'Partial $direction symmetry. Centre subject for stronger balance.';
      } else {
        tip = 'No strong symmetry. Try reflections or centred subjects.';
      }

      return RuleResult(
        ruleName: 'Symmetry',
        score:    score,
        tip:      tip,
        detected: score > 30,
      );
    } catch (e) {
      return const RuleResult(
        ruleName: 'Symmetry',
        score:    50,
        tip:      'Could not analyse symmetry.',
        detected: false,
      );
    }
  }

  // ── Rule 5: Framing ───────────────────────────────────────
  Future<RuleResult> _checkFraming(
      img.Image image, DetectedObject? subject) async {
    if (_deeplabInterpreter == null) {
      return const RuleResult(
        ruleName: 'Framing',
        score:    50,
        tip:      'Framing model not loaded.',
        detected: false,
      );
    }

    try {
      const dlSize = 257;
      final resized = img.copyResize(image, width: dlSize, height: dlSize);

      // Build input tensor normalised 0.0 to 1.0
      final input = List.generate(
        1, (_) => List.generate(
          dlSize, (y) => List.generate(
            dlSize, (x) {
              final p = resized.getPixel(x, y);
              return [p.r/255.0, p.g/255.0, p.b/255.0];
            },
          ),
        ),
      );

      // Output: [1, 257, 257, 21] class scores per pixel
      final outputShape = _deeplabInterpreter!.getOutputTensor(0).shape;
      final output = List.generate(
        outputShape[0], (_) => List.generate(
          outputShape[1], (_) => List.generate(
            outputShape[2], (_) => List.filled(outputShape[3], 0.0),
          ),
        ),
      );

      _deeplabInterpreter!.run(input, output);

      // Get class map — argmax over 21 classes per pixel
      final seg = List.generate(dlSize, (y) =>
        List.generate(dlSize, (x) {
          final scores = output[0][y][x];
          int    best  = 0;
          double bVal  = scores[0];
          for (int c = 1; c < scores.length; c++) {
            if (scores[c] > bVal) { bVal = scores[c]; best = c; }
          }
          return best;
        }),
      );

      // Find subject class in centre region
      final cx1 = (dlSize * 0.28).round();
      final cx2 = (dlSize * 0.72).round();
      final cy1 = (dlSize * 0.22).round();
      final cy2 = (dlSize * 0.78).round();

      final classCounts = List.filled(21, 0);
      for (int y = cy1; y < cy2; y++) {
        for (int x = cx1; x < cx2; x++) {
          classCounts[seg[y][x]]++;
        }
      }
      // Prefer real object over background
      classCounts[0] = 0;
      int subjectClass = 0;
      int maxCount     = 0;
      for (int c = 0; c < 21; c++) {
        if (classCounts[c] > maxCount) {
          maxCount     = classCounts[c];
          subjectClass = c;
        }
      }

      // Check each border strip
      final strip = (dlSize * 0.18).round();
      final strips = {
        'TOP'   : _getStripClass(seg, 0,          strip,    cx1, cx2),
        'BOTTOM': _getStripClass(seg, dlSize-strip,dlSize,  cx1, cx2),
        'LEFT'  : _getStripClass(seg, cy1,         cy2,     0,   strip),
        'RIGHT' : _getStripClass(seg, cy1,         cy2, dlSize-strip, dlSize),
      };

      final framingSides = strips.entries
          .where((e) => e.value != subjectClass)
          .map((e) => e.key)
          .toList();

      final n     = framingSides.length;
      final score = [0, 25, 55, 80, 98][n.clamp(0, 4)];

      String tip;
      if (n >= 3) {
        tip = 'Subject framed on $n sides (${framingSides.join(', ')}). Excellent!';
      } else if (n == 2) {
        final missing = ['TOP','BOTTOM','LEFT','RIGHT']
            .where((s) => !framingSides.contains(s)).toList();
        tip = 'Partial framing. Add an element on the ${missing.first} side.';
      } else if (n == 1) {
        tip = 'Weak framing. Try shooting through a doorway or arch.';
      } else {
        tip = 'No framing. Look for windows, arches, or branches.';
      }

      return RuleResult(
        ruleName: 'Framing',
        score:    score,
        tip:      tip,
        detected: n > 0,
      );
    } catch (e) {
      return const RuleResult(
        ruleName: 'Framing',
        score:    50,
        tip:      'Could not analyse framing.',
        detected: false,
      );
    }
  }

  int _getStripClass(List<List<int>> seg,
      int y0, int y1, int x0, int x1) {
    final counts = List.filled(21, 0);
    for (int y = y0; y < y1 && y < seg.length; y++) {
      for (int x = x0; x < x1 && x < seg[0].length; x++) {
        counts[seg[y][x]]++;
      }
    }
    int best = 0, bestVal = 0;
    for (int c = 0; c < 21; c++) {
      if (counts[c] > bestVal) { bestVal = counts[c]; best = c; }
    }
    return best;
  }

  // ── Rule 6: Perspective / Angle ───────────────────────────
  Future<RuleResult> _checkPerspective(img.Image image) async {
    if (_midasInterpreter == null) {
      return const RuleResult(
        ruleName: 'Perspective',
        score:    50,
        tip:      'Depth model not loaded.',
        detected: false,
      );
    }

    try {
      const mdSize = 256;
      final resized = img.copyResize(image, width: mdSize, height: mdSize);

      // MiDaS v2.1 normalisation: -1.0 to +1.0
      final input = List.generate(
        1, (_) => List.generate(
          mdSize, (y) => List.generate(
            mdSize, (x) {
              final p = resized.getPixel(x, y);
              return [
                p.r / 127.5 - 1.0,
                p.g / 127.5 - 1.0,
                p.b / 127.5 - 1.0,
              ];
            },
          ),
        ),
      );

      final outputShape = _midasInterpreter!.getOutputTensor(0).shape;
      final output = List.generate(
        outputShape[0], (_) => List.generate(
          outputShape[1], (_) => List.filled(outputShape[2], 0.0),
        ),
      );

      _midasInterpreter!.run(input, output);

      // Normalise depth map 0.0 to 1.0
      final depthFlat = output[0].expand((r) => r).toList();
      final dMin = depthFlat.reduce(min);
      final dMax = depthFlat.reduce(max);
      final range = dMax - dMin;

      final depth = List.generate(
        mdSize, (y) => List.generate(
          mdSize, (x) => range > 1e-6
              ? (output[0][y][x] - dMin) / range
              : 0.0,
        ),
      );

      // 5-zone vertical analysis
      final zoneSize = mdSize ~/ 5;
      final zoneMeans = List.generate(5, (i) {
        double sum = 0;
        int    cnt = 0;
        for (int y = i*zoneSize; y < (i+1)*zoneSize && y < mdSize; y++) {
          for (int x = 0; x < mdSize; x++) {
            sum += depth[y][x];
            cnt++;
          }
        }
        return cnt > 0 ? sum / cnt : 0.0;
      });

      final topMean = (zoneMeans[0] + zoneMeans[1]) / 2;
      final botMean = (zoneMeans[3] + zoneMeans[4]) / 2;
      final overall = depthFlat.reduce((a,b)=>a+b) / depthFlat.length;
      final variance = depthFlat.map((v)=>pow(v-overall,2))
                                .reduce((a,b)=>a+b) / depthFlat.length;

      final vDiff  = botMean - topMean;
      final vRatio = overall > 1e-6 ? vDiff / overall : 0.0;

      // Sky detection — look for blue-dominant bright pixels in top zone
      double skyRatio = 0;
      int    skyCount = 0;
      final skyZone   = mdSize ~/ 3;
      for (int y = 0; y < skyZone; y++) {
        for (int x = 0; x < mdSize; x++) {
          final p = resized.getPixel(x, y);
          if (p.b > p.r + 10 && p.b > p.g && p.b > 80) skyCount++;
        }
      }
      skyRatio = skyCount / (skyZone * mdSize);

      // Overhead detection
      final isOverhead = skyRatio < 0.05 &&
                         variance < 0.04  &&
                         vDiff.abs() < 0.25;

      // Classify angle
      String label;
      int    score;

      const strong = 0.28;
      const moderate = 0.12;

      if (isOverhead) {
        label = 'HIGH ANGLE';
        score = 75;
      } else if (vRatio > strong && vDiff > 0.07 &&
                 (skyRatio > 0.04 || vRatio > 0.35)) {
        label = 'LOW ANGLE';
        score = min(100, (vRatio / 0.55 * 100).round());
      } else if (vRatio > moderate && vDiff > 0.05) {
        label = 'SLIGHT LOW ANGLE';
        score = min(100, (vRatio / 0.55 * 100).round());
      } else if (vRatio < -strong && vDiff.abs() > 0.07) {
        label = 'HIGH ANGLE';
        score = min(100, (vRatio.abs() / 0.55 * 100).round());
      } else if (vRatio < -moderate && vDiff.abs() > 0.05) {
        label = 'SLIGHT HIGH ANGLE';
        score = min(100, (vRatio.abs() / 0.55 * 100).round());
      } else {
        label = 'EYE LEVEL';
        score = min(45, (variance / 0.04 * 45).round());
      }

      final tip = label == 'LOW ANGLE'
          ? 'LOW ANGLE detected — dramatic and powerful.'
          : label == 'SLIGHT LOW ANGLE'
          ? 'SLIGHT LOW ANGLE — try going lower for more impact.'
          : label == 'HIGH ANGLE'
          ? 'HIGH ANGLE detected — overhead perspective.'
          : label == 'SLIGHT HIGH ANGLE'
          ? 'SLIGHT HIGH ANGLE — try going higher.'
          : 'EYE LEVEL — try a lower or higher angle for more impact.';

      return RuleResult(
        ruleName: 'Perspective',
        score:    score.clamp(0, 100),
        tip:      tip,
        detected: label != 'EYE LEVEL',
      );
    } catch (e) {
      return const RuleResult(
        ruleName: 'Perspective',
        score:    50,
        tip:      'Could not analyse perspective.',
        detected: false,
      );
    }
  }

  // ── NIMA overall aesthetic score ──────────────────────────
  Future<double> _getNimaScore(img.Image image) async {
    if (_nimaInterpreter == null) return 50.0;

    try {
      final resized = img.copyResize(image, width: 224, height: 224);
      final input = List.generate(
        1, (_) => List.generate(
          224, (y) => List.generate(
            224, (x) {
              final p = resized.getPixel(x, y);
              return [p.r/255.0, p.g/255.0, p.b/255.0];
            },
          ),
        ),
      );

      final output = [List.filled(10, 0.0)];
      _nimaInterpreter!.run(input, output);

      // Convert distribution to mean score 0-100
      double mean = 0;
      for (int i = 0; i < 10; i++) {
        mean += output[0][i] * (i + 1);
      }
      return (mean / 10 * 100).clamp(0, 100);
    } catch (e) {
      return 50.0;
    }
  }

  // ── Crop camera UI from screenshots ───────────────────────
  img.Image _cropCameraUI(img.Image image) {
    final H      = image.height;
    final W      = image.width;
    final top    = (H * 0.175).round();
    final bottom = (H * 0.660).round();
    if (bottom > top + 50) {
      return img.copyCrop(image, x: 0, y: top, width: W, height: bottom - top);
    }
    return image;
  }

  // ── Weighted overall score ─────────────────────────────────
  int _calculateOverall(List<RuleResult> rules) {
    // Weights for each rule
    const weights = [0.20, 0.15, 0.15, 0.15, 0.20, 0.15];
    double total  = 0;
    for (int i = 0; i < rules.length; i++) {
      total += rules[i].score * weights[i];
    }
    return total.round().clamp(0, 100);
  }

  // Return an error result when image cannot be processed
  CompositionResult _errorResult(String message) {
    final errorRule = RuleResult(
      ruleName: 'Error',
      score:    0,
      tip:      message,
      detected: false,
    );
    return CompositionResult(
      ruleOfThirds:  errorRule,
      leadingLines:  errorRule,
      negativeSpace: errorRule,
      symmetry:      errorRule,
      framing:       errorRule,
      perspective:   errorRule,
      overallScore:  0,
      nimaScore:     0,
      bestTip:       message,
      angleLabel:    'UNKNOWN',
    );
  }

  void dispose() {
    _yolo.dispose();
    _deeplabInterpreter?.close();
    _midasInterpreter?.close();
    _nimaInterpreter?.close();
  }
}

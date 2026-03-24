import 'dart:typed_data';
import 'dart:math';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;

class DetectedObject {
  final String className;
  final double confidence;
  final double x;
  final double y;
  final double width;
  final double height;

  const DetectedObject({
    required this.className,
    required this.confidence,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  double get centerX => x + width  / 2;
  double get centerY => y + height / 2;
  double get area    => width * height;
}

// COCO class names — YOLOv8 was trained on these 80 classes
const List<String> cocoClasses = [
  'person','bicycle','car','motorcycle','airplane','bus','train','truck',
  'boat','traffic light','fire hydrant','stop sign','parking meter','bench',
  'bird','cat','dog','horse','sheep','cow','elephant','bear','zebra','giraffe',
  'backpack','umbrella','handbag','tie','suitcase','frisbee','skis','snowboard',
  'sports ball','kite','baseball bat','baseball glove','skateboard','surfboard',
  'tennis racket','bottle','wine glass','cup','fork','knife','spoon','bowl',
  'banana','apple','sandwich','orange','broccoli','carrot','hot dog','pizza',
  'donut','cake','chair','couch','potted plant','bed','dining table','toilet',
  'tv','laptop','mouse','remote','keyboard','cell phone','microwave','oven',
  'toaster','sink','refrigerator','book','clock','vase','scissors',
  'teddy bear','hair drier','toothbrush',
];

class YoloDetector {
  Interpreter? _interpreter;
  bool _isLoaded = false;

  bool get isLoaded => _isLoaded;

  Future<void> loadModel() async {
    try {
      final options = InterpreterOptions()..threads = 2;
      _interpreter = await Interpreter.fromAsset(
        'assets/models/yolov8n_int8.tflite',
        options: options,
      );
      _isLoaded = true;
    } catch (e) {
      _isLoaded = false;
    }
  }

  Future<List<DetectedObject>> detect(
    img.Image image, {
    double confidenceThreshold = 0.20,
    int    maxDetections       = 10,
  }) async {
    if (!_isLoaded || _interpreter == null) return [];

    try {
      const inputSize = 320;
      final resized = img.copyResize(image, width: inputSize, height: inputSize);

      // Preprocess input based on tensor type (int8/uint8/float32)
      final inputInfo = _interpreter!.getInputTensor(0);
      final isInt8    = inputInfo.type == TfLiteType.kTfLiteInt8;
      final isUint8   = inputInfo.type == TfLiteType.kTfLiteUInt8;

      Object inputTensor;
      if (isInt8 || isUint8) {
        // Quantize: [0, 255] -> [-128, 127] or [0, 255]
        final bytes = List.generate(
          1, (_) => List.generate(
            inputSize, (y) => List.generate(
              inputSize, (x) {
                final p = resized.getPixel(x, y);
                if (isUint8) return [p.r.toInt(), p.g.toInt(), p.b.toInt()];
                return [(p.r.toInt() - 128), (p.g.toInt() - 128), (p.b.toInt() - 128)];
              },
            ),
          ),
        );
        inputTensor = bytes;
      } else {
        // Standard float32 [0, 1]
        inputTensor = List.generate(
          1, (_) => List.generate(
            inputSize, (y) => List.generate(
              inputSize, (x) {
                final p = resized.getPixel(x, y);
                return [p.r / 255.0, p.g / 255.0, p.b / 255.0];
              },
            ),
          ),
        );
      }

      final outShape = _interpreter!.getOutputTensor(0).shape;
      // Support both [1,84,8400] (transposed) and [1,8400,84] (NHWC)
      final isTransposed = outShape.length == 3 && outShape[1] == 84;
      final numDet       = isTransposed ? outShape[2] : outShape[1];
      final numCols      = isTransposed ? outShape[1] : outShape[2];

      final outputTensor = List.generate(
        outShape[0], (_) => List.generate(
          outShape[1], (_) => List.filled(outShape[2], 0.0),
        ),
      );

      _interpreter!.run(inputTensor, outputTensor);
      final raw = outputTensor[0];

      final detections = <DetectedObject>[];

      for (int i = 0; i < numDet; i++) {
        double cx, cy, w, h;
        double maxScore = 0;
        int    bestClass = 0;

        if (isTransposed) {
          // raw[row][col] where row = feature dim, col = detection
          cx = raw[0][i];
          cy = raw[1][i];
          w  = raw[2][i];
          h  = raw[3][i];
          for (int c = 0; c < 80 && (4 + c) < numCols; c++) {
            final s = raw[4 + c][i];
            if (s > maxScore) { maxScore = s; bestClass = c; }
          }
        } else {
          // raw[detection][feature]
          cx = raw[i][0];
          cy = raw[i][1];
          w  = raw[i][2];
          h  = raw[i][3];
          for (int c = 0; c < 80 && (4 + c) < numCols; c++) {
            final s = raw[i][4 + c];
            if (s > maxScore) { maxScore = s; bestClass = c; }
          }
        }

        if (maxScore < confidenceThreshold) continue;

        // YOLOv8n INT8 outputs values in [0,320] not [0,1] — normalise
        final normCx = (cx / inputSize).clamp(0.0, 1.0);
        final normCy = (cy / inputSize).clamp(0.0, 1.0);
        final normW  = (w  / inputSize).clamp(0.0, 1.0);
        final normH  = (h  / inputSize).clamp(0.0, 1.0);

        final x = (normCx - normW / 2).clamp(0.0, 1.0);
        final y = (normCy - normH / 2).clamp(0.0, 1.0);
        final bw = normW.clamp(0.0, 1.0 - x);
        final bh = normH.clamp(0.0, 1.0 - y);

        if (bw * bh < 0.005) continue; // skip tiny boxes

        detections.add(DetectedObject(
          className:  bestClass < cocoClasses.length ? cocoClasses[bestClass] : 'object',
          confidence: maxScore,
          x: x, y: y, width: bw, height: bh,
        ));
      }

      detections.sort((a, b) => b.confidence.compareTo(a.confidence));
      return _nms(detections, iouThreshold: 0.45, maxResults: maxDetections);
    } catch (e) {
      return [];
    }
  }

  List<DetectedObject> _nms(
    List<DetectedObject> dets, {
    required double iouThreshold,
    required int    maxResults,
  }) {
    final out     = <DetectedObject>[];
    final removed = <int>{};
    for (int i = 0; i < dets.length && out.length < maxResults; i++) {
      if (removed.contains(i)) continue;
      out.add(dets[i]);
      for (int j = i + 1; j < dets.length; j++) {
        if (!removed.contains(j) && _iou(dets[i], dets[j]) > iouThreshold) {
          removed.add(j);
        }
      }
    }
    return out;
  }

  double _iou(DetectedObject a, DetectedObject b) {
    final ix1 = max(a.x, b.x);
    final iy1 = max(a.y, b.y);
    final ix2 = min(a.x + a.width,  b.x + b.width);
    final iy2 = min(a.y + a.height, b.y + b.height);
    final iw  = ix2 - ix1;
    final ih  = iy2 - iy1;
    if (iw <= 0 || ih <= 0) return 0.0;
    final inter = iw * ih;
    return inter / (a.area + b.area - inter);
  }

  DetectedObject? getPrimarySubject(List<DetectedObject> dets) {
    if (dets.isEmpty) return null;
    final persons = dets.where((d) => d.className == 'person').toList();
    if (persons.isNotEmpty) return persons.first;
    return dets.first;
  }

  void dispose() {
    _interpreter?.close();
    _isLoaded = false;
  }
}

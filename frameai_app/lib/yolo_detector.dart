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
    double confidenceThreshold = 0.15,
    int    maxDetections       = 10,
  }) async {
    if (!_isLoaded || _interpreter == null) return [];

    try {
      const inputSize = 320;
      final resized = img.copyResize(image, width: inputSize, height: inputSize);

      final inputTensor = _interpreter!.getInputTensor(0);
      final isInt8      = inputTensor.type == TfLiteType.kTfLiteInt8;
      final isUint8     = inputTensor.type == TfLiteType.kTfLiteUInt8;

      // Use typed lists for performance and reliability
      final inputData = isInt8
          ? Int8List(1 * inputSize * inputSize * 3)
          : (isUint8 ? Uint8List(1 * inputSize * inputSize * 3) : Float32List(1 * inputSize * inputSize * 3));
      
      final data = inputData as List;
      int pixelIdx = 0;
      for (int y = 0; y < inputSize; y++) {
        for (int x = 0; x < inputSize; x++) {
          final p = resized.getPixel(x, y);
          if (isInt8) {
             data[pixelIdx++] = (p.r.toInt() - 128);
             data[pixelIdx++] = (p.g.toInt() - 128);
             data[pixelIdx++] = (p.b.toInt() - 128);
          } else if (isUint8) {
             data[pixelIdx++] = p.r.toInt();
             data[pixelIdx++] = p.g.toInt();
             data[pixelIdx++] = p.b.toInt();
          } else {
             data[pixelIdx++] = p.r / 255.0;
             data[pixelIdx++] = p.g / 255.0;
             data[pixelIdx++] = p.b / 255.0;
          }
        }
      }

      final outputTensor = _interpreter!.getOutputTensor(0);
      final outShape     = outputTensor.shape;
      final isOutInt8    = outputTensor.type == TfLiteType.kTfLiteInt8;
      
      final numElements = outShape.reduce((a, b) => a * b);
      final outputData = isOutInt8 ? Int8List(numElements) : Float32List(numElements);
      
      _interpreter!.run(inputData, outputData);

      List<double> scores;
      if (isOutInt8) {
        double scale = outputTensor.params.scale;
        if (scale == 0.0) scale = 0.00390625; // Fallback if metadata is stripped
        final int zeroPoint = outputTensor.params.zeroPoint;
        final data = outputData as Int8List;
        scores = data.map((v) => (v - zeroPoint) * scale).toList();
      } else {
        scores = (outputData as Float32List).toList();
      }

      final isTransposed = outShape.length == 3 && outShape[1] == 84;
      final numDet       = isTransposed ? outShape[2] : outShape[1];
      final numCols      = isTransposed ? outShape[1] : outShape[2];

      final detections = <DetectedObject>[];
      for (int i = 0; i < numDet; i++) {
        double cx, cy, w, h;
        double maxScore = 0;
        int    bestClass = 0;

        if (isTransposed) {
          // data[feature][detection]
          cx = scores[0 * numDet + i];
          cy = scores[1 * numDet + i];
          w  = scores[2 * numDet + i];
          h  = scores[3 * numDet + i];
          for (int c = 0; c < 80; c++) {
            final s = scores[(4 + c) * numDet + i];
            if (s > maxScore) { maxScore = s; bestClass = c; }
          }
        } else {
          // data[detection][feature]
          final base = i * numCols;
          cx = scores[base + 0];
          cy = scores[base + 1];
          w  = scores[base + 2];
          h  = scores[base + 3];
          for (int c = 0; c < 80; c++) {
            final s = scores[base + 4 + c];
            if (s > maxScore) { maxScore = s; bestClass = c; }
          }
        }

        if (maxScore < confidenceThreshold) continue;

        // YOLOv8n INT8 usually outputs raw pixel coordinates [0, 320]
        final normCx = (cx / inputSize).clamp(0.0, 1.0);
        final normCy = (cy / inputSize).clamp(0.0, 1.0);
        final normW  = (w  / inputSize).clamp(0.0, 1.0);
        final normH  = (h  / inputSize).clamp(0.0, 1.0);

        final x = (normCx - normW / 2).clamp(0.0, 1.0);
        final y = (normCy - normH / 2).clamp(0.0, 1.0);
        final bw = normW.clamp(0.0, 1.0 - x);
        final bh = normH.clamp(0.0, 1.0 - y);

        if (bw * bh < 0.002) continue; // skip tiny noise

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

import 'dart:typed_data';
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;

// One detected object — has a class name, confidence score, and position
class DetectedObject {
  final String className;
  final double confidence;
  final double x;       // left edge as fraction 0.0 to 1.0
  final double y;       // top edge as fraction 0.0 to 1.0
  final double width;   // width as fraction 0.0 to 1.0
  final double height;  // height as fraction 0.0 to 1.0

  const DetectedObject({
    required this.className,
    required this.confidence,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  // Centre point of the bounding box as fractions
  double get centerX => x + width  / 2;
  double get centerY => y + height / 2;

  // Area of bounding box as fraction of total frame
  double get area => width * height;

  @override
  String toString() =>
      'DetectedObject($className, conf=${confidence.toStringAsFixed(2)}, '
      'cx=${centerX.toStringAsFixed(2)}, cy=${centerY.toStringAsFixed(2)})';
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

  // Load the YOLOv8n TFLite model from assets
  Future<void> loadModel() async {
    try {
      final options = InterpreterOptions()..threads = 2;
      _interpreter = await Interpreter.fromAsset(
        'assets/models/yolov8n_int8.tflite',
        options: options,
      );
      _isLoaded = true;
      print('YoloDetector: model loaded successfully');
    } catch (e) {
      print('YoloDetector: failed to load model — $e');
      _isLoaded = false;
    }
  }

  // Run detection on a PIL image
  // Returns list of detected objects sorted by confidence
  Future<List<DetectedObject>> detect(
    img.Image image, {
    double confidenceThreshold = 0.35,
    int    maxDetections       = 10,
  }) async {
    if (!_isLoaded || _interpreter == null) {
      print('YoloDetector: model not loaded');
      return [];
    }

    try {
      // YOLOv8n expects 320x320 RGB input
      const inputSize = 320;

      // Resize image to model input size
      final resized = img.copyResize(
        image,
        width:  inputSize,
        height: inputSize,
      );

      // Convert image to float32 tensor normalised 0.0 to 1.0
      // Shape: [1, 320, 320, 3]
      final inputTensor = List.generate(
        1, (_) => List.generate(
          inputSize, (y) => List.generate(
            inputSize, (x) {
              final pixel = resized.getPixel(x, y);
              return [
                pixel.r / 255.0,
                pixel.g / 255.0,
                pixel.b / 255.0,
              ];
            },
          ),
        ),
      );

      // YOLOv8 output shape: [1, 84, 8400]
      // 84 = 4 bbox coords + 80 class scores
      // 8400 = number of candidate detections
      final outputShape = _interpreter!.getOutputTensor(0).shape;
      final outputTensor = List.generate(
        outputShape[0], (_) => List.generate(
          outputShape[1], (_) => List.filled(outputShape[2], 0.0),
        ),
      );

      // Run inference
      _interpreter!.run(inputTensor, outputTensor);

      // Parse detections from output tensor
      return _parseDetections(
        outputTensor[0],
        confidenceThreshold: confidenceThreshold,
        maxDetections:       maxDetections,
      );

    } catch (e) {
      print('YoloDetector: detection failed — $e');
      return [];
    }
  }

  // Parse raw YOLOv8 output into DetectedObject list
  List<DetectedObject> _parseDetections(
    List<List<double>> output, {
    required double confidenceThreshold,
    required int    maxDetections,
  }) {
    final detections = <DetectedObject>[];
    final numDetections = output[0].length; // 8400

    for (int i = 0; i < numDetections; i++) {
      // Extract bbox coordinates (centre format, normalised)
      final cx = output[0][i];
      final cy = output[1][i];
      final w  = output[2][i];
      final h  = output[3][i];

      // Find class with highest score
      double maxScore    = 0.0;
      int    bestClassId = 0;
      for (int c = 0; c < 80; c++) {
        final score = output[4 + c][i];
        if (score > maxScore) {
          maxScore    = score;
          bestClassId = c;
        }
      }

      // Skip detections below confidence threshold
      if (maxScore < confidenceThreshold) continue;

      // Convert from centre format to top-left format
      final x = cx - w / 2;
      final y = cy - h / 2;

      // Clamp to valid range
      final clampedX = x.clamp(0.0, 1.0);
      final clampedY = y.clamp(0.0, 1.0);
      final clampedW = w.clamp(0.0, 1.0 - clampedX);
      final clampedH = h.clamp(0.0, 1.0 - clampedY);

      // Skip tiny detections (less than 1% of frame)
      if (clampedW * clampedH < 0.01) continue;

      final className = bestClassId < cocoClasses.length
          ? cocoClasses[bestClassId]
          : 'object';

      detections.add(DetectedObject(
        className:  className,
        confidence: maxScore,
        x:          clampedX,
        y:          clampedY,
        width:      clampedW,
        height:     clampedH,
      ));
    }

    // Sort by confidence — highest first
    detections.sort((a, b) => b.confidence.compareTo(a.confidence));

    // Apply simple non-max suppression to remove duplicate detections
    return _nonMaxSuppression(
      detections,
      iouThreshold: 0.45,
      maxResults:   maxDetections,
    );
  }

  // Remove overlapping duplicate detections
  List<DetectedObject> _nonMaxSuppression(
    List<DetectedObject> detections, {
    required double iouThreshold,
    required int    maxResults,
  }) {
    final result  = <DetectedObject>[];
    final removed = <int>{};

    for (int i = 0; i < detections.length && result.length < maxResults; i++) {
      if (removed.contains(i)) continue;
      result.add(detections[i]);

      for (int j = i + 1; j < detections.length; j++) {
        if (removed.contains(j)) continue;
        if (_iou(detections[i], detections[j]) > iouThreshold) {
          removed.add(j);
        }
      }
    }
    return result;
  }

  // Calculate Intersection over Union between two boxes
  double _iou(DetectedObject a, DetectedObject b) {
    final interX1 = max(a.x, b.x);
    final interY1 = max(a.y, b.y);
    final interX2 = min(a.x + a.width,  b.x + b.width);
    final interY2 = min(a.y + a.height, b.y + b.height);

    final interW = interX2 - interX1;
    final interH = interY2 - interY1;

    if (interW <= 0 || interH <= 0) return 0.0;

    final interArea = interW * interH;
    final unionArea = a.area + b.area - interArea;

    return unionArea > 0 ? interArea / unionArea : 0.0;
  }

  // Get the most prominent detected object
  // Used for Rule of Thirds and Negative Space checks
  DetectedObject? getPrimarySubject(List<DetectedObject> detections) {
    if (detections.isEmpty) return null;

    // Prefer person class — most common photography subject
    final persons = detections.where((d) => d.className == 'person').toList();
    if (persons.isNotEmpty) return persons.first;

    // Otherwise return highest confidence detection
    return detections.first;
  }

  void dispose() {
    _interpreter?.close();
    _isLoaded = false;
  }
}

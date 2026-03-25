import 'dart:math';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';

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

/// Renamed to YoloDetector purely to keep imports working smoothly during the transition,
/// but functionally this is now entirely powered by Google ML Kit.
class YoloDetector {
  ObjectDetector? _objectDetector;
  bool _isLoaded = false;

  bool get isLoaded => _isLoaded;

  Future<void> loadModel() async {
    try {
      final options = ObjectDetectorOptions(
        mode: DetectionMode.single,
        classifyObjects: true,
        multipleObjects: true,
      );
      _objectDetector = ObjectDetector(options: options);
      _isLoaded = true;
    } catch (e) {
      _isLoaded = false;
    }
  }

  /// Detect objects using Google ML Kit.
  /// Accepts the file path directly to bypass manual pixel array parsing.
  Future<List<DetectedObject>> detect(String imagePath, int imgWidth, int imgHeight) async {
    if (!_isLoaded || _objectDetector == null) return [];

    try {
      final inputImage = InputImage.fromFilePath(imagePath);
      final objects = await _objectDetector!.processImage(inputImage);

      final detections = <DetectedObject>[];
      for (final obj in objects) {
        final rect = obj.boundingBox;
        
        // Normalize bounding boxes to [0.0, 1.0] for the Composition Rules
        final x = (rect.left / imgWidth).clamp(0.0, 1.0);
        final y = (rect.top / imgHeight).clamp(0.0, 1.0);
        final w = (rect.width / imgWidth).clamp(0.0, 1.0 - x);
        final h = (rect.height / imgHeight).clamp(0.0, 1.0 - y);

        if (w * h < 0.005) continue; // skip tiny noise

        String label = 'object';
        double conf = 0.5; // MLKit defaults to high geometric confidence for untagged objects
        
        if (obj.labels.isNotEmpty) {
          final bestLabel = obj.labels.reduce((a, b) => a.confidence > b.confidence ? a : b);
          label = bestLabel.text.toLowerCase();
          conf = bestLabel.confidence;
        }

        detections.add(DetectedObject(
          className: label,
          confidence: conf,
          x: x, y: y, width: w, height: h,
        ));
      }

      detections.sort((a, b) => b.confidence.compareTo(a.confidence));
      return detections;
    } catch (e) {
      return [];
    }
  }

  DetectedObject? getPrimarySubject(List<DetectedObject> dets) {
    if (dets.isEmpty) return null;
    
    // ML Kit uses coarse labels like 'Fashion good', 'Food', 'Place', etc.
    // We prioritize humans/fashion as subjects.
    final persons = dets.where((d) => 
      d.className.contains('person') || 
      d.className.contains('fashion') ||
      d.className.contains('portrait')
    ).toList();
    
    if (persons.isNotEmpty) return persons.first;
    
    // Otherwise return the most confident generic object
    return dets.first;
  }

  void dispose() {
    _objectDetector?.close();
    _isLoaded = false;
  }
}

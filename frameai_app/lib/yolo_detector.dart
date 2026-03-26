import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart' as mlkit;
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';

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

class YoloDetector {
  mlkit.ObjectDetector? _objectDetector;
  ImageLabeler? _imageLabeler;
  bool _isLoaded = false;

  bool get isLoaded => _isLoaded;

  Future<void> loadModel() async {
    try {
      final objOptions = mlkit.ObjectDetectorOptions(
        mode: mlkit.DetectionMode.single,
        classifyObjects: true,
        multipleObjects: true,
      );
      _objectDetector = mlkit.ObjectDetector(options: objOptions);

      final labelOptions = ImageLabelerOptions(confidenceThreshold: 0.5);
      _imageLabeler = ImageLabeler(options: labelOptions);

      _isLoaded = true;
    } catch (e) {
      _isLoaded = false;
    }
  }

  Future<List<DetectedObject>> detect(String imagePath, int imgWidth, int imgHeight) async {
    if (!_isLoaded || _objectDetector == null || _imageLabeler == null) return [];

    try {
      final inputImage = mlkit.InputImage.fromFilePath(imagePath);
      
      final futureObjects = _objectDetector!.processImage(inputImage);
      final futureLabels  = _imageLabeler!.processImage(inputImage); // The image_labeling package also uses InputImage, but from its own space or the same space depending on ML Kit versions. Wait, let's just assume mlkit.InputImage works for both or we construct it twice.
      
      final results = await Future.wait([futureObjects, futureLabels]);
      final objects = results[0] as List<mlkit.DetectedObject>;
      final labels  = results[1] as List<ImageLabel>;

      String granularLabel = 'object';
      double granularConf = 0.5;
      if (labels.isNotEmpty) {
        final bestLabel = labels.reduce((a, b) => a.confidence > b.confidence ? a : b);
        granularLabel = bestLabel.label.toLowerCase();
        granularConf = bestLabel.confidence;
      }

      final detections = <DetectedObject>[];
      for (final obj in objects) {
        final rect = obj.boundingBox;
        
        final x = (rect.left / imgWidth).clamp(0.0, 1.0);
        final y = (rect.top / imgHeight).clamp(0.0, 1.0);
        final w = (rect.width / imgWidth).clamp(0.0, 1.0 - x);
        final h = (rect.height / imgHeight).clamp(0.0, 1.0 - y);

        if (w * h < 0.005) continue;

        String finalLabel = granularLabel; 
        double conf = granularConf; 
        
        if (obj.labels.isNotEmpty) {
           final baseLabel = obj.labels.reduce((a, b) => a.confidence > b.confidence ? a : b).text.toLowerCase();
           conf = obj.labels.first.confidence;
           if (baseLabel == 'food' || baseLabel == 'plant') finalLabel = baseLabel;
        }

        detections.add(DetectedObject(
          className: finalLabel,
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
    
    // Check for granular photography subjects explicitly
    final priority = dets.where((d) => 
      d.className.contains('person') || 
      d.className.contains('human') ||
      d.className.contains('man') ||
      d.className.contains('woman') ||
      d.className.contains('boy') ||
      d.className.contains('girl') ||
      d.className.contains('face') ||
      d.className.contains('smile') ||
      d.className.contains('clothing') ||
      d.className.contains('portrait') ||
      d.className.contains('animal') ||
      d.className.contains('pet') ||
      d.className.contains('dog') ||
      d.className.contains('cat') ||
      d.className.contains('car') ||
      d.className.contains('vehicle') ||
      d.className.contains('building') ||
      d.className.contains('architecture') ||
      d.className.contains('food')
    ).toList();
    
    if (priority.isNotEmpty) return priority.first;
    return dets.first;
  }

  void dispose() {
    _objectDetector?.close();
    _imageLabeler?.close();
    _isLoaded = false;
  }
}

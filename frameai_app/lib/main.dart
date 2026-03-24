import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'camera_screen.dart';

List<CameraDescription> globalCameras = [];

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    globalCameras = await availableCameras();
  } catch (e) {
    globalCameras = [];
  }
  runApp(const FrameAIApp());
}

class FrameAIApp extends StatelessWidget {
  const FrameAIApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FrameAI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFFF6B2B),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const CameraScreen(),
    );
  }
}

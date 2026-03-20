import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'camera_screen.dart';

// This runs inside the floating overlay window
// It listens for the open_camera message from the trigger button
class OverlayService extends StatefulWidget {
  const OverlayService({super.key});

  @override
  State<OverlayService> createState() => _OverlayServiceState();
}

class _OverlayServiceState extends State<OverlayService> {
  bool _cameraOpen = false;

  @override
  void initState() {
    super.initState();
    // Listen for messages from the overlay trigger button
    FlutterOverlayWindow.overlayListener.listen((data) {
      if (data == 'open_camera' && mounted) {
        setState(() => _cameraOpen = true);
        // Expand overlay to full screen for camera
        FlutterOverlayWindow.resizeOverlay(
          WindowSize.fullCover,
          WindowSize.fullCover,
          true,
        );
      }
    });
  }

  void _closeCamera() {
    setState(() => _cameraOpen = false);
    // Shrink back to small button size
    FlutterOverlayWindow.resizeOverlay(70, 70, true);
  }

  @override
  Widget build(BuildContext context) {
    if (_cameraOpen) {
      return CameraScreen(onClose: _closeCamera);
    }
    // Show nothing when camera is closed
    // The trigger button is shown by OverlayTriggerButton in main.dart
    return const SizedBox.shrink();
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'camera_screen.dart';

class OverlayApp extends StatelessWidget {
  const OverlayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: const OverlayHome(),
    );
  }
}

class OverlayHome extends StatefulWidget {
  const OverlayHome({super.key});

  @override
  State<OverlayHome> createState() => _OverlayHomeState();
}

class _OverlayHomeState extends State<OverlayHome>
    with SingleTickerProviderStateMixin {

  bool _cameraOpen = false;
  late AnimationController _pulse;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _anim = Tween<double>(begin: 0.9, end: 1.1).animate(
      CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _openCamera() async {
    await FlutterOverlayWindow.resizeOverlay(
      WindowSize.matchParent,
      WindowSize.matchParent,
      false,
    );
    if (mounted) setState(() => _cameraOpen = true);
  }

  Future<void> _closeCamera() async {
    if (mounted) setState(() => _cameraOpen = false);
    await FlutterOverlayWindow.resizeOverlay(70, 70, true);
  }

  @override
  Widget build(BuildContext context) {
    if (_cameraOpen) {
      return CameraScreen(onClose: _closeCamera);
    }
    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        onTap: _openCamera,
        child: AnimatedBuilder(
          animation: _anim,
          builder: (context, child) => Transform.scale(
            scale: _anim.value,
            child: child,
          ),
          child: Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: const Color(0xFFFF6B2B),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFFF6B2B).withAlpha(120),
                  blurRadius: 12,
                  spreadRadius: 3,
                ),
              ],
            ),
            child: const Icon(
              Icons.center_focus_strong,
              color: Colors.black,
              size: 28,
            ),
          ),
        ),
      ),
    );
  }
}

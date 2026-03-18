import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:permission_handler/permission_handler.dart';
import 'overlay_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FrameAIApp());
}

// Entry point when app is launched as overlay
@pragma("vm:entry-point")
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OverlayApp());
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
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _overlayActive = false;
  String _statusMessage = 'Tap START to activate FrameAI';

  @override
  void initState() {
    super.initState();
    _checkPermissions();
  }

  // Check if overlay permission is already granted
  Future<void> _checkPermissions() async {
    final hasOverlay = await FlutterOverlayWindow.isPermissionGranted();
    if (mounted) {
      setState(() {
        if (hasOverlay) {
          _statusMessage = 'Permission granted. Tap START to activate.';
        } else {
          _statusMessage = 'Overlay permission needed. Tap REQUEST PERMISSION.';
        }
      });
    }
  }

  // Ask user for overlay permission
  Future<void> _requestPermission() async {
    final granted = await FlutterOverlayWindow.requestPermission();
    if (mounted) {
      setState(() {
        if (granted == true) {
          _statusMessage = 'Permission granted! Tap START to activate.';
        } else {
          _statusMessage = 'Permission denied. Please allow in Settings.';
        }
      });
    }
  }

  // Start the floating overlay
  Future<void> _startOverlay() async {
    final hasPermission = await FlutterOverlayWindow.isPermissionGranted();
    if (!hasPermission) {
      setState(() {
        _statusMessage = 'Please request permission first.';
      });
      return;
    }

    await FlutterOverlayWindow.showOverlay(
      enableDrag: true,
      overlayTitle: 'FrameAI',
      overlayContent: 'FrameAI is running',
      flag: OverlayFlag.defaultFlag,
      visibility: NotificationVisibility.visibilityPublic,
      positionGravity: PositionGravity.auto,
      width: 160,
      height: 400,
    );

    if (mounted) {
      setState(() {
        _overlayActive = true;
        _statusMessage = 'FrameAI is active! Open your camera app.';
      });
    }
  }

  // Stop the floating overlay
  Future<void> _stopOverlay() async {
    await FlutterOverlayWindow.closeOverlay();
    if (mounted) {
      setState(() {
        _overlayActive = false;
        _statusMessage = 'FrameAI stopped.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [

              // Logo and title
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: const Color(0xFFFF6B2B),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Icon(
                  Icons.camera_enhance,
                  color: Colors.black,
                  size: 44,
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'FrameAI',
                style: TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Real-Time Composition Coach',
                style: TextStyle(
                  fontSize: 14,
                  color: Color(0xFF888888),
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 48),

              // Status message
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1A1A),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: const Color(0xFF333333),
                  ),
                ),
                child: Text(
                  _statusMessage,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFFCCCCCC),
                    height: 1.5,
                  ),
                ),
              ),
              const SizedBox(height: 32),

              // Request permission button
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: _requestPermission,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFFF6B2B),
                    side: const BorderSide(color: Color(0xFFFF6B2B)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text(
                    'REQUEST PERMISSION',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // Start / Stop button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _overlayActive ? _stopOverlay : _startOverlay,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _overlayActive
                        ? const Color(0xFF333333)
                        : const Color(0xFFFF6B2B),
                    foregroundColor: _overlayActive
                        ? Colors.white
                        : Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 0,
                  ),
                  child: Text(
                    _overlayActive ? 'STOP FRAMEAI' : 'START FRAMEAI',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 32),

              // Instructions
              const Text(
                'How to use:\n'
                '1. Tap REQUEST PERMISSION and allow\n'
                '2. Tap START FRAMEAI\n'
                '3. Open your camera app\n'
                '4. Tap the orange button to analyse',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: Color(0xFF666666),
                  height: 1.8,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:camera/camera.dart';

// Global camera list — loaded once at startup
List<CameraDescription> globalCameras = [];

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Load available cameras before app starts
  try {
    globalCameras = await availableCameras();
  } catch (e) {
    globalCameras = [];
  }

  runApp(const FrameAIApp());
}

// Entry point when running as overlay
@pragma("vm:entry-point")
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OverlayEntryApp());
}

// Minimal app wrapper for overlay entry point
class OverlayEntryApp extends StatelessWidget {
  const OverlayEntryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: const OverlayRoot(),
    );
  }
}

// Root widget shown inside the overlay window
class OverlayRoot extends StatelessWidget {
  const OverlayRoot({super.key});

  @override
  Widget build(BuildContext context) {
    return const OverlayTriggerButton();
  }
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
  String _statusMessage = 'Tap REQUEST PERMISSION then START FRAMEAI';

  @override
  void initState() {
    super.initState();
    _checkPermission();
  }

  Future<void> _checkPermission() async {
    final has = await FlutterOverlayWindow.isPermissionGranted();
    if (mounted) {
      setState(() {
        _statusMessage = has
            ? 'Permission granted. Tap START FRAMEAI.'
            : 'Tap REQUEST PERMISSION first.';
      });
    }
  }

  Future<void> _requestPermission() async {
    final granted = await FlutterOverlayWindow.requestPermission();
    if (mounted) {
      setState(() {
        _statusMessage = (granted == true)
            ? 'Permission granted! Tap START FRAMEAI.'
            : 'Permission denied. Please allow in Settings.';
      });
    }
  }

  Future<void> _startOverlay() async {
    final has = await FlutterOverlayWindow.isPermissionGranted();
    if (!has) {
      setState(() => _statusMessage = 'Please grant permission first.');
      return;
    }

    await FlutterOverlayWindow.showOverlay(
      enableDrag:       true,
      overlayTitle:     'FrameAI',
      overlayContent:   'FrameAI is running',
      flag:             OverlayFlag.defaultFlag,
      visibility:       NotificationVisibility.visibilityPublic,
      positionGravity:  PositionGravity.auto,
      width:            70,
      height:           70,
    );

    if (mounted) {
      setState(() {
        _overlayActive  = true;
        _statusMessage  = 'FrameAI is active! Open your camera app and tap the orange button.';
      });
    }
  }

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
              Container(
                width: 80, height: 80,
                decoration: BoxDecoration(
                  color: const Color(0xFFFF6B2B),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Icon(Icons.camera_enhance,
                    color: Colors.black, size: 44),
              ),
              const SizedBox(height: 20),
              const Text('FrameAI',
                  style: TextStyle(fontSize: 36,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      letterSpacing: 2)),
              const SizedBox(height: 8),
              const Text('Real-Time Composition Coach',
                  style: TextStyle(fontSize: 14,
                      color: Color(0xFF888888),
                      letterSpacing: 1)),
              const SizedBox(height: 48),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1A1A),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF333333)),
                ),
                child: Text(_statusMessage,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 14,
                        color: Color(0xFFCCCCCC), height: 1.5)),
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: _requestPermission,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFFF6B2B),
                    side: const BorderSide(color: Color(0xFFFF6B2B)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('REQUEST PERMISSION',
                      style: TextStyle(fontSize: 14,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1)),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _overlayActive ? _stopOverlay : _startOverlay,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _overlayActive
                        ? const Color(0xFF333333)
                        : const Color(0xFFFF6B2B),
                    foregroundColor: _overlayActive
                        ? Colors.white : Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    elevation: 0,
                  ),
                  child: Text(
                    _overlayActive ? 'STOP FRAMEAI' : 'START FRAMEAI',
                    style: const TextStyle(fontSize: 16,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.5),
                  ),
                ),
              ),
              const SizedBox(height: 32),
              const Text(
                'How to use:\n'
                '1. Tap REQUEST PERMISSION and allow\n'
                '2. Tap START FRAMEAI\n'
                '3. Tap the orange button floating on screen\n'
                '4. Frame your shot and tap ANALYSE',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13,
                    color: Color(0xFF666666), height: 1.8),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// The small floating orange button shown in the overlay
class OverlayTriggerButton extends StatefulWidget {
  const OverlayTriggerButton({super.key});

  @override
  State<OverlayTriggerButton> createState() =>
      _OverlayTriggerButtonState();
}

class _OverlayTriggerButtonState extends State<OverlayTriggerButton>
    with SingleTickerProviderStateMixin {

  late AnimationController _pulse;
  late Animation<double>   _anim;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1500))
      ..repeat(reverse: true);
    _anim = Tween<double>(begin: 0.9, end: 1.1).animate(
        CurvedAnimation(parent: _pulse, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  void _openCamera() {
    // Send message to overlay to open camera screen
    FlutterOverlayWindow.shareData('open_camera');
  }

  @override
  Widget build(BuildContext context) {
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
            width: 60, height: 60,
            decoration: BoxDecoration(
              color: const Color(0xFFFF6B2B),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFFF6B2B).withAlpha(100),
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

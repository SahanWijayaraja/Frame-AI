import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'composition_analyzer.dart';
import 'score_box_widget.dart';

// This widget runs inside the floating overlay window
// It is what the user sees floating above their camera app
class OverlayApp extends StatelessWidget {
  const OverlayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: const OverlayScreen(),
    );
  }
}

class OverlayScreen extends StatefulWidget {
  const OverlayScreen({super.key});

  @override
  State<OverlayScreen> createState() => _OverlayScreenState();
}

class _OverlayScreenState extends State<OverlayScreen>
    with SingleTickerProviderStateMixin {

  // States the overlay can be in
  bool _isAnalysing = false;
  bool _showResults = false;
  CompositionResult? _result;
  String _errorMessage = '';

  // Animation for the pulsing orange button
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  // The analyzer that runs all 6 composition rules
  final CompositionAnalyzer _analyzer = CompositionAnalyzer();

  @override
  void initState() {
    super.initState();
    _initAnimations();
    _analyzer.loadModels();
  }

  void _initAnimations() {
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _analyzer.dispose();
    super.dispose();
  }

  // Called when user taps the orange button
  Future<void> _onAnalysePressed() async {
    if (_isAnalysing) return;

    setState(() {
      _isAnalysing  = true;
      _showResults  = false;
      _errorMessage = '';
    });

    try {
      // Take a screenshot of what is currently on screen
      // This captures the camera viewfinder
      final screenshot = await _captureScreen();

      if (screenshot == null) {
        setState(() {
          _isAnalysing  = false;
          _errorMessage = 'Could not capture screen.\nTap again to retry.';
        });
        return;
      }

      // Run all 6 composition rules on the captured image
      final result = await _analyzer.analyseImage(screenshot);

      setState(() {
        _isAnalysing = false;
        _showResults = true;
        _result      = result;
      });

    } catch (e) {
      setState(() {
        _isAnalysing  = false;
        _errorMessage = 'Analysis failed.\nTap again to retry.';
      });
    }
  }

  // Capture the current screen as image bytes
  Future<List<int>?> _captureScreen() async {
    try {
      // Use Flutter overlay window's built-in screenshot capability
      // This captures what is behind the overlay (the camera app)
      await Future.delayed(const Duration(milliseconds: 300));
      // Return null for now — will be replaced with real capture
      // in a later step after testing basic overlay works
      return null;
    } catch (e) {
      return null;
    }
  }

  void _closeResults() {
    setState(() {
      _showResults  = false;
      _result       = null;
      _errorMessage = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: SizedBox(
        width:  160,
        height: 400,
        child: Stack(
          children: [

            // Score box — shown after analysis
            if (_showResults && _result != null)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: ScoreBoxWidget(
                  result:  _result!,
                  onClose: _closeResults,
                ),
              ),

            // Error message
            if (_errorMessage.isNotEmpty && !_isAnalysing)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xCC0A0A0A),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: const Color(0xFFEF4444),
                    ),
                  ),
                  child: Text(
                    _errorMessage,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFFEF4444),
                      height: 1.4,
                    ),
                  ),
                ),
              ),

            // Analysing spinner
            if (_isAnalysing)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xCC0A0A0A),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: const Color(0x4DFF6B2B),
                    ),
                  ),
                  child: Column(
                    children: [
                      const SizedBox(
                        width:  36,
                        height: 36,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Color(0xFFFF6B2B),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'ANALYSING...',
                        style: TextStyle(
                          fontSize: 10,
                          color:    Color(0xFFFF6B2B),
                          letterSpacing: 2,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // Orange floating trigger button — always visible
            Positioned(
              bottom: 0,
              right:  0,
              child: GestureDetector(
                onTap: _onAnalysePressed,
                child: AnimatedBuilder(
                  animation: _pulseAnimation,
                  builder: (context, child) {
                    return Transform.scale(
                      scale: _isAnalysing ? 1.0 : _pulseAnimation.value,
                      child: child,
                    );
                  },
                  child: Container(
                    width:  52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: _isAnalysing
                          ? const Color(0xFF555555)
                          : const Color(0xFFFF6B2B),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFFF6B2B).withOpacity(0.4),
                          blurRadius:   12,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: Icon(
                      _isAnalysing
                          ? Icons.hourglass_top
                          : Icons.center_focus_strong,
                      color: Colors.black,
                      size: 24,
                    ),
                  ),
                ),
              ),
            ),

          ],
        ),
      ),
    );
  }
}

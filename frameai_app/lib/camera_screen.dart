import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import 'composition_analyzer.dart';
import 'score_box_widget.dart';
import 'camera_overlay_painter.dart';
import 'main.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {

  CameraController? _controller;
  bool _isInitialised  = false;
  bool _isAnalysing    = false;
  bool _showResults    = false;
  bool _showGrid       = true;
  CompositionResult?  _result;
  String _errorMessage = '';

  final CompositionAnalyzer _analyzer = CompositionAnalyzer();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
    _analyzer.loadModels();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    _analyzer.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _controller?.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  Future<void> _initCamera() async {
    if (globalCameras.isEmpty) {
      setState(() => _errorMessage = 'No camera found on this device.');
      return;
    }

    // Use back camera
    final camera = globalCameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => globalCameras.first,
    );

    final controller = CameraController(
      camera,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    try {
      await controller.initialize();
      if (mounted) {
        setState(() {
          _controller    = controller;
          _isInitialised = true;
          _errorMessage  = '';
        });
      }
    } catch (e) {
      setState(() => _errorMessage = 'Could not start camera: $e');
    }
  }

  // Capture current frame and run AI analysis
  Future<void> _analyse() async {
    if (_isAnalysing || _controller == null ||
        !_controller!.value.isInitialized) return;

    setState(() {
      _isAnalysing  = true;
      _showResults  = false;
      _errorMessage = '';
    });

    try {
      // Capture photo from camera
      final XFile file       = await _controller!.takePicture();
      final Uint8List bytes  = await file.readAsBytes();

      // Run all 6 composition rules + NIMA
      final result = await _analyzer.analyseImage(bytes.toList());

      if (mounted) {
        setState(() {
          _isAnalysing = false;
          _showResults = true;
          _result      = result;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isAnalysing  = false;
          _errorMessage = 'Analysis failed. Tap ANALYSE to try again.';
        });
      }
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
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [

            // ── Camera preview ──────────────────────────
            if (_isInitialised && _controller != null)
              Positioned.fill(
                child: CameraPreview(_controller!),
              ),

            // ── Loading camera ──────────────────────────
            if (!_isInitialised && _errorMessage.isEmpty)
              const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(
                      color: Color(0xFFFF6B2B),
                    ),
                    SizedBox(height: 12),
                    Text('Starting camera...',
                        style: TextStyle(
                            color: Colors.white, fontSize: 14)),
                  ],
                ),
              ),

            // ── Error message ───────────────────────────
            if (_errorMessage.isNotEmpty)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(_errorMessage,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Color(0xFFEF4444), fontSize: 14)),
                ),
              ),

            // ── Grid overlay (rule of thirds) ───────────
            if (_isInitialised && _showGrid)
              Positioned.fill(
                child: CameraOverlayWidget(
                  result:   _result,
                  subject:  null,
                  showGrid: _showGrid,
                ),
              ),

            // ── Score results panel ─────────────────────
            if (_showResults && _result != null)
              Positioned(
                top:   60,
                left:  12,
                right: 12,
                child: ScoreBoxWidget(
                  result:  _result!,
                  onClose: _closeResults,
                ),
              ),

            // ── Analysing spinner ───────────────────────
            if (_isAnalysing)
              Container(
                color: Colors.black54,
                child: const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 56, height: 56,
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          color: Color(0xFFFF6B2B),
                        ),
                      ),
                      SizedBox(height: 16),
                      Text('ANALYSING...',
                          style: TextStyle(
                            color:         Color(0xFFFF6B2B),
                            fontSize:      13,
                            fontWeight:    FontWeight.bold,
                            letterSpacing: 3,
                          )),
                      SizedBox(height: 8),
                      Text('Running 6 composition rules',
                          style: TextStyle(
                              color: Colors.white54,
                              fontSize: 12)),
                    ],
                  ),
                ),
              ),

            // ── Top bar — close + grid toggle ───────────
            Positioned(
              top: 0, left: 0, right: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 10),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end:   Alignment.bottomCenter,
                    colors: [Colors.black87, Colors.transparent],
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [

                    const SizedBox(width: 40), // Spacer where close button was

                    // FrameAI title
                    const Text('FrameAI',
                        style: TextStyle(
                          color:         Color(0xFFFF6B2B),
                          fontSize:      16,
                          fontWeight:    FontWeight.bold,
                          letterSpacing: 2,
                        )),

                    // Grid toggle button
                    GestureDetector(
                      onTap: () => setState(
                              () => _showGrid = !_showGrid),
                      child: Container(
                        width: 40, height: 40,
                        decoration: BoxDecoration(
                          color: _showGrid
                              ? const Color(0x33FF6B2B)
                              : Colors.black54,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: _showGrid
                                ? const Color(0xFFFF6B2B)
                                : Colors.white30,
                          ),
                        ),
                        child: Icon(Icons.grid_on,
                            color: _showGrid
                                ? const Color(0xFFFF6B2B)
                                : Colors.white,
                            size: 20),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // ── Bottom bar — ANALYSE button ─────────────
            if (!_isAnalysing)
              Positioned(
                bottom: 0, left: 0, right: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(
                      24, 20, 24, 32),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end:   Alignment.topCenter,
                      colors: [Colors.black87, Colors.transparent],
                    ),
                  ),
                  child: Row(
                    children: [

                      // Score summary if results exist
                      if (_showResults && _result != null)
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 10),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                  color: const Color(0x33FF6B2B)),
                            ),
                            child: Row(
                              mainAxisAlignment:
                              MainAxisAlignment.spaceAround,
                              children: [
                                _miniScore('Overall',
                                    _result!.overallScore),
                                _miniScore('NIMA',
                                    _result!.nimaScore.round()),
                              ],
                            ),
                          ),
                        ),

                      if (_showResults && _result != null)
                        const SizedBox(width: 12),

                      // ANALYSE button
                      Expanded(
                        flex: _showResults ? 1 : 2,
                        child: GestureDetector(
                          onTap: _analyse,
                          child: Container(
                            height: 56,
                            decoration: BoxDecoration(
                              color: const Color(0xFFFF6B2B),
                              borderRadius: BorderRadius.circular(28),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFFFF6B2B)
                                      .withAlpha(100),
                                  blurRadius:   12,
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                            child: const Row(
                              mainAxisAlignment:
                              MainAxisAlignment.center,
                              children: [
                                Icon(Icons.analytics,
                                    color: Colors.black, size: 22),
                                SizedBox(width: 8),
                                Text('ANALYSE',
                                    style: TextStyle(
                                      color:         Colors.black,
                                      fontSize:      15,
                                      fontWeight:    FontWeight.bold,
                                      letterSpacing: 2,
                                    )),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

          ],
        ),
      ),
    );
  }

  Widget _miniScore(String label, int score) {
    final color = score >= 70
        ? const Color(0xFF00D4AA)
        : score >= 45
        ? const Color(0xFFF59E0B)
        : const Color(0xFFEF4444);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$score',
            style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: color)),
        Text(label,
            style: const TextStyle(
                fontSize: 10, color: Colors.white54)),
      ],
    );
  }
}

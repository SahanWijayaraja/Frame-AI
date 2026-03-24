import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:gal/gal.dart';
import 'package:image/image.dart' as img;
import 'composition_analyzer.dart';
import 'score_box_widget.dart';
import 'camera_overlay_painter.dart';
import 'yolo_detector.dart';
import 'main.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {

  CameraController?   _controller;
  bool _isInitialised = false;
  bool _isAnalysing   = false;
  bool _showResults   = false;
  bool _isSaving      = false;
  CompositionResult?  _result;
  DetectedObject?     _liveSubject;
  String _errorMessage  = '';
  String _savedMessage  = '';

  final CompositionAnalyzer _analyzer = CompositionAnalyzer();
  late AnimationController  _gridPulse;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _gridPulse = AnimationController(
      vsync: this, duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _initCamera();
    _analyzer.loadModels();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _gridPulse.dispose();
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
    final camera = globalCameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => globalCameras.first,
    );
    final controller = CameraController(
      camera, ResolutionPreset.high,
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
      if (mounted) setState(() => _errorMessage = 'Camera error: $e');
    }
  }

  // ── Shutter — save photo to gallery ──────────────────────
  Future<void> _shutter() async {
    if (_controller == null || !_controller!.value.isInitialized || _isSaving) return;
    setState(() => _isSaving = true);
    try {
      final file = await _controller!.takePicture();
      await Gal.putImage(file.path);
      if (mounted) {
        setState(() => _savedMessage = 'Photo saved  ✓');
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) setState(() => _savedMessage = '');
        });
      }
    } catch (_) {
      if (mounted) setState(() => _savedMessage = 'Could not save photo');
    }
    if (mounted) setState(() => _isSaving = false);
  }

  // ── Analyse — capture + run AI ────────────────────────────
  Future<void> _analyse() async {
    if (_isAnalysing || _controller == null || !_controller!.value.isInitialized) return;
    setState(() { _isAnalysing = true; _showResults = false; _errorMessage = ''; });

    try {
      final file  = await _controller!.takePicture();
      final bytes = await file.readAsBytes();
      final image = img.decodeImage(bytes);

      // Run live subject detection for overlay
      if (image != null) {
        final dets = await _analyzer.yolo.detect(image);
        _liveSubject = _analyzer.yolo.getPrimarySubject(dets);
      }

      final result = await _analyzer.analyseImage(bytes.toList());
      if (mounted) {
        setState(() {
          _isAnalysing = false;
          _showResults  = true;
          _result       = result;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isAnalysing  = false;
          _errorMessage = 'Analysis failed. Try again.';
        });
      }
    }
  }

  void _closeResults() {
    setState(() { _showResults = false; _result = null; _liveSubject = null; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(),
            Expanded(child: _buildCameraArea()),
            _buildBottomBar(),
          ],
        ),
      ),
    );
  }

  // ── Top bar ───────────────────────────────────────────────
  Widget _buildTopBar() {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end:   Alignment.bottomCenter,
          colors: [Color(0xE5000000), Colors.transparent],
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            'FrameAI',
            style: TextStyle(
              color: Color(0xFFFF6B2B), fontSize: 18,
              fontWeight: FontWeight.bold, letterSpacing: 2,
            ),
          ),
          // NIMA score badge after analysis
          if (_result != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0x33FF6B2B),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0x66FF6B2B)),
              ),
              child: Text(
                'NIMA ${_result!.nimaScore.round()}',
                style: const TextStyle(
                  color: Color(0xFFFF6B2B), fontSize: 11,
                  fontWeight: FontWeight.bold, letterSpacing: 1,
                ),
              ),
            ),
          if (_savedMessage.isNotEmpty)
            Text(
              _savedMessage,
              style: const TextStyle(color: Color(0xFF00D4AA), fontSize: 12),
            ),
        ],
      ),
    );
  }

  // ── Camera area — 3:4 aspect ratio ───────────────────────
  Widget _buildCameraArea() {
    return LayoutBuilder(builder: (context, constraints) {
      // Calculate 3:4 (width:height) preview box
      final maxW  = constraints.maxWidth;
      final maxH  = constraints.maxHeight;
      final prevW = maxW;
      final prevH = (prevW * 4 / 3).clamp(0.0, maxH);

      return Stack(
        alignment: Alignment.topCenter,
        children: [
          // Black bars to fill remaining space
          Positioned.fill(child: Container(color: Colors.black)),

          // Camera preview
          SizedBox(
            width:  prevW,
            height: prevH,
            child: ClipRect(
              child: Stack(children: [
                if (_isInitialised && _controller != null)
                  Positioned.fill(child: CameraPreview(_controller!)),

                if (!_isInitialised && _errorMessage.isEmpty)
                  const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(color: Color(0xFFFF6B2B)),
                        SizedBox(height: 12),
                        Text('Starting camera…',
                            style: TextStyle(color: Colors.white54, fontSize: 13)),
                      ],
                    ),
                  ),

                if (_errorMessage.isNotEmpty)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_errorMessage,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Color(0xFFEF4444), fontSize: 13)),
                    ),
                  ),

                // Rule-of-thirds grid (always visible, subtle)
                Positioned.fill(
                  child: AnimatedBuilder(
                    animation: _gridPulse,
                    builder: (_, __) => CustomPaint(
                      painter: CameraOverlayPainter(
                        result:    _result,
                        subject:   _liveSubject,
                        showGrid:  true,
                        animValue: _gridPulse.value,
                      ),
                    ),
                  ),
                ),

                // Analysing spinner
                if (_isAnalysing)
                  Container(
                    color: Colors.black54,
                    child: const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 52, height: 52,
                            child: CircularProgressIndicator(
                              strokeWidth: 3, color: Color(0xFFFF6B2B),
                            ),
                          ),
                          SizedBox(height: 14),
                          Text('ANALYSING…', style: TextStyle(
                            color: Color(0xFFFF6B2B), fontSize: 12,
                            fontWeight: FontWeight.bold, letterSpacing: 3,
                          )),
                          SizedBox(height: 6),
                          Text('Running 4 AI models', style: TextStyle(
                            color: Colors.white54, fontSize: 11,
                          )),
                        ],
                      ),
                    ),
                  ),

                // Results overlay — pinned to bottom of preview
                if (_showResults && _result != null)
                  Positioned(
                    left: 0, right: 0, bottom: 0,
                    child: ScoreBoxWidget(
                      result:  _result!,
                      onClose: _closeResults,
                    ),
                  ),
              ]),
            ),
          ),
        ],
      );
    });
  }

  // ── Bottom bar — shutter + analyse ───────────────────────
  Widget _buildBottomBar() {
    return Container(
      height: 110,
      padding: const EdgeInsets.symmetric(horizontal: 32),
      color: Colors.black,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Analyse button
          GestureDetector(
            onTap: _isAnalysing ? null : _analyse,
            child: Container(
              width: 100, height: 46,
              decoration: BoxDecoration(
                color: _isAnalysing
                    ? const Color(0x55FF6B2B)
                    : const Color(0xFFFF6B2B),
                borderRadius: BorderRadius.circular(24),
                boxShadow: _isAnalysing ? [] : [
                  BoxShadow(
                    color: const Color(0xFFFF6B2B).withAlpha(80),
                    blurRadius: 16, spreadRadius: 2,
                  ),
                ],
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.analytics_outlined, color: Colors.black, size: 18),
                  SizedBox(width: 6),
                  Text('ANALYSE',
                      style: TextStyle(
                        color: Colors.black, fontSize: 12,
                        fontWeight: FontWeight.bold, letterSpacing: 1.5,
                      )),
                ],
              ),
            ),
          ),

          // Shutter button (classic circular)
          GestureDetector(
            onTap: _isSaving ? null : _shutter,
            child: Container(
              width: 72, height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 3),
                color: Colors.transparent,
              ),
              child: Center(
                child: Container(
                  width: 58, height: 58,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isSaving ? Colors.grey : Colors.white,
                  ),
                ),
              ),
            ),
          ),

          // Grid toggle / results dismiss
          GestureDetector(
            onTap: _showResults ? _closeResults : null,
            child: Container(
              width: 46, height: 46,
              decoration: BoxDecoration(
                color: _showResults
                    ? const Color(0x33FF6B2B)
                    : const Color(0x22FFFFFF),
                borderRadius: BorderRadius.circular(23),
                border: Border.all(
                  color: _showResults
                      ? const Color(0xFFFF6B2B)
                      : Colors.white24,
                ),
              ),
              child: Icon(
                _showResults ? Icons.close : Icons.info_outline,
                color: _showResults ? const Color(0xFFFF6B2B) : Colors.white54,
                size: 20,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

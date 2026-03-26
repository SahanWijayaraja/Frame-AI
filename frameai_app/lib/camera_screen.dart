import 'dart:ui' as ui;
import 'dart:io';
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

  CameraController?  _controller;
  bool _isInitialised = false;
  bool _isAnalysing   = false;
  bool _showResults   = false;
  bool _isSaving      = false;
  
  // Freeze frame state
  ui.Image? _frozenFrame;

  FlashMode _flashMode = FlashMode.off;   // Flash OFF by default
  CompositionResult? _result;
  DetectedObject?    _liveSubject;
  String _errorMessage = '';
  String _toastMessage = '';

  final CompositionAnalyzer _analyzer = CompositionAnalyzer();
  late AnimationController  _gridAnim;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    
    _gridAnim = AnimationController(
      vsync: this, duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _initCamera();
    _analyzer.loadModels();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _gridAnim.dispose();
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
      camera, 
      ResolutionPreset.max, // 3:4 on most sensors
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    try {
      await controller.initialize();
      await controller.setFlashMode(FlashMode.off);
      try { await controller.setFocusMode(FocusMode.auto); } catch (_) {}
      
      if (mounted) {
        setState(() {
          _controller    = controller;
          _isInitialised = true;
          _errorMessage  = '';
          _flashMode     = FlashMode.off;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _errorMessage = 'Camera error: $e');
    }
  }

  // ── Flash toggle ──────────────────────────────────────────
  Future<void> _toggleFlash() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    final next = _flashMode == FlashMode.off ? FlashMode.torch : FlashMode.off;
    try {
      await _controller!.setFlashMode(next);
      setState(() => _flashMode = next);
    } catch (_) {}
  }

  // ── Crop utility — ensure captured photo is exactly 3:4 ────────
  Future<File> _cropTo3x4(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      img.Image? image = img.decodeImage(bytes);
      if (image == null) return File(path);

      // Target aspect ratio 3:4 (width:height)
      int targetW = image.width;
      int targetH = (image.width * 4 / 3).round();

      if (targetH > image.height) {
        // Source is wider/shorter than 3:4 (e.g. 16:9 landscape)
        targetH = image.height;
        targetW = (image.height * 3 / 4).round();
      }

      final xOff = ((image.width - targetW) / 2).round();
      final yOff = ((image.height - targetH) / 2).round();

      final cropped = img.copyCrop(image, x: xOff, y: yOff, width: targetW, height: targetH);
      final out = File(path);
      await out.writeAsBytes(img.encodeJpg(cropped));
      return out;
    } catch (_) {
      return File(path);
    }
  }

  // ── Shutter — save cropped 3:4 photo to gallery ───────────
  Future<void> _shutter() async {
    if (_controller == null || !_controller!.value.isInitialized || _isSaving) return;
    setState(() => _isSaving = true);
    try {
      final file = await _controller!.takePicture();
      final cropped = await _cropTo3x4(file.path);
      await Gal.putImage(cropped.path);
      _showToast('Photo saved ✓');
    } catch (_) {
      _showToast('Could not save photo');
    }
    if (mounted) setState(() => _isSaving = false);
  }

  void _showToast(String msg) {
    setState(() => _toastMessage = msg);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _toastMessage = '');
    });
  }

  // ── Analyse — capture, freeze, crop, and run AI ────────────
  Future<void> _analyse() async {
    if (_isAnalysing || _controller == null || !_controller!.value.isInitialized) return;
    setState(() { 
      _isAnalysing = true; 
      _showResults = false; 
      _errorMessage = ''; 
      _frozenFrame  = null;
    });

    try {
      // 1. Capture still
      final file = await _controller!.takePicture();
      
      // 2. Crop to 3:4
      final cropped = await _cropTo3x4(file.path);
      final bytes   = await cropped.readAsBytes();

      // 3. Freeze UI
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      if (mounted) setState(() => _frozenFrame = frame.image);

      // 4. Run Analysis
      final image = img.decodeImage(bytes);
      if (image != null) {
        final dets = await _analyzer.yolo.detect(cropped.path, image.width, image.height);
        if (mounted) setState(() => _liveSubject = _analyzer.yolo.getPrimarySubject(dets));
      }

      final result = await _analyzer.analyseImage(bytes.toList(), cropped.path);
      
      if (mounted) {
        setState(() {
          _isAnalysing = false;
          _showResults = true;
          _result      = result;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _isAnalysing = false; _errorMessage = 'Analysis failed: $e'; });
    }
  }

  void _closeResults() {
    setState(() { 
      _showResults   = false; 
      _result        = null; 
      _liveSubject   = null; 
      _frozenFrame   = null;
    });
    try { _controller?.setFocusMode(FocusMode.auto); } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(),
            Expanded(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  _buildCameraArea(),
                  _buildOverlays(),
                ],
              ),
            ),
            _buildBottomBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    final flashOn = _flashMode == FlashMode.torch;
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      color: Colors.black,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
          Row(
            children: [
              const Text('FrameAI',
                  style: TextStyle(
                    color: Color(0xFFFF6B2B), fontSize: 18,
                    fontWeight: FontWeight.bold, letterSpacing: 2,
                  )),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _showInfoDialog,
                child: const Icon(Icons.info_outline, color: Colors.white54, size: 20),
              ),
            ],
          ),
          GestureDetector(
            onTap: _toggleFlash,
            child: Container(
              width: 40, height: 40,
              decoration: BoxDecoration(
                color: flashOn ? const Color(0xFFFFD600) : const Color(0x22FFFFFF),
                shape: BoxShape.circle,
              ),
              child: Icon(
                flashOn ? Icons.flash_on : Icons.flash_off,
                color: flashOn ? Colors.black : Colors.white54,
                size: 20,
              ),
            ),
          ),
          if (_toastMessage.isNotEmpty)
            Text(_toastMessage,
                style: const TextStyle(color: Color(0xFF00D4AA), fontSize: 12))
          else if (_result != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0x33FF6B2B),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0x66FF6B2B)),
              ),
              child: Text('NIMA ${_result!.nimaScore.round()}',
                  style: const TextStyle(
                    color: Color(0xFFFF6B2B), fontSize: 11,
                    fontWeight: FontWeight.bold, letterSpacing: 1,
                  )),
            ),
        ],
      ),
    );
  }

  // ── Camera area — 3:4 aspect ratio, no distortion ─────────
  Widget _buildCameraArea() {
    if (!_isInitialised || _controller == null) {
      return const Center(child: CircularProgressIndicator(color: Color(0xFFFF6B2B)));
    }

    return LayoutBuilder(builder: (context, constraints) {
      final maxW = constraints.maxWidth;
      final maxH = constraints.maxHeight;

      // Container for the 3:4 box
      double uiW, uiH;
      if (maxH / maxW >= 4 / 3) {
        uiW = maxW; uiH = maxW * 4 / 3;
      } else {
        uiH = maxH; uiW = maxH * 3 / 4;
      }

      return Center(
        child: SizedBox(
          width:  uiW,
          height: uiH,
          child: AspectRatio(
            aspectRatio: 3 / 4,
            child: ClipRect(
              child: _frozenFrame != null
                ? RawImage(image: _frozenFrame!, fit: BoxFit.cover)
                : OverflowBox(
                    alignment: Alignment.center,
                    child: FittedBox(
                      fit: BoxFit.cover,
                      child: SizedBox(
                        width:  _controller!.value.previewSize?.height ?? uiW,
                        height: _controller!.value.previewSize?.width  ?? uiH,
                        child: CameraPreview(_controller!),
                      ),
                    ),
                  ),
            ),
          ),
        ),
      );
    });
  }

  Widget _buildOverlays() {
    return LayoutBuilder(builder: (context, constraints) {
      final maxW = constraints.maxWidth;
      final maxH = constraints.maxHeight;
      double uiW, uiH;
      if (maxH / maxW >= 4 / 3) { uiW = maxW; uiH = maxW * 4 / 3; }
      else { uiH = maxH; uiW = maxH * 3 / 4; }

      return SizedBox(
        width: uiW, height: uiH,
        child: Stack(children: [
          // Rule of thirds grid (always on, even during freeze)
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _gridAnim,
              builder: (_, __) => CustomPaint(
                painter: CameraOverlayPainter(
                  result:    _result,
                  subject:   _liveSubject,
                  showGrid:  true,
                  animValue: _gridAnim.value,
                ),
              ),
            ),
          ),

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
                  ],
                ),
              ),
            ),

          if (_showResults && _result != null)
            Positioned(
              left: 0, right: 0, bottom: 0,
              child: ScoreBoxWidget(
                result:  _result!,
                onClose: _closeResults,
              ),
            ),
        ]),
      );
    });
  }

  // ── Bottom bar — Analyse + Shutter + Close ────────────────
  Widget _buildBottomBar() {
    return Container(
      height: 110,
      padding: const EdgeInsets.symmetric(horizontal: 32),
      color: Colors.black,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // ANALYSE button
          GestureDetector(
            onTap: _isAnalysing ? null : _analyse,
            child: Container(
              width: 100, height: 46,
              decoration: BoxDecoration(
                color: _isAnalysing ? const Color(0x55FF6B2B) : const Color(0xFFFF6B2B),
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

          // Shutter button
          GestureDetector(
            onTap: _isSaving ? null : _shutter,
            child: Container(
              width: 72, height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 3),
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

          // Close results button
          GestureDetector(
            onTap: _showResults ? _closeResults : null,
            child: Container(
              width: 46, height: 46,
              decoration: BoxDecoration(
                color: _showResults ? const Color(0x33FF6B2B) : const Color(0x22FFFFFF),
                borderRadius: BorderRadius.circular(23),
                border: Border.all(
                  color: _showResults ? const Color(0xFFFF6B2B) : Colors.white24,
                ),
              ),
              child: Icon(
                _showResults ? Icons.close : Icons.photo_camera_outlined,
                color: _showResults ? const Color(0xFFFF6B2B) : Colors.white54,
                size: 20,
              ),
            ),
          ),
        ],
      ),
    );
  }
  // ── Info Bottom Sheet ─────────────────────────────────────────
  void _showInfoDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7, maxChildSize: 0.9, minChildSize: 0.4,
          builder: (_, controller) {
             return Padding(
               padding: const EdgeInsets.all(24.0),
               child: ListView(
                 controller: controller,
                 children: const [
                    Text('FrameAI Photography Engine', style: TextStyle(color: Color(0xFFFF6B2B), fontSize: 24, fontWeight: FontWeight.bold)),
                    SizedBox(height: 12),
                    Text('Aesthetic Scoring (NIMA)', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                    SizedBox(height: 6),
                    Text('NIMA (Neural Image Assessment) is an advanced Google deep-learning baseline algorithm that mathematically rates the sheer lighting, tone, noise, and aesthetic "punch" of your photo exactly as professional photography judges would rate it.', style: TextStyle(color: Colors.white70, fontSize: 14)),
                    SizedBox(height: 24),
                    Text('The 6 Core Rules', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                    SizedBox(height: 12),
                    _RuleInfo(title: '1. Rule of Thirds', desc: 'Anchoring your prominent subject onto visual power intersections creates psychological balance and weight.'),
                    _RuleInfo(title: '2. Negative Space (Lead Room)', desc: 'Subjects need "breathing room." If they look to the left, logic dictates leaving empty space (lead room) on the left side to balance the frame.'),
                    _RuleInfo(title: '3. Leading Lines', desc: 'Natural geometric edges (streets, fences, horizons) act as "visual arrows", pulling the viewers eye directly inward, establishing depth.'),
                    _RuleInfo(title: '4. Symmetry', desc: 'Perfectly centered environments or reflective surfaces induce a profound sense of artificial equilibrium and impact.'),
                    _RuleInfo(title: '5. Framing', desc: 'Surrounding your subject using environmental edges (doorways, archways, branches) acts as a physical spotlight, hiding generic backgrounds.'),
                    _RuleInfo(title: '6. Perspective', desc: 'A lens dictates psychological power. Shooting up (Low Angle) makes subjects feel powerful and large, while High Angles impart subtle vulnerability. Eye-level establishes a 1-to-1 neutral connection.'),
                    SizedBox(height: 24),
                 ],
               ),
             );
          }
        );
      }
    );
  }
}

class _RuleInfo extends StatelessWidget {
  final String title;
  final String desc;
  const _RuleInfo({required this.title, required this.desc});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(color: Color(0xFF00D4AA), fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(desc, style: const TextStyle(color: Colors.white70, fontSize: 14)),
        ]
      )
    );
  }
}

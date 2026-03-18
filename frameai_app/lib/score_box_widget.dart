import 'package:flutter/material.dart';
import 'composition_analyzer.dart';

class ScoreBoxWidget extends StatefulWidget {
  final CompositionResult result;
  final VoidCallback       onClose;

  const ScoreBoxWidget({
    super.key,
    required this.result,
    required this.onClose,
  });

  @override
  State<ScoreBoxWidget> createState() => _ScoreBoxWidgetState();
}

class _ScoreBoxWidgetState extends State<ScoreBoxWidget>
    with SingleTickerProviderStateMixin {

  late AnimationController _animController;
  late Animation<double>   _scaleAnim;
  late Animation<double>   _fadeAnim;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 400),
    );
    _scaleAnim = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(parent: _animController, curve: Curves.elasticOut),
    );
    _fadeAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOut),
    );
    _animController.forward();
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  // Colour based on score value
  Color _scoreColor(int score) {
    if (score >= 70) return const Color(0xFF00D4AA);  // teal  = good
    if (score >= 45) return const Color(0xFFF59E0B);  // amber = average
    return const Color(0xFFEF4444);                    // red   = needs work
  }

  // Rule icon for each composition rule
  String _ruleIcon(String ruleName) {
    switch (ruleName) {
      case 'Rule of Thirds' : return '⅓';
      case 'Leading Lines'  : return '↗';
      case 'Negative Space' : return '□';
      case 'Symmetry'       : return '↔';
      case 'Framing'        : return '⊡';
      case 'Perspective'    : return '↕';
      default               : return '•';
    }
  }

  // Colour for each rule icon background
  Color _ruleIconColor(String ruleName) {
    switch (ruleName) {
      case 'Rule of Thirds' : return const Color(0x30FF6B2B);
      case 'Leading Lines'  : return const Color(0x304A9EFF);
      case 'Negative Space' : return const Color(0x3000D4AA);
      case 'Symmetry'       : return const Color(0x30A855F7);
      case 'Framing'        : return const Color(0x3010B981);
      case 'Perspective'    : return const Color(0x30F59E0B);
      default               : return const Color(0x30888888);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeAnim,
      child: ScaleTransition(
        scale: _scaleAnim,
        child: Container(
          width:       155,
          decoration:  BoxDecoration(
            color:        const Color(0xF00A0A14),
            borderRadius: BorderRadius.circular(14),
            border:       Border.all(
              color: const Color(0x4DFF6B2B),
              width: 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildHeader(),
              _buildScoreSection(),
              _buildRulesSection(),
              _buildTipSection(),
              _buildAngleSection(),
            ],
          ),
        ),
      ),
    );
  }

  // ── Header bar with title and close button ────────────────
  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: const BoxDecoration(
        color:        Color(0x1FFF6B2B),
        borderRadius: BorderRadius.vertical(top: Radius.circular(13)),
        border: Border(
          bottom: BorderSide(color: Color(0x0FFFFFFF)),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            'FRAMEAI',
            style: TextStyle(
              fontSize:      9,
              color:         Color(0xFFFF6B2B),
              letterSpacing: 2,
              fontWeight:    FontWeight.bold,
            ),
          ),
          GestureDetector(
            onTap: widget.onClose,
            child: const Icon(
              Icons.close,
              size:  14,
              color: Color(0x99FFFFFF),
            ),
          ),
        ],
      ),
    );
  }

  // ── Large score number + progress bar ─────────────────────
  Widget _buildScoreSection() {
    final score = widget.result.overallScore;
    final color = _scoreColor(score);
    final label = score >= 70 ? 'Excellent' :
                  score >= 55 ? 'Good'      :
                  score >= 40 ? 'Fair'       : 'Needs Work';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Color(0x0FFFFFFF)),
        ),
      ),
      child: Column(
        children: [
          // Score number
          Text(
            '$score',
            style: TextStyle(
              fontSize:   34,
              fontWeight: FontWeight.bold,
              color:      color,
              height:     1.0,
              shadows: [
                Shadow(
                  color:       color.withOpacity(0.4),
                  blurRadius:  12,
                ),
              ],
            ),
          ),
          const SizedBox(height: 5),
          // Progress bar
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value:           score / 100,
              backgroundColor: const Color(0x1AFFFFFF),
              valueColor:      AlwaysStoppedAnimation<Color>(color),
              minHeight:       3,
            ),
          ),
          const SizedBox(height: 4),
          // Label
          Text(
            label,
            style: TextStyle(
              fontSize:      9,
              color:         color,
              fontWeight:    FontWeight.bold,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }

  // ── 6 rule rows with dot indicators ───────────────────────
  Widget _buildRulesSection() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Color(0x0FFFFFFF)),
        ),
      ),
      child: Column(
        children: widget.result.allRules
            .map((rule) => _buildRuleRow(rule))
            .toList(),
      ),
    );
  }

  Widget _buildRuleRow(RuleResult rule) {
    final color     = _scoreColor(rule.score);
    final iconColor = _ruleIconColor(rule.ruleName);
    final icon      = _ruleIcon(rule.ruleName);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.5),
      child: Row(
        children: [
          // Rule icon
          Container(
            width:        16,
            height:       16,
            decoration:   BoxDecoration(
              color:        iconColor,
              borderRadius: BorderRadius.circular(3),
            ),
            child: Center(
              child: Text(
                icon,
                style: const TextStyle(fontSize: 8, color: Colors.white),
              ),
            ),
          ),
          const SizedBox(width: 5),
          // Rule name
          Expanded(
            child: Text(
              rule.ruleName,
              style: const TextStyle(
                fontSize: 8,
                color:    Color(0xAAFFFFFF),
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // 5 dot indicator
          Row(
            children: List.generate(5, (i) {
              final filled = i < (rule.score / 20).round();
              return Container(
                width:  4,
                height: 4,
                margin: const EdgeInsets.only(left: 2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: filled ? color : const Color(0x1FFFFFFF),
                ),
              );
            }),
          ),
          const SizedBox(width: 4),
          // Numeric score
          SizedBox(
            width: 20,
            child: Text(
              '${rule.score}',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize:   8,
                color:      color,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Tip section ───────────────────────────────────────────
  Widget _buildTipSection() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Color(0x0FFFFFFF)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'SUGGESTION',
            style: TextStyle(
              fontSize:      7,
              color:         Color(0xFFFF6B2B),
              letterSpacing: 1,
              fontWeight:    FontWeight.bold,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            widget.result.bestTip,
            style: const TextStyle(
              fontSize: 9,
              color:    Color(0xDDFFFFFF),
              height:   1.4,
            ),
          ),
        ],
      ),
    );
  }

  // ── Angle label at bottom ──────────────────────────────────
  Widget _buildAngleSection() {
    final angle = widget.result.angleLabel;
    final color = angle == 'LOW ANGLE'    ? const Color(0xFFFF6B2B) :
                  angle == 'HIGH ANGLE'   ? const Color(0xFF4A9EFF) :
                  angle == 'DUTCH TILT'   ? const Color(0xFFA855F7) :
                  const Color(0xFF888888);

    return Container(
      width:   double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Text(
        angle,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize:      9,
          color:         color,
          fontWeight:    FontWeight.bold,
          letterSpacing: 1,
        ),
      ),
    );
  }
}

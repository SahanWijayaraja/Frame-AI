import 'package:flutter/material.dart';
import 'composition_analyzer.dart';

class ScoreBoxWidget extends StatefulWidget {
  final CompositionResult result;
  final VoidCallback       onClose;

  const ScoreBoxWidget({super.key, required this.result, required this.onClose});

  @override
  State<ScoreBoxWidget> createState() => _ScoreBoxWidgetState();
}

class _ScoreBoxWidgetState extends State<ScoreBoxWidget>
    with SingleTickerProviderStateMixin {

  late AnimationController _anim;
  late Animation<double> _slide;
  late Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 350));
    _slide = Tween<double>(begin: 60, end: 0).animate(
      CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic));
    _fade  = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _anim, curve: Curves.easeOut));
    _anim.forward();
  }

  @override
  void dispose() { _anim.dispose(); super.dispose(); }

  Color _color(int score) {
    if (score < 0)     return const Color(0xFF555555);
    if (score >= 70)   return const Color(0xFF00D4AA);
    if (score >= 45)   return const Color(0xFFF59E0B);
    return const Color(0xFFEF4444);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, __) => Transform.translate(
        offset: Offset(0, _slide.value),
        child: Opacity(
          opacity: _fade.value,
          child: Container(
            width: double.infinity,
            decoration: const BoxDecoration(
              color: Color(0xF0090910),
              border: Border(top: BorderSide(color: Color(0x4DFF6B2B), width: 1)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _header(),
                _overallRow(),
                _rulesGrid(),
                _suggestion(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Header ────────────────────────────────────────────────
  Widget _header() {
    final angle = widget.result.angleLabel;
    final angleColor =
        angle == 'LOW ANGLE'  ? const Color(0xFFFF6B2B) :
        angle == 'HIGH ANGLE' ? const Color(0xFF4A9EFF) :
        const Color(0xFF888888);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text('COMPOSITION ANALYSIS',
              style: TextStyle(
                color: Color(0xFFFF6B2B), fontSize: 10,
                fontWeight: FontWeight.bold, letterSpacing: 2,
              )),
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: angleColor.withAlpha(40),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: angleColor.withAlpha(100)),
              ),
              child: Text(angle,
                  style: TextStyle(
                    color: angleColor, fontSize: 9,
                    fontWeight: FontWeight.bold, letterSpacing: 1,
                  )),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: widget.onClose,
              child: const Icon(Icons.close, color: Color(0x88FFFFFF), size: 16),
            ),
          ]),
        ],
      ),
    );
  }

  // ── Overall score ─────────────────────────────────────────
  Widget _overallRow() {
    final score  = widget.result.overallScore;
    final color  = _color(score);
    final label  = score >= 75 ? 'Excellent' : score >= 58 ? 'Good' :
                   score >= 42 ? 'Fair' : 'Needs Work';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Row(
        children: [
          // Big score number
          Text('$score',
              style: TextStyle(
                fontSize: 44, fontWeight: FontWeight.bold,
                color: color, height: 1.0,
                shadows: [Shadow(color: color.withAlpha(100), blurRadius: 14)],
              )),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                      fontSize: 13, color: color, fontWeight: FontWeight.bold,
                    )),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: score / 100,
                    backgroundColor: const Color(0x1AFFFFFF),
                    valueColor: AlwaysStoppedAnimation<Color>(color),
                    minHeight: 5,
                  ),
                ),
                const SizedBox(height: 3),
                Text('NIMA: ${widget.result.nimaScore.round()} / 100',
                    style: const TextStyle(
                      fontSize: 9, color: Color(0xFF888888), letterSpacing: 1,
                    )),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── 6 rule bars ───────────────────────────────────────────
  Widget _rulesGrid() {
    final rules = widget.result.allRules;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        children: rules.map((r) => _ruleBar(r)).toList(),
      ),
    );
  }

  Widget _ruleBar(RuleResult rule) {
    final isNA  = !rule.detected || rule.score < 0;
    final color = isNA ? const Color(0xFF333333) : _color(rule.score);
    final pct   = isNA ? 0.0 : rule.score / 100.0;

    final icon = _ruleIcon(rule.ruleName);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.5),
      child: Row(children: [
        // Icon
        Container(
          width: 20, height: 20,
          decoration: BoxDecoration(
            color: isNA ? const Color(0x15FFFFFF) : color.withAlpha(35),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Center(
            child: Text(icon,
                style: TextStyle(
                  fontSize: 10,
                  color: isNA ? const Color(0xFF444444) : color,
                )),
          ),
        ),
        const SizedBox(width: 6),
        // Name
        SizedBox(
          width: 85,
          child: Text(rule.ruleName,
              style: TextStyle(
                fontSize: 9.5,
                color: isNA ? const Color(0xFF444444) : const Color(0xCCFFFFFF),
              ),
              overflow: TextOverflow.ellipsis),
        ),
        // Bar
        Expanded(
          child: Stack(children: [
            Container(
              height: 5,
              decoration: BoxDecoration(
                color: const Color(0x14FFFFFF),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            FractionallySizedBox(
              widthFactor: pct,
              child: Container(
                height: 5,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ]),
        ),
        const SizedBox(width: 6),
        // Score / N/A
        SizedBox(
          width: 26,
          child: Text(
            isNA ? 'N/A' : '${rule.score}',
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: 9,
              color: isNA ? const Color(0xFF444444) : color,
              fontFamily: 'monospace',
            ),
          ),
        ),
      ]),
    );
  }

  String _ruleIcon(String name) {
    switch (name) {
      case 'Rule of Thirds'  : return '⅓';
      case 'Leading Lines'   : return '↗';
      case 'Negative Space'  : return '□';
      case 'Symmetry'        : return '↔';
      case 'Framing'         : return '⊡';
      case 'Perspective'     : return '↕';
      default                : return '•';
    }
  }

  // ── Professional suggestion ───────────────────────────────
  Widget _suggestion() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0x0DFFFFFF))),
      ),
      child: RichText(
        text: TextSpan(children: [
          const TextSpan(
            text: '📸  ',
            style: TextStyle(fontSize: 11),
          ),
          TextSpan(
            text: widget.result.professionalSuggestion,
            style: const TextStyle(
              fontSize: 11, color: Color(0xDDFFFFFF), height: 1.5,
            ),
          ),
        ]),
      ),
    );
  }
}

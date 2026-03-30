import 'dart:typed_data';
import 'package:google_generative_ai/google_generative_ai.dart';

class GeminiService {
  static const String _prompt = '''
You are an elite, professional photography coach. Analyze this raw photo.
Provide a highly structured, encouraging, but technical critique. 

Structure your response exactly like this:
## 📸 The Breakdown
(Briefly identify the primary subject, the style of the shot, and the current composition logic).

## ✨ What Works
(List 2-3 strong points about lighting, framing, lines, or emotional impact using bullet points).

## 💡 Pro Tips for Improvement
(List 2-3 highly specific, actionable, technical tips. Mention things like 'lead room', 'rule of thirds', 'lens compression', or 'dynamic range').

Keep the tone expert, concise, and highly encouraging. Use emojis to make it readable.
''';

  static String get _obfuscatedKey {
    // SECURITY: Real API keys must be injected via --dart-define=GEMINI_API_KEY=YOUR_KEY during build.
    // This static fallback is just a dummy placeholder to prevent crashes.
    return 'YOUR_GEMINI_API_KEY_HERE';
  }

  /// Fetches the entire markdown response in one single API request.
  static Future<String> getStaticCritique(Uint8List imageBytes) async {
    var apiKey = const String.fromEnvironment('GEMINI_API_KEY');
    
    // Fallback to the dummy static key if build flags are missing
    if (apiKey.isEmpty || apiKey == 'YOUR_GEMINI_API_KEY_HERE') {
      apiKey = _obfuscatedKey;
    }

    final model = GenerativeModel(
      model: 'gemini-2.5-flash', // Matching the exact stable checkpoint utilized in BKG123/frame-ai
      apiKey: apiKey,
    );

    final promptText = TextPart(_prompt);
    final imagePart  = DataPart('image/jpeg', imageBytes);

    try {
      final response = await model.generateContent([
        Content.multi([promptText, imagePart])
      ]);
      return response.text ?? '';
    } catch (e) {
      final errorStr = e.toString();
      
      // Native offline network trap
      final lowerErr = errorStr.toLowerCase();
      if (lowerErr.contains('socketexception') || lowerErr.contains('failed host lookup') || lowerErr.contains('network is unreachable')) {
        throw Exception("📶 **No Internet Connection:**\n\nPlease connect to Wi-Fi or Cellular Data to receive a professional Cloud Critique.");
      }
      
      if (errorStr.contains('Quota exceeded') || errorStr.contains('limit: 0') || errorStr.contains('429')) {
        throw Exception("⚠️ **Cloud Limit Reached:**\n\nYour Google account is currently geo-blocked from the Free Tier (Quota: 0), or you have completely exhausted your daily requests. \n\nPlease attach a billing account on Google AI Studio to increase your quota limits.");
      }
      throw Exception("❌ **Cloud Error:** Could not connect to Gemini API. ($errorStr)");
    }
  }
}

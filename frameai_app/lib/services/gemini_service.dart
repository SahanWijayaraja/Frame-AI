import 'dart:typed_data';
import 'package:google_generative_ai/google_generative_ai.dart';

class GeminiService {
  // Developer Note: Replace this with your actual Google Gemini API Key
  // Get one free at: https://aistudio.google.com/app/apikey
  static const String _geminiApiKey = 'YOUR_GEMINI_API_KEY_HERE';

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

  /// Streams the markdown response continuously as Gemini generates it.
  static Stream<String> streamCritique(Uint8List imageBytes) {
    if (_geminiApiKey == 'YOUR_GEMINI_API_KEY_HERE' || _geminiApiKey.isEmpty) {
      return Stream.value("⚠️ **API Key Missing!**\n\nPlease add your Gemini API Key inside `lib/services/gemini_service.dart` to unlock the Cloud AI Feature.");
    }

    try {
      final model = GenerativeModel(
        model: 'gemini-2.0-flash', // The absolute latest free Gemini model version
        apiKey: _geminiApiKey,
      );

      final promptText = TextPart(_prompt);
      final imagePart  = DataPart('image/jpeg', imageBytes);

      return model.generateContentStream([
        Content.multi([promptText, imagePart])
      ]).map((response) => response.text ?? '');
    } catch (e) {
      return Stream.value("❌ **Cloud Error:** Could not connect to Gemini API. ($e)");
    }
  }
}

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

  /// Streams the markdown response continuously as Gemini generates it.
  static Stream<String> streamCritique(Uint8List imageBytes) {
    const apiKey = String.fromEnvironment('GEMINI_API_KEY');
    if (apiKey.isEmpty || apiKey.contains('ENTER_YOUR')) {
      return Stream.value("⚠️ **API Key Missing!**\n\nThe App was not compiled with a Gemini API Key. To fix this, run `flutter build apk --dart-define=GEMINI_API_KEY=your_key`.");
    }

    try {
      final model = GenerativeModel(
        model: 'gemini-2.0-flash', // The absolute latest free Gemini model version
        apiKey: apiKey,
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

import 'dart:typed_data';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;
import 'yolo_detector.dart';

class RuleResult {
  final String ruleName;
  final int    score;     // 0–100, or -1 = N/A (not applicable)
  final String tip;
  final bool   detected;  // false = rule could not be evaluated

  const RuleResult({
    required this.ruleName,
    required this.score,
    required this.tip,
    required this.detected,
  });
}

class CompositionResult {
  final RuleResult ruleOfThirds;
  final RuleResult leadingLines;
  final RuleResult negativeSpace;
  final RuleResult symmetry;
  final RuleResult framing;
  final RuleResult perspective;
  final int        overallScore;
  final double     nimaScore;
  final String     bestTip;
  final String     angleLabel;
  final String     professionalSuggestion;

  const CompositionResult({
    required this.ruleOfThirds,
    required this.leadingLines,
    required this.negativeSpace,
    required this.symmetry,
    required this.framing,
    required this.perspective,
    required this.overallScore,
    required this.nimaScore,
    required this.bestTip,
    required this.angleLabel,
    required this.professionalSuggestion,
  });

  List<RuleResult> get allRules => [
    ruleOfThirds, leadingLines, negativeSpace,
    symmetry, framing, perspective,
  ];
}class _FeedbackEngine {
  static final Random _rng = Random();

  static String getPraise() {
    return ["Masterful composition.", "Excellent visual weight.", "Strong framing.", "Very intentional layout."][_rng.nextInt(4)];
  }

  static String getRuleOfThirdsTip(double dx, double dy, bool isGood) {
    if (isGood) {
      return ["Subject perfectly anchored on power intersections.", "Balanced visual weight.", "Classic, strong framing."][_rng.nextInt(3)];
    }
    String hTip = dx > 0.05 ? 'left' : dx < -0.05 ? 'right' : '';
    String vTip = dy > 0.05 ? 'up' : dy < -0.05 ? 'down' : '';
    String dir = [hTip, vTip].where((s) => s.isNotEmpty).join(' & ');
    if (dir.isEmpty) return "Anchor the subject on a third-line intersection.";
    
    return [
      "Pan slightly $dir to anchor your subject.",
      "Shift $dir to hit a power intersection.",
      "Move $dir for a stronger visual anchor."
    ][_rng.nextInt(3)];
  }

  static String getNegativeSpaceTip(double ratio, bool isLeadRoomGood, bool isGood) {
    if (isGood) {
      return ["Excellent breathing room.", "Perfect spatial balance.", "Negative space carries the subject well."][_rng.nextInt(3)];
    }
    if (ratio < 0.10) {
      return ["Subject lacks impact. Move closer.", "Fill the frame—too much dead space."][_rng.nextInt(2)];
    } else if (ratio > 0.55) {
      return ["Frame feels suffocating. Step back.", "Introduce more 'breathing room' around the subject."][_rng.nextInt(2)];
    } else if (!isLeadRoomGood) {
      return ["Leave more open 'Lead Room' in front.", "Subject needs space to look into."][_rng.nextInt(2)];
    }
    return "Balance your negative space.";
  }

  static String getLeadingLinesTip(int score) {
    if (score >= 70) {
      return ["Strong natural geometry.", "Lines pull the eye straight in.", "Excellent visual arrows."][_rng.nextInt(3)];
    } else if (score >= 35) {
      return ["Subtle lines. Align them to point inward.", "Reposition so lines guide to the center."][_rng.nextInt(2)];
    }
    return ["Use roads or shores to create depth.", "Look for geometric paths."][_rng.nextInt(2)];
  }

  static String getSymmetryTip(int score, String direction) {
    if (score >= 75) {
      return ["Perfect $direction equilibrium.", "Beautifully balanced reflection.", "Strong intentional centering."][_rng.nextInt(3)];
    } else if (score >= 45) {
      return ["Square up to perfect $direction symmetry.", "Center the subject explicitly."][_rng.nextInt(2)];
    }
    return ["Utilize reflections or archways for symmetry.", "Center perfectly if aiming symmetric."][_rng.nextInt(2)];
  }

  static const Map<String, String> _tips = {
    // ── People & Body ──
    'person': 'Anchor the eyes on the upper-third intersection for a striking portrait.',
    'human': 'Focus sharply on the nearest eye and blur the background.',
    'man': 'Use strong side-lighting to emphasize masculine jawline and features.',
    'woman': 'Soft diffused light flatters skin — avoid harsh midday sun.',
    'boy': 'Capture candid moments — children look best when unposed.',
    'girl': 'Get down to their eye level for a more intimate, genuine perspective.',
    'face': 'Fill the frame with the face for powerful emotional impact.',
    'smile': 'Catch genuine smiles — shoot in burst mode during conversation.',
    'selfie': 'Hold the camera slightly above eye level for a flattering angle.',
    'crowd': 'Use a wide lens and find a high vantage point to capture the full energy.',
    'baby': 'Use natural window light and keep the background simple and clean.',
    'child': 'Shoot at their eye level — never from above.',
    'portrait': 'Use shallow depth of field to separate the subject from the background.',
    'clothing': 'Ensure the fabric texture is visible — use angled side-lighting.',
    'beard': 'Side-light to reveal texture and shape of facial hair.',
    'hair': 'Backlight can create a beautiful rim glow around hair strands.',
    'hand': 'Photograph hands in action — holding or creating something makes them alive.',
    'finger': 'Macro mode reveals incredible detail in close-up hand shots.',
    'skin': 'Soft, even lighting minimizes imperfections in skin photography.',
    'eye': 'Get as close as possible — the iris has stunning detail at macro range.',
    'muscle': 'Hard directional light creates dramatic shadows on muscles.',
    'body': 'Use leading lines to draw attention to the pose and form.',
    'arm': 'Capture arms in motion for dynamic, powerful compositions.',
    'leg': 'Low angles elongate legs and give a sense of power.',
    'fashion': 'Clean negative space lets the outfit become the hero of the frame.',
    'wedding': 'Capture emotions over poses — the candid tears and laughter.',
    'dancer': 'Use a fast shutter speed to freeze mid-leap elegance.',
    'athlete': 'Anticipate peak action and shoot in continuous burst mode.',

    // ── Animals & Wildlife ──
    'dog': 'Get down to the dog\'s eye level — it creates an instant emotional bond.',
    'cat': 'Cats photograph best in natural window light. Wait patiently for the perfect pose.',
    'bird': 'Use a long focal length and keep the bird\'s eye razor sharp.',
    'fish': 'Minimize reflections on aquarium glass by pressing the lens against it.',
    'horse': 'Shoot slightly from below to emphasize the horse\'s majestic stature.',
    'cow': 'Frame the animal against open pasture for a classic rural composition.',
    'insect': 'Use macro mode — get within inches to reveal invisible wing patterns.',
    'reptile': 'Side-lighting reveals the incredible texture of scales beautifully.',
    'frog': 'Get level with the water surface for a dramatic half-submerged perspective.',
    'rabbit': 'Soft, warm-toned light suits the gentle nature of small mammals.',
    'bear': 'Keep your distance and use a telephoto lens — fill the frame safely.',
    'lion': 'Capture the mane backlit by golden hour sun for a majestic portrait.',
    'tiger': 'Focus on the eyes — they are the anchor of every predator portrait.',
    'elephant': 'Wide-angle can capture scale when you emphasize the massive body against the sky.',
    'duck': 'Shoot at water level to capture reflections alongside the subject.',
    'chicken': 'Morning light brings out vibrant feather colors naturally.',
    'bee': 'Use continuous autofocus and shoot in burst mode on flowers.',
    'butterfly': 'Approach slowly and shoot from above to display the full wing pattern.',
    'spider': 'Macro mode with side-light reveals web details impossibly well.',
    'ant': 'Use the absolute closest macro distance to make tiny subjects monumental.',
    'snake': 'Shoot from a low angle to create a dramatic sense of the animal.',
    'wolf': 'Backlight through dust or mist creates atmosphere around wild canines.',
    'deer': 'Early morning fog adds a magical quality to wildlife captures.',
    'eagle': 'Pan smoothly to track flight — use a fast shutter for sharp wing detail.',
    'owl': 'Low light conditions suit owl photography — use high ISO and wide aperture.',
    'penguin': 'Capture group behavior for storytelling — isolation shots for portraits.',
    'dolphin': 'Anticipate the jump — pre-focus on the water surface ahead of the animal.',
    'whale': 'Wide shots capture the massive scale against the ocean horizon.',
    'shark': 'Underwater clarity depends on shooting upward toward surface light.',
    'parrot': 'The vibrant colors pop against a dark or blurred green background.',
    'hamster': 'Tiny subjects need macro lenses — fill the frame with the face.',
    'turtle': 'Underwater shots benefit from shooting slightly upward toward the light.',
    'monkey': 'Focus on the eyes and hands — they convey emotion powerfully.',
    'gorilla': 'Black fur needs careful exposure — overexpose slightly to retain detail.',
    'zebra': 'The stripe pattern is the star — frame tightly to emphasize the graphic quality.',
    'giraffe': 'Vertical compositions suit the tall frame naturally.',
    'panda': 'Expose for the white patches to avoid blowing out highlights.',
    'peacock': 'Wait for the full fan display — backlight makes the feathers glow.',
    'flamingo': 'Reflections in still water double the visual impact — include them.',
    'crab': 'Beach light is harsh — shoot during golden hour for warm tones.',
    'jellyfish': 'Dark backgrounds make translucent bodies glow dramatically.',
    'pet': 'Get at their eye level and use treats behind the camera for attention.',
    'animal': 'Patience is key — wait for the animal to look directly at the lens.',
    'wildlife': 'Use natural light and never use flash — it disturbs wild animals.',
    'puppy': 'Shoot in burst mode — puppies are too fast for single shots.',
    'kitten': 'Window light and a simple blanket is all you need for stunning kitten shots.',

    // ── Architecture & Structures ──
    'building': 'Keep vertical lines straight — tilt distortion ruins architectural shots.',
    'house': 'Include landscaping for context — shoot in golden hour for warm tones.',
    'architecture': 'Look for geometric patterns, symmetry, and repeating elements.',
    'bridge': 'Shoot from below to emphasize the engineering and create drama.',
    'tower': 'Vertical panorama captures the full height with maximum impact.',
    'skyscraper': 'Look straight up from the base for a dramatic converging-lines composition.',
    'church': 'Interior shots benefit from high ISO and no flash to preserve the ambient mood.',
    'temple': 'Frame the entrance symmetrically — temples are designed for balanced viewing.',
    'mosque': 'Capture the geometric tile patterns in detail alongside the structure.',
    'castle': 'Low angles make fortifications look imposing and dominant.',
    'monument': 'Include people for scale — monuments feel grander with human reference.',
    'statue': 'Strong side-light creates dramatic shadows that reveal sculptural form.',
    'fountain': 'Use a slow shutter speed to blur the water into silky streams.',
    'window': 'Shoot toward the window from inside for dramatic silhouette portraits.',
    'door': 'Centered framing works perfectly — doors are natural symmetry points.',
    'wall': 'Texture photography demands raking side-light at extreme angles.',
    'ceiling': 'Point straight up and center the pattern for graphic impact.',
    'corridor': 'Leading lines converge naturally — place the subject at the vanishing point.',
    'tunnel': 'Expose for the light at the end — let the tunnel walls go dark.',
    'stair': 'Spiral staircases shot from above create hypnotic geometric patterns.',
    'arch': 'Use the arch as a natural frame for whatever lies beyond it.',
    'column': 'Repeating columns create rhythm — shoot at an angle to show depth.',
    'fence': 'Shallow depth of field with a fence in the foreground creates beautiful bokeh.',
    'gate': 'Frame your subject through the gate opening for a layered composition.',
    'roof': 'Rooftops work best as foreground elements against dramatic skies.',
    'shed': 'Rustic structures look best in warm, late-afternoon directional light.',
    'room': 'Wide-angle lens from a corner captures maximum interior space.',
    'furniture': 'Style the scene before shooting — remove clutter for clean interiors.',
    'barn': 'Barns glow beautifully during blue hour with interior lights on.',
    'lighthouse': 'Include the beam at dusk — long exposure can capture the light sweep.',
    'pier': 'Use the pier as a leading line pointing into the horizon.',
    'stadium': 'Wide-angle from high seats captures the atmosphere of the full venue.',

    // ── Food & Drink ──
    'food': 'Shoot from 45 degrees or directly overhead for the most appetizing look.',
    'meal': 'Style the full place setting — cutlery and napkins add production value.',
    'fruit': 'Water droplets on fruit surfaces catch light beautifully — mist them first.',
    'vegetable': 'Group vegetables by color gradient for a visually stunning flat-lay.',
    'coffee': 'Capture steam rising against a dark background for cozy atmosphere.',
    'tea': 'Overhead flat-lays with teacups, leaves, and books tell a complete story.',
    'cake': 'Slice and show the interior layers — texture is the star in pastry shots.',
    'pizza': 'The cheese pull shot requires one person lifting while you shoot at table level.',
    'burger': 'Stack height matters — shoot at exact eye level with the patty.',
    'bread': 'Rustic wooden boards and flour dust create artisan bakery atmosphere.',
    'cheese': 'Warm side-lighting emphasizes the creamy texture and color variations.',
    'salad': 'Overhead shots let you showcase the full arrangement of colors.',
    'soup': 'Steam and a garnish sprig transform a plain bowl into a hero shot.',
    'sushi': 'Clean white or black surfaces emphasize the precision of Japanese cuisine.',
    'chocolate': 'Melting chocolate needs to be shot quickly — have your angle pre-planned.',
    'cookie': 'Stack cookies and shoot at a 20-degree angle for depth.',
    'sandwich': 'Cross-section cuts reveal the fillings — the most appetizing angle.',
    'egg': 'Backlight makes the yolk glow when broken open.',
    'pasta': 'Twirl pasta on a fork and freeze the action mid-lift.',
    'dessert': 'Desserts are art — treat them like product photography with intentional lighting.',
    'wine': 'Backlight through the glass reveals deep ruby and gold tones beautifully.',
    'beer': 'Capture condensation droplets on the glass — mist with a spray bottle.',
    'drink': 'Dark backgrounds make colorful cocktails pop dramatically.',
    'plate': 'Negative space around the plate keeps the focus on the food.',
    'ice cream': 'Shoot quickly before it melts — pre-focus and have lighting set.',

    // ── Vehicles & Transport ──
    'car': 'Leave lead room in front of the car to imply forward motion.',
    'truck': 'Low angles make trucks look imposing and dominant — shoot from knee height.',
    'bicycle': 'Frame the bicycle against urban architecture for lifestyle context.',
    'motorcycle': 'Three-quarter front angles show the most detail of the body shape.',
    'boat': 'Include the water reflection — calm water doubles the visual impact.',
    'airplane': 'Panning with the aircraft creates dramatic motion blur in the background.',
    'train': 'Leading lines from the rails create powerful vanishing point compositions.',
    'bus': 'Motion blur of a passing bus against a static background is dynamic.',
    'helicopter': 'Shoot from below against the sky — rotor blur adds energy.',
    'ship': 'Dawn and dusk give ships the most dramatic silhouette against the horizon.',
    'taxi': 'Night city shots with taxi headlights create atmospheric urban energy.',
    'scooter': 'Street-level panning shots create excellent motion blur backgrounds.',
    'vehicle': 'Eye-level with the headlights is the most dynamic car photography angle.',
    'tire': 'Macro detail shots of tire tread reveal impressive mechanical texture.',
    'wheel': 'Chrome wheels pop when side-lit — avoid direct overhead light.',
    'engine': 'Clean the surface first — engine detail photography demands pristine subjects.',

    // ── Nature & Landscape ──
    'tree': 'Shoot upward through the canopy for dramatic perspective.',
    'plant': 'Soft backlight makes leaves glow translucently — shoot toward the light.',
    'flower': 'Get below the flower and shoot upward against the sky for drama.',
    'water': 'Long exposure turns moving water into smooth, silky streams.',
    'sky': 'Include an interesting foreground — sky alone rarely makes a strong image.',
    'mountain': 'Use foreground rocks or wildflowers to create depth in landscape shots.',
    'cloud': 'Polarizing filters deepen blue skies and make clouds pop dramatically.',
    'sea': 'Slow shutter speeds create misty, dreamlike ocean surfaces.',
    'river': 'Find a bend in the river and use it as a leading line into the distance.',
    'lake': 'Still water morning reflections create perfect mirror compositions.',
    'forest': 'Fog in forests creates atmosphere — shoot during early morning.',
    'desert': 'Leading lines from sand dune ridges create powerful minimalist compositions.',
    'beach': 'Low tide reveals textures — shoot during golden hour for warm sand tones.',
    'sunset': 'Expose for the sky, let the foreground silhouette for maximum drama.',
    'sunrise': 'Arrive 30 minutes early — the best light is before the sun clears the horizon.',
    'snow': 'Overexpose by +1 EV to keep snow white instead of grey.',
    'rain': 'Backlight reveals individual rain drops — shoot toward a light source.',
    'fog': 'Simplify the composition — fog isolates subjects naturally.',
    'leaf': 'Backlit leaves glow with incredible inner color and vein detail.',
    'grass': 'Shoot through grass blades for a blurry foreground framing effect.',
    'rock': 'Wet rocks have richer color — shoot after rain.',
    'stone': 'Low raking light across stone surfaces reveals texture beautifully.',
    'waterfall': 'Use a 1-2 second exposure to create silky water while keeping rocks sharp.',
    'field': 'Golden hour side-light across a field creates long, dramatic shadows.',
    'valley': 'Elevated viewpoints capture the full sweep and depth of valleys.',
    'volcano': 'Blue hour with lava glow creates the most dramatic volcanic shots.',
    'garden': 'Shoot after rain — droplets catch light on petals beautifully.',
    'pond': 'Include lily pads or reflections for layered, rich compositions.',
    'cave': 'Expose for the cave entrance light — let the interior go dark for drama.',
    'cliff': 'Include a person on the edge for scale that emphasizes height.',
    'coral': 'Underwater macro reveals colors invisible to the naked eye.',
    'mushroom': 'Get at ground level for the most dramatic mushroom perspective.',
    'moss': 'Macro mode reveals a miniature forest world in moss patches.',
    'landscape': 'Strong foreground, middle ground, and background create depth.',
    'nature': 'Patience is the most powerful tool — wait for the perfect light.',

    // ── Sports & Action ──
    'sport': 'Anticipate the peak moment and pre-focus on the spot it will happen.',
    'ball': 'Freeze the ball mid-air with a fast shutter speed.',
    'soccer': 'Shoot from the corner flag position for dramatic angle on goal shots.',
    'basketball': 'Capture the peak height of a jump shot from a low angle.',
    'tennis': 'Side-on to the baseline captures powerful serve motion.',
    'golf': 'The follow-through swing is the most aesthetic moment to freeze.',
    'boxing': 'Ringside angles capture impact — use burst mode for knockout sequences.',
    'swim': 'Underwater housings or splash-proof setups capture the best aquatic action.',
    'dance': 'Slow shutter with flash creates sharp subject with motion-blurred limbs.',
    'gym': 'Hard directional light from the side emphasizes muscle definition.',
    'workout': 'Shoot from low angles to make the athlete look powerful.',
    'ski': 'Follow the skier down the slope with continuous tracking focus.',
    'surf': 'Water housing or a long telephoto from the beach captures spray and power.',
    'climb': 'Shoot from below to emphasize height and the drama of the ascent.',
    'race': 'Panning at slow shutter speeds creates dramatic streaked backgrounds.',
    'run': 'Freeze mid-stride with 1/1000s or faster shutter speed.',
    'jump': 'Shoot at the apex of the jump when the subject is momentarily still.',
    'action': 'Pre-focus on where the action will happen and shoot in burst mode.',
    'game': 'Capture the emotional reactions — celebration and defeat tell the story.',
    'yoga': 'Clean backgrounds and soft light complement the flowing poses.',
    'martial arts': 'Freeze the kick at full extension for maximum impact.',
    'skateboard': 'Low angles with a wide lens exaggerate the height of tricks.',
    'cycling': 'Pan with the cyclist — sharp subject, blurred background equals speed.',

    // ── Technology & Electronics ──
    'computer': 'Clean the screen and use it as a soft light source in dark environments.',
    'phone': 'Shoot at a slight angle to avoid direct screen reflections.',
    'laptop': 'Open at 90 degrees and shoot from the keyboard side for product shots.',
    'tablet': 'Display compelling content on the screen to add context to the shot.',
    'keyboard': 'Angled macro shots of keycaps reveal satisfying texture detail.',
    'mouse': 'Side-lighting on a dark surface creates dramatic product photography.',
    'monitor': 'Turn off to shoot the design, or display content for lifestyle shots.',
    'screen': 'Matching the screen color temperature to your lights eliminates color casts.',
    'tv': 'Photograph the TV as part of the room setup — not as an isolated object.',
    'television': 'Include the viewing area for a lifestyle scene composition.',
    'camera': 'Mirror or reflective surfaces make camera gear photography tricky — use matte backgrounds.',
    'headphone': 'Suspend headphones on a stand — floating subjects look premium.',
    'speaker': 'Dramatic low-key lighting suits the sleek industrial design of audio gear.',
    'watch': 'Set the time to 10:10 — it frames the logo and looks aesthetically balanced.',
    'robot': 'Eye-level perspective humanizes robotic subjects.',
    'drone': 'Capture with the propellers spinning using a slower shutter speed.',
    'printer': 'Include the printed output emerging for an action-in-progress shot.',
    'microphone': 'Dramatic spotlight from one side creates a studio-feel product shot.',
    'controller': 'Flat-lay with complementary gaming accessories for a lifestyle setup.',
    'charger': 'Minimalist product shots on white surfaces suit tech accessories.',

    // ── Fashion & Accessories ──
    'shoe': 'Shoot at ground level — the shoe\'s own perspective is more engaging.',
    'bag': 'Style the bag with contents partially visible for lifestyle context.',
    'hat': 'Photograph on a model or a quality hat stand — never flat on a table.',
    'glasses': 'Avoid reflections by angling the glasses slightly off-axis to the camera.',
    'jewelry': 'Macro lens reveals gemstone facets invisible to the naked eye.',
    'necklace': 'Drape on a dark velvet surface for maximum sparkle contrast.',
    'ring': 'Prop the ring in flowers or textured fabric for romantic context.',
    'dress': 'Movement shots — spinning or walking — show how fabric flows.',
    'jacket': 'Hang on a quality hanger with the shape stuffed for clean form.',
    'shirt': 'Flat-lay with complementary accessories tells a style story.',
    'sunglasses': 'Reflections in the lenses showing the scene add a creative dimension.',
    'belt': 'Coil artfully on a leather surface for a premium flat-lay.',
    'wallet': 'Slightly open to show the interior craftsmanship.',
    'umbrella': 'Rain photography with an umbrella in use tells a powerful weather story.',
    'scarf': 'Flowing scarves in wind create dynamic, organic movement in the frame.',
    'boots': 'Muddy boots on a trail tell an adventure story instantly.',
    'tie': 'Tight crop on the knot detail for texture-focused product photography.',
    'gloves': 'Photograph gloves in use — gripping a mug or touching snow.',

    // ── Household & Interior ──
    'chair': 'Natural light from a nearby window is the best light for furniture shots.',
    'table': 'Overhead flat-lay from directly above showcases table settings best.',
    'bed': 'Messy beds with morning light tell a cozy lifestyle story.',
    'desk': 'Clean up and curate the objects — minimalist desk setups photograph best.',
    'sofa': 'Include throw pillows and blankets for warmth and texture.',
    'couch': 'Photograph from a 45-degree angle to show both depth and width.',
    'shelf': 'Style the shelves symmetrically before shooting — order creates calm.',
    'lamp': 'Turn the lamp on in a dim room — it becomes both subject and light source.',
    'mirror': 'Shoot at an angle to avoid your own reflection in the mirror.',
    'curtain': 'Sheer curtains with backlight create ethereal, dreamy atmosphere.',
    'rug': 'Flat-lay from directly above shows the full pattern.',
    'vase': 'Side-lighting on ceramics reveals the glaze texture beautifully.',
    'candle': 'Dim room + candle flame = atmospheric low-light mood photography.',
    'clock': 'Set it to a meaningful time for added storytelling depth.',
    'pot': 'Kitchen pots look best with steam rising out of them during cooking.',
    'towel': 'Rolled or folded neatly with spa elements for a lifestyle shot.',
    'pillow': 'Soft diffused light complements the softness of textile subjects.',
    'blanket': 'Drape casually over furniture for a lived-in, cozy composition.',

    // ── Tools & Industrial ──
    'tool': 'Arrange tools neatly on a workbench — the organized chaos aesthetic.',
    'hammer': 'Action shots mid-strike create powerful dynamic compositions.',
    'wrench': 'Oil and metal reflections add grit and character to tool photography.',
    'drill': 'Show the drill bit tip in sharp macro for technical detail shots.',
    'saw': 'Sawdust particles frozen mid-air with flash create stunning action shots.',
    'bolt': 'Extreme macro reveals threading detail invisible to the naked eye.',
    'cable': 'Coil neatly or show in dynamic tangles — both tell different stories.',
    'pipe': 'Industrial pipes create powerful leading lines and geometric patterns.',
    'machine': 'Include the operator for scale and human interest.',
    'equipment': 'Clean industrial equipment first — dust kills product photography.',
    'gear': 'Interlocking gears shot in macro reveal mesmerizing mechanical beauty.',

    // ── Books, Art & Stationery ──
    'book': 'Fan the pages with side-light for a dreamy, literary atmosphere.',
    'pen': 'Macro reveals the craftsmanship of a fine pen — show the nib detail.',
    'paper': 'Crumpled paper with dramatic side-light creates incredible texture.',
    'notebook': 'Flat-lay with coffee and a pen for a workspace storytelling shot.',
    'painting': 'Match your lighting to the painting\'s mood — cool for blue, warm for gold.',
    'sculpture': 'Walk around it and find the most dynamic angle before shooting.',
    'art': 'Shoot art straight-on and parallel to avoid keystoning distortion.',
    'drawing': 'Include the artist\'s tools next to the drawing for context.',
    'canvas': 'Angled lighting reveals brushstroke texture for authentic fine art documentation.',
    'pencil': 'Group colored pencils in gradient for satisfying graphic compositions.',
    'brush': 'Paint-loaded brushes mid-stroke create dynamic art-action shots.',
    'poster': 'Photograph in context on a wall — not flat on a table.',

    // ── Containers & Packaging ──
    'bottle': 'Backlight through colored glass creates stunning luminous effects.',
    'cup': 'Steam or latte art makes coffee cup shots irresistible.',
    'bowl': 'Overhead shots with garnish and surrounding ingredients create food context.',
    'box': 'Open boxes with tissue paper suggest luxury unboxing experiences.',
    'jar': 'Side-lighting through glass jars reveals the contents beautifully.',
    'can': 'Water droplets on a cold can add refreshing appeal.',
    'glass': 'Backlight makes the liquid glow — dark backgrounds maximize the effect.',
    'tray': 'Arrange items on the tray with intentional spacing for balanced compositions.',
    'container': 'Show containers in their natural use context for lifestyle relevance.',
    'bucket': 'Fill with ice and bottles for a classic refreshment scene.',

    // ── Musical Instruments ──
    'guitar': 'Shoot the neck stretching away for dramatic perspective.',
    'piano': 'Black and white keys demand careful exposure — meter for midtones.',
    'violin': 'The S-curves of a violin body are inherently photogenic from any angle.',
    'drum': 'Freeze drumstick impact with flash for explosive action captures.',
    'flute': 'Reflections along the metal body create beautiful abstract highlights.',
    'trumpet': 'Brass instruments glow under warm tungsten light.',
    'saxophone': 'Include the player for storytelling — jazz clubs add atmosphere.',
    'harp': 'Backlight through the strings creates a magical ethereal glow.',
    'music': 'Capture the emotion on the musician\'s face — technique is secondary.',
    'bass': 'Low angles suit low-frequency instruments — shoot from below.',

    // ── Medical & Science ──
    'medical': 'Clean white backgrounds communicate clinical precision.',
    'hospital': 'Respect privacy — capture the environment, not patient identities.',
    'lab': 'Reflections in glassware create compelling abstract science imagery.',
    'science': 'Macro mode reveals molecular and crystalline worlds invisible to the eye.',
    'microscope': 'Include the eyepiece view as an inset for context.',
    'medicine': 'Precise arrangement on white surfaces creates pharmaceutical aesthetics.',
    'doctor': 'Environmental portraits in their workspace tell a professional story.',
    'nurse': 'Candid action shots during care convey compassion and dedication.',
    'syringe': 'Extreme close-up of the needle tip is dramatic at macro scale.',
    'pill': 'Color-code pills on white for graphic medical stock imagery.',

    // ── Miscellaneous Objects ──
    'flag': 'Wind-blown flags need fast shutter speeds to freeze the fabric shape.',
    'sign': 'Shoot straight-on and level — signs demand square, parallel framing.',
    'toy': 'Get at the toy\'s scale — shoot from its eye level for a miniature world.',
    'doll': 'Treat it like a portrait — focus on the eyes, blur the background.',
    'key': 'Macro photography makes everyday keys look like ancient artifacts.',
    'coin': 'Side-lighting reveals embossed detail on coin surfaces.',
    'map': 'Flat-lay with travel accessories for an adventure-planning composition.',
    'trophy': 'Polish first, then side-light to create dramatic metallic reflections.',
    'medal': 'Macro on the engraving detail with the ribbon draped artfully.',
    'badge': 'Include the uniform or context for storytelling relevance.',
    'rope': 'Coiled rope with nautical context creates rustic maritime atmosphere.',
    'chain': 'Individual links in macro reveal surprising mechanical beauty.',
    'basket': 'Fill with seasonal items — flowers, fruit, bread — for lifestyle context.',
    'carpet': 'Raking light at extreme angles reveals carpet pile and pattern texture.',
    'balloon': 'Groups against blue sky create joyful, colorful compositions.',
    'kite': 'Include the string and the person flying it for the full story.',
    'tent': 'Interior glow at dusk against a star-filled sky is photography gold.',
    'backpack': 'Adventure context — trail, mountain, or airport — tells the story.',
    'suitcase': 'Open with clothes spilling out for a travel preparation narrative.',
    'mat': 'Yoga mats with props create wellness and fitness lifestyle compositions.',
    'sticker': 'Macro reveals printing detail and adhesive edges at close range.',
    'tape': 'Translucent tape against light creates interesting abstract studies.',
  };

  static String getSubjectSpecificTip(String subjectClass) {
    if (subjectClass.isEmpty || subjectClass == 'object' || subjectClass == 'foreground object') return "";
    final s = subjectClass.toLowerCase();
    
    // 1. Direct HashMap lookup (O(1) instant match)
    if (_tips.containsKey(s)) return _tips[s]!;
    
    // 2. Substring fallback for compound labels like "golden retriever" → matches "dog" etc.
    for (final entry in _tips.entries) {
      if (s.contains(entry.key)) return entry.value;
    }
    
    // 3. Universal catch-all
    return "Use the Rule of Thirds to place the subject off-center for a dynamic composition.";
  }

  static String generateProfessionalSuggestion(List<RuleResult> activeRules, double nima, String subjectClass) {
    if (activeRules.isEmpty) return 'Point at a clear subject for technical coaching.';

    final issues = activeRules.where((r) => r.score < 65).toList()
      ..sort((a, b) => a.score.compareTo(b.score));
    final good = activeRules.where((r) => r.score >= 80).toList();
    
    final nimaStr = nima >= 70 ? 'Stunning aesthetics.'
                  : nima >= 45 ? 'Decent lighting.'
                  : 'Requires better lighting.';

    if (issues.isEmpty) {
      final goodNames = good.map((r) => r.ruleName.toLowerCase()).toList();
      final goodJoined = goodNames.take(2).join(' & ');
      return '${getPraise()} $goodJoined working perfectly. $nimaStr';
    }

    final primary = issues.first;
    String text = "${primary.tip}";
    
    if (nima >= 70 && primary.score < 50) {
      return "Gorgeous light, but framing feels loose. $text";
    }
    if (good.isNotEmpty && (primary.score - issues.last.score).abs() > 30) {
      final strTop = good.first.ruleName.toLowerCase();
      text = "Solid $strTop, but $text";
    } else if (issues.length > 1) {
       text += " Also: ${issues[1].tip}";
    }
    
    // Safety crop for extremely long combined strings
    if (text.length > 100) text = "${primary.tip} $nimaStr";
    
    return text;
  }
}

class CompositionAnalyzer {
  final YoloDetector _yolo = YoloDetector();
  Interpreter? _deeplabInterpreter;
  Interpreter? _midasInterpreter;
  Interpreter? _nimaInterpreter;

  YoloDetector get yolo => _yolo;

  Future<void> loadModels() async {
    try {
      await _yolo.loadModel();
      final options = InterpreterOptions()..threads = 2;
      _deeplabInterpreter = await Interpreter.fromAsset('assets/models/deeplabv3.tflite', options: options);
      _midasInterpreter   = await Interpreter.fromAsset('assets/models/midas_small.tflite', options: options);
      _nimaInterpreter    = await Interpreter.fromAsset('assets/models/nima_mobilenet.tflite', options: options);
      debugPrint('AI Models Loaded Successfully');
    } catch (e) {
      debugPrint('AI Model Load Failure: \$e');
    }
  }

  Future<CompositionResult> analyseImage(List<int> imageBytes, String imagePath) async {
    final image = img.decodeImage(Uint8List.fromList(imageBytes));
    if (image == null) return _errorResult('Could not decode image');

    // 1. Run Google ML Kit native object detection
    final detections = await _yolo.detect(imagePath, image.width, image.height);

    // 2. Run Perspective/Depth analysis (reusable for sensor fusion)
    final perspectiveData = await _checkPerspective(image);
    final r6 = perspectiveData.result;
    final depthMap = perspectiveData.depth;

    // 3. Sensor Fusion: Combine YOLO boxes and MiDaS depth to rank targets
    final subject = _fusionSubjectDetector(detections, depthMap);
    final bool isDepthFallback = (subject != null && subject.className == 'foreground object');

    // 4. Run remaining rules
    final r1 = _checkRuleOfThirds(subject);
    final r2 = _checkLeadingLines(image);
    final r3 = _checkNegativeSpace(subject);
    final r4 = _checkSymmetry(image);
    final r5 = await _checkFraming(image, subject);
    final nimaScore = await _getNimaScore(image);

    final active = [r1, r2, r3, r4, r5, r6].where((r) => r.detected && r.score >= 0).toList();
    final overall = active.isEmpty ? 50 : (active.map((r) => r.score).reduce((a, b) => a + b) / active.length).round();
    final weakest = active.isEmpty ? null : active.reduce((a, b) => a.score < b.score ? a : b);

    final angle = r6.tip.contains('LOW') ? 'LOW ANGLE' : r6.tip.contains('HIGH') ? 'HIGH ANGLE' : 'EYE LEVEL';
    
    String suggestion;
    if (subject == null) {
      suggestion = 'Blank frame detected. Please point the camera at a subject or clear landscape.';
    } else {
      final subjectTip = _FeedbackEngine.getSubjectSpecificTip(subject.className);
      final generalTip = _FeedbackEngine.generateProfessionalSuggestion(active, nimaScore, subject.className);
      suggestion = [subjectTip, generalTip].where((s) => s.isNotEmpty).join(' ');
      
      if (isDepthFallback) {
        suggestion = 'Composition tips based on nearest dominant object. $suggestion';
      }
    }

    return CompositionResult(
      ruleOfThirds: r1, leadingLines: r2, negativeSpace: r3,
      symmetry: r4, framing: r5, perspective: r6,
      overallScore: overall.clamp(0, 100),
      nimaScore: nimaScore,
      bestTip: weakest?.tip ?? 'Frame your shot and tap ANALYSE.',
      angleLabel: angle,
      professionalSuggestion: suggestion,
    );
  }

  /// Synthesise YOLO bounding boxes with MiDaS depth map to rank by proximity and confidence.
  DetectedObject? _fusionSubjectDetector(List<DetectedObject> yoloSubjects, List<List<double>>? depth) {
    if (yoloSubjects.isEmpty && depth == null) return null;
    
    // Fallback: if no depth model loaded, default to YOLO's largest box
    if (depth == null && yoloSubjects.isNotEmpty) return _yolo.getPrimarySubject(yoloSubjects);

    int H = depth!.length;
    int W = depth[0].length;
    double maxD = 0;
    for (var row in depth) { for (var v in row) { if (v > maxD) maxD = v; } }
    if (maxD < 1e-4) maxD = 1; 

    DetectedObject? bestYoloSubject;
    double bestScore = -1;

    for (var subject in yoloSubjects) {
      int sx1 = (subject.x * W).toInt().clamp(0, W - 1);
      int sy1 = (subject.y * H).toInt().clamp(0, H - 1);
      int sx2 = ((subject.x + subject.width) * W).toInt().clamp(0, W - 1);
      int sy2 = ((subject.y + subject.height) * H).toInt().clamp(0, H - 1);
      
      double sumD = 0; int count = 0;
      for (int y = sy1; y <= sy2; y++) {
        for (int x = sx1; x <= sx2; x++) { sumD += depth[y][x]; count++; }
      }
      double avgD = count > 0 ? sumD / count : 0;
      
      // Score ranks YOLO targets by Semantic Confidence + Physical Proximity
      double score = (avgD / maxD) * 0.5 + subject.confidence * 0.5;
      if (score > bestScore) { bestScore = score; bestYoloSubject = subject; }
    }

    // Now evaluate raw depth map for geometric foreground prominence
    // Instead of fixed thresholds, find the 95th percentile (top 5% closest pixels)
    final flatDepth = depth.expand((r) => r).toList()..sort();
    final threshold = flatDepth[(flatDepth.length * 0.95).toInt()]; // top 5%
    
    int minX = W, minY = H, maxX = 0, maxY = 0;
    for (int y = 0; y < H; y++) {
      for (int x = 0; x < W; x++) {
        if (depth[y][x] >= threshold) {
          if (x < minX) minX = x; if (y < minY) minY = y;
          if (x > maxX) maxX = x; if (y > maxY) maxY = y;
        }
      }
    }
    
    double geoWidth = (maxX - minX + 1) / W;
    double geoHeight = (maxY - minY + 1) / H;
    
    if (bestYoloSubject == null) {
      return DetectedObject(className: 'foreground object', confidence: 0.8, x: minX / W, y: minY / H, width: geoWidth, height: geoHeight);
    }
    return bestYoloSubject;
  }

  // ── RULE 1 — Granular Rule of Thirds
  RuleResult _checkRuleOfThirds(DetectedObject? subject) {
    if (subject == null) {
      return const RuleResult(
        ruleName: 'Rule of Thirds', score: -1,
        tip: 'No subject detected. Point at a clear subject.', detected: false,
      );
    }

    const intersections = [
      [1/3.0, 1/3.0], [2/3.0, 1/3.0],
      [1/3.0, 2/3.0], [2/3.0, 2/3.0],
    ];

    // Check if the subject's exact bounding box *covers* a power point
    bool coversPoint = false;
    for (final pt in intersections) {
      if (pt[0] >= subject.x && pt[0] <= subject.x + subject.width &&
          pt[1] >= subject.y && pt[1] <= subject.y + subject.height) {
        coversPoint = true; break;
      }
    }

    double minDist = double.infinity;
    List<double> nearest = intersections[0];
    for (final pt in intersections) {
      final dx = subject.centerX - pt[0];
      final dy = subject.centerY - pt[1];
      final d  = sqrt(dx*dx + dy*dy);
      if (d < minDist) { minDist = d; nearest = pt; }
    }

    int score = coversPoint ? 95 : (max(0.0, 1.0 - minDist / 0.50) * 100).round().clamp(0, 100);
    
    final dx = subject.centerX - nearest[0];
    final dy = subject.centerY - nearest[1];
    
    String tip = _FeedbackEngine.getRuleOfThirdsTip(dx, dy, coversPoint || score >= 82);
    return RuleResult(ruleName: 'Rule of Thirds', score: score, tip: tip, detected: true);
  }

  // ── RULE 2 — Leading Lines
  RuleResult _checkLeadingLines(img.Image image) {
    try {
      const size = 96;
      final small = img.copyResize(image, width: size, height: size);
      final gray  = img.grayscale(small);
      int converging = 0; int total = 0;

      for (int y = 1; y < size - 1; y++) {
        for (int x = 1; x < size - 1; x++) {
          final tl = gray.getPixel(x-1, y-1).r.toInt();
          final tc = gray.getPixel(x,   y-1).r.toInt();
          final tr = gray.getPixel(x+1, y-1).r.toInt();
          final ml = gray.getPixel(x-1, y  ).r.toInt();
          final mr = gray.getPixel(x+1, y  ).r.toInt();
          final bl = gray.getPixel(x-1, y+1).r.toInt();
          final bc = gray.getPixel(x,   y+1).r.toInt();
          final br = gray.getPixel(x+1, y+1).r.toInt();

          final gx = (-tl - 2*ml - bl + tr + 2*mr + br).toDouble();
          final gy = (-tl - 2*tc - tr + bl + 2*bc + br).toDouble();
          final mag = sqrt(gx*gx + gy*gy);

          if (mag < 25) continue;
          total++;

          final cx = (size / 2 - x).toDouble();
          final cy = (size / 2 - y).toDouble();
          if (gx * cx + gy * cy > 0) converging++;
        }
      }

      if (total < 100) {
        return RuleResult(ruleName: 'Leading Lines', score: 20, tip: _FeedbackEngine.getLeadingLinesTip(20), detected: true);
      }

      final ratio = converging / total;
      final score = ((ratio - 0.50) / 0.32 * 100).round().clamp(0, 100);
      return RuleResult(ruleName: 'Leading Lines', score: score, tip: _FeedbackEngine.getLeadingLinesTip(score), detected: true);
    } catch (_) {
      return RuleResult(ruleName: 'Leading Lines', score: 30, tip: _FeedbackEngine.getLeadingLinesTip(30), detected: true);
    }
  }

  // ── RULE 3 — Negative Space (with Lead Room analysis)
  RuleResult _checkNegativeSpace(DetectedObject? subject) {
    if (subject == null) {
      return const RuleResult(ruleName: 'Negative Space', score: -1, tip: 'No subject detected.', detected: false);
    }

    final ratio = subject.area.clamp(0.0, 1.0);
    int score;
    bool leadRoomGood = true;

    // Check lateral looking-space limits
    if (subject.width < 0.4) {
      if (subject.centerX < 0.4) leadRoomGood = true; // left aligned, space is on right
      else if (subject.centerX > 0.6) leadRoomGood = true; // right aligned, space on left
      else leadRoomGood = true; // center aligned is fine. We just want to flag edge crowding.
      // If subject is too close to an edge while facing away from the center, that's bad lead room.
      // E.g. x > 0.8 means touching right edge. If it's a profile, it feels cramped.
      if (subject.x < 0.05 || subject.x + subject.width > 0.95) leadRoomGood = false;
    }

    if (ratio < 0.05) score = (ratio / 0.05 * 40).round();
    else if (ratio < 0.10) score = (40 + (ratio - 0.05) / 0.05 * 50).round();
    else if (ratio <= 0.35) score = leadRoomGood ? 95 : 75;
    else if (ratio <= 0.55) score = (95 - ((ratio - 0.35) / 0.20 * 45)).round();
    else score = (50 - ((ratio - 0.55) / 0.45 * 50)).round();

    bool isGood = score >= 85;
    if (!leadRoomGood) score -= 20;

    String tip = _FeedbackEngine.getNegativeSpaceTip(ratio, leadRoomGood, isGood);
    return RuleResult(ruleName: 'Negative Space', score: score.clamp(0, 100), tip: tip, detected: true);
  }

  // ── RULE 4 — Symmetry
  RuleResult _checkSymmetry(img.Image image) {
    try {
      final small = img.copyResize(image, width: 128, height: 128);
      final W = small.width; final H = small.height;

      double computeSim(bool horizontal) {
        double totalDiff = 0; const b = 4;
        if (horizontal) {
          for (int y = 0; y < H; y += b) {
            for (int x = 0; x < W ~/ 2; x += b) {
              double bL = 0, bR = 0;
              for (int dy = 0; dy < b && y+dy < H; dy++) {
                for (int dx = 0; dx < b && x+dx < W; dx++) {
                  bL += img.getLuminance(small.getPixel(x+dx, y+dy));
                  bR += img.getLuminance(small.getPixel(W-1-(x+dx), y+dy));
                }
              }
              totalDiff += (bL - bR).abs();
            }
          }
          return 1.0 - (totalDiff / ((W/2) * H * 255));
        } else {
          for (int y = 0; y < H ~/ 2; y += b) {
            for (int x = 0; x < W; x += b) {
              double bT = 0, bB = 0;
              for (int dy = 0; dy < b && y+dy < H; dy++) {
                for (int dx = 0; dx < b && x+dx < W; dx++) {
                  bT += img.getLuminance(small.getPixel(x+dx, y+dy));
                  bB += img.getLuminance(small.getPixel(x+dx, H-1-(y+dy)));
                }
              }
              totalDiff += (bT - bB).abs();
            }
          }
          return 1.0 - (totalDiff / (W * (H/2) * 255));
        }
      }

      final lrSim = computeSim(true);
      final tbSim = computeSim(false);
      final bestSim   = max(lrSim, tbSim);
      final direction = lrSim >= tbSim ? 'left-right' : 'top-bottom';
      final score = ((bestSim - 0.65) / 0.31 * 100).round().clamp(0, 100);

      String tip = _FeedbackEngine.getSymmetryTip(score, direction);
      return RuleResult(ruleName: 'Symmetry', score: score, tip: tip, detected: true);
    } catch (_) {
      return const RuleResult(ruleName: 'Symmetry', score: 20, tip: 'Try reflections or centred subjects.', detected: true);
    }
  }

  // ── RULE 5 — Framing
  Future<RuleResult> _checkFraming(img.Image image, DetectedObject? subject) async {
    if (_deeplabInterpreter == null) {
      return const RuleResult(ruleName: 'Framing', score: 20, tip: 'Look for windows, arches, or branches to frame your subject.', detected: true);
    }
    try {
      const dlSize = 257;
      final resized = img.copyResize(image, width: dlSize, height: dlSize);
      final inputInfo = _deeplabInterpreter!.getInputTensor(0);
      final isInt8    = inputInfo.type == TfLiteType.kTfLiteInt8;
      final isUint8   = inputInfo.type == TfLiteType.kTfLiteUInt8;

      Object input;
      if (isInt8 || isUint8) {
        input = List.generate(1, (_) => List.generate(dlSize, (y) => List.generate(dlSize, (x) {
          final p = resized.getPixel(x, y);
          if (isUint8) return [p.r.toInt(), p.g.toInt(), p.b.toInt()];
          return [p.r.toInt() - 128, p.g.toInt() - 128, p.b.toInt() - 128];
        })));
      } else {
        input = List.generate(1, (_) => List.generate(dlSize, (y) => List.generate(dlSize, (x) {
          final p = resized.getPixel(x, y);
          return [p.r / 255.0, p.g / 255.0, p.b / 255.0];
        })));
      }

      final outShape = _deeplabInterpreter!.getOutputTensor(0).shape;
      final output   = List.generate(outShape[0], (_) => List.generate(outShape[1], (_) => List.generate(outShape[2], (_) => List.filled(outShape[3], 0.0))));
      _deeplabInterpreter!.run(input, output);

      final seg = List.generate(dlSize, (y) => List.generate(dlSize, (x) {
        final s = output[0][y][x];
        int best = 0; double bv = s[0];
        for (int c = 1; c < s.length; c++) { if (s[c] > bv) { bv = s[c]; best = c; } }
        return best;
      }));

      final cx1 = (dlSize * 0.25).round(); final cx2 = (dlSize * 0.75).round();
      final cy1 = (dlSize * 0.20).round(); final cy2 = (dlSize * 0.80).round();
      final counts = List.filled(21, 0);
      for (int y = cy1; y < cy2; y++) { for (int x = cx1; x < cx2; x++) counts[seg[y][x]]++; }
      counts[0] = 0;
      int subjClass = 0, maxCnt = 0;
      for (int c = 0; c < 21; c++) { if (counts[c] > maxCnt) { maxCnt = counts[c]; subjClass = c; } }

      if (maxCnt < 100) return const RuleResult(ruleName: 'Framing', score: 15, tip: 'No clear subject centre detected. Try shooting through a frame.', detected: true);

      final stripW = (dlSize * 0.18).round();
      final sides  = {
        'TOP'   : _mostCommonClass(seg, 0,          stripW,  cx1, cx2),
        'BOTTOM': _mostCommonClass(seg, dlSize-stripW, dlSize, cx1, cx2),
        'LEFT'  : _mostCommonClass(seg, cy1,          cy2,    0,   stripW),
        'RIGHT' : _mostCommonClass(seg, cy1,          cy2,    dlSize-stripW, dlSize),
      };

      final framingSides = sides.entries.where((e) => e.value != subjClass && e.value != 0).map((e) => e.key).toList();
      final n = framingSides.length;
      final score = n == 0 ? 0 : n == 1 ? 25 : n == 2 ? 55 : n == 3 ? 80 : 98;

      final _rng = Random();
      String tip;
      if (n >= 3) {
        tip = ["Excellent framing! Subject framed on \$n sides.", "Perfect natural frame.", "Beautifully framed by the environment."][_rng.nextInt(3)];
      } else if (n == 2) {
        final allSides = ['TOP', 'BOTTOM', 'LEFT', 'RIGHT'];
        final missingSide = allSides.firstWhere((s) => !framingSides.contains(s), orElse: () => 'opposite');
        tip = 'Add a framing element on the $missingSide side.';
      } else if (n == 1) tip = 'Weak framing. Try shooting through a doorway or archway.';
      else tip = 'No framing detected. Look for windows, trees, or arches.';

      return RuleResult(ruleName: 'Framing', score: score, tip: tip, detected: true);
    } catch (_) {
      return const RuleResult(ruleName: 'Framing', score: 20, tip: 'Look for natural frames like arches, windows, or branches.', detected: true);
    }
  }

  int _mostCommonClass(List<List<int>> seg, int y0, int y1, int x0, int x1) {
    final c = List.filled(21, 0);
    for (int y = y0; y < y1 && y < seg.length; y++) {
      for (int x = x0; x < x1 && x < seg[0].length; x++) c[seg[y][x]]++;
    }
    int best = 0, bv = 0;
    for (int i = 0; i < 21; i++) { if (c[i] > bv) { bv = c[i]; best = i; } }
    return best;
  }

  // ── RULE 6 — Perspective & Angle
  Future<({RuleResult result, List<List<double>>? depth})> _checkPerspective(img.Image image) async {
    if (_midasInterpreter == null) return (result: const RuleResult(ruleName: 'Perspective', score: 50, tip: 'EYE LEVEL — try a low or high angle.', detected: true), depth: null);
    try {
      const mdSize = 256;
      final resized = img.copyResize(image, width: mdSize, height: mdSize);
      final inputTensor = _midasInterpreter!.getInputTensor(0);
      final isInt8      = inputTensor.type == TfLiteType.kTfLiteInt8;
      
      final inputData = isInt8 ? Int8List(1 * mdSize * mdSize * 3) : Float32List(1 * mdSize * mdSize * 3);
      final data = inputData as List;
      int pIdx = 0;
      for (int y = 0; y < mdSize; y++) {
        for (int x = 0; x < mdSize; x++) {
          final p = resized.getPixel(x, y);
          if (isInt8) {
            data[pIdx++] = (p.r.toInt() - 128); data[pIdx++] = (p.g.toInt() - 128); data[pIdx++] = (p.b.toInt() - 128);
          } else {
            data[pIdx++] = p.r / 127.5 - 1.0; data[pIdx++] = p.g / 127.5 - 1.0; data[pIdx++] = p.b / 127.5 - 1.0;
          }
        }
      }

      final outShape = _midasInterpreter!.getOutputTensor(0).shape;
      final output   = [List.generate(outShape[1], (_) => List.filled(outShape[2], 0.0))];
      _midasInterpreter!.run(inputData, output);

      final flat   = output[0].expand((r) => r).toList();
      final dMin   = flat.reduce(min); final dMax   = flat.reduce(max);
      final dRange = (dMax - dMin).abs();
      if (dRange < 1e-4) return (result: const RuleResult(ruleName: 'Perspective', score: 50, tip: 'EYE LEVEL — flat depth.', detected: true), depth: null);

      final depth = List.generate(mdSize, (y) => List.generate(mdSize, (x) => (output[0][y][x] - dMin) / dRange));

      final z = mdSize ~/ 5;
      final zones = List.generate(5, (i) {
        double s = 0; int n = 0;
        for (int y = i*z; y < (i+1)*z; y++) { for (int x = 0; x < mdSize; x++) { s += depth[y][x]; n++; } }
        return s / n;
      });

      final topMean = (zones[0] + zones[1]) / 2;
      final bottomMean = (zones[3] + zones[4]) / 2;
      final overall = flat.map((v) => (v - dMin) / dRange).reduce((a, b) => a + b) / (mdSize * mdSize);
      final variance = flat.map((v) => pow((v - dMin) / dRange - overall, 2)).reduce((a, b) => a + b) / (mdSize * mdSize);
      final vertDiff = bottomMean - topMean;
      final vertRatio = vertDiff / overall;

      int skyCount = 0;
      for (int y = 0; y < mdSize ~/ 3; y++) {
        for (int x = 0; x < mdSize; x++) {
          final p = resized.getPixel(x, y);
          if (p.b > p.r + 15 && p.b > p.g && p.b > 90) skyCount++;
        }
      }
      final skyRatio = skyCount / (mdSize * mdSize / 3);
      final isOverhead = (skyRatio < 0.05 && variance < 0.04 && vertDiff.abs() < 0.25);

      String label, tip; int score;
      if (isOverhead) { label = 'HIGH ANGLE'; score = 75; tip = 'Camera pointing straight down — overhead shot.'; } 
      else if (vertRatio > 0.28 && vertDiff > 0.07 && (skyRatio > 0.04 || zones[4] > zones[0])) { label = 'LOW ANGLE'; score = (min(vertRatio / 0.55, 1.0) * 100).round(); tip = 'Excellent! Low angles create drama and dominance.'; } 
      else if (vertRatio < -0.28 && vertDiff.abs() > 0.07) { label = 'HIGH ANGLE'; score = (min(vertRatio.abs() / 0.55, 1.0) * 100).round(); tip = 'High angle works well for overview shots.'; } 
      else { label = 'EYE LEVEL'; score = (min(variance / 0.04, 1.0) * 45).round(); tip = 'Standard eye-level shot. Try crouching or raising the camera.'; }

      return (result: RuleResult(ruleName: 'Perspective', score: score.clamp(0, 100), tip: tip, detected: true), depth: depth);
    } catch (_) {
      return (result: const RuleResult(ruleName: 'Perspective', score: 50, tip: 'EYE LEVEL — neutrally balanced.', detected: true), depth: null);
    }
  }

  // ── NIMA
  Future<double> _getNimaScore(img.Image image) async {
    if (_nimaInterpreter == null) return 50.0;
    try {
      final resized = img.copyResize(image, width: 224, height: 224);
      final input   = List.generate(1, (_) => List.generate(224, (y) => List.generate(224, (x) {
          final p = resized.getPixel(x, y); return [p.r / 255.0, p.g / 255.0, p.b / 255.0];
        })));
      final output = [List.filled(10, 0.0)];
      _nimaInterpreter!.run(input, output);

      final raw  = output[0];
      final maxV = raw.reduce(max);
      final exps = raw.map((v) => exp(v - maxV)).toList();
      final sumE = exps.reduce((a, b) => a + b);
      final prob = exps.map((e) => e / sumE).toList();

      double mean = 0;
      for (int i = 0; i < 10; i++) mean += prob[i] * (i + 1);
      return ((mean - 4.0) / 3.5 * 100).clamp(0.0, 100.0);
    } catch (_) { return 50.0; }
  }

  CompositionResult _errorResult(String msg) {
    final e = RuleResult(ruleName: 'Error', score: -1, tip: msg, detected: false);
    return CompositionResult(ruleOfThirds: e, leadingLines: e, negativeSpace: e, symmetry: e, framing: e, perspective: e, overallScore: 0, nimaScore: 0, bestTip: msg, angleLabel: 'UNKNOWN', professionalSuggestion: msg);
  }

  void dispose() {
    _yolo.dispose();
    _deeplabInterpreter?.close();
    _midasInterpreter?.close();
    _nimaInterpreter?.close();
  }
}

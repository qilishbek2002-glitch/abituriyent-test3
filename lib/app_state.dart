import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:android_id/android_id.dart';
import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'activation.dart';
import 'config.dart';
import 'l10n.dart';
import 'models.dart';

enum ActivateResult { ok, bad, wrongDevice, expired }

enum AddKeyResult { ok, limit, duplicate, empty }

const String _kIdAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

/// Butun ilova holati (til, mavzu, kalitlar, obuna, kitoblar, testlar, natijalar).
final AppState app = AppState();

String subjectName(String id) => tr('subject_$id');

class AppState extends ChangeNotifier {
  late SharedPreferences _p;

  String lang = 'uz';
  bool langChosen = false;
  bool keysOnboarded = false;
  ThemeMode themeMode = ThemeMode.system;
  List<AiKey> keys = [];
  String deviceId = '';

  /// Obuna: tugash sanasi (YYYYMMDD, Toshkent vaqti bo'yicha shu kun oxirigacha) va tarif kunlari.
  String expiryYmd = '';
  int planDays = 0;
  String lastActivatedExpiry = '';

  /// Serverdan olingan eng so'nggi vaqt: soatni orqaga surib aldashga yo'l qo'ymaydi.
  int serverFloor = 0;
  int trialLeft = kFreeTests;

  List<PersonalBook> personalBooks = [];
  List<SavedTest> tests = [];
  List<Attempt> attempts = [];
  Map<String, String> subjectImages = {};
  List<String> pdfAssets = [];

  Future<void> init() async {
    _p = await SharedPreferences.getInstance();

    final savedLang = _p.getString('lang');
    langChosen = savedLang != null;
    lang = savedLang ?? 'uz';
    currentLang = lang;

    switch (_p.getString('theme')) {
      case 'light':
        themeMode = ThemeMode.light;
        break;
      case 'dark':
        themeMode = ThemeMode.dark;
        break;
      default:
        themeMode = ThemeMode.system;
    }

    // Kalitlar (eski versiyadagi bitta 'apiKey' ni ko'chiramiz).
    try {
      final raw = _p.getString('keys');
      if (raw != null) {
        keys = (jsonDecode(raw) as List)
            .map((e) => AiKey.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
      }
    } catch (_) {
      keys = [];
    }
    final legacy = _p.getString('apiKey') ?? '';
    if (keys.isEmpty && legacy.isNotEmpty) {
      keys = [AiKey(id: _newId(), provider: AiProviderType.gemini, key: legacy)];
      await _saveKeys();
      await _p.setBool('onboarded', true);
    }
    keysOnboarded = _p.getBool('onboarded') ?? false;

    deviceId = await _resolveDeviceId();

    expiryYmd = _p.getString('expiryYmd') ?? '';
    planDays = _p.getInt('planDays') ?? 0;
    lastActivatedExpiry = '';
    serverFloor = _p.getInt('serverFloor') ?? 0;
    trialLeft = _p.getInt('trialLeft') ?? kFreeTests;

    try {
      final raw = _p.getString('personal');
      if (raw != null) {
        personalBooks = (jsonDecode(raw) as List)
            .map((e) => PersonalBook.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
      }
    } catch (_) {
      personalBooks = [];
    }

    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final all = manifest.listAssets();
      pdfAssets = all
          .where((a) =>
              a.startsWith('assets/books/') && a.toLowerCase().endsWith('.pdf'))
          .toList()
        ..sort();
      final ids = <String>[...kSubjects.map((s) => s.id), 'personal'];
      for (final id in ids) {
        for (final ext in const ['png', 'jpg', 'jpeg', 'webp']) {
          final path = 'assets/subjects/$id.$ext';
          if (all.contains(path)) {
            subjectImages[id] = path;
            break;
          }
        }
      }
    } catch (_) {}

    await _loadTests();
    await _loadAttempts();
  }

  // ---------------- qurilma ID ----------------

  /// Barqaror ID: Android ID dan hosil qilinadi (ilovani o'chirib qayta o'rnatsa ham o'zgarmaydi,
  /// agar ilova doim bir xil kalit bilan imzolangan bo'lsa). Olinmasa tasodifiy ID saqlanadi.
  Future<String> _resolveDeviceId() async {
    try {
      final aid = await AndroidId().getId();
      if (aid != null && aid.isNotEmpty) {
        final bytes = sha256.convert(utf8.encode('abt|$aid')).bytes;
        final id = [
          for (var i = 0; i < 8; i++) _kIdAlphabet[bytes[i] % _kIdAlphabet.length]
        ].join();
        await _p.setString('deviceId', id);
        return id;
      }
    } catch (_) {}
    var id = _p.getString('deviceId') ?? '';
    if (!RegExp(r'^[A-HJ-NP-Z2-9]{8}$').hasMatch(id)) {
      final r = Random.secure();
      id = List.generate(8, (_) => _kIdAlphabet[r.nextInt(_kIdAlphabet.length)])
          .join();
      await _p.setString('deviceId', id);
    }
    return id;
  }

  // ---------------- vaqt va obuna ----------------

  int get nowMs => max(DateTime.now().millisecondsSinceEpoch, serverFloor);

  /// Obuna tugash vaqti (millisekund): tugash sanasi kunining oxiri, Toshkent vaqti (UTC+5).
  int get expiresAt {
    if (expiryYmd.length != 8) return 0;
    final y = int.tryParse(expiryYmd.substring(0, 4));
    final m = int.tryParse(expiryYmd.substring(4, 6));
    final d = int.tryParse(expiryYmd.substring(6, 8));
    if (y == null || m == null || d == null) return 0;
    return DateTime.utc(y, m, d + 1).millisecondsSinceEpoch - 5 * 3600000;
  }

  bool get subscribed => expiresAt > nowMs;

  /// Obuna tugash kunigacha qolgan kalendar kunlar (Toshkent vaqti). Tugash kunining o'zida 0.
  /// Yangi 365 kunlik kod olingan kuni 365 ko'rinadi.
  int get daysLeft {
    if (expiryYmd.length != 8) return 0;
    final y = int.tryParse(expiryYmd.substring(0, 4));
    final m = int.tryParse(expiryYmd.substring(4, 6));
    final d = int.tryParse(expiryYmd.substring(6, 8));
    if (y == null || m == null || d == null) return 0;
    final t = DateTime.fromMillisecondsSinceEpoch(nowMs, isUtc: true)
        .add(const Duration(hours: 5));
    final diff = DateTime.utc(y, m, d)
        .difference(DateTime.utc(t.year, t.month, t.day))
        .inDays;
    return diff < 0 ? 0 : diff;
  }

  /// Obuna tugagan kuni (UI uchun, DD.MM.YYYY).
  String get expiryLabel {
    if (expiryYmd.length != 8) return '';
    return '${expiryYmd.substring(6, 8)}.${expiryYmd.substring(4, 6)}.${expiryYmd.substring(0, 4)}';
  }

  /// Obunada 0..1 qolgan ulush (progress chizig'i uchun).
  double get planFraction {
    if (planDays <= 0) return 0;
    final f = daysLeft / planDays;
    return f < 0 ? 0 : (f > 1 ? 1 : f);
  }

  bool get hasKeys => keys.isNotEmpty;

  bool get canGenerate => !kSubscriptionRequired || subscribed || trialLeft > 0;

  /// Bepul rejimda faqat [kFreeQuestions] talik testlar ruxsat etiladi.
  bool get freeOnly => kSubscriptionRequired && !subscribed;

  /// Serverdan haqiqiy vaqtni olib, soat orqaga surilganini aniqlaydi. Xato bo'lsa jim o'tadi.
  Future<void> syncServerTime() async {
    HttpClient? c;
    try {
      c = HttpClient()..connectionTimeout = const Duration(seconds: 6);
      final req = await c
          .getUrl(Uri.parse('https://www.google.com/generate_204'))
          .timeout(const Duration(seconds: 8));
      final res = await req.close().timeout(const Duration(seconds: 8));
      final h = res.headers.value('date');
      await res.drain<void>();
      if (h != null) {
        final ms = HttpDate.parse(h).millisecondsSinceEpoch;
        if (ms > serverFloor) {
          serverFloor = ms;
          await _p.setInt('serverFloor', ms);
          notifyListeners();
        }
      }
    } catch (_) {
    } finally {
      c?.close(force: true);
    }
  }

  Future<ActivateResult> activate(String raw) async {
    final r = parseCode(raw, deviceId);
    if (r.status == CodeStatus.badFormat || r.status == CodeStatus.badSignature) {
      return ActivateResult.bad;
    }
    if (r.status == CodeStatus.wrongDevice) return ActivateResult.wrongDevice;

    await syncServerTime();
    final prevYmd = expiryYmd;
    final prevPlan = planDays;
    expiryYmd = r.expiry;
    if (expiresAt <= nowMs) {
      expiryYmd = prevYmd;
      planDays = prevPlan;
      return ActivateResult.expired;
    }
    // Yangi kod eskisidan keyinroq tugasa almashtiramiz; aks holda eskisi qoladi.
    if (prevYmd.compareTo(r.expiry) > 0) {
      expiryYmd = prevYmd;
      planDays = prevPlan;
    } else {
      planDays = r.days;
    }
    lastActivatedExpiry = expiryLabel;
    await _p.setString('expiryYmd', expiryYmd);
    await _p.setInt('planDays', planDays);
    notifyListeners();
    return ActivateResult.ok;
  }

  Future<void> consumeTrial() async {
    if (!subscribed && trialLeft > 0) {
      trialLeft -= 1;
      await _p.setInt('trialLeft', trialLeft);
      notifyListeners();
    }
  }

  // ---------------- til, mavzu, kalitlar ----------------

  Future<void> setLang(String l) async {
    lang = l;
    langChosen = true;
    currentLang = l;
    await _p.setString('lang', l);
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode m) async {
    themeMode = m;
    await _p.setString(
        'theme', m == ThemeMode.light ? 'light' : (m == ThemeMode.dark ? 'dark' : 'system'));
    notifyListeners();
  }

  Future<void> finishKeyOnboarding() async {
    keysOnboarded = true;
    await _p.setBool('onboarded', true);
    notifyListeners();
  }

  Future<AddKeyResult> addKey(AiProviderType provider, String raw) async {
    final key = raw.trim();
    if (key.isEmpty) return AddKeyResult.empty;
    if (keys.length >= kMaxKeys) return AddKeyResult.limit;
    if (keys.any((k) => k.key == key)) return AddKeyResult.duplicate;
    keys = [...keys, AiKey(id: _newId(), provider: provider, key: key)];
    await _saveKeys();
    notifyListeners();
    return AddKeyResult.ok;
  }

  Future<void> removeKey(String id) async {
    keys = keys.where((k) => k.id != id).toList();
    await _saveKeys();
    notifyListeners();
  }

  Future<void> _saveKeys() async {
    await _p.setString('keys', jsonEncode(keys.map((k) => k.toJson()).toList()));
  }

  String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch}${Random().nextInt(9999)}';

  // ---------------- kitoblar ----------------

  List<Book> assetBooks(String subjectId, String kind) {
    final prefix = 'assets/books/$subjectId/$kind/';
    return pdfAssets
        .where((a) => a.startsWith(prefix))
        .map((a) => Book(
              id: a,
              title: _titleFromPath(a),
              assetPath: a,
              subjectId: subjectId,
            ))
        .toList();
  }

  int assetBookCount(String subjectId, String kind) =>
      assetBooks(subjectId, kind).length;

  String _titleFromPath(String p) {
    var name = p.split('/').last;
    try {
      name = Uri.decodeComponent(name);
    } catch (_) {}
    if (name.toLowerCase().endsWith('.pdf')) {
      name = name.substring(0, name.length - 4);
    }
    return name.replaceAll('_', ' ').trim();
  }

  /// Foydalanuvchi qo'shgan kitoblar: [subjectId] null = "Shaxsiy kitob" bo'limi.
  List<PersonalBook> userBooks(String? subjectId, String? kind) {
    return personalBooks
        .where((b) =>
            b.subjectId == subjectId && (subjectId == null || b.kind == kind))
        .toList();
  }

  int bookCount(String subjectId, String kind) =>
      assetBookCount(subjectId, kind) + userBooks(subjectId, kind).length;

  Future<void> addPersonalBook(XFile file,
      {String? subjectId, String? kind}) async {
    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory('${dir.path}/personal');
    if (!await folder.exists()) {
      await folder.create(recursive: true);
    }
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final dest = '${folder.path}/$id.pdf';
    final bytes = await file.readAsBytes();
    await File(dest).writeAsBytes(bytes, flush: true);

    var title = file.name;
    if (title.toLowerCase().endsWith('.pdf')) {
      title = title.substring(0, title.length - 4);
    }
    if (title.trim().isEmpty) title = 'PDF';
    personalBooks = [
      PersonalBook(
        id: id,
        title: title,
        path: dest,
        subjectId: subjectId,
        kind: kind,
      ),
      ...personalBooks,
    ];
    await _savePersonal();
    notifyListeners();
  }

  Future<void> removePersonalBook(String id) async {
    final matches = personalBooks.where((b) => b.id == id).toList();
    for (final b in matches) {
      try {
        final f = File(b.path);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    personalBooks = personalBooks.where((b) => b.id != id).toList();
    await _savePersonal();
    notifyListeners();
  }

  Future<void> _savePersonal() async {
    await _p.setString(
        'personal', jsonEncode(personalBooks.map((b) => b.toJson()).toList()));
  }

  // ---------------- saqlangan testlar ----------------

  Future<File> _testsFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/tests.json');
  }

  Future<void> _loadTests() async {
    try {
      final f = await _testsFile();
      if (await f.exists()) {
        final raw = await f.readAsString();
        tests = (jsonDecode(raw) as List)
            .map((e) => SavedTest.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
      }
    } catch (_) {
      tests = [];
    }
  }

  Future<void> _saveTests() async {
    try {
      final f = await _testsFile();
      await f.writeAsString(jsonEncode(tests.map((t) => t.toJson()).toList()));
    } catch (_) {}
  }

  Future<void> addTest(SavedTest t) async {
    tests = [t, ...tests];
    if (tests.length > 40) tests = tests.sublist(0, 40);
    await _saveTests();
    notifyListeners();
  }

  Future<void> deleteTest(String id) async {
    tests = tests.where((t) => t.id != id).toList();
    await _saveTests();
    notifyListeners();
  }

  Future<void> recordAttempt({
    required String testId,
    required String title,
    required String? subjectId,
    required int total,
    required int correct,
    required int seconds,
  }) async {
    final percent = total == 0 ? 0 : (correct * 100 / total).round();
    for (final t in tests) {
      if (t.id == testId) {
        t.attempts += 1;
        if (percent > t.bestPercent) t.bestPercent = percent;
      }
    }
    attempts = [
      ...attempts,
      Attempt(
        t: nowMs,
        testId: testId,
        title: title,
        subjectId: subjectId,
        total: total,
        correct: correct,
        seconds: seconds,
      ),
    ];
    if (attempts.length > 3000) attempts = attempts.sublist(attempts.length - 3000);
    await _saveTests();
    await _saveAttempts();
    notifyListeners();
  }

  // ---------------- oylik natijalar ----------------

  List<Attempt> attemptsIn(int year, int month) {
    return attempts.where((a) {
      final d = DateTime.fromMillisecondsSinceEpoch(a.t);
      return d.year == year && d.month == month;
    }).toList();
  }

  Future<File> _attemptsFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/attempts.json');
  }

  Future<void> _loadAttempts() async {
    try {
      final f = await _attemptsFile();
      if (await f.exists()) {
        attempts = (jsonDecode(await f.readAsString()) as List)
            .map((e) => Attempt.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
      }
    } catch (_) {
      attempts = [];
    }
  }

  Future<void> _saveAttempts() async {
    try {
      final f = await _attemptsFile();
      await f.writeAsString(jsonEncode(attempts.map((a) => a.toJson()).toList()));
    } catch (_) {}
  }
}

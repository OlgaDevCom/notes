// lib/screen_gen.dart — read by MaterialApp(locale: screenGenLocale(), …)
// and by whatever builds the app's initial data.
import 'package:flutter/widgets.dart';

const _locale = String.fromEnvironment('SCREEN_GEN_LOCALE');

/// True only in a Screen Gen run: show demo content instead of a real account.
const screenGenDemo = bool.fromEnvironment('SCREEN_GEN_DEMO');

/// The store locale Screen Gen asked for (`uk`, `en-US`, `zh-Hans`), or null
/// in a normal run so the app keeps following the device language.
Locale? screenGenLocale() {
  if (_locale.isEmpty) return null;
  final parts = _locale.split('-');
  if (parts.length == 1) return Locale(parts[0]);
  // A four-letter subtag is a script (zh-Hans), anything else a region (en-US).
  return parts[1].length == 4
      ? Locale.fromSubtags(languageCode: parts[0], scriptCode: parts[1])
      : Locale(parts[0], parts[1]);
}

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/settings_service.dart';

import '../test_helpers/prefs.dart';

void main() {
  setUp(() => resetSharedPreferencesForTest());

  test('subtitle preference defaults to no override', () async {
    final settings = await SettingsService.getInstance();
    expect(settings.read(SettingsService.subtitlePreferenceOverride), SubtitlePreferenceOverride.off);
  });

  test('subtitle preference survives reinitialization for each option', () async {
    var settings = await SettingsService.getInstance();
    for (final value in SubtitlePreferenceOverride.values) {
      await settings.write(SettingsService.subtitlePreferenceOverride, value);
      SettingsService.resetForTesting();
      settings = await SettingsService.getInstance();
      expect(settings.read(SettingsService.subtitlePreferenceOverride), value);
    }
  });

  test('unknown persisted subtitle preference safely disables the override', () async {
    final settings = await SettingsService.getInstance();
    await settings.writeString(SettingsService.subtitlePreferenceOverride.key, 'unknown');
    expect(settings.read(SettingsService.subtitlePreferenceOverride), SubtitlePreferenceOverride.off);
  });
}

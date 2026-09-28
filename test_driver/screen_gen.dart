// Runs on the CI host and writes every screenshot the test takes into
// SCREEN_GEN_OUT, which screen-gen-capture.sh sets per locale and device.
import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() {
  final out = Platform.environment['SCREEN_GEN_OUT'] ?? 'screen-gen/local';
  return integrationDriver(
    onScreenshot:
        (String name, List<int> bytes, [Map<String, Object?>? args]) async {
          final file = File('$out/$name.png');
          await file.create(recursive: true);
          await file.writeAsBytes(bytes);
          return true;
        },
  );
}

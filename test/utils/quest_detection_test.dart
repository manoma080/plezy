import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/utils/platform_detector.dart';

void main() {
  test('Quest detection requires explicit headset evidence', () {
    bool detect(String maker, String model, [List<String> features = const []]) =>
        detectAndroidQuest(features: features, manufacturer: maker, model: model);
    expect(detect('Meta', 'Quest 3'), isTrue);
    expect(detect('Oculus', 'Pacific'), isTrue);
    expect(detect('', '', ['oculus.software.handtracking']), isTrue);
    expect(detect('Meta', 'phone'), isFalse);
    expect(detect('Samsung', 'Quest'), isFalse);
    expect(detect('', ''), isFalse);
  });
}

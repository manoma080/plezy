# Equalizer playback mock

Build the isolated debug app with `PLEZY_EQUALIZER_MOCK=1 flutter build apk --debug -t lib/equalizer_mock.dart`. Its application ID defaults to `com.edde746.plezy.equalizermock`; set `PLEZY_EQUALIZER_MOCK_ID` to a separate valid application ID when an existing installation uses a different signing key. Do not uninstall an existing app to work around a signing mismatch.

The mock uses the normal Android hardware-decoding preference (`mediacodec,mediacodec-copy`), and logs `MOCK_ROUTE` with `hwdec-current`, `current-vo`, and `pause` after opening, toggling pause, and completing a slider change. These properties show the selected mpv path, not proof of physical hardware acceleration or visible pixels. For a diagnostic copy-back comparison, build with `--dart-define=MOCK_HWDEC=mediacodec-copy`; this is not the production configuration.

`assets/equalizer-sample.mp4` is the previous colorful sample transcoded to H.264 using FFmpeg's `libopenh264`; the existing Android instrumentation H.264 fixture is black and cannot show color changes. Pause the same frame, capture neutral, change one filter, capture, return to zero, and capture again. Verify the video itself is visible before interpreting pixel comparisons. A black screen or an unchanged screenshot alone does not establish that the filter worked.

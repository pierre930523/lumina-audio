import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/audio_output_info.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/ffi_audio_service.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/ui/zones/output_zone_panel.dart';
import 'package:material_ui/material_ui.dart';

class _TestOutputMockAudioService extends MockAudioService {
  List<AudioDeviceCapabilitiesModel> scriptedCaps;
  String? scriptedSelectError;
  bool failNextSelect = false;
  int selectCalls = 0;
  String? lastSelectedDeviceId;
  int lastSelectedBackendIndex = -1;
  bool forceSharedActive = false;

  _TestOutputMockAudioService({required this.scriptedCaps});

  @override
  Future<List<AudioDeviceCapabilitiesModel>> listDeviceCapabilities() async =>
      List<AudioDeviceCapabilitiesModel>.from(scriptedCaps);

  @override
  Future<List<AudioDeviceInfo>> listAudioDevices() async {
    return scriptedCaps
        .map(
          (c) => AudioDeviceInfo(
            id: c.deviceId,
            name: c.name,
            backend: c.backend,
            isDefault: c.isDefault,
            isExclusive: c.isExclusive,
            supportedSampleRates: c.supportedSampleRates,
          ),
        )
        .toList();
  }

  @override
  String? get lastError => scriptedSelectError;

  @override
  Future<void> selectAudioDevice(
    String? deviceId, {
    int backendIndex = -1,
  }) async {
    selectCalls += 1;
    lastSelectedDeviceId = deviceId;
    lastSelectedBackendIndex = backendIndex;
    if (failNextSelect) {
      failNextSelect = false;
      scriptedSelectError =
          'WASAPI exclusive activation failed: AUDCLNT_E_DEVICE_IN_USE (0x8889000A)';
      return;
    }
    scriptedSelectError = null;
    forceSharedActive =
        backendIndex == 2 || (deviceId?.startsWith('wasapi-shared::') ?? false);
    if (forceSharedActive && isStrictBitPerfect) {
      await setStrictBitPerfect(false);
    }
    await super.selectAudioDevice(deviceId, backendIndex: backendIndex);
  }

  @override
  Future<AudioEngineOutputInfoModel> getOutputInfo() async {
    final base = await super.getOutputInfo();
    final activeCap = isSystemOutputActive
        ? (scriptedCaps
                .where(
                  (c) =>
                      c.isOsDefault &&
                      (isStrictBitPerfect ? !c.isSharedMode : c.isSharedMode),
                )
                .firstOrNull ??
            scriptedCaps.where((c) => c.isOsDefault).firstOrNull)
        : scriptedCaps.where((c) => c.deviceId == activeDeviceId).firstOrNull;
    final isShared = activeCap?.isSharedMode ?? forceSharedActive;
    if (isShared) {
      return AudioEngineOutputInfoModel(
        source: base.source,
        decoder: base.decoder,
        output: AudioOutputInfoModel(
          selectedDevice: activeCap?.name ?? base.output.selectedDevice,
          transportKind: '喇叭',
          audioApi: 'WindowsWasapiShared',
          outputMode: 'WASAPI Shared',
          sampleRateHz: 48000,
          containerBits: 32,
          validBits: 32,
          channels: 2,
          bufferSizeFrames: 480,
          dspStatus: 'Enabled',
          softwareVolumeStatus: 'Active Attenuated',
          strictMode: false,
          hardwareVolumeRecommended: false,
        ),
        verification: const AudioVerificationInfoModel(
          pcmSampleCheck: 'MODIFIED (Windows Shared Mixer)',
          sampleHashMatch: false,
          formatMatch: false,
          outputPath: 'FLAC -> WASAPI Shared',
          status: 'NOT BIT-PERFECT',
        ),
      );
    }
    return AudioEngineOutputInfoModel(
      source: base.source,
      decoder: base.decoder,
      output: AudioOutputInfoModel(
        selectedDevice: activeCap?.name ?? base.output.selectedDevice,
        transportKind: activeCap?.transport ?? base.output.transportKind,
        audioApi: activeCap?.backend ?? base.output.audioApi,
        outputMode: activeCap?.interfaceLabel ?? base.output.outputMode,
        sampleRateHz: base.output.sampleRateHz,
        containerBits: base.output.containerBits,
        validBits: base.output.validBits,
        channels: base.output.channels,
        bufferSizeFrames: preferredBufferFrames,
        dspStatus: isStrictBitPerfect ? 'Bypassed' : base.output.dspStatus,
        softwareVolumeStatus: isStrictBitPerfect
            ? 'Disabled (Unity 1.0x)'
            : base.output.softwareVolumeStatus,
        strictMode: isStrictBitPerfect,
        hardwareVolumeRecommended: isStrictBitPerfect,
      ),
      verification: AudioVerificationInfoModel(
        pcmSampleCheck: isStrictBitPerfect
            ? 'PASS (SHA-256 Match)'
            : 'Not Verified',
        sampleHashMatch: isStrictBitPerfect,
        formatMatch: isStrictBitPerfect,
        outputPath: activeCap?.interfaceLabel ?? 'Idle',
        status: isStrictBitPerfect ? 'BIT-PERFECT' : 'NOT VERIFIED',
      ),
    );
  }
}

List<AudioDeviceCapabilitiesModel> _sampleHardwareMatrix() => const [
  AudioDeviceCapabilitiesModel(
    deviceId: 'usb-dac-1',
    name: 'FiiO Q series USB DAC',
    backend: 'windows_wasapi_exclusive',
    transport: 'usb_dac',
    isDefault: true,
    isOsDefault: true,
    isExclusive: true,
    hardwareSupportsExclusive: true,
    supportedSampleRates: [44100, 48000, 88200, 96000, 176400, 192000, 384000],
    supportedBitDepths: [16, 24, 32],
    supportedContainerBits: [16, 32],
    supportedChannels: [2],
    supportedOutputModes: ['wasapi_exclusive', 'dop_over_wasapi_exclusive'],
    supportsDop: true,
    exclusiveAvailable: true,
    bufferSizeSupported: true,
    minBufferFrames: 128,
    maxBufferFrames: 2048,
    defaultBufferFrames: 512,
  ),
  AudioDeviceCapabilitiesModel(
    deviceId: 'wasapi-shared::usb-dac-1',
    name: 'FiiO Q series USB DAC',
    backend: 'windows_wasapi_shared',
    transport: 'usb_dac',
    isDefault: false,
    isOsDefault: true,
    isExclusive: false,
    hardwareSupportsExclusive: true,
    supportedSampleRates: [48000],
    supportedBitDepths: [32],
    supportedContainerBits: [32],
    supportedChannels: [2],
    supportedOutputModes: ['wasapi_shared', 'dsd_to_pcm'],
    supportsFloat32: true,
    exclusiveAvailable: false,
    bufferSizeSupported: false,
    probeNote: 'Windows Shared Mixer (48000 Hz)',
  ),
  AudioDeviceCapabilitiesModel(
    deviceId: 'asio::asio://FiiO ASIO Driver',
    name: 'FiiO ASIO Driver (ASIO)',
    backend: 'windows_asio',
    transport: 'asio',
    isDefault: false,
    isExclusive: true,
    hardwareSupportsExclusive: true,
    supportedSampleRates: [44100, 48000, 96000, 192000, 384000, 2822400],
    supportedBitDepths: [16, 24, 32],
    supportedContainerBits: [16, 24, 32],
    supportedChannels: [2],
    supportedOutputModes: ['asio_pcm', 'asio_native_dsd', 'dop_over_asio'],
    supportsNativeDsd: true,
    supportsDop: true,
    maxDsdRate: 'Dsd256',
    asioAvailable: true,
    asioDriverName: 'FiiO ASIO Driver',
    exclusiveAvailable: true,
    bufferSizeSupported: true,
    minBufferFrames: 64,
    maxBufferFrames: 2048,
    defaultBufferFrames: 256,
  ),
  AudioDeviceCapabilitiesModel(
    deviceId: 'wasapi-shared::hdmi-1',
    name: 'PHL 275M8RZ (NVIDIA High Definition Audio)',
    backend: 'windows_wasapi_shared',
    transport: 'internal',
    isHdmi: true,
    isDefault: false,
    isExclusive: false,
    hardwareSupportsExclusive: false,
    supportedSampleRates: [48000],
    supportedBitDepths: [16],
    supportedContainerBits: [16],
    supportedChannels: [2],
    supportedOutputModes: ['wasapi_shared'],
    exclusiveAvailable: false,
    bufferSizeSupported: false,
  ),
  AudioDeviceCapabilitiesModel(
    deviceId: 'wasapi-shared::bt-1',
    name: 'WH-1000XM5 Headphones',
    backend: 'windows_wasapi_shared',
    transport: 'headphones',
    isDefault: false,
    isExclusive: false,
    hardwareSupportsExclusive: false,
    supportedSampleRates: [48000],
    supportedBitDepths: [16],
    supportedContainerBits: [32],
    supportedChannels: [2],
    supportedOutputModes: ['wasapi_shared'],
    exclusiveAvailable: false,
    bufferSizeSupported: false,
    probeNote: 'Bluetooth wireless audio',
  ),
  AudioDeviceCapabilitiesModel(
    deviceId: 'wasapi-shared::spk-1',
    name: 'Realtek Speakers',
    backend: 'windows_wasapi_shared',
    transport: 'speakers',
    isDefault: false,
    isExclusive: false,
    hardwareSupportsExclusive: false,
    supportedSampleRates: [48000],
    supportedBitDepths: [32],
    supportedContainerBits: [32],
    supportedChannels: [2],
    supportedOutputModes: ['wasapi_shared'],
    exclusiveAvailable: false,
    bufferSizeSupported: false,
  ),
];

void main() {
  testWidgets(
    'Responsive card grid: 2 columns wide, 1 column narrow, zero overflow at 100% and 150% scale',
    (tester) async {
      final svc = _TestOutputMockAudioService(
        scriptedCaps: _sampleHardwareMatrix(),
      );
      addTearDown(svc.dispose);

      // 1. Wide desktop (1000x800) -> 2 columns
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(24),
              child: OutputZonePanel(audioService: svc),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final sysRect = tester.getRect(
        find.byKey(const Key('output_card_system_output')),
      );
      final exclRect = tester.getRect(
        find.byKey(const Key('output_card_usb-dac-1__windows_wasapi_exclusive')),
      );
      // Side by side in 2-column row
      expect(sysRect.top, closeTo(exclRect.top, 0.5));
      expect(exclRect.left, greaterThan(sysRect.right));
      expect(sysRect.height, closeTo(exclRect.height, 0.5));

      // 2. Narrow width (420x800) -> 1 column
      tester.view.physicalSize = const Size(420, 800);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final sysNarrow = tester.getRect(
        find.byKey(const Key('output_card_system_output')),
      );
      final exclNarrow = tester.getRect(
        find.byKey(const Key('output_card_usb-dac-1__windows_wasapi_exclusive')),
      );
      expect(exclNarrow.top, greaterThan(sysNarrow.bottom));
      expect(exclNarrow.left, closeTo(sysNarrow.left, 1.0));

      // 3. 150% text/UI scale at medium width (660x800) -> zero RenderFlex overflow
      tester.view.physicalSize = const Size(660, 800);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
            child: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: OutputZonePanel(audioService: svc),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Card states, separate WASAPI Shared/Exclusive/ASIO cards, icons, deduplication & error handling',
    (tester) async {
      // Inject an intentional duplicate entry to verify strict deduplication
      final dupMatrix = [..._sampleHardwareMatrix(), _sampleHardwareMatrix()[1]];
      final svc = _TestOutputMockAudioService(scriptedCaps: dupMatrix);
      await svc.selectAudioDevice('usb-dac-1', backendIndex: 1);
      addTearDown(svc.dispose);

      tester.view.physicalSize = const Size(1100, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: OutputZonePanel(audioService: svc)),
        ),
      );
      await tester.pumpAndSettle();

      // Separate cards for Exclusive vs Shared vs ASIO (and no duplicate Shared card!)
      expect(
        find.byKey(const Key('output_card_usb-dac-1__windows_wasapi_exclusive')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('output_card_wasapi-shared::usb-dac-1__windows_wasapi_shared'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('output_card_asio::asio://FiiO ASIO Driver__windows_asio'),
        ),
        findsOneWidget,
      );

      // Distinct interface subtitles
      expect(find.text('WASAPI Exclusive'), findsOneWidget);
      expect(find.text('WASAPI Shared'), findsNWidgets(4));
      expect(find.text('ASIO'), findsOneWidget);

      // Icons for USB DAC, HDMI, Headphones, Speakers, ASIO, System Output
      expect(find.byIcon(Icons.desktop_windows_rounded), findsOneWidget);
      expect(find.byIcon(Icons.usb_rounded), findsNWidgets(2));
      expect(find.byIcon(Icons.settings_input_hdmi_rounded), findsOneWidget);
      expect(find.byIcon(Icons.headphones_rounded), findsOneWidget);
      expect(find.byIcon(Icons.speaker_rounded), findsOneWidget);
      expect(find.byIcon(Icons.tune_rounded), findsOneWidget);

      // Active card shows brighter solid grey background + gear button (no '啟用')
      final activeCardContainer = tester.widget<Container>(
        find.byKey(const Key('output_card_usb-dac-1__windows_wasapi_exclusive')),
      );
      final activeDec = activeCardContainer.decoration as BoxDecoration;
      expect(activeDec.color, const Color(0xFF2E323C));
      expect(
        find.byKey(
          const Key('btn_device_settings_usb-dac-1__windows_wasapi_exclusive'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('btn_activate_device_usb-dac-1__windows_wasapi_exclusive'),
        ),
        findsNothing,
      );

      // Inactive card shows dark background + subtle grey border + purple '啟用' button
      final inactiveCardContainer = tester.widget<Container>(
        find.byKey(
          const Key('output_card_wasapi-shared::usb-dac-1__windows_wasapi_shared'),
        ),
      );
      final inactiveDec = inactiveCardContainer.decoration as BoxDecoration;
      expect(inactiveDec.color, const Color(0xFF191B21));
      expect(
        find.byKey(
          const Key(
            'btn_activate_device_wasapi-shared::usb-dac-1__windows_wasapi_shared',
          ),
        ),
        findsOneWidget,
      );

      // Activation failure surfaces exact error & NEVER fakes active switch!
      svc.failNextSelect = true;
      final sharedActivateBtn = find.byKey(
        const Key(
          'btn_activate_device_wasapi-shared::usb-dac-1__windows_wasapi_shared',
        ),
      );
      await tester.ensureVisible(sharedActivateBtn);
      await tester.tap(sharedActivateBtn);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('output_device_error_banner')),
        findsOneWidget,
      );
      expect(find.textContaining('AUDCLNT_E_DEVICE_IN_USE'), findsOneWidget);
      // Original active card must STILL be active!
      expect(
        find.byKey(
          const Key('btn_device_settings_usb-dac-1__windows_wasapi_exclusive'),
        ),
        findsOneWidget,
      );

      // Successful activation of ASIO card
      final asioActivateBtn = find.byKey(
        const Key(
          'btn_activate_device_asio::asio://FiiO ASIO Driver__windows_asio',
        ),
      );
      await tester.ensureVisible(asioActivateBtn);
      await tester.tap(asioActivateBtn);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('output_device_error_banner')), findsNothing);
      expect(svc.lastSelectedBackendIndex, 0);
      expect(
        find.byKey(
          const Key(
            'btn_device_settings_asio::asio://FiiO ASIO Driver__windows_asio',
          ),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'System Output dynamic OS default update & Hot-plug unplug/replug refresh',
    (tester) async {
      final svc = _TestOutputMockAudioService(
        scriptedCaps: _sampleHardwareMatrix(),
      );
      await svc.selectAudioDevice(null);
      addTearDown(svc.dispose);

      tester.view.physicalSize = const Size(1100, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: OutputZonePanel(audioService: svc)),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('btn_device_settings_system_output')),
        findsOneWidget,
      );
      expect(
        find.textContaining('跟隨 Windows 預設 · FiiO Q series USB DAC'),
        findsOneWidget,
      );

      // Simulate hot-plug unplug of USB DAC & OS default changing to Realtek Speakers
      svc.scriptedCaps = [
        AudioDeviceCapabilitiesModel(
          deviceId: 'wasapi-shared::spk-1',
          name: 'Realtek Speakers',
          backend: 'windows_wasapi_shared',
          transport: 'speakers',
          isDefault: true,
          isOsDefault: true,
          isExclusive: false,
          hardwareSupportsExclusive: false,
          supportedSampleRates: const [48000],
          supportedBitDepths: const [32],
          supportedContainerBits: const [32],
          supportedChannels: const [2],
          supportedOutputModes: const ['wasapi_shared'],
          exclusiveAvailable: false,
          bufferSizeSupported: false,
        ),
      ];

      await tester.tap(find.byKey(const Key('btn_refresh_audio_devices')));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('跟隨 Windows 預設 · Realtek Speakers'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('output_card_usb-dac-1__windows_wasapi_exclusive')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'System Output card and settings reflect WindowsWasapiExclusive when engine uses Exclusive',
    (tester) async {
      final svc = _TestOutputMockAudioService(
        scriptedCaps: _sampleHardwareMatrix(),
      );
      await svc.selectAudioDevice(null);
      await svc.setStrictBitPerfect(true);
      addTearDown(svc.dispose);

      tester.view.physicalSize = const Size(1100, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: OutputZonePanel(audioService: svc)),
        ),
      );
      await tester.pumpAndSettle();

      // Should match WASAPI Exclusive capability for OS default, NOT WASAPI Shared!
      expect(
        find.textContaining('跟隨 Windows 預設 · FiiO Q series USB DAC (WASAPI Exclusive)'),
        findsOneWidget,
      );
      expect(find.text('BIT-PERFECT'), findsOneWidget);

      await tester.tap(
        find.byKey(const Key('btn_device_settings_system_output')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('device_settings_dialog')), findsOneWidget);
      expect(
        find.byKey(const Key('switch_device_strict_bit_perfect')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('shared_not_bit_perfect_notice')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'Per-device Settings dialog enforces real capabilities and WASAPI Shared never displays BIT-PERFECT',
    (tester) async {
      final svc = _TestOutputMockAudioService(
        scriptedCaps: _sampleHardwareMatrix(),
      );
      await svc.selectAudioDevice('usb-dac-1', backendIndex: 1);
      addTearDown(svc.dispose);

      tester.view.physicalSize = const Size(1100, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: OutputZonePanel(audioService: svc)),
        ),
      );
      await tester.pumpAndSettle();

      // Open settings for WASAPI Exclusive USB DAC
      await tester.tap(
        find.byKey(
          const Key('btn_device_settings_usb-dac-1__windows_wasapi_exclusive'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('device_settings_dialog')), findsOneWidget);

      // Real sample rates & buffer choices are shown, Native DSD is NOT shown for WASAPI DAC
      expect(find.text('384 kHz'), findsOneWidget);
      expect(find.text('Native DSD'), findsNothing);
      expect(find.byKey(const Key('btn_buffer_frames_512')), findsOneWidget);

      // Enable Strict Bit-Perfect -> locks SW volume to 100% Unity
      final strictSwitch = find.byKey(
        const Key('switch_device_strict_bit_perfect'),
      );
      await tester.ensureVisible(strictSwitch);
      await tester.tap(strictSwitch);
      await tester.pumpAndSettle();
      expect(svc.isStrictBitPerfect, isTrue);
      expect(find.byKey(const Key('volume_rule_unity_locked')), findsOneWidget);

      // Toggle Exclusive Mode OFF -> switches to WASAPI Shared sibling & never displays BIT-PERFECT
      final exclSwitch = find.byKey(const Key('switch_device_exclusive_mode'));
      await tester.ensureVisible(exclSwitch);
      await tester.tap(exclSwitch);
      await tester.pumpAndSettle();

      expect(svc.lastSelectedBackendIndex, 2);
      expect(
        find.byKey(const Key('shared_not_bit_perfect_notice')),
        findsOneWidget,
      );
      expect(find.text('BIT-PERFECT'), findsNothing);
      // Buffer choices must NOT be fabricated on WASAPI Shared
      expect(find.byKey(const Key('btn_buffer_frames_512')), findsNothing);
    },
  );

  test(
    'FfiAudioService real backend integration: System Output, device selection, buffer frames & error surfacing',
    () async {
      final tempDir = Directory.systemTemp.createTempSync('lumina_zone_redesign_');
      final dbPath = '${tempDir.path}${Platform.pathSeparator}zone_redesign.db';
      final svc = FfiAudioService(headless: true, databasePath: dbPath);
      try {
        final caps = await svc.listDeviceCapabilities();
        expect(caps, isNotEmpty);

        // Selecting nonexistent device surfaces exact error and never clears active state
        await svc.selectAudioDevice('definitely-nonexistent-device-id');
        expect(svc.lastError, isNotNull);
        expect(svc.lastError!, contains('definitely-nonexistent-device-id'));

        // Selecting System Output succeeds cleanly
        await svc.selectAudioDevice(null);
        expect(svc.lastError, isNull);
        expect(svc.isSystemOutputActive, isTrue);

        // Selecting real/virtual device & setting buffer frames updates output info
        await svc.selectAudioDevice(caps.first.deviceId);
        expect(svc.lastError, isNull);
        expect(svc.isSystemOutputActive, isFalse);

        final okBuf = await svc.setBufferFrames(1024);
        expect(okBuf, isTrue);
        final info = await svc.getOutputInfo();
        expect(info.output.bufferSizeFrames, 1024);

        // Mid-playback device reroute preserves active playing stream without wiping track
        await svc.play();
        expect(svc.currentState.status, PlaybackStatus.playing);
        await svc.selectAudioDevice(null);
        expect(svc.lastError, isNull);
        expect(svc.currentState.status, PlaybackStatus.playing);
        expect(svc.currentState.track, isNotNull);
        await svc.stop();
      } finally {
        svc.dispose();
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    },
  );
}

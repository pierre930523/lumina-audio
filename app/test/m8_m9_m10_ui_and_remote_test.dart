import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/main.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/ffi_audio_service.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/server_audio_service.dart';
import 'package:lumina_app/ui/albums/album_detail_page.dart';
import 'package:material_ui/material_ui.dart';

Uint8List _buildMockDnsSdAnnouncement({
  required String hostname,
  required int port,
  String ipv4 = '127.0.0.1',
}) {
  final out = BytesBuilder();
  void addName(String name) {
    for (final l in name.split('.').where((s) => s.isNotEmpty)) {
      final b = utf8.encode(l);
      out.addByte(b.length);
      out.add(b);
    }
    out.addByte(0);
  }

  void addRrHdr(String name, int type, int rdLen) {
    addName(name);
    final bd = ByteData(10);
    bd.setUint16(0, type);
    bd.setUint16(2, 1);
    bd.setUint32(4, 120);
    bd.setUint16(8, rdLen);
    out.add(bd.buffer.asUint8List());
  }

  // Header: ANCOUNT = 4
  out.add([0, 0, 0x84, 0, 0, 0, 0, 4, 0, 0, 0, 0]);
  final inst = '$hostname._lumina._tcp.local.';
  final fqdn = '$hostname.local.';

  // 1. PTR
  final ptrData = BytesBuilder();
  for (final l in inst.split('.').where((s) => s.isNotEmpty)) {
    final b = utf8.encode(l);
    ptrData.addByte(b.length);
    ptrData.add(b);
  }
  ptrData.addByte(0);
  final ptrBytes = ptrData.toBytes();
  addRrHdr('_lumina._tcp.local.', 12, ptrBytes.length);
  out.add(ptrBytes);

  // 2. SRV
  final srvData = BytesBuilder();
  final srvHdr = ByteData(6)..setUint16(4, port);
  srvData.add(srvHdr.buffer.asUint8List());
  for (final l in fqdn.split('.').where((s) => s.isNotEmpty)) {
    final b = utf8.encode(l);
    srvData.addByte(b.length);
    srvData.add(b);
  }
  srvData.addByte(0);
  final srvBytes = srvData.toBytes();
  addRrHdr(inst, 33, srvBytes.length);
  out.add(srvBytes);

  // 3. TXT
  final txtEntry = utf8.encode('server_name=$hostname');
  addRrHdr(inst, 16, txtEntry.length + 1);
  out.addByte(txtEntry.length);
  out.add(txtEntry);

  // 4. A
  addRrHdr(fqdn, 1, 4);
  out.add(InternetAddress(ipv4).rawAddress);

  return out.toBytes();
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _enterVisibleText(
  WidgetTester tester,
  Finder finder,
  String text,
) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.enterText(finder, text);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'Desktop UI: Albums/Versions switcher, Credits Graph, DSP panel, Zones, Providers, Remote & Profiles',
    (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final service = MockAudioService();
      addTearDown(service.dispose);

      await tester.pumpWidget(LuminaApp(audioService: service));
      await tester.pumpAndSettle();

      // 1. Profile Switcher dialog create & switch
      await tester.tap(find.byKey(const Key('btn_profile_switcher')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('input_new_profile_name')),
        'Late Night',
      );
      await tester.tap(find.byKey(const Key('btn_create_profile')));
      await tester.pumpAndSettle();
      expect((await service.listProfiles()).any((p) => p.name == 'Late Night'), isTrue);
      // Dismiss dialog
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      // 2. Albums Grid, Canonical Album detail & Versions switcher
      await tester.tap(find.byKey(const Key('nav_tab_albums')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('album_grid_view')), findsOneWidget);

      await _tapVisible(tester, find.byKey(const Key('btn_deduplicate_albums')));
      expect(find.textContaining('已合併'), findsOneWidget);

      await _tapVisible(tester, find.byKey(const Key('btn_enrich_credits')));

      await _tapVisible(tester, find.byKey(const Key('album_card_alb-dsotm')));
      expect(find.byType(AlbumDetailPage), findsOneWidget);
      expect(find.byKey(const Key('album_detail_back_btn')), findsNothing);
      expect(
        find.descendant(
          of: find.byType(AlbumDetailPage),
          matching: find.text('The Dark Side of the Moon'),
        ),
        findsOneWidget,
      );

      // Navigate back via HomeScreen top bar and forward again
      await _tapVisible(tester, find.byKey(const Key('btn_nav_back')));
      expect(find.byKey(const Key('album_grid_view')), findsOneWidget);
      await _tapVisible(tester, find.byKey(const Key('btn_nav_forward')));
      expect(find.byType(AlbumDetailPage), findsOneWidget);

      await _tapVisible(tester, find.byKey(const Key('version_chip_local')));
      expect(find.text('目前採用版本：SACD DSD64 Rip'), findsOneWidget);

      // Open Credits Graph via contributor chip
      await _tapVisible(tester, find.byKey(const Key('detail_credit_art-ap')));
      expect(find.byKey(const Key('credits_graph_view')), findsOneWidget);
      expect(find.text('Alan Parsons'), findsWidgets);

      // 3. Open Advanced Settings Hub -> DSP Control Panel (10-band PEQ, AutoEQ import, Crossfeed, ReplayGain)
      await tester.tap(find.byKey(const Key('btn_open_settings_hub')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nav_tab_dsp')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('dsp_control_panel')), findsOneWidget);
      expect(find.byKey(const Key('peq_band_0')), findsOneWidget);
      expect(find.byKey(const Key('peq_band_9')), findsOneWidget);

      await _enterVisibleText(
        tester,
        find.byKey(const Key('autoeq_import_input')),
        'Preamp: -4.0 dB\nFilter 1: ON PK Fc 120 Hz Gain 3.5 dB Q 0.71\n',
      );
      await _tapVisible(tester, find.byKey(const Key('btn_import_autoeq')));
      expect(find.textContaining('已匯入 1 組 AutoEQ'), findsOneWidget);

      await _tapVisible(tester, find.byKey(const Key('switch_crossfeed')));
      await _tapVisible(tester, find.byKey(const Key('btn_apply_dsp')));
      final dsp = await service.getDspConfig();
      expect(dsp.crossfeedEnabled, isFalse);

      // 4. Output Devices & Multi-Room Zones UI
      await tester.tap(find.byKey(const Key('nav_tab_zones')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('output_devices_grid')), findsOneWidget);
      expect(find.byKey(const Key('output_card_system_output')), findsOneWidget);
      expect(find.byKey(const Key('btn_refresh_audio_devices')), findsOneWidget);
      await _tapVisible(tester, find.byKey(const Key('btn_discover_zones')));
      expect(find.textContaining('Bedroom AirPlay Receiver'), findsOneWidget);
      await _tapVisible(tester, find.byKey(const Key('btn_group_zones')));
      await _tapVisible(tester, find.byKey(const Key('btn_sync_zones')));

      // 5. Providers & Remote Pairing UI
      await tester.tap(find.byKey(const Key('nav_tab_settings')));
      await tester.pumpAndSettle();

      await _tapVisible(
        tester,
        find.byKey(const Key('provider_row_apple_music')),
      );
      await _enterVisibleText(
        tester,
        find.byKey(const Key('input_apple_music_token')),
        'am_test_tok_123',
      );
      await _tapVisible(tester, find.byKey(const Key('btn_save_apple_music')));
      expect(find.byKey(const Key('btn_logout_apple_music')), findsOneWidget);
      expect(find.byKey(const Key('nav_streaming_apple_music')), findsOneWidget);

      await _tapVisible(
        tester,
        find.byKey(const Key('provider_row_youtube_music')),
      );
      await _enterVisibleText(
        tester,
        find.byKey(const Key('input_youtube_music_token')),
        'ytm_test_tok_123',
      );
      await _tapVisible(
        tester,
        find.byKey(const Key('btn_save_youtube_music')),
      );
      expect(
        find.byKey(const Key('btn_logout_youtube_music')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('nav_streaming_youtube_music')),
        findsOneWidget,
      );

      // Click logged-in Apple Music sidebar entry, sync catalog, then log out
      await tester.tap(find.byKey(const Key('nav_streaming_apple_music')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('streaming_service_view_apple_music')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('btn_sync_streaming_provider')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('streaming_track_am-001')), findsOneWidget);
      await tester.tap(find.byKey(const Key('btn_streaming_open_settings')));
      await tester.pumpAndSettle();
      await _tapVisible(tester, find.byKey(const Key('btn_logout_apple_music')));
      expect(find.byKey(const Key('nav_streaming_apple_music')), findsNothing);
      expect(
        find.byKey(const Key('nav_streaming_youtube_music')),
        findsOneWidget,
      );

      await _tapVisible(tester, find.byKey(const Key('provider_row_qobuz')));
      await _enterVisibleText(
        tester,
        find.byKey(const Key('input_qobuz_token')),
        'qb_test_tok_123',
      );
      await _tapVisible(tester, find.byKey(const Key('btn_save_qobuz')));

      await _tapVisible(tester, find.byKey(const Key('provider_row_tidal')));
      await _tapVisible(tester, find.byKey(const Key('btn_tidal_pkce_start')));
      await _enterVisibleText(
        tester,
        find.byKey(const Key('input_tidal_code')),
        'auth_code_xyz',
      );
      await _tapVisible(tester, find.byKey(const Key('btn_tidal_pkce_complete')));

      await _tapVisible(tester, find.byKey(const Key('provider_row_deezer')));
      await _enterVisibleText(
        tester,
        find.byKey(const Key('input_deezer_arl')),
        'arl_cookie_sample',
      );
      await _tapVisible(tester, find.byKey(const Key('btn_save_deezer')));

      await _tapVisible(tester, find.byKey(const Key('provider_row_web_dav')));
      await _enterVisibleText(
        tester,
        find.byKey(const Key('input_webdav_uri')),
        'http://127.0.0.1:8080/dav',
      );
      await _tapVisible(tester, find.byKey(const Key('btn_save_webdav')));

      await _tapVisible(tester, find.byKey(const Key('provider_row_smb')));
      await _enterVisibleText(
        tester,
        find.byKey(const Key('input_smb_uri')),
        'smb://user:pass@127.0.0.1/music',
      );
      await _tapVisible(tester, find.byKey(const Key('btn_save_smb')));

      await _tapVisible(
        tester,
        find.byKey(const Key('row_remote_pairing_toggle')),
      );
      await _tapVisible(tester, find.byKey(const Key('btn_generate_host_pin')));
      expect(find.byKey(const Key('host_pairing_qr_text')), findsOneWidget);

      await _tapVisible(tester, find.byKey(const Key('btn_discover_lan_servers')));
      await _enterVisibleText(
        tester,
        find.byKey(const Key('input_remote_pin')),
        '849201',
      );
      await _tapVisible(tester, find.byKey(const Key('btn_pair_remote')));
      expect(service.connectionMode, ConnectionMode.lanRemote);

      await _tapVisible(tester, find.byKey(const Key('btn_switch_local_mode')));
      expect(service.connectionMode, ConnectionMode.localOrUsbDac);
    },
  );

  test('Phase 3 MdnsDiscoveryClient parses loopback _lumina._tcp.local. response', () async {
    final mockSock = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(mockSock.close);
    mockSock.listen((event) {
      if (event == RawSocketEvent.read) {
        while (true) {
          final dg = mockSock.receive();
          if (dg == null) break;
          final pkt = _buildMockDnsSdAnnouncement(
            hostname: 'Studio-Core',
            port: 9912,
          );
          final sent = mockSock.send(pkt, dg.address, dg.port);
          if (sent == 0) {
            Future<void>.delayed(const Duration(milliseconds: 10), () {
              try {
                mockSock.send(pkt, dg.address, dg.port);
              } catch (_) {}
            });
          }
        }
      }
    });

    final servers = await MdnsDiscoveryClient.discover(
      targetHost: '127.0.0.1',
      port: mockSock.port,
      timeout: const Duration(milliseconds: 500),
    );
    expect(servers.length, 1);
    expect(servers.first.serverName, 'Studio-Core');
    expect(servers.first.port, 9912);
    expect(servers.first.httpBaseUrl, 'http://127.0.0.1:9912');

    final parsedQr = MdnsDiscoveryClient.parsePairingQrUri(
      'lumina://pair?pin=123456&host=192.168.1.50&port=9888',
    );
    expect(parsedQr, isNotNull);
    expect(parsedQr!.pin, '123456');
    expect(parsedQr.port, 9888);
  });

  test('Live ServerAudioService pairs via PIN, syncs WebSocket & controls embedded Rust FFI server', () async {
    final tempDir = Directory.systemTemp.createTempSync('lumina_remote_e2e_');
    final dbPath = '${tempDir.path}${Platform.pathSeparator}remote_test.db';
    final hostFfi = FfiAudioService(headless: true, databasePath: dbPath);

    try {
      expect(hostFfi.isNativeBound, isTrue);

      // Start embedded Rust Axum HTTP + WS server & generate host PIN/QR
      final pairInfo = await hostFfi.initiateHostPairing();
      expect(pairInfo, isNotNull);
      final parsedQr = MdnsDiscoveryClient.parsePairingQrUri(pairInfo!.qrPayload);
      expect(parsedQr, isNotNull);

      final remote = ServerAudioService(baseUrl: 'http://${parsedQr!.host}:${parsedQr.port}');
      addTearDown(remote.dispose);

      expect(await remote.checkHealth(), isTrue);
      final token = await remote.pairAndConnectRemote(
        baseUrl: 'http://${parsedQr.host}:${parsedQr.port}',
        pin: parsedQr.pin,
      );
      expect(token, isNotNull);
      expect(token!.startsWith('lum_sec_'), isTrue);

      // Verify WebSocket live event sync & REST control against real core-server
      final events = <PlaybackStatus>[];
      final sub = remote.stateStream.listen((st) => events.add(st.status));
      addTearDown(sub.cancel);

      await remote.play(
        track: TrackInfo(
          id: 'trk-remote-1',
          title: 'Shine On',
          artist: 'Pink Floyd',
          album: 'Wish You Were Here',
          duration: const Duration(minutes: 5),
          format: const AudioFormat(
            codec: AudioCodec.flac,
            sampleRateHz: 96000,
            bitDepth: 24,
            channels: 2,
          ),
          providerName: 'Qobuz',
        ),
      );
      await remote.pause();
      await remote.setVolume(0.45);

      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(events, containsAll([PlaybackStatus.playing, PlaybackStatus.paused]));
      expect(remote.currentState.volume, closeTo(0.45, 0.02));

      // Verify remote profiles, devices, zones & DSP endpoints through ServerAudioService
      final prof = await remote.createProfile('Mobile Remote User');
      expect(prof.name, 'Mobile Remote User');
      final devs = await remote.listAudioDevices();
      expect(devs, isNotEmpty);
      final zones = await remote.discoverZones();
      expect(zones, isNotEmpty);
      final bands = await remote.importAutoEqProfile(
        'Preamp: -2.0 dB\nFilter 1: ON PK Fc 500 Hz Gain 2.0 dB Q 1.0\n',
      );
      expect(bands.length, 1);
    } finally {
      hostFfi.dispose();
      try {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      } catch (_) {}
    }
  });
}

part of '../server_audio_service.dart';

class MdnsDiscoveryClient {
  static Uint8List buildPtrQueryPacket({
    String serviceType = '_lumina._tcp.local.',
  }) {
    final builder = BytesBuilder();
    // DNS Header: ID=0, Flags=0, QD=1, AN=0, NS=0, AR=0
    builder.add([0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
    for (final label in serviceType.split('.').where((l) => l.isNotEmpty)) {
      final bytes = utf8.encode(label);
      builder.addByte(bytes.length);
      builder.add(bytes);
    }
    builder.addByte(0);
    // QTYPE = PTR (12), QCLASS = IN (1)
    builder.add([0, 12, 0, 1]);
    return builder.toBytes();
  }

  static (String, int) _decodeDnsName(Uint8List pkt, int offset) {
    final labels = <String>[];
    var pos = offset;
    var origNext = offset;
    var jumped = false;
    final seen = <int>{};

    while (pos < pkt.length) {
      if (!seen.add(pos)) break;
      final len = pkt[pos];
      if (len == 0) {
        if (!jumped) origNext = pos + 1;
        break;
      }
      if ((len & 0xC0) == 0xC0 && pos + 1 < pkt.length) {
        final ptr = ((len & 0x3F) << 8) | pkt[pos + 1];
        if (!jumped) origNext = pos + 2;
        jumped = true;
        pos = ptr;
        continue;
      }
      pos += 1;
      if (pos + len > pkt.length) break;
      labels.add(utf8.decode(pkt.sublist(pos, pos + len), allowMalformed: true));
      pos += len;
    }
    return ('${labels.join('.')}.', origNext);
  }

  static DiscoveredServerInfo? parseDnsSdResponsePacket(Uint8List pkt) {
    if (pkt.length < 12) return null;
    final qdCount = (pkt[4] << 8) | pkt[5];
    final anCount = (pkt[6] << 8) | pkt[7];
    final nsCount = (pkt[8] << 8) | pkt[9];
    final arCount = (pkt[10] << 8) | pkt[11];

    var pos = 12;
    for (var i = 0; i < qdCount && pos < pkt.length; i++) {
      final (_, nextPos) = _decodeDnsName(pkt, pos);
      pos = nextPos + 4;
    }

    String? serverName;
    String? ipv4;
    int port = 9888;
    final txt = <String, String>{};

    final totalRr = anCount + nsCount + arCount;
    for (var i = 0; i < totalRr && pos + 10 <= pkt.length; i++) {
      final (rrName, afterName) = _decodeDnsName(pkt, pos);
      if (afterName + 10 > pkt.length) break;
      final bd = ByteData.sublistView(pkt, afterName, afterName + 10);
      final rtype = bd.getUint16(0);
      final rdLen = bd.getUint16(8);
      final rdataStart = afterName + 10;
      if (rdataStart + rdLen > pkt.length) break;

      if (rtype == 12) {
        final (target, _) = _decodeDnsName(pkt, rdataStart);
        serverName ??= target.split('.').first;
      } else if (rtype == 33 && rdLen >= 6) {
        final srvBd = ByteData.sublistView(pkt, rdataStart, rdataStart + 6);
        port = srvBd.getUint16(4);
        serverName ??= rrName.split('.').first;
      } else if (rtype == 16) {
        var tpos = rdataStart;
        final end = rdataStart + rdLen;
        while (tpos < end) {
          final slen = pkt[tpos];
          tpos += 1;
          if (tpos + slen > end) break;
          final entry = utf8.decode(
            pkt.sublist(tpos, tpos + slen),
            allowMalformed: true,
          );
          tpos += slen;
          final eq = entry.indexOf('=');
          if (eq > 0) {
            txt[entry.substring(0, eq)] = entry.substring(eq + 1);
          }
        }
      } else if (rtype == 1 && rdLen == 4) {
        ipv4 =
            '${pkt[rdataStart]}.${pkt[rdataStart + 1]}.${pkt[rdataStart + 2]}.${pkt[rdataStart + 3]}';
      }
      pos = rdataStart + rdLen;
    }

    if (ipv4 == null && txt.isEmpty) return null;
    return DiscoveredServerInfo(
      serverName: txt['server_name'] ?? serverName ?? 'Lumina-Desktop',
      host: ipv4 ?? '127.0.0.1',
      port: port,
      txtRecords: txt,
    );
  }

  static Future<List<DiscoveredServerInfo>> discover({
    String targetHost = '224.0.0.251',
    int port = 5353,
    Duration timeout = const Duration(milliseconds: 500),
  }) async {
    final bindAddr = targetHost == '127.0.0.1'
        ? InternetAddress.loopbackIPv4
        : InternetAddress.anyIPv4;
    final socket = await RawDatagramSocket.bind(bindAddr, 0);
    final found = <String, DiscoveredServerInfo>{};
    final completer = Completer<void>();
    final queryPkt = buildPtrQueryPacket();
    final targetAddr = InternetAddress.tryParse(targetHost) ??
        InternetAddress('127.0.0.1');
    Timer? retryTimer;

    void finishDiscovery() {
      retryTimer?.cancel();
      if (!completer.isCompleted) {
        completer.complete();
      }
    }

    late final StreamSubscription<RawSocketEvent> sub;
    sub = socket.listen((event) {
      if (event == RawSocketEvent.write) {
        try {
          socket.send(queryPkt, targetAddr, port);
        } catch (_) {}
        socket.writeEventsEnabled = false;
      }
      if (event == RawSocketEvent.read) {
        while (true) {
          final dg = socket.receive();
          if (dg == null) break;
          final parsed = parseDnsSdResponsePacket(dg.data);
          if (parsed != null) {
            found['${parsed.host}:${parsed.port}'] = parsed;
            if (targetHost == '127.0.0.1') {
              finishDiscovery();
            }
          }
        }
      }
    });

    try {
      socket.send(queryPkt, targetAddr, port);
    } catch (_) {}

    retryTimer = Timer.periodic(const Duration(milliseconds: 40), (_) {
      if (found.isNotEmpty || completer.isCompleted) {
        retryTimer?.cancel();
        return;
      }
      try {
        socket.send(queryPkt, targetAddr, port);
      } catch (_) {}
    });

    Timer(timeout, finishDiscovery);

    await completer.future;
    retryTimer.cancel();
    await sub.cancel();
    socket.close();
    return found.values.toList();
  }

  static ({String host, int port, String pin})? parsePairingQrUri(String uri) {
    final parsed = Uri.tryParse(uri.trim());
    if (parsed == null || parsed.scheme != 'lumina') return null;
    final pin = parsed.queryParameters['pin'] ?? '';
    final host = parsed.queryParameters['host'] ?? '';
    final port = int.tryParse(parsed.queryParameters['port'] ?? '') ?? 9888;
    if (pin.length != 6 || host.isEmpty) return null;
    return (host: host, port: port, pin: pin);
  }
}

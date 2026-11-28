import 'package:material_ui/material_ui.dart';

import '../../models/audio_output_info.dart';
import '../theme/lumina_tokens.dart';

class SignalPathTelemetrySection extends StatelessWidget {
  final AudioEngineOutputInfoModel outputInfo;
  final Color statusColor;
  final bool showDetails;
  final VoidCallback onToggleDetails;

  const SignalPathTelemetrySection({
    super.key,
    required this.outputInfo,
    required this.statusColor,
    required this.showDetails,
    required this.onToggleDetails,
  });

  @override
  Widget build(BuildContext context) {
    final ver = outputInfo.verification;
    final out = outputInfo.output;
    final src = outputInfo.source;
    final dec = outputInfo.decoder;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          button: true,
          toggled: showDetails,
          label: '展開或收合輸出資訊面板',
          child: InkWell(
            key: const Key('toggle_phase10_panel'),
            onTap: onToggleDetails,
            mouseCursor: SystemMouseCursors.click,
            hoverColor: LuminaTokens.glassRowHoverBg,
            focusColor: LuminaTokens.focusRing.withValues(alpha: 0.22),
            borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
              child: Row(
                children: [
                  Icon(
                    showDetails
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    color: LuminaTokens.textSecondary,
                    size: 18,
                  ),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Text(
                      'OUTPUT INFORMATION PANEL (PHASE 10 TELEMETRY)',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: LuminaTokens.textSecondary,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (showDetails) ...[
          const SizedBox(height: LuminaTokens.space2xs + 2),
          Container(
            key: const Key('phase10_output_info_panel'),
            width: double.infinity,
            padding: const EdgeInsets.all(LuminaTokens.spaceSm),
            decoration: BoxDecoration(
              color: LuminaTokens.glassCardBg,
              borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
              border: Border.all(color: LuminaTokens.glassCardBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSectionHeader('SOURCE'),
                _buildKvRow(
                  'Codec / Format',
                  '${src.codec} · ${src.sourceFormat}',
                ),
                _buildKvRow(
                  'Rate / Bit Depth / Ch',
                  '${src.sampleRateHz} Hz · ${src.bitDepth}-bit · ${src.channels}ch (${src.channelLayout})',
                ),
                const Divider(
                  color: LuminaTokens.glassCardDivider,
                  height: 14,
                ),
                _buildSectionHeader('DECODER'),
                _buildKvRow('Decoder Type', dec.decoderType),
                _buildKvRow(
                  'PCM / Bit Preservation',
                  '${dec.decodedPcmFormat} · ${dec.sampleRateHz} Hz · valid ${dec.validBits}/${dec.containerBits}-bit${dec.integerPreserved ? ' (Integer Preserved)' : ''}',
                ),
                const Divider(
                  color: LuminaTokens.glassCardDivider,
                  height: 14,
                ),
                _buildSectionHeader('OUTPUT'),
                _buildKvRow(
                  'Device / Transport',
                  '${out.selectedDevice} (${out.transportKind})',
                ),
                _buildKvRow(
                  'Audio API / Mode',
                  '${out.audioApi} · ${out.outputMode}',
                ),
                _buildKvRow(
                  'Rate / Container / Ch / Buf',
                  '${out.sampleRateHz} Hz · ${out.validBits}/${out.containerBits}-bit · ${out.channels}ch · ${out.bufferSizeFrames} frames',
                ),
                _buildKvRow(
                  'DSP / SW Volume',
                  '${out.dspStatus} · ${out.softwareVolumeStatus}',
                ),
                const Divider(
                  color: LuminaTokens.glassCardDivider,
                  height: 14,
                ),
                _buildSectionHeader('VERIFICATION'),
                _buildKvRow(
                  'Bit-Perfect Status',
                  ver.status,
                  highlight: statusColor,
                ),
                _buildKvRow('PCM Sample Check', ver.pcmSampleCheck),
                _buildKvRow(
                  'Format Match',
                  ver.formatMatch ? 'EXACT MATCH' : 'MODIFIED / MISMATCH',
                ),
                _buildKvRow('Output Path', ver.outputPath),
                if (ver.decoderSha256.isNotEmpty ||
                    ver.backendInputSha256.isNotEmpty)
                  _buildKvRow(
                    'SHA-256 (Dec / Proc / Out)',
                    '${ver.decoderSha256} / ${ver.processingSha256} / ${ver.backendInputSha256}',
                  ),
                _buildKvRow('Verification Level', ver.verificationLevel),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: LuminaTokens.space2xs),
      child: Text(
        title,
        style: const TextStyle(
          color: LuminaTokens.glassTextSecondary,
          fontSize: 10.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.0,
        ),
      ),
    );
  }

  Widget _buildKvRow(String label, String value, {Color? highlight}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 146,
            child: Text(
              label,
              style: const TextStyle(
                color: LuminaTokens.textMuted,
                fontSize: 11,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '—' : value,
              style: TextStyle(
                color: highlight ?? LuminaTokens.textPrimary,
                fontSize: 11,
                fontWeight: highlight != null ? FontWeight.w700 : FontWeight.w500,
                fontFamily: label.startsWith('SHA-256') ? 'monospace' : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

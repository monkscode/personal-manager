import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/app_controller.dart';
import '../../widgets/ui.dart';
import 'sheet_scaffold.dart';

Future<void> showAiSettingsSheet(BuildContext context, WidgetRef ref) {
  return showAppSheet(context, (_) => const _AiSettingsSheet());
}

class _AiSettingsSheet extends ConsumerStatefulWidget {
  const _AiSettingsSheet();

  @override
  ConsumerState<_AiSettingsSheet> createState() => _AiSettingsSheetState();
}

class _AiSettingsSheetState extends ConsumerState<_AiSettingsSheet> {
  late final TextEditingController _key;
  late final TextEditingController _model;
  late final TextEditingController _endpoint;
  late final TextEditingController _sa;
  late final TextEditingController _region;

  @override
  void initState() {
    super.initState();
    final s = ref.read(appControllerProvider);
    _key = TextEditingController(text: s.aiApiKey);
    _model = TextEditingController(text: s.aiModel);
    _endpoint = TextEditingController(text: s.aiEndpoint);
    _sa = TextEditingController(text: s.aiServiceAccount);
    _region = TextEditingController(text: s.aiRegion);
  }

  @override
  void dispose() {
    _key.dispose();
    _model.dispose();
    _endpoint.dispose();
    _sa.dispose();
    _region.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final ctrl = ref.read(appControllerProvider.notifier);
    return SheetScaffold(
      title: 'AI extraction (optional)',
      subtitle:
          'Paste your Gemini/Vertex API key to use AI for reading bills instead of the on-device rules. '
          'With AI on, email text is sent to Google to extract bills, and usage is billed to your account.',
      children: [
        const FieldLabel('API key'),
        AppTextField(controller: _key, hint: 'AIza… / your Vertex key', fillAlt: true, onChanged: ctrl.setAiApiKey),
        const SizedBox(height: 14),
        const FieldLabel('Model'),
        AppTextField(controller: _model, hint: 'gemini-2.5-flash', fillAlt: true, onChanged: ctrl.setAiModel),
        const SizedBox(height: 14),
        const FieldLabel('Endpoint (advanced — change only for Vertex hosts)'),
        AppTextField(controller: _endpoint, hint: 'https://generativelanguage.googleapis.com/v1beta', fillAlt: true, onChanged: ctrl.setAiEndpoint),
        const SizedBox(height: 18),
        Container(height: 1, color: p.border),
        const SizedBox(height: 14),
        Text('Or: Vertex service account', style: jakarta(size: 13, weight: FontWeight.w700, color: p.textPrimary)),
        const SizedBox(height: 4),
        Text('Paste your credentials.json contents to use Vertex AI. Takes priority over the API key above.',
            style: jakarta(size: 12, weight: FontWeight.w500, height: 1.5, color: p.textTertiary)),
        const SizedBox(height: 10),
        const FieldLabel('Service account JSON (credentials.json)'),
        TextField(
          controller: _sa,
          onChanged: ctrl.setAiServiceAccount,
          maxLines: 4,
          style: jakarta(size: 12, weight: FontWeight.w500, color: p.textPrimary),
          decoration: InputDecoration(
            hintText: '{ "type": "service_account", "project_id": "...", ... }',
            hintStyle: jakarta(size: 12, weight: FontWeight.w500, color: p.textTertiary),
            filled: true,
            fillColor: p.surfaceAlt,
            contentPadding: const EdgeInsets.all(12),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: p.border)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: AppColors.teal)),
          ),
        ),
        const SizedBox(height: 12),
        const FieldLabel('Vertex region'),
        AppTextField(controller: _region, hint: 'us-central1', fillAlt: true, onChanged: ctrl.setAiRegion),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: p.surfaceAlt, borderRadius: BorderRadius.circular(12)),
          child: Text(
            'Leave the key empty to keep everything on-device (free, private). If an AI call fails, the app falls back to the on-device parser automatically.',
            style: jakarta(size: 12, weight: FontWeight.w500, height: 1.5, color: p.textSecondary),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: GestureDetector(
                onTap: () {
                  ctrl.setAiApiKey('');
                  ctrl.setAiServiceAccount('');
                  _key.clear();
                  _sa.clear();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: p.borderStrong)),
                  child: Center(child: Text('Turn off', style: jakarta(size: 13, weight: FontWeight.w700, color: p.textSecondary))),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(child: PrimaryButton(label: 'Done', height: 46, radius: 12, onTap: () => Navigator.of(context).pop())),
          ],
        ),
      ],
    );
  }
}

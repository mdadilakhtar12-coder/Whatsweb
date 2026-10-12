import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_docs.dart';
import 'api_screen.dart' show apiBaseUrl;

/// The API documentation: every address with an example request and answer (the same text as docs/API.md).
class ApiDocsScreen extends StatelessWidget {
  const ApiDocsScreen({super.key});

  static String curl(ApiEndpoint e, String base) {
    final url = '$base${e.path}';
    if (e.body == null) return 'curl -H "Authorization: Bearer \$API_KEY" "$url"';
    final compact = e.body!.replaceAll(RegExp(r'\s*\n\s*'), ' ');
    return 'curl -X ${e.method} -H "Authorization: Bearer \$API_KEY" -H "Content-Type: application/json" \\\n  -d \'$compact\' "$url"';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    String fill(String s) => s.replaceAll('{base}', apiBaseUrl);
    return Scaffold(
      appBar: AppBar(title: const Text('API documentation')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          for (final g in apiGeneralDocs) _text(context, g.$1, fill(g.$2)),
          Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 4),
            child: Text('Endpoints', style: Theme.of(context).textTheme.titleMedium),
          ),
          for (final e in apiEndpoints)
            Card(
              margin: const EdgeInsets.symmetric(vertical: 4),
              child: Theme(
                data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: const EdgeInsets.symmetric(horizontal: 14),
                  childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  title: Row(
                    children: [
                      _Method(e.method),
                      const SizedBox(width: 8),
                      Expanded(child: Text(e.path, style: const TextStyle(fontFamily: 'monospace', fontSize: 13, fontWeight: FontWeight.w600))),
                    ],
                  ),
                  subtitle: Text(e.title),
                  children: [
                    Text(e.about, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
                    if (e.params.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text('Query parameters', style: Theme.of(context).textTheme.labelLarge),
                      for (final p in e.params)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text.rich(TextSpan(children: [
                            TextSpan(text: p.$1, style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600)),
                            TextSpan(text: '  ${p.$2}'),
                          ]), style: const TextStyle(fontSize: 13)),
                        ),
                    ],
                    const SizedBox(height: 10),
                    _Code(title: 'Example request', text: curl(e, apiBaseUrl)),
                    const SizedBox(height: 8),
                    _Code(title: 'Example answer', text: e.response),
                  ],
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 4),
            child: Text('Outgoing webhooks', style: Theme.of(context).textTheme.titleMedium),
          ),
          for (final w in apiWebhookDocs) _text(context, w.$1, fill(w.$2)),
        ],
      ),
    );
  }

  Widget _text(BuildContext context, String title, String body) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(top: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            const SizedBox(height: 6),
            SelectableText(body, style: TextStyle(fontSize: 13, color: scheme.onSurface)),
          ],
        ),
      ),
    );
  }
}

class _Method extends StatelessWidget {
  final String method;

  const _Method(this.method);

  @override
  Widget build(BuildContext context) {
    final color = switch (method) {
      'GET' => Colors.green.shade700,
      'POST' => Colors.blue.shade700,
      _ => Colors.orange.shade800,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(6)),
      child: Text(method, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12)),
    );
  }
}

class _Code extends StatelessWidget {
  final String title;
  final String text;

  const _Code({required this.title, required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(title, style: Theme.of(context).textTheme.labelLarge)),
            IconButton(
              tooltip: 'Copy',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: text));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
              },
            ),
          ],
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: scheme.surfaceContainerHighest.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(8)),
          child: SelectableText(text, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ),
      ],
    );
  }
}
